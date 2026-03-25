import AVFoundation
import Foundation

/// Continuously fetches HLS segments and decodes them to PCM buffers.
actor HLSStreamer {
    private let session = URLSession.shared
    private var mediaPlaylistURL: URL?
    private var lastSequence: Int = -1
    private var isRunning = false
    private let continuation: AsyncStream<AVAudioPCMBuffer>.Continuation
    let buffers: AsyncStream<AVAudioPCMBuffer>

    /// The audio format of decoded segments (available after first segment).
    private(set) var format: AVAudioFormat?

    init() {
        var cont: AsyncStream<AVAudioPCMBuffer>.Continuation!
        buffers = AsyncStream { cont = $0 }
        continuation = cont
    }

    func start(station: Station) {
        guard !isRunning else { return }
        isRunning = true
        lastSequence = -1
        mediaPlaylistURL = nil

        Task { await resolveAndStream(station: station) }
    }

    func stop() {
        isRunning = false
        continuation.finish()
    }

    // MARK: - HLS Resolution

    private func resolveAndStream(station: Station) async {
        // Step 1: Resolve master → variant → media playlist
        guard let mediaURL = await resolveMediaPlaylist(master: station.url) else {
            NSLog("🔴 HLSStreamer: failed to resolve media playlist")
            return
        }
        mediaPlaylistURL = mediaURL
        NSLog("🔊 HLSStreamer: media playlist = \(mediaURL)")

        // Step 2: Poll loop
        while isRunning {
            await fetchAndQueueNewSegments()
            try? await Task.sleep(for: .seconds(2))
        }
    }

    private func resolveMediaPlaylist(master masterURL: URL) async -> URL? {
        // Master playlist may be multi-level: master → variant → media
        guard let text = await fetchText(masterURL) else { return nil }

        // Find first non-comment, non-empty line (variant reference)
        var variantPath: String?
        for line in text.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty && !t.hasPrefix("#") && t.hasSuffix(".m3u8") {
                variantPath = t
                break
            }
        }
        guard let vp = variantPath else { return nil }

        let variantURL = vp.hasPrefix("http")
            ? URL(string: vp)!
            : masterURL.deletingLastPathComponent().appendingPathComponent(vp)

        // Check if variant is actually a media playlist (has EXTINF)
        guard let variantText = await fetchText(variantURL) else { return nil }

        if variantText.contains("#EXTINF:") {
            return variantURL
        }

        // It's another level of indirection — resolve again
        for line in variantText.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty && !t.hasPrefix("#") && t.hasSuffix(".m3u8") {
                return t.hasPrefix("http")
                    ? URL(string: t)
                    : variantURL.deletingLastPathComponent().appendingPathComponent(t)
            }
        }
        return nil
    }

    // MARK: - Segment Fetching

    private func fetchAndQueueNewSegments() async {
        guard let playlistURL = mediaPlaylistURL,
              let text = await fetchText(playlistURL) else { return }

        let baseURL = playlistURL.deletingLastPathComponent()

        // Parse media sequence and segments
        var mediaSequence = 0
        var segments: [(seq: Int, url: URL)] = []
        var currentSeq = 0

        for line in text.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespacesAndNewlines)

            if t.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") {
                mediaSequence = Int(t.replacingOccurrences(of: "#EXT-X-MEDIA-SEQUENCE:", with: "")) ?? 0
                currentSeq = mediaSequence
            } else if t.hasSuffix(".aac") || t.hasSuffix(".ts") || t.hasSuffix(".m4s") {
                let url = t.hasPrefix("http")
                    ? URL(string: t)!
                    : baseURL.appendingPathComponent(t)
                segments.append((seq: currentSeq, url: url))
                currentSeq += 1
            }
        }

        // On first fetch, start from the last few segments (near-live)
        if lastSequence < 0 {
            let startFrom = max(0, segments.count - 3)
            for seg in segments.suffix(from: startFrom) {
                await downloadAndDecode(seg.url)
                lastSequence = seg.seq
            }
        } else {
            // Only fetch new segments
            for seg in segments where seg.seq > lastSequence {
                await downloadAndDecode(seg.url)
                lastSequence = seg.seq
            }
        }
    }

    private func downloadAndDecode(_ url: URL) async {
        guard isRunning else { return }

        do {
            let (data, _) = try await session.data(from: url)

            let tmpFile = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + ".aac")
            try data.write(to: tmpFile)
            defer { try? FileManager.default.removeItem(at: tmpFile) }

            let audioFile = try AVAudioFile(forReading: tmpFile)

            if format == nil {
                format = audioFile.processingFormat
                NSLog("🔊 HLSStreamer: audio format = \(audioFile.processingFormat)")
            }

            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: audioFile.processingFormat,
                frameCapacity: AVAudioFrameCount(audioFile.length)
            ) else { return }

            try audioFile.read(into: buffer)
            continuation.yield(buffer)
        } catch {
            NSLog("🔴 HLSStreamer: decode error: \(error)")
        }
    }

    // MARK: - Helpers

    private func fetchText(_ url: URL) async -> String? {
        do {
            let (data, _) = try await session.data(from: url)
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }
}
