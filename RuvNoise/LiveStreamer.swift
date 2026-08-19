import AVFoundation
import Foundation

// MARK: - Frame Assembler
//
// Turns a continuous HTTP audio byte stream (ICEcast / SHOUTcast / plain MP3 or
// ADTS-AAC over HTTP) into ~1.5 s chunks of complete, frame-synced frames, which
// are then decoded with AVAudioFile — the same path HLSStreamer uses for segments.
//
// IMPORTANT: never use Data.removeFirst(_:) here — on macOS 26 Foundation it
// leaves a stale startIndex (e.g. 321 after removeFirst(321)) so later Data
// subscript reads (d[0]) trap with SIGTRAP. removeSubrange / dropFirst / a
// fresh copy all behave correctly. (Verified on macOS 26.5.2.)

struct LiveFrameAssembler {
    enum Codec: String {
        case aac
        case mp3
        case unknown
    }

    private(set) var codec: Codec = .unknown
    private var buffer = Data()      // unparsed bytes (may include a partial frame)
    private var pending = Data()     // complete frames, not yet emitted
    private var framesPending = 0
    private let framesPerChunk = 64  // 1024-sample AAC packets ≈ 1.5 s @ 44.1 kHz

    private var id3Handled = false

    mutating func append(_ data: Data) {
        buffer.append(data)
        skipLeadingID3IfPresent()
        parseAvailableFrames()
    }

    /// Returns a chunk of complete frames (~1.5 s) when one is ready, else nil.
    mutating func takeReadyChunk() -> (data: Data, codec: Codec)? {
        guard !pending.isEmpty, framesPending >= framesPerChunk else { return nil }
        let d = pending
        pending = Data()
        framesPending = 0
        return (d, codec)
    }

    // MARK: - Parsing

    private mutating func skipLeadingID3IfPresent() {
        guard !id3Handled, codec == .unknown, buffer.count >= 10,
              buffer.starts(with: Data("ID3".utf8)) else { return }
        let size = syncsafe(buffer[6], buffer[7], buffer[8], buffer[9])
        let total = 10 + size
        if buffer.count >= total {
            buffer.removeSubrange(0..<total)
            id3Handled = true
        }
    }

    private mutating func parseAvailableFrames() {
        // Drop leading garbage if no sync word appears within a reasonable window.
        if buffer.count > 1_000_000, !containsSyncWord() {
            buffer.removeSubrange(0..<(buffer.count - 4))
        }

        while let (frame, codec) = nextCompleteFrame() {
            self.codec = codec
            pending.append(frame)
            framesPending += 1
        }
    }

    private func containsSyncWord() -> Bool {
        for i in 0..<(buffer.count - 1) where buffer[i] == 0xFF {
            let b1 = buffer[i + 1]
            if (b1 & 0xF6) == 0xF0 { return true }  // ADTS
            if (b1 & 0xE0) == 0xE0 { return true }  // MP3
        }
        return false
    }

    private mutating func nextCompleteFrame() -> (Data, Codec)? {
        guard buffer.count >= 4 else { return nil }

        // Find the sync word (0xFFFx ADTS or 0xFFEx MPEG).
        var start: Int?
        for i in 0..<(buffer.count - 1) where buffer[i] == 0xFF {
            let b1 = buffer[i + 1]
            if (b1 & 0xF6) == 0xF0 || (b1 & 0xE0) == 0xE0 {
                start = i
                break
            }
        }
        guard let start else {
            if buffer.count > 4 { buffer.removeSubrange(0..<(buffer.count - 4)) }
            return nil
        }

        // Consume garbage before the sync word.
        if start > 0 { buffer.removeSubrange(0..<start) }
        guard buffer.count >= 7 else { return nil }

        let b1 = buffer[1]
        let frameLength: Int
        let detected: Codec
        if (b1 & 0xF6) == 0xF0 {
            // ADTS AAC
            let b3 = Int(buffer[3]), b4 = Int(buffer[4]), b5 = Int(buffer[5])
            frameLength = ((b3 & 0x03) << 11) | (b4 << 3) | (b5 >> 5)
            detected = .aac
        } else if (b1 & 0xE0) == 0xE0 {
            // MPEG audio (Layer I/II/III)
            guard let len = mp3FrameLength() else {
                // Invalid header — skip one byte and resync.
                buffer.removeSubrange(0..<1)
                return nil
            }
            frameLength = len
            detected = .mp3
        } else {
            buffer.removeSubrange(0..<1)
            return nil
        }

        guard frameLength >= 7, buffer.count >= frameLength else {
            // Need more bytes to complete the frame.
            return nil
        }

        let frame = buffer.prefix(frameLength)
        buffer.removeSubrange(0..<frameLength)
        return (Data(frame), detected)
    }

    /// Parses an MPEG audio header at buffer[0..<4] and returns the frame length in bytes.
    private func mp3FrameLength() -> Int? {
        guard buffer.count >= 4 else { return nil }
        let b1 = buffer[1], b2 = buffer[2]
        let version = (b1 >> 3) & 0x3    // 3 = MPEG1, 2 = MPEG2, 0 = MPEG2.5
        let layer = (b1 >> 1) & 0x3      // 1 = Layer III, 2 = Layer II, 3 = Layer I
        let bitrateIndex = Int(b2 >> 4) & 0xF
        let sampleRateIndex = Int(b2 >> 2) & 0x3
        let padding = Int(b2 >> 1) & 0x1

        guard version != 1, layer != 0, bitrateIndex != 0xF,
              bitrateIndex != 0, sampleRateIndex != 3 else { return nil }

        let sampleRate: Int
        switch version {
        case 3: sampleRate = [44100, 48000, 32000][sampleRateIndex]
        case 2: sampleRate = [22050, 24000, 16000][sampleRateIndex]
        default: sampleRate = [11025, 12000, 8000][sampleRateIndex]
        }

        let bitrateKbps: Int
        switch (version == 3, layer) {
        case (true, 1):  bitrateKbps = [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320][bitrateIndex]
        case (false, 1): bitrateKbps = [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160][bitrateIndex]
        case (true, 2):  bitrateKbps = [0, 32, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384][bitrateIndex]
        case (false, 2): bitrateKbps = [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160][bitrateIndex]
        case (true, 3):  bitrateKbps = [0, 32, 64, 96, 128, 160, 192, 224, 256, 288, 320, 352, 384, 416, 448][bitrateIndex]
        default:         bitrateKbps = [0, 32, 48, 56, 64, 80, 96, 112, 128, 144, 160, 176, 192, 224, 256][bitrateIndex]
        }

        if layer == 3 {
            return (12 * bitrateKbps * 1000 / sampleRate + padding) * 4  // Layer I
        }
        let samplesPerFrame = version == 3 ? 144_000 : 72_000
        return samplesPerFrame * bitrateKbps / sampleRate + padding     // Layer II/III
    }

    private func syncsafe(_ a: UInt8, _ b: UInt8, _ c: UInt8, _ d: UInt8) -> Int {
        (Int(a) << 21) | (Int(b) << 14) | (Int(c) << 7) | Int(d)
    }
}

// MARK: - ICY Metadata Stripper
//
// ICEcast/SHOUTcast insert an ICY metadata block every `icy-metaint` bytes of
// audio. This strips those blocks from the byte stream and extracts StreamTitle.

struct ICYMetadataStripper {
    var metaint = 0
    private(set) var latestTitle: String?

    private enum Mode { case audio, meta }
    private var mode: Mode = .audio
    private var audioCounter = 0
    private var lengthByte: UInt8?
    private var remaining = 0
    private var payload = Data()

    mutating func process(_ input: Data) -> (clean: Data, title: String?) {
        guard metaint > 0 else { return (input, nil) }

        var out = Data()
        out.reserveCapacity(input.count)
        var newTitle: String?

        for byte in input {
            switch mode {
            case .audio:
                out.append(byte)
                audioCounter += 1
                if audioCounter == metaint {
                    audioCounter = 0
                    mode = .meta
                    lengthByte = nil
                    remaining = 0
                    payload = Data()
                }
            case .meta:
                if lengthByte == nil {
                    lengthByte = byte
                    remaining = Int(byte) * 16
                } else if remaining > 0 {
                    payload.append(byte)
                    remaining -= 1
                    if remaining == 0 {
                        if let t = Self.parseTitle(payload) { newTitle = t }
                        mode = .audio
                    }
                } else {
                    mode = .audio
                }
            }
        }

        if let newTitle { latestTitle = newTitle }
        return (out, newTitle)
    }

    static func parseTitle(_ payload: Data) -> String? {
        // ICY metadata is classically Latin-1; some servers send UTF-8.
        guard let s = String(data: payload, encoding: .utf8)
            ?? String(data: payload, encoding: .isoLatin1),
            let range = s.range(of: "StreamTitle='"),
            let end = s[range.upperBound...].firstIndex(of: "'") else { return nil }
        let title = String(s[range.upperBound..<end])
        return title.isEmpty ? nil : title
    }
}

// MARK: - LiveStreamer
//
// Streams a continuous HTTP audio stream (ICEcast/SHOUTcast/plain HTTP audio),
// strips ICY metadata, frame-syncs and decodes to PCM, and yields buffers on an
// AsyncStream — the same interface HLSStreamer exposes. Reconnects with backoff.

actor LiveStreamer {
    fileprivate enum Event: Sendable {
        case response(URLResponse)
        case data(Data)
        case finished
    }

    private let continuation: AsyncStream<AVAudioPCMBuffer>.Continuation
    let buffers: AsyncStream<AVAudioPCMBuffer>

    /// Best-effort song/talk title from ICY metadata (nil if the stream sends none).
    private(set) var currentTitle: String?

    private var task: Task<Void, Never>?
    private var isRunning = false

    init() {
        var cont: AsyncStream<AVAudioPCMBuffer>.Continuation!
        buffers = AsyncStream { cont = $0 }
        continuation = cont
    }

    func start(url: URL) {
        guard !isRunning else { return }
        isRunning = true
        task = Task { await runLoop(url: url) }
    }

    func stop() {
        isRunning = false
        task?.cancel()
        task = nil
        continuation.finish()
    }

    // MARK: - Loop

    private func runLoop(url: URL) async {
        while isRunning {
            if Task.isCancelled { break }
            await consume(url: url)
            if isRunning {
                NSLog("🔁 LiveStreamer: stream ended, retrying in 3 s")
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    private func consume(url: URL) async {
        var stripper = ICYMetadataStripper()
        var assembler = LiveFrameAssembler()

        for await event in openStream(url) {
            if Task.isCancelled { break }
            switch event {
            case .response(let response):
                let metaint = (response as? HTTPURLResponse)?
                    .value(forHTTPHeaderField: "icy-metaint")
                    .flatMap(Int.init) ?? 0
                stripper.metaint = metaint
                let contentType = (response as? HTTPURLResponse)?
                    .value(forHTTPHeaderField: "Content-Type") ?? "?"
                NSLog("🎧 LiveStreamer: \(response.url?.lastPathComponent ?? url.lastPathComponent) content-type=\(contentType) metaint=\(metaint)")

            case .data(let data):
                let (clean, title) = stripper.process(data)
                if let title, title != currentTitle {
                    currentTitle = title
                    NSLog("🎵 LiveStreamer title: \(title)")
                }
                assembler.append(clean)
                while let (chunk, codec) = assembler.takeReadyChunk(),
                      let buffer = decodeChunk(chunk, codec: codec) {
                    continuation.yield(buffer)
                }

            case .finished:
                break
            }
        }
    }

    private func decodeChunk(_ data: Data, codec: LiveFrameAssembler.Codec) -> AVAudioPCMBuffer? {
        let ext = codec == .mp3 ? "mp3" : "aac"
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + "." + ext)
        do {
            try data.write(to: tmp)
            defer { try? FileManager.default.removeItem(at: tmp) }
            let file = try AVAudioFile(forReading: tmp)
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat,
                frameCapacity: AVAudioFrameCount(file.length)
            ) else { return nil }
            try file.read(into: buffer)
            return buffer
        } catch {
            NSLog("🔴 LiveStreamer: decode error: \(error)")
            return nil
        }
    }

    private func openStream(_ url: URL) -> AsyncStream<Event> {
        AsyncStream { continuation in
            let delegate = LiveStreamDelegate(continuation: continuation)
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 20
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
            delegate.keepAlive = session
            var request = URLRequest(url: url)
            request.setValue("1", forHTTPHeaderField: "Icy-MetaData")
            let task = session.dataTask(with: request)
            task.resume()
        }
    }
}

private final class LiveStreamDelegate: NSObject, URLSessionDataDelegate {
    let continuation: AsyncStream<LiveStreamer.Event>.Continuation
    var keepAlive: URLSession?

    init(continuation: AsyncStream<LiveStreamer.Event>.Continuation) {
        self.continuation = continuation
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        continuation.yield(.response(response))
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        continuation.yield(.data(data))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        continuation.yield(.finished)
        continuation.finish()
        keepAlive = nil
    }
}
