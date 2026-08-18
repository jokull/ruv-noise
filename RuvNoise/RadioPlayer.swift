import AVFoundation
import Accelerate
import CoreMedia

enum Station: String, CaseIterable {
    case ras1 = "RÁS 1"
    case ras2 = "RÁS 2"

    var url: URL {
        switch self {
        case .ras1: URL(string: "https://ruv-radio-live.akamaized.net/streymi/ras1/ras1.m3u8")!
        case .ras2: URL(string: "https://ruv-radio-live.akamaized.net/streymi/ras2/ras2.m3u8")!
        }
    }
}

enum AudioMode: String, CaseIterable {
    case clean = "Clean"
    case fm = "FM"
    case kitchen = "Kitchen"

    var systemImage: String {
        switch self {
        case .clean: "waveform"
        case .fm: "radio"
        case .kitchen: "frying.pan"
        }
    }
}

// MARK: - Show Info

struct ShowInfo: Equatable {
    let title: String
    let startTime: Date
    let endTime: Date
}

// MARK: - DSP Context

final class DSPContext {
    var noiseGen = PinkNoiseGenerator()
    var sampleRate: Float = 48000
    var audioMode: AudioMode = .fm

    // -- FM mode state --
    // 50μs de-emphasis (European/Iceland) — single-pole IIR
    var deemphAlpha: Float = 0
    var deemphStateL: Float = 0
    var deemphStateR: Float = 0

    // 15 kHz brick-wall LP (4th order = 2 cascaded biquads)
    var lp15kSetup1: OpaquePointer?
    var lp15kSetup2: OpaquePointer?
    var lp15kDelays1L = [Float](repeating: 0, count: 4)
    var lp15kDelays1R = [Float](repeating: 0, count: 4)
    var lp15kDelays2L = [Float](repeating: 0, count: 4)
    var lp15kDelays2R = [Float](repeating: 0, count: 4)

    // Broadcast compressor (simple wideband — Optimod-lite)
    var compEnvelopeL: Float = 0
    var compEnvelopeR: Float = 0
    var compAttackCoeff: Float = 0
    var compReleaseCoeff: Float = 0

    // Soft clipper threshold
    let clipThreshold: Float = 0.7

    // FM noise state (differentiated white noise)
    var prevNoiseL: Float = 0
    var prevNoiseR: Float = 0

    // Multipath delay lines (2 reflections)
    var mp1Buf = [Float](repeating: 0, count: 256)  // ~0.5ms
    var mp1Idx: Int = 0
    var mp2Buf = [Float](repeating: 0, count: 512)  // ~1.5ms
    var mp2Idx: Int = 0
    var mp1Samples: Int = 24   // 0.5ms at 48kHz
    var mp2Samples: Int = 72   // 1.5ms at 48kHz
    var mpPhase1: Float = 0
    var mpPhase2: Float = 0

    // Pilot tone phase
    var pilotPhase: Float = 0

    // -- Kitchen mode state --
    var kitchenHPSetup: OpaquePointer?
    var kitchenSatInterstageSetup: OpaquePointer?
    var doorwayLPSetup: OpaquePointer?
    var stofaColorSetup: OpaquePointer?
    var kitchenHPDelaysL = [Float](repeating: 0, count: 4)
    var kitchenHPDelaysR = [Float](repeating: 0, count: 4)
    var kitchenIntDelaysL = [Float](repeating: 0, count: 4)
    var kitchenIntDelaysR = [Float](repeating: 0, count: 4)
    var doorwayLPDelaysL = [Float](repeating: 0, count: 4)
    var doorwayLPDelaysR = [Float](repeating: 0, count: 4)
    var stofaColorDelaysL = [Float](repeating: 0, count: 4)
    var stofaColorDelaysR = [Float](repeating: 0, count: 4)

    // Kitchen reverb — gentler than before (1/3 of old values)
    var eldhusDelayBuf = [Float](repeating: 0, count: 2048)
    var eldhusDelayIdx: Int = 0
    var eldhusDelaySamples: Int = 384
    var stofaDelayBuf = [Float](repeating: 0, count: 4096)
    var stofaDelayIdx: Int = 0
    var stofaDelaySamples: Int = 1200

    var tempBuffer = [Float](repeating: 0, count: 8192)

    deinit {
        for s in [lp15kSetup1, lp15kSetup2, kitchenHPSetup,
                  kitchenSatInterstageSetup, doorwayLPSetup, stofaColorSetup] {
            if let s { vDSP_biquad_DestroySetup(s) }
        }
    }

    func configure(sampleRate sr: Double) {
        sampleRate = Float(sr)

        // 50μs de-emphasis coefficient
        let tauSamples = 50e-6 * sr
        deemphAlpha = Float(1.0 - exp(-1.0 / tauSamples))
        deemphStateL = 0; deemphStateR = 0

        // 15 kHz LP (4th-order Butterworth = 2 cascaded 2nd-order)
        bqSetup(&lp15kSetup1, Self.lowPassCoeffs(cutoff: 15000, sr: sr))
        bqSetup(&lp15kSetup2, Self.lowPassCoeffs(cutoff: 15000, sr: sr))
        resetArray(&lp15kDelays1L); resetArray(&lp15kDelays1R)
        resetArray(&lp15kDelays2L); resetArray(&lp15kDelays2R)

        // Broadcast compressor — slow attack, moderate release
        compAttackCoeff = expf(-1.0 / (sampleRate * 0.010))  // 10ms
        compReleaseCoeff = expf(-1.0 / (sampleRate * 0.200)) // 200ms

        // Multipath delay sizes
        mp1Samples = Int(sr * 0.0005)  // 0.5ms
        mp2Samples = Int(sr * 0.0015)  // 1.5ms
        mp1Buf = [Float](repeating: 0, count: max(mp1Samples + 1, 256))
        mp2Buf = [Float](repeating: 0, count: max(mp2Samples + 1, 512))
        mp1Idx = 0; mp2Idx = 0

        // Kitchen filters
        bqSetup(&kitchenHPSetup, Self.highPassCoeffs(cutoff: 120, sr: sr))
        bqSetup(&kitchenSatInterstageSetup, Self.lowPassCoeffs(cutoff: 5000, sr: sr))
        bqSetup(&doorwayLPSetup, Self.lowPassCoeffs(cutoff: 2500, sr: sr))
        bqSetup(&stofaColorSetup, Self.peakingEQCoeffs(freq: 300, gainDB: 2, Q: 0.8, sr: sr))
        resetArray(&kitchenHPDelaysL); resetArray(&kitchenHPDelaysR)
        resetArray(&kitchenIntDelaysL); resetArray(&kitchenIntDelaysR)
        resetArray(&doorwayLPDelaysL); resetArray(&doorwayLPDelaysR)
        resetArray(&stofaColorDelaysL); resetArray(&stofaColorDelaysR)

        eldhusDelaySamples = Int(sr * 0.006)
        eldhusDelayBuf = [Float](repeating: 0, count: max(eldhusDelaySamples + 1, 2048))
        eldhusDelayIdx = 0
        stofaDelaySamples = Int(sr * 0.020)
        stofaDelayBuf = [Float](repeating: 0, count: max(stofaDelaySamples + 1, 4096))
        stofaDelayIdx = 0

        prevNoiseL = 0; prevNoiseR = 0
    }

    private func bqSetup(_ ptr: inout OpaquePointer?, _ coeffs: [Double]) {
        if let s = ptr { vDSP_biquad_DestroySetup(s) }
        ptr = vDSP_biquad_CreateSetup(coeffs, 1)
    }
    private func resetArray(_ a: inout [Float]) { a = [Float](repeating: 0, count: 4) }

    // MARK: - Process buffer

    func process(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        if tempBuffer.count < frameCount { tempBuffer = [Float](repeating: 0, count: frameCount) }
        guard channelCount >= 1, audioMode != .clean else { return }

        // Build a mutable array of channel pointers
        var channels = [UnsafeMutablePointer<Float>]()
        for ch in 0..<channelCount { channels.append(channelData[ch]) }

        channels.withUnsafeMutableBufferPointer { buf in
            switch audioMode {
            case .fm: processFM(buf.baseAddress!, frameCount: frameCount, channelCount: channelCount)
            case .kitchen: processKitchen(buf.baseAddress!, frameCount: frameCount, channelCount: channelCount)
            case .clean: break
            }
        }
    }

    // MARK: - FM Mode (broadcast radio simulation)

    private func processFM(_ data: UnsafeMutablePointer<UnsafeMutablePointer<Float>>,
                           frameCount: Int, channelCount: Int) {
        let n = vDSP_Length(frameCount)

        // Process each channel
        for ch in 0..<min(channelCount, 2) {
            let ptr = data[ch]
            let isLeft = ch == 0

            // 1. Broadcast compression (wideband, Optimod-lite)
            broadcastCompress(ptr, frameCount: frameCount, isLeft: isLeft)

            // 2. Soft clipper (odd harmonics, broadcast "edge")
            softClip(ptr, n: n)

            // 3. 15 kHz brick-wall LP (4th order)
            if isLeft {
                if let s = lp15kSetup1 { vDSP_biquad(s, &lp15kDelays1L, ptr, 1, ptr, 1, n) }
                if let s = lp15kSetup2 { vDSP_biquad(s, &lp15kDelays2L, ptr, 1, ptr, 1, n) }
            } else {
                if let s = lp15kSetup1 { vDSP_biquad(s, &lp15kDelays1R, ptr, 1, ptr, 1, n) }
                if let s = lp15kSetup2 { vDSP_biquad(s, &lp15kDelays2R, ptr, 1, ptr, 1, n) }
            }

            // 4. FM-shaped noise (differentiated white → de-emphasize)
            addFMNoise(ptr, frameCount: frameCount, isLeft: isLeft)

            // 5. 50μs de-emphasis — THE key FM filter
            applyDeemphasis(ptr, frameCount: frameCount, isLeft: isLeft)
        }

        // 6. Stereo width reduction (real FM has ~35 dB separation)
        if channelCount >= 2 {
            let l = data[0], r = data[1]
            for i in 0..<frameCount {
                let mid = (l[i] + r[i]) * 0.5
                let side = (l[i] - r[i]) * 0.5
                l[i] = mid + side * 0.7   // reduce side by ~3 dB
                r[i] = mid - side * 0.7
            }
        }

        // 7. Multipath (subtle modulated reflections)
        applyMultipath(data[0], frameCount: frameCount)
        if channelCount >= 2 { applyMultipath(data[1], frameCount: frameCount) }

        // 8. Faint 19 kHz pilot tone (cheap receiver leakage)
        let pilotAmp: Float = 0.003  // ~-50 dB
        let pilotInc = 19000.0 * 2 * Float.pi / sampleRate
        for i in 0..<frameCount {
            let p = pilotAmp * sinf(pilotPhase)
            data[0][i] += p
            if channelCount >= 2 { data[1][i] += p }
            pilotPhase += pilotInc
        }
        if pilotPhase > 2 * .pi { pilotPhase -= 2 * .pi }
    }

    // MARK: - Kitchen Mode (radio in the other room)

    private func processKitchen(_ data: UnsafeMutablePointer<UnsafeMutablePointer<Float>>,
                                frameCount: Int, channelCount: Int) {
        let n = vDSP_Length(frameCount)

        for ch in 0..<min(channelCount, 2) {
            let ptr = data[ch]
            let isLeft = ch == 0

            // 1. Gentle HP to remove sub-bass
            bq(kitchenHPSetup, ptr, n: n,
               dL: &kitchenHPDelaysL, dR: &kitchenHPDelaysR, isLeft: isLeft)

            // 2. Mild tube saturation (the kitchen radio's cheap amp)
            var drive: Float = 1.2
            vDSP_vsmul(ptr, 1, &drive, ptr, 1, n)
            var count = Int32(frameCount)
            vvtanhf(ptr, ptr, &count)

            // 3. Interstage LP
            bq(kitchenSatInterstageSetup, ptr, n: n,
               dL: &kitchenIntDelaysL, dR: &kitchenIntDelaysR, isLeft: isLeft)

            // 4. Eldhús reverb — small room, short, moderate wet
            applyDelay(ptr, frameCount: frameCount,
                       buf: &eldhusDelayBuf, idx: &eldhusDelayIdx,
                       samples: eldhusDelaySamples,
                       feedback: 0.25, wet: 0.20, dry: 0.85)

            // 5. Doorway LP — HF lost going through the door
            bq(doorwayLPSetup, ptr, n: n,
               dL: &doorwayLPDelaysL, dR: &doorwayLPDelaysR, isLeft: isLeft)

            // 6. Stofa reverb — bigger room, longer, less wet
            bq(stofaColorSetup, ptr, n: n,
               dL: &stofaColorDelaysL, dR: &stofaColorDelaysR, isLeft: isLeft)
            applyDelay(ptr, frameCount: frameCount,
                       buf: &stofaDelayBuf, idx: &stofaDelayIdx,
                       samples: stofaDelaySamples,
                       feedback: 0.15, wet: 0.12, dry: 0.90)
        }

        // 7. Mono collapse (the kitchen radio is mono)
        if channelCount >= 2 {
            vDSP_vadd(data[0], 1, data[1], 1, data[0], 1, n)
            var half: Float = 0.5
            vDSP_vsmul(data[0], 1, &half, data[0], 1, n)
            memcpy(data[1], data[0], frameCount * MemoryLayout<Float>.size)
        }

        // 8. Distance attenuation (~-4 dB, gentle — you can still hear it clearly)
        var gain: Float = 0.65
        let n2 = n
        vDSP_vsmul(data[0], 1, &gain, data[0], 1, n2)
        if channelCount >= 2 { vDSP_vsmul(data[1], 1, &gain, data[1], 1, n2) }

        // 9. Ambient noise (relative to attenuated signal — like room tone)
        let noiseAmp: Float = 0.003
        for i in 0..<frameCount {
            let noise = noiseGen.next() * noiseAmp / noiseGen.amplitude
            data[0][i] += noise
            if channelCount >= 2 { data[1][i] += noise }
        }
    }

    // MARK: - FM DSP primitives

    private func broadcastCompress(_ data: UnsafeMutablePointer<Float>, frameCount: Int, isLeft: Bool) {
        let n = vDSP_Length(frameCount)
        var meansq: Float = 0
        vDSP_measqv(data, 1, &meansq, n)
        let rms = sqrtf(meansq)

        var envelope = isLeft ? compEnvelopeL : compEnvelopeR
        let coeff = rms > envelope ? compAttackCoeff : compReleaseCoeff
        envelope = coeff * envelope + (1 - coeff) * rms
        if isLeft { compEnvelopeL = envelope } else { compEnvelopeR = envelope }

        // Gentle compression: ratio ~3:1, threshold -12 dBFS
        let threshold: Float = 0.25
        if envelope > threshold {
            let overDB = 20 * log10f(envelope / threshold)
            let compressed = overDB / 3.0
            var gain = powf(10, (compressed - overDB) / 20)
            vDSP_vsmul(data, 1, &gain, data, 1, n)
        }
    }

    private func softClip(_ data: UnsafeMutablePointer<Float>, n: vDSP_Length) {
        // Gentle soft clip — just catches peaks
        let t = clipThreshold
        for i in 0..<Int(n) {
            let x = data[i]
            if x > t { data[i] = t + (x - t) / (1 + ((x - t) / (1 - t)) * ((x - t) / (1 - t))) }
            else if x < -t { data[i] = -t + (x + t) / (1 + ((x + t) / (1 - t)) * ((x + t) / (1 - t))) }
        }
    }

    private func applyDeemphasis(_ data: UnsafeMutablePointer<Float>, frameCount: Int, isLeft: Bool) {
        let a = deemphAlpha
        var state = isLeft ? deemphStateL : deemphStateR
        for i in 0..<frameCount {
            state = state + a * (data[i] - state)
            data[i] = state
        }
        if isLeft { deemphStateL = state } else { deemphStateR = state }
    }

    private func addFMNoise(_ data: UnsafeMutablePointer<Float>, frameCount: Int, isLeft: Bool) {
        // FM noise: white → differentiate (triangular spectrum) → mix
        // The de-emphasis applied after this will flatten the noise naturally
        let level: Float = 0.006  // subtle hiss
        var prev = isLeft ? prevNoiseL : prevNoiseR
        for i in 0..<frameCount {
            let white = Float.random(in: -1...1)
            let shaped = (white - prev) * level  // differentiator = +6dB/oct
            prev = white
            data[i] += shaped
        }
        if isLeft { prevNoiseL = prev } else { prevNoiseR = prev }
    }

    private func applyMultipath(_ data: UnsafeMutablePointer<Float>, frameCount: Int) {
        // Two subtle reflections with slow flutter
        let rate1: Float = 3.5 * 2 * .pi / sampleRate
        let rate2: Float = 5.2 * 2 * .pi / sampleRate
        let depth: Float = 0.04  // subtle
        let buf1Len = mp1Buf.count
        let buf2Len = mp2Buf.count

        for i in 0..<frameCount {
            let g1 = depth * (0.5 + 0.5 * sinf(mpPhase1))
            let g2 = depth * 0.6 * (0.5 + 0.5 * sinf(mpPhase2))

            let r1 = mp1Buf[(mp1Idx - mp1Samples + buf1Len) % buf1Len]
            let r2 = mp2Buf[(mp2Idx - mp2Samples + buf2Len) % buf2Len]

            mp1Buf[mp1Idx] = data[i]
            mp2Buf[mp2Idx] = data[i]
            mp1Idx = (mp1Idx + 1) % buf1Len
            mp2Idx = (mp2Idx + 1) % buf2Len

            data[i] += r1 * g1 + r2 * g2

            mpPhase1 += rate1
            mpPhase2 += rate2
        }
        if mpPhase1 > 2 * .pi { mpPhase1 -= 2 * .pi }
        if mpPhase2 > 2 * .pi { mpPhase2 -= 2 * .pi }
    }

    // MARK: - Shared primitives

    private func bq(_ setup: OpaquePointer?, _ data: UnsafeMutablePointer<Float>, n: vDSP_Length,
                    dL: inout [Float], dR: inout [Float], isLeft: Bool) {
        guard let s = setup else { return }
        if isLeft { vDSP_biquad(s, &dL, data, 1, data, 1, n) }
        else { vDSP_biquad(s, &dR, data, 1, data, 1, n) }
    }

    private func applyDelay(_ data: UnsafeMutablePointer<Float>, frameCount: Int,
                            buf: inout [Float], idx: inout Int,
                            samples: Int, feedback: Float, wet: Float, dry: Float) {
        let bufLen = buf.count
        for i in 0..<frameCount {
            let readIdx = (idx - samples + bufLen) % bufLen
            let delayed = buf[readIdx]
            buf[idx] = data[i] + delayed * feedback
            idx = (idx + 1) % bufLen
            data[i] = data[i] * dry + delayed * wet
        }
    }

    // MARK: - Biquad coefficients

    static func highPassCoeffs(cutoff: Double, sr: Double) -> [Double] {
        let w0 = 2.0 * .pi * cutoff / sr
        let alpha = sin(w0) / (2.0 * sqrt(2.0))
        let c = cos(w0); let a0 = 1.0 + alpha
        return [((1+c)/2)/a0, (-(1+c))/a0, ((1+c)/2)/a0, (-2*c)/a0, (1-alpha)/a0]
    }

    static func lowPassCoeffs(cutoff: Double, sr: Double) -> [Double] {
        let w0 = 2.0 * .pi * cutoff / sr
        let alpha = sin(w0) / (2.0 * sqrt(2.0))
        let c = cos(w0); let a0 = 1.0 + alpha
        return [((1-c)/2)/a0, (1-c)/a0, ((1-c)/2)/a0, (-2*c)/a0, (1-alpha)/a0]
    }

    static func peakingEQCoeffs(freq: Double, gainDB: Double, Q: Double, sr: Double) -> [Double] {
        let A = pow(10, gainDB/40); let w0 = 2 * .pi * freq / sr
        let alpha = sin(w0)/(2*Q); let c = cos(w0); let a0 = 1+alpha/A
        return [(1+alpha*A)/a0, (-2*c)/a0, (1-alpha*A)/a0, (-2*c)/a0, (1-alpha/A)/a0]
    }
}

// MARK: - Raw Buffer Ring

/// Thread-safe ring buffer of raw (unprocessed) PCM buffers.
private final class RawBufferRing: @unchecked Sendable {
    private let lock = NSLock()
    private var ring: [AVAudioPCMBuffer] = []
    private let maxCount = 8

    func push(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        ring.append(buffer)
        if ring.count > maxCount { ring.removeFirst() }
        lock.unlock()
    }

    func snapshot() -> [AVAudioPCMBuffer] {
        lock.lock()
        let copy = ring.map { copyBuffer($0) }
        lock.unlock()
        return copy
    }

    private func copyBuffer(_ src: AVAudioPCMBuffer) -> AVAudioPCMBuffer {
        let dst = AVAudioPCMBuffer(pcmFormat: src.format, frameCapacity: src.frameLength)!
        dst.frameLength = src.frameLength
        let bytes = Int(src.frameLength) * MemoryLayout<Float>.size
        for ch in 0..<Int(src.format.channelCount) {
            memcpy(dst.floatChannelData![ch], src.floatChannelData![ch], bytes)
        }
        return dst
    }
}

// MARK: - Playback State Machine

enum PlaybackState: Equatable {
    case idle
    case loading(Station)
    case playing(Station)
}

extension PlaybackState {
    var activeStation: Station? {
        switch self {
        case .loading(let s), .playing(let s): s
        case .idle: nil
        }
    }
    var isActive: Bool { activeStation != nil }
    func isStation(_ s: Station) -> Bool { activeStation == s }
}

// MARK: - RadioPlayer

@MainActor
@Observable
final class RadioPlayer {
    nonisolated init() {
        bufferRing = RawBufferRing()
    }

    private var engine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var streamer: HLSStreamer?
    private var downloadTask: Task<Void, Never>?
    private var showFetchTask: Task<Void, Never>?
    private let bufferRing: RawBufferRing
    private var silenceTimer: Timer?
    private let dsp = DSPContext()
    
    private var showSchedule: [ShowInfo] = []
    private var streamStartTime: Date?
    private var activeStation: Station?

    // -- Observable state (single source of truth) --
    private(set) var state: PlaybackState = .idle
    private(set) var audioMode: AudioMode = .fm
    private(set) var nowPlayingShow: ShowInfo?

    // MARK: - Public API

    /// Toggle station: tap active station to stop, tap different station to switch.
    func selectStation(_ station: Station) async {
        if state.activeStation == station {
            stop()
            return
        }
        stop()
        state = .loading(station)
        await startStream(for: station)
    }

    /// Start a station without toggle behavior (used by NewsScheduler).
    func forcePlay(station: Station) async {
        stop()
        state = .loading(station)
        await startStream(for: station)
    }

    func stop() {
        downloadTask?.cancel()
        downloadTask = nil
        showFetchTask?.cancel()
        showFetchTask = nil
        playerNode?.stop()
        engine?.stop()
        engine = nil
        playerNode = nil
        if let s = streamer { Task { await s.stop() } }
        streamer = nil
        state = .idle
        nowPlayingShow = nil
        streamStartTime = nil
        activeStation = nil
        showSchedule = []
    }

    func setAudioMode(_ mode: AudioMode) {
        guard mode != audioMode else { return }
        audioMode = mode
        dsp.audioMode = mode
        guard engine != nil else { return }
        reflush()
        engine?.mainMixerNode.outputVolume = 0
        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: false) { [weak self] _ in
            let captured = self
            Task { @MainActor in
                captured?.engine?.mainMixerNode.outputVolume = 1
            }
        }
    }

    // MARK: - Show Info

    /// Fetch the day's show schedule from the GraphQL API.
    private func fetchShowSchedule(for station: Station) async {
        NSLog("📺 Fetching show schedule for \(station.rawValue)")
        let channelId = station == .ras1 ? "ras1" : "ras2"
        let tz = TimeZone(identifier: "Atlantic/Reykjavik")!
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        df.timeZone = tz

        let today = df.string(from: Date())
        let tomorrow = df.string(from: Date().addingTimeInterval(86400))

        async let todaySchedule = fetchShowScheduleForDate(today, channel: channelId)
        async let tomorrowSchedule = fetchShowScheduleForDate(tomorrow, channel: channelId)

        let today_ = (try? await todaySchedule) ?? []
        let tomorrow_ = (try? await tomorrowSchedule) ?? []
        showSchedule = (today_ + tomorrow_).sorted { $0.startTime < $1.startTime }
        NSLog("✅ Fetched \(showSchedule.count) shows")
        if showSchedule.isEmpty {
            NSLog("⚠️ No shows found!")
        } else {
            NSLog("   First show: \(showSchedule.first?.title ?? "N/A") at \(showSchedule.first?.startTime ?? Date())")
            NSLog("   Last show: \(showSchedule.last?.title ?? "N/A") at \(showSchedule.last?.endTime ?? Date())")
        }

        updateCurrentShow()
    }

    private func fetchShowScheduleForDate(_ date: String, channel: String) async throws -> [ShowInfo] {
        NSLog("   Fetching shows for \(channel) on \(date)...")
        let vars = "{\"channel\":\"\(channel)\",\"date\":\"\(date)\"}"
        let ext = "{\"persistedQuery\":{\"version\":1,\"sha256Hash\":\"16670c47c2a2e68558ce1984fa60f4486542b693d360de3a80620c32a4f5791d\"}}"

        var comps = URLComponents(string: "https://spilari.nyr.ruv.is/gql/")!
        comps.queryItems = [
            URLQueryItem(name: "operationName", value: "getSchedule"),
            URLQueryItem(name: "variables", value: vars),
            URLQueryItem(name: "extensions", value: ext),
        ]

        var req = URLRequest(url: comps.url!)
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue("https://www.ruv.is/", forHTTPHeaderField: "referer")
        req.setValue("https://www.ruv.is", forHTTPHeaderField: "origin")

        let (data, _) = try await URLSession.shared.data(for: req)

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let d = json["data"] as? [String: Any],
              let sched = d["Schedule"] as? [String: Any],
              let events = sched["events"] as? [[String: Any]] else {
            NSLog("⚠️ Failed to parse JSON response")
            return []
        }
        NSLog("   Got \(events.count) events from API")

        let tz = TimeZone(identifier: "Atlantic/Reykjavik")!
        let timeFmt = DateFormatter()
        timeFmt.dateFormat = "yyyy-MM-dd HH:mm"
        timeFmt.timeZone = tz

        return events.compactMap { ev -> ShowInfo? in
            guard let title = ev["title"] as? String,
                  let start = ev["start_time_friendly"] as? String,
                  let end = ev["end_time_friendly"] as? String,
                  let startDate = timeFmt.date(from: "\(date) \(start)"),
                  var endDate = timeFmt.date(from: "\(date) \(end)") else { return nil }

            if endDate <= startDate { endDate.addTimeInterval(86400) }
            return ShowInfo(title: title, startTime: startDate, endTime: endDate)
        }
    }

    /// Update the current show based on elapsed stream time and HLS latency.
    private func updateCurrentShow() {
        guard streamStartTime != nil, activeStation != nil else {
            nowPlayingShow = nil
            NSLog("⚠️ updateCurrentShow: No stream start time or station")
            return
        }

        // Account for HLS latency (approximately 24 seconds)
        let hlsLatency: TimeInterval = 24
        let listenerTime = Date().addingTimeInterval(-hlsLatency)
        NSLog("🕐 Current listener time (with HLS latency): \(listenerTime)")
        NSLog("   Checking \(showSchedule.count) shows...")

        // First, look for a show currently playing
        if let show = showSchedule.first(where: { $0.startTime <= listenerTime && listenerTime < $0.endTime }) {
            if nowPlayingShow != show {
                nowPlayingShow = show
                NSLog("📍 Now playing: \(show.title) (\(show.startTime) - \(show.endTime))")
            }
        } else {
            // If no current show, show the next upcoming show
            if let nextShow = showSchedule.first(where: { $0.startTime > listenerTime }) {
                if nowPlayingShow != nextShow {
                    nowPlayingShow = nextShow
                    NSLog("📍 Up next: \(nextShow.title) (starting \(nextShow.startTime))")
                }
            } else {
                NSLog("❌ No show found for this time or upcoming")
                nowPlayingShow = nil
            }
        }
    }

    // MARK: - Private

    private func startStream(for station: Station) async {
        let hlsStreamer = HLSStreamer()
        self.streamer = hlsStreamer
        await hlsStreamer.start(station: station)

        let dspRef = dsp
        let ring = bufferRing
        let modeRef = audioMode

        // Track station and stream start time for show info
        activeStation = station
        streamStartTime = Date()

        // Fetch show schedule for the station
        showFetchTask?.cancel()
        showFetchTask = Task {
            await fetchShowSchedule(for: station)
            // Periodically update current show every 30 seconds
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30 * 1_000_000_000)
                if !Task.isCancelled {
                    updateCurrentShow()
                }
            }
        }

        downloadTask = Task { [weak self] in
            var engineStarted = false

            for await buffer in await hlsStreamer.buffers {
                guard let self, !Task.isCancelled else { break }

                ring.push(buffer)

                if !engineStarted {
                    let format = buffer.format
                    dspRef.configure(sampleRate: format.sampleRate)
                    dspRef.audioMode = modeRef

                    let audioEngine = AVAudioEngine()
                    let node = AVAudioPlayerNode()
                    audioEngine.attach(node)
                    audioEngine.connect(node, to: audioEngine.mainMixerNode, format: format)

                    do {
                        try audioEngine.start()
                    } catch {
                        NSLog("🔴 RadioPlayer: engine start failed: \(error)")
                        self.stop()
                        return
                    }

                    self.engine = audioEngine
                    self.playerNode = node
                    node.play()
                    self.state = .playing(station)
                    engineStarted = true
                }

                let copy = ring.snapshot().last!
                dspRef.process(copy)
                self.playerNode?.scheduleBuffer(copy, completionHandler: nil)
            }
        }
    }

    private func reflush() {
        guard let node = playerNode else { return }
        node.stop()
        if let latest = bufferRing.snapshot().last {
            dsp.process(latest)
            node.scheduleBuffer(latest, completionHandler: nil)
        }
        node.play()
    }
}
