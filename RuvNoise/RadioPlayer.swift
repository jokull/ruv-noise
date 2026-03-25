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
    case lofi = "Lo-Fi"
    case kitchen = "Kitchen Mode"

    var systemImage: String {
        switch self {
        case .clean: "waveform"
        case .lofi: "radio"
        case .kitchen: "frying.pan"
        }
    }
}

// MARK: - DSP Context

final class DSPContext {
    var noiseGen = PinkNoiseGenerator()
    var crackleGen = CrackleGenerator()

    var sampleRate: Float = 48000
    var audioMode: AudioMode = .lofi

    // FM detuning
    var fmPhase: Float = 0
    var fmFlutterPhase: Float = 0
    var fmInterferencePhase: Float = 0

    // Filter setups
    var highPassSetup: OpaquePointer?
    var lowPassSetup: OpaquePointer?
    var midBoostSetup: OpaquePointer?
    var bassBoostSetup: OpaquePointer?
    var preEmphasisSetup: OpaquePointer?
    var deEmphasisSetup: OpaquePointer?
    var interstageSetup: OpaquePointer?

    // Kitchen mode
    var kitchenHPSetup: OpaquePointer?
    var kitchenDoorSetup: OpaquePointer?
    var doorwayLPSetup: OpaquePointer?
    var stofaColorSetup: OpaquePointer?

    // Biquad delay states (L/R)
    var highPassDelays = [Float](repeating: 0, count: 4)
    var highPassDelaysR = [Float](repeating: 0, count: 4)
    var lowPassDelays = [Float](repeating: 0, count: 4)
    var lowPassDelaysR = [Float](repeating: 0, count: 4)
    var midBoostDelays = [Float](repeating: 0, count: 4)
    var midBoostDelaysR = [Float](repeating: 0, count: 4)
    var bassBoostDelays = [Float](repeating: 0, count: 4)
    var bassBoostDelaysR = [Float](repeating: 0, count: 4)
    var preEmphDelays = [Float](repeating: 0, count: 4)
    var preEmphDelaysR = [Float](repeating: 0, count: 4)
    var deEmphDelays = [Float](repeating: 0, count: 4)
    var deEmphDelaysR = [Float](repeating: 0, count: 4)
    var interstageDelays = [Float](repeating: 0, count: 4)
    var interstageDelaysR = [Float](repeating: 0, count: 4)
    var kitchenHPDelays = [Float](repeating: 0, count: 4)
    var kitchenHPDelaysR = [Float](repeating: 0, count: 4)
    var kitchenDoorDelays = [Float](repeating: 0, count: 4)
    var kitchenDoorDelaysR = [Float](repeating: 0, count: 4)
    var doorwayLPDelays = [Float](repeating: 0, count: 4)
    var doorwayLPDelaysR = [Float](repeating: 0, count: 4)
    var stofaColorDelays = [Float](repeating: 0, count: 4)
    var stofaColorDelaysR = [Float](repeating: 0, count: 4)

    // Room reverb delay lines
    var eldhusDelayBuf = [Float](repeating: 0, count: 2048)
    var eldhusDelayIdx: Int = 0
    var eldhusDelaySamples: Int = 384
    var stofaDelayBuf = [Float](repeating: 0, count: 4096)
    var stofaDelayIdx: Int = 0
    var stofaDelaySamples: Int = 1200

    // Compressor
    var compEnvelopeL: Float = 0
    var compEnvelopeR: Float = 0

    var tempBuffer = [Float](repeating: 0, count: 8192)

    // Saturation — subtle warmth, not destruction
    let drive1: Float = 1.3
    let bias1: Float = 0.12
    let drive2: Float = 1.4
    let bias2: Float = 0.08
    let exciterAmount: Float = 0.10

    let compThreshold: Float = 0.25
    let compRatio: Float = 3.0
    let compKneeWidth: Float = 0.25
    var compAttackCoeff: Float = 0
    var compReleaseCoeff: Float = 0
    var dcOffset1: Float = 0
    var dcOffset2: Float = 0

    deinit {
        for setup in [highPassSetup, lowPassSetup, midBoostSetup, bassBoostSetup,
                      preEmphasisSetup, deEmphasisSetup, interstageSetup,
                      kitchenHPSetup, kitchenDoorSetup, doorwayLPSetup,
                      stofaColorSetup] {
            if let s = setup { vDSP_biquad_DestroySetup(s) }
        }
    }

    func configure(sampleRate: Double) {
        self.sampleRate = Float(sampleRate)
        compAttackCoeff = expf(-1.0 / (self.sampleRate * 0.020))
        compReleaseCoeff = expf(-1.0 / (self.sampleRate * 0.150))
        dcOffset1 = tanhf(bias1 * drive1)
        dcOffset2 = tanhf(bias2 * drive2)

        setup(&highPassSetup, Self.highPassCoeffs(cutoff: 200, sr: sampleRate))
        setup(&lowPassSetup, Self.lowPassCoeffs(cutoff: 5500, sr: sampleRate))
        setup(&midBoostSetup, Self.peakingEQCoeffs(freq: 2200, gainDB: 3, Q: 0.8, sr: sampleRate))
        setup(&bassBoostSetup, Self.peakingEQCoeffs(freq: 180, gainDB: 2, Q: 0.7, sr: sampleRate))
        setup(&preEmphasisSetup, Self.highShelfCoeffs(freq: 3000, gainDB: 3, sr: sampleRate))
        setup(&deEmphasisSetup, Self.highShelfCoeffs(freq: 3000, gainDB: -3, sr: sampleRate))
        setup(&interstageSetup, Self.lowPassCoeffs(cutoff: 6000, sr: sampleRate))

        setup(&kitchenHPSetup, Self.highPassCoeffs(cutoff: 200, sr: sampleRate))
        setup(&kitchenDoorSetup, Self.peakingEQCoeffs(freq: 600, gainDB: 6, Q: 2.0, sr: sampleRate))
        setup(&doorwayLPSetup, Self.lowPassCoeffs(cutoff: 1200, sr: sampleRate))
        setup(&stofaColorSetup, Self.peakingEQCoeffs(freq: 250, gainDB: 3, Q: 0.8, sr: sampleRate))

        eldhusDelaySamples = Int(sampleRate * 0.008)
        eldhusDelayBuf = [Float](repeating: 0, count: max(eldhusDelaySamples + 1, 2048))
        eldhusDelayIdx = 0
        stofaDelaySamples = Int(sampleRate * 0.025)
        stofaDelayBuf = [Float](repeating: 0, count: max(stofaDelaySamples + 1, 4096))
        stofaDelayIdx = 0

        resetDelays()
    }

    private func setup(_ ptr: inout OpaquePointer?, _ coeffs: [Double]) {
        if let s = ptr { vDSP_biquad_DestroySetup(s) }
        ptr = vDSP_biquad_CreateSetup(coeffs, 1)
    }

    private func resetDelays() {
        let zero4 = [Float](repeating: 0, count: 4)
        highPassDelays = zero4; highPassDelaysR = zero4
        lowPassDelays = zero4; lowPassDelaysR = zero4
        midBoostDelays = zero4; midBoostDelaysR = zero4
        bassBoostDelays = zero4; bassBoostDelaysR = zero4
        preEmphDelays = zero4; preEmphDelaysR = zero4
        deEmphDelays = zero4; deEmphDelaysR = zero4
        interstageDelays = zero4; interstageDelaysR = zero4
        kitchenHPDelays = zero4; kitchenHPDelaysR = zero4
        kitchenDoorDelays = zero4; kitchenDoorDelaysR = zero4
        doorwayLPDelays = zero4; doorwayLPDelaysR = zero4
        stofaColorDelays = zero4; stofaColorDelaysR = zero4
    }

    // MARK: - Process a buffer in-place

    func process(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)

        if tempBuffer.count < frameCount {
            tempBuffer = [Float](repeating: 0, count: frameCount)
        }

        guard channelCount >= 1 else { return }

        processChannel(channelData[0], frameCount: frameCount, isLeft: true)
        if channelCount >= 2 {
            processChannel(channelData[1], frameCount: frameCount, isLeft: false)

            // Mono collapse
            let n = vDSP_Length(frameCount)
            vDSP_vadd(channelData[0], 1, channelData[1], 1, channelData[0], 1, n)
            var half: Float = 0.5
            vDSP_vsmul(channelData[0], 1, &half, channelData[0], 1, n)
            memcpy(channelData[1], channelData[0], frameCount * MemoryLayout<Float>.size)
        }

        // Add noise (skip in clean)
        guard audioMode != .clean else { return }
        let noiseScale: Float = audioMode == .kitchen ? 1.5 : 1.0
        for i in 0..<frameCount {
            let noise = (noiseGen.next() + crackleGen.next()) * noiseScale
            channelData[0][i] += noise
            if channelCount >= 2 { channelData[1][i] += noise }
        }
    }

    // MARK: - Per-channel DSP

    private func processChannel(_ data: UnsafeMutablePointer<Float>, frameCount: Int, isLeft: Bool) {
        let n = vDSP_Length(frameCount)

        if audioMode == .clean { return }

        func bq(_ setup: OpaquePointer?, _ dL: inout [Float], _ dR: inout [Float]) {
            guard let s = setup else { return }
            if isLeft { vDSP_biquad(s, &dL, data, 1, data, 1, n) }
            else { vDSP_biquad(s, &dR, data, 1, data, 1, n) }
        }

        let kitchen = audioMode == .kitchen

        // 1. HP
        if kitchen { bq(kitchenHPSetup, &kitchenHPDelays, &kitchenHPDelaysR) }
        else { bq(highPassSetup, &highPassDelays, &highPassDelaysR) }

        // 2. Exciter (skip kitchen)
        if !kitchen {
            tempBuffer.withUnsafeMutableBufferPointer { tmp in
                vDSP_vsq(data, 1, tmp.baseAddress!, 1, n)
                var amt = exciterAmount
                vDSP_vsma(tmp.baseAddress!, 1, &amt, data, 1, data, 1, n)
            }
        }

        // 3. Mid boost / kitchen resonance
        if kitchen { bq(kitchenDoorSetup, &kitchenDoorDelays, &kitchenDoorDelaysR) }
        else { bq(midBoostSetup, &midBoostDelays, &midBoostDelaysR) }

        // 4. Pre-emphasis (skip kitchen)
        if !kitchen { bq(preEmphasisSetup, &preEmphDelays, &preEmphDelaysR) }

        // 5. Saturation stage 1
        let d1: Float = kitchen ? 0.8 : drive1
        let b1: Float = kitchen ? 0.05 : bias1
        saturate(data, n: n, drive: d1, bias: b1, dcOffset: tanhf(b1 * d1))

        // 6. Interstage LP
        bq(interstageSetup, &interstageDelays, &interstageDelaysR)

        // 7. Saturation stage 2
        let d2: Float = kitchen ? 0.9 : drive2
        let b2: Float = kitchen ? 0.03 : bias2
        saturate(data, n: n, drive: d2, bias: b2, dcOffset: tanhf(b2 * d2))

        // 8. De-emphasis (skip kitchen)
        if !kitchen { bq(deEmphasisSetup, &deEmphDelays, &deEmphDelaysR) }

        // 9. Compressor
        compressor(data, frameCount: frameCount, isLeft: isLeft)

        // 9.5. FM detuning (lo-fi only)
        if !kitchen { fmDetune(data, frameCount: frameCount) }

        if kitchen {
            // Eldhús reverb
            bq(kitchenDoorSetup, &kitchenDoorDelays, &kitchenDoorDelaysR)
            applyDelay(data, frameCount: frameCount, buf: &eldhusDelayBuf, idx: &eldhusDelayIdx,
                       samples: eldhusDelaySamples, feedback: 0.55, wet: 0.60, dry: 0.50)

            // Doorway LP
            bq(doorwayLPSetup, &doorwayLPDelays, &doorwayLPDelaysR)

            // Stofa reverb
            bq(stofaColorSetup, &stofaColorDelays, &stofaColorDelaysR)
            applyDelay(data, frameCount: frameCount, buf: &stofaDelayBuf, idx: &stofaDelayIdx,
                       samples: stofaDelaySamples, feedback: 0.35, wet: 0.40, dry: 0.65)

            // Distance attenuation
            var gain: Float = 0.50
            vDSP_vsmul(data, 1, &gain, data, 1, n)
        } else {
            // Normal LP + bass
            bq(lowPassSetup, &lowPassDelays, &lowPassDelaysR)
            bq(bassBoostSetup, &bassBoostDelays, &bassBoostDelaysR)
        }
    }

    // MARK: - DSP primitives

    private func saturate(_ data: UnsafeMutablePointer<Float>, n: vDSP_Length, drive: Float, bias: Float, dcOffset: Float) {
        var b = bias; vDSP_vsadd(data, 1, &b, data, 1, n)
        var d = drive; vDSP_vsmul(data, 1, &d, data, 1, n)
        var count = Int32(n); vvtanhf(data, data, &count)
        var negDC = -dcOffset; vDSP_vsadd(data, 1, &negDC, data, 1, n)
    }

    private func compressor(_ data: UnsafeMutablePointer<Float>, frameCount: Int, isLeft: Bool) {
        let n = vDSP_Length(frameCount)
        var meansq: Float = 0
        vDSP_measqv(data, 1, &meansq, n)
        let rms = sqrtf(meansq)

        var envelope = isLeft ? compEnvelopeL : compEnvelopeR
        let coeff = rms > envelope ? compAttackCoeff : compReleaseCoeff
        envelope = coeff * envelope + (1 - coeff) * rms
        if isLeft { compEnvelopeL = envelope } else { compEnvelopeR = envelope }

        let threshold = compThreshold
        let knee = compKneeWidth
        var gainReduction: Float = 1.0

        if envelope > threshold + knee / 2 {
            let overDB = 20 * log10f(envelope / threshold)
            let compressedDB = overDB / compRatio
            gainReduction = powf(10, (compressedDB - overDB) / 20)
        } else if envelope > threshold - knee / 2 {
            let x = envelope - (threshold - knee / 2)
            let kneeRatio = x / knee
            let effectiveRatio = 1.0 + (compRatio - 1.0) * kneeRatio
            let overDB = 20 * log10f(envelope / threshold)
            let compressedDB = overDB / effectiveRatio
            gainReduction = powf(10, (compressedDB - overDB) / 20)
        }

        if gainReduction < 1.0 {
            vDSP_vsmul(data, 1, &gainReduction, data, 1, n)
        }
    }

    private func fmDetune(_ data: UnsafeMutablePointer<Float>, frameCount: Int) {
        let sr = sampleRate
        let driftRate: Float = 0.3 * 2 * .pi / sr
        let flutterRate: Float = 7.0 * 2 * .pi / sr
        let buzzRate: Float = 61.0 * 2 * .pi / sr
        let driftDepth: Float = 0.06
        let flutterDepth: Float = 0.03
        let buzzLevel: Float = 0.008

        for i in 0..<frameCount {
            let drift = 1.0 + driftDepth * sinf(fmPhase)
            let flutter = 1.0 + flutterDepth * sinf(fmFlutterPhase)
            let buzz = buzzLevel * sinf(fmInterferencePhase)
            data[i] = data[i] * drift * flutter + buzz
            fmPhase += driftRate
            fmFlutterPhase += flutterRate
            fmInterferencePhase += buzzRate
        }
        if fmPhase > 2 * .pi { fmPhase -= 2 * .pi }
        if fmFlutterPhase > 2 * .pi { fmFlutterPhase -= 2 * .pi }
        if fmInterferencePhase > 2 * .pi { fmInterferencePhase -= 2 * .pi }
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

    // MARK: - Biquad coefficient calculators

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

    static func highShelfCoeffs(freq: Double, gainDB: Double, sr: Double) -> [Double] {
        let A = pow(10, gainDB/40); let w0 = 2 * .pi * freq / sr
        let alpha = sin(w0)/2 * sqrt((A+1/A)*(1/0.7-1)+2)
        let c = cos(w0); let s2a = 2*sqrt(A)*alpha
        let a0 = (A+1)-(A-1)*c+s2a
        return [A*((A+1)+(A-1)*c+s2a)/a0, -2*A*((A-1)+(A+1)*c)/a0,
                A*((A+1)+(A-1)*c-s2a)/a0, 2*((A-1)-(A+1)*c)/a0, ((A+1)-(A-1)*c-s2a)/a0]
    }
}

// MARK: - Vinyl crackle

struct CrackleGenerator {
    var density: Float = 0.0002
    var amplitude: Float = 0.03

    mutating func next() -> Float {
        guard Float.random(in: 0...1) < density else { return 0 }
        let sign: Float = Float.random(in: 0...1) > 0.5 ? 1.0 : -1.0
        return sign * amplitude * Float.random(in: 0.3...1.0)
    }
}

// MARK: - RadioPlayer

/// Thread-safe ring buffer of raw (unprocessed) PCM buffers.
private final class RawBufferRing: @unchecked Sendable {
    private let lock = NSLock()
    private var ring: [AVAudioPCMBuffer] = []
    private let maxCount = 8  // ~48s of audio at 6s segments

    func push(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        ring.append(buffer)
        if ring.count > maxCount { ring.removeFirst() }
        lock.unlock()
    }

    /// Returns a deep copy of all buffered segments.
    func snapshot() -> [AVAudioPCMBuffer] {
        lock.lock()
        let copy = ring.map { copyBuffer($0) }
        lock.unlock()
        return copy
    }

    /// Deep copy a PCM buffer so DSP can mutate it without affecting the ring.
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
    private let bufferRing: RawBufferRing

    private(set) var currentStation: Station?
    private(set) var isPlaying = false
    private(set) var isMuted = false
    private(set) var audioMode: AudioMode = .lofi

    private var silenceTimer: Timer?
    private let dsp = DSPContext()

    func play(station: Station) async {
        if currentStation == station && engine != nil {
            stop()
            return
        }

        stop()
        currentStation = station

        let hlsStreamer = HLSStreamer()
        self.streamer = hlsStreamer

        await hlsStreamer.start(station: station)

        // Single consumer: download, store in ring, process, schedule
        let dspRef = dsp
        let ring = bufferRing
        let modeRef = audioMode

        downloadTask = Task { [weak self] in
            var engineStarted = false

            for await buffer in await hlsStreamer.buffers {
                guard let self, !Task.isCancelled else { break }

                // Store raw copy in ring (for mode-switch reflush)
                ring.push(buffer)

                if !engineStarted {
                    let format = buffer.format
                    NSLog("🔊 RadioPlayer: starting engine with format \(format)")
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
                    self.isPlaying = true
                    engineStarted = true
                }

                // Process a copy (ring keeps the raw original)
                let copy = ring.snapshot().last!
                dspRef.process(copy)
                self.playerNode?.scheduleBuffer(copy, completionHandler: nil)
            }
        }
    }

    /// Flush engine queue and reprocess the last raw buffer with current DSP mode.
    private func reflush() {
        guard let node = playerNode else { return }
        node.stop()

        // Grab the most recent raw buffer, process with new mode, queue it
        if let latest = bufferRing.snapshot().last {
            dsp.process(latest)
            node.scheduleBuffer(latest, completionHandler: nil)
        }
        node.play()
    }

    func stop() {
        downloadTask?.cancel()
        downloadTask = nil
        playerNode?.stop()
        engine?.stop()
        engine = nil
        playerNode = nil
        if let s = streamer {
            Task { await s.stop() }
        }
        streamer = nil
        currentStation = nil
        isPlaying = false
    }

    func toggleMute() {
        guard let engine else { return }
        engine.mainMixerNode.outputVolume = engine.mainMixerNode.outputVolume > 0 ? 0 : 1
        isMuted = engine.mainMixerNode.outputVolume == 0
    }

    func setAudioMode(_ mode: AudioMode) {
        guard mode != audioMode else { return }
        audioMode = mode
        dsp.audioMode = mode

        // Flush old processed buffers and immediately reprocess from raw ring
        reflush()

        // Brief silence gap as audible cue
        engine?.mainMixerNode.outputVolume = 0
        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: false) { [weak self] _ in
            let captured = self
            Task { @MainActor in
                guard let s = captured, !s.isMuted else { return }
                s.engine?.mainMixerNode.outputVolume = 1
            }
        }
    }
}
