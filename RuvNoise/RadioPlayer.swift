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

// MARK: - DSP Context passed into MTAudioProcessingTap callbacks

private final class TapContext {
    var noiseGen = PinkNoiseGenerator()
    var crackleGen = CrackleGenerator()

    var sampleRate: Float = 44100
    var kitchenMode = false                  // Toggled from RadioPlayer

    // Filter setups (created in configureBiquads)
    var highPassSetup: OpaquePointer?       // HP (200 Hz normal, 400 Hz kitchen)
    var lowPassSetup: OpaquePointer?        // LP (5.5 kHz normal, 3 kHz kitchen)
    var midBoostSetup: OpaquePointer?       // Peaking 2.2 kHz +4 dB
    var bassBoostSetup: OpaquePointer?      // Peaking 180 Hz +2 dB
    var preEmphasisSetup: OpaquePointer?    // High shelf +3 dB at 3 kHz
    var deEmphasisSetup: OpaquePointer?     // High shelf -3 dB at 3 kHz
    var interstageSetup: OpaquePointer?     // LP 6 kHz between saturation stages

    // Kitchen mode: "radio in the other room" simulation
    var kitchenHPSetup: OpaquePointer?      // HP 200 Hz
    var kitchenLP1Setup: OpaquePointer?     // LP 1000 Hz (wall absorption stage 1)
    var kitchenLP2Setup: OpaquePointer?     // LP 800 Hz (wall absorption stage 2)
    var kitchenDoorSetup: OpaquePointer?    // Peaking 700 Hz +6 dB Q=3 (doorway resonance)
    var kitchenRoomSetup: OpaquePointer?    // Peaking 200 Hz +3 dB Q=1.0 (room mode)
    var kitchenHPDelays = [Float](repeating: 0, count: 4)
    var kitchenHPDelaysR = [Float](repeating: 0, count: 4)
    var kitchenLP1Delays = [Float](repeating: 0, count: 4)
    var kitchenLP1DelaysR = [Float](repeating: 0, count: 4)
    var kitchenLP2Delays = [Float](repeating: 0, count: 4)
    var kitchenLP2DelaysR = [Float](repeating: 0, count: 4)
    var kitchenDoorDelays = [Float](repeating: 0, count: 4)
    var kitchenDoorDelaysR = [Float](repeating: 0, count: 4)
    var kitchenRoomDelays = [Float](repeating: 0, count: 4)
    var kitchenRoomDelaysR = [Float](repeating: 0, count: 4)

    // Feedback delay line for kitchen wall reflections.
    // A short delay with feedback creates a decaying series of reflections
    // simulating the small kitchen's reverberant field.
    var kitchenDelayBuf = [Float](repeating: 0, count: 2048)
    var kitchenDelayIdx: Int = 0
    var kitchenDelaySamples: Int = 662      // ~15ms at 44100

    // Per-channel biquad delay state (L and R)
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

    // Compressor state per channel
    var compEnvelopeL: Float = 0
    var compEnvelopeR: Float = 0

    // Temp buffer for exciter x² computation
    var tempBuffer = [Float](repeating: 0, count: 8192)

    // Saturation parameters
    let drive1: Float = 1.2
    let bias1: Float = 0.15
    let drive2: Float = 1.4
    let bias2: Float = 0.1
    let exciterAmount: Float = 0.15

    // Compressor parameters
    let compThreshold: Float = 0.25    // ~-12 dBFS
    let compRatio: Float = 3.0
    let compKneeWidth: Float = 0.25    // in linear amplitude
    var compAttackCoeff: Float = 0
    var compReleaseCoeff: Float = 0

    // DC offset corrections (precomputed)
    var dcOffset1: Float = 0
    var dcOffset2: Float = 0

    deinit {
        for setup in [highPassSetup, lowPassSetup, midBoostSetup, bassBoostSetup,
                      preEmphasisSetup, deEmphasisSetup, interstageSetup,
                      kitchenHPSetup, kitchenLP1Setup, kitchenLP2Setup,
                      kitchenDoorSetup, kitchenRoomSetup] {
            if let s = setup { vDSP_biquad_DestroySetup(s) }
        }
    }

    func configureBiquads(sampleRate: Double) {
        self.sampleRate = Float(sampleRate)

        // Precompute compressor coefficients
        compAttackCoeff = expf(-1.0 / (self.sampleRate * 0.020))   // 20 ms attack
        compReleaseCoeff = expf(-1.0 / (self.sampleRate * 0.150))  // 150 ms release

        // Precompute DC offset corrections for asymmetric saturation
        dcOffset1 = tanhf(bias1 * drive1)
        dcOffset2 = tanhf(bias2 * drive2)

        // HP at 200 Hz
        destroyAndCreate(&highPassSetup, Self.highPassCoefficients(cutoff: 200, sampleRate: sampleRate))
        highPassDelays = [Float](repeating: 0, count: 4)
        highPassDelaysR = [Float](repeating: 0, count: 4)

        // LP at 5500 Hz
        destroyAndCreate(&lowPassSetup, Self.lowPassCoefficients(cutoff: 5500, sampleRate: sampleRate))
        lowPassDelays = [Float](repeating: 0, count: 4)
        lowPassDelaysR = [Float](repeating: 0, count: 4)

        // Mid presence boost: 2.2 kHz, +4 dB, Q=0.8
        destroyAndCreate(&midBoostSetup, Self.peakingEQCoefficients(centerFreq: 2200, gainDB: 4, Q: 0.8, sampleRate: sampleRate))
        midBoostDelays = [Float](repeating: 0, count: 4)
        midBoostDelaysR = [Float](repeating: 0, count: 4)

        // Bass resonance: 180 Hz, +2 dB, Q=0.7
        destroyAndCreate(&bassBoostSetup, Self.peakingEQCoefficients(centerFreq: 180, gainDB: 2, Q: 0.7, sampleRate: sampleRate))
        bassBoostDelays = [Float](repeating: 0, count: 4)
        bassBoostDelaysR = [Float](repeating: 0, count: 4)

        // Tape pre-emphasis: high shelf +3 dB at 3 kHz
        destroyAndCreate(&preEmphasisSetup, Self.highShelfCoefficients(freq: 3000, gainDB: 3, sampleRate: sampleRate))
        preEmphDelays = [Float](repeating: 0, count: 4)
        preEmphDelaysR = [Float](repeating: 0, count: 4)

        // Tape de-emphasis: high shelf -3 dB at 3 kHz
        destroyAndCreate(&deEmphasisSetup, Self.highShelfCoefficients(freq: 3000, gainDB: -3, sampleRate: sampleRate))
        deEmphDelays = [Float](repeating: 0, count: 4)
        deEmphDelaysR = [Float](repeating: 0, count: 4)

        // Interstage LP at 6 kHz
        destroyAndCreate(&interstageSetup, Self.lowPassCoefficients(cutoff: 6000, sampleRate: sampleRate))
        interstageDelays = [Float](repeating: 0, count: 4)
        interstageDelaysR = [Float](repeating: 0, count: 4)

        // Kitchen mode: "radio in the other room" — heavily muffled through walls
        destroyAndCreate(&kitchenHPSetup, Self.highPassCoefficients(cutoff: 200, sampleRate: sampleRate))
        kitchenHPDelays = [Float](repeating: 0, count: 4)
        kitchenHPDelaysR = [Float](repeating: 0, count: 4)
        // Cascaded LP for aggressive wall absorption — kills everything above ~800 Hz
        destroyAndCreate(&kitchenLP1Setup, Self.lowPassCoefficients(cutoff: 1000, sampleRate: sampleRate))
        kitchenLP1Delays = [Float](repeating: 0, count: 4)
        kitchenLP1DelaysR = [Float](repeating: 0, count: 4)
        destroyAndCreate(&kitchenLP2Setup, Self.lowPassCoefficients(cutoff: 800, sampleRate: sampleRate))
        kitchenLP2Delays = [Float](repeating: 0, count: 4)
        kitchenLP2DelaysR = [Float](repeating: 0, count: 4)
        // Doorway resonance — strong nasal coloring from sound funneling through the opening
        destroyAndCreate(&kitchenDoorSetup, Self.peakingEQCoefficients(centerFreq: 700, gainDB: 6, Q: 3.0, sampleRate: sampleRate))
        kitchenDoorDelays = [Float](repeating: 0, count: 4)
        kitchenDoorDelaysR = [Float](repeating: 0, count: 4)
        // Room mode from kitchen standing waves
        destroyAndCreate(&kitchenRoomSetup, Self.peakingEQCoefficients(centerFreq: 200, gainDB: 3, Q: 1.0, sampleRate: sampleRate))
        kitchenRoomDelays = [Float](repeating: 0, count: 4)
        kitchenRoomDelaysR = [Float](repeating: 0, count: 4)
        // Feedback delay line for kitchen wall reflections (~15ms)
        kitchenDelaySamples = Int(sampleRate * 0.015)
        kitchenDelayBuf = [Float](repeating: 0, count: max(kitchenDelaySamples + 1, 2048))
        kitchenDelayIdx = 0
    }

    private func destroyAndCreate(_ setup: inout OpaquePointer?, _ coeffs: [Double]) {
        if let s = setup { vDSP_biquad_DestroySetup(s) }
        setup = vDSP_biquad_CreateSetup(coeffs, 1)
    }

    // MARK: - Biquad coefficient calculators

    static func highPassCoefficients(cutoff: Double, sampleRate: Double) -> [Double] {
        let w0 = 2.0 * Double.pi * cutoff / sampleRate
        let alpha = sin(w0) / (2.0 * sqrt(2.0))
        let cosW0 = cos(w0)
        let a0 = 1.0 + alpha
        return [
            ((1.0 + cosW0) / 2.0) / a0,
            (-(1.0 + cosW0)) / a0,
            ((1.0 + cosW0) / 2.0) / a0,
            (-2.0 * cosW0) / a0,
            (1.0 - alpha) / a0,
        ]
    }

    static func lowPassCoefficients(cutoff: Double, sampleRate: Double) -> [Double] {
        let w0 = 2.0 * Double.pi * cutoff / sampleRate
        let alpha = sin(w0) / (2.0 * sqrt(2.0))
        let cosW0 = cos(w0)
        let a0 = 1.0 + alpha
        return [
            ((1.0 - cosW0) / 2.0) / a0,
            (1.0 - cosW0) / a0,
            ((1.0 - cosW0) / 2.0) / a0,
            (-2.0 * cosW0) / a0,
            (1.0 - alpha) / a0,
        ]
    }

    static func peakingEQCoefficients(centerFreq: Double, gainDB: Double, Q: Double, sampleRate: Double) -> [Double] {
        let A = pow(10.0, gainDB / 40.0)
        let w0 = 2.0 * Double.pi * centerFreq / sampleRate
        let alpha = sin(w0) / (2.0 * Q)
        let cosW0 = cos(w0)
        let a0 = 1.0 + alpha / A
        return [
            (1.0 + alpha * A) / a0,
            (-2.0 * cosW0) / a0,
            (1.0 - alpha * A) / a0,
            (-2.0 * cosW0) / a0,
            (1.0 - alpha / A) / a0,
        ]
    }

    static func highShelfCoefficients(freq: Double, gainDB: Double, sampleRate: Double) -> [Double] {
        let A = pow(10.0, gainDB / 40.0)
        let w0 = 2.0 * Double.pi * freq / sampleRate
        let S = 0.7
        let alpha = sin(w0) / 2.0 * sqrt((A + 1.0 / A) * (1.0 / S - 1.0) + 2.0)
        let cosW0 = cos(w0)
        let sqrtA2alpha = 2.0 * sqrt(A) * alpha
        let a0 = (A + 1) - (A - 1) * cosW0 + sqrtA2alpha
        return [
            (A * ((A + 1) + (A - 1) * cosW0 + sqrtA2alpha)) / a0,
            (-2 * A * ((A - 1) + (A + 1) * cosW0)) / a0,
            (A * ((A + 1) + (A - 1) * cosW0 - sqrtA2alpha)) / a0,
            (2 * ((A - 1) - (A + 1) * cosW0)) / a0,
            ((A + 1) - (A - 1) * cosW0 - sqrtA2alpha) / a0,
        ]
    }
}

// MARK: - Vinyl crackle generator

struct CrackleGenerator {
    var density: Float = 0.0003
    var amplitude: Float = 0.04

    mutating func next() -> Float {
        guard Float.random(in: 0...1) < density else { return 0 }
        let sign: Float = Float.random(in: 0...1) > 0.5 ? 1.0 : -1.0
        return sign * amplitude * Float.random(in: 0.3...1.0)
    }
}

// MARK: - MTAudioProcessingTap callbacks

private func tapInit(
    tap: MTAudioProcessingTap,
    clientInfo: UnsafeMutableRawPointer?,
    tapStorageOut: UnsafeMutablePointer<UnsafeMutableRawPointer?>
) {
    tapStorageOut.pointee = clientInfo
}

private func tapFinalize(tap: MTAudioProcessingTap) {}

private func tapPrepare(
    tap: MTAudioProcessingTap,
    maxFrames: CMItemCount,
    processingFormat: UnsafePointer<AudioStreamBasicDescription>
) {
    let ctx = Unmanaged<TapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
    ctx.configureBiquads(sampleRate: processingFormat.pointee.mSampleRate)
    // Ensure temp buffer is large enough
    if ctx.tempBuffer.count < Int(maxFrames) {
        ctx.tempBuffer = [Float](repeating: 0, count: Int(maxFrames))
    }
}

private func tapUnprepare(tap: MTAudioProcessingTap) {}

private func tapProcess(
    tap: MTAudioProcessingTap,
    numberFrames: CMItemCount,
    flags: MTAudioProcessingTapFlags,
    bufferListInOut: UnsafeMutablePointer<AudioBufferList>,
    numberFramesOut: UnsafeMutablePointer<CMItemCount>,
    flagsOut: UnsafeMutablePointer<MTAudioProcessingTapFlags>
) {
    var sourceFlags = MTAudioProcessingTapFlags(0)
    let status = MTAudioProcessingTapGetSourceAudio(tap, numberFrames, bufferListInOut, &sourceFlags, nil, numberFramesOut)
    guard status == noErr else { return }

    let ctx = Unmanaged<TapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
    let frameCount = Int(numberFramesOut.pointee)

    let ablPointer = UnsafeMutableAudioBufferListPointer(bufferListInOut)
    let channelCount = ablPointer.count

    guard channelCount >= 1, let data0 = ablPointer[0].mData?.assumingMemoryBound(to: Float.self) else { return }

    processChannel(data0, frameCount: frameCount, ctx: ctx, isLeft: true)

    if channelCount >= 2, let data1 = ablPointer[1].mData?.assumingMemoryBound(to: Float.self) {
        processChannel(data1, frameCount: frameCount, ctx: ctx, isLeft: false)

        // Mono collapse: average L+R
        vDSP_vadd(data0, 1, data1, 1, data0, 1, vDSP_Length(frameCount))
        var half: Float = 0.5
        vDSP_vsmul(data0, 1, &half, data0, 1, vDSP_Length(frameCount))
        memcpy(data1, data0, frameCount * MemoryLayout<Float>.size)
    }

    // Add pink noise + vinyl crackle.
    // Kitchen mode uses 1.5x noise (less than before, but the -10 dB signal
    // attenuation makes it relatively much more prominent — like room ambience).
    let noiseScale: Float = ctx.kitchenMode ? 1.5 : 1.0
    for i in 0..<frameCount {
        let noise = (ctx.noiseGen.next() + ctx.crackleGen.next()) * noiseScale
        data0[i] += noise
        if channelCount >= 2, let data1 = ablPointer[1].mData?.assumingMemoryBound(to: Float.self) {
            data1[i] += noise
        }
    }
}

// MARK: - Per-channel DSP pipeline

private func processChannel(_ data: UnsafeMutablePointer<Float>, frameCount: Int, ctx: TapContext, isLeft: Bool) {
    let n = vDSP_Length(frameCount)

    // Helper to pick L/R delay state
    func biquad(_ setup: OpaquePointer?, _ delaysL: inout [Float], _ delaysR: inout [Float]) {
        guard let setup else { return }
        if isLeft {
            vDSP_biquad(setup, &delaysL, data, 1, data, 1, n)
        } else {
            vDSP_biquad(setup, &delaysR, data, 1, data, 1, n)
        }
    }

    let kitchen = ctx.kitchenMode

    // 1. High-pass
    if kitchen {
        biquad(ctx.kitchenHPSetup, &ctx.kitchenHPDelays, &ctx.kitchenHPDelaysR)
    } else {
        biquad(ctx.highPassSetup, &ctx.highPassDelays, &ctx.highPassDelaysR)
    }

    // 2. 2nd harmonic exciter — skip entirely in kitchen (distance kills harmonics)
    if !kitchen {
        ctx.tempBuffer.withUnsafeMutableBufferPointer { tmp in
            vDSP_vsq(data, 1, tmp.baseAddress!, 1, n)
            var amount = ctx.exciterAmount
            vDSP_vsma(tmp.baseAddress!, 1, &amount, data, 1, data, 1, n)
        }
    }

    // 3. Mid-range presence / doorway resonance
    if kitchen {
        biquad(ctx.kitchenDoorSetup, &ctx.kitchenDoorDelays, &ctx.kitchenDoorDelaysR)
    } else {
        biquad(ctx.midBoostSetup, &ctx.midBoostDelays, &ctx.midBoostDelaysR)
    }

    // 4. Tape pre-emphasis (skip in kitchen — irrelevant at this distance)
    if !kitchen {
        biquad(ctx.preEmphasisSetup, &ctx.preEmphDelays, &ctx.preEmphDelaysR)
    }

    // 5. Saturation stage 1 — very gentle in kitchen
    let d1: Float = kitchen ? 0.8 : ctx.drive1
    let b1: Float = kitchen ? 0.05 : ctx.bias1
    asymmetricSaturate(data, n: n, drive: d1, bias: b1, dcOffset: tanhf(b1 * d1))

    // 6. Interstage LP at 6 kHz
    biquad(ctx.interstageSetup, &ctx.interstageDelays, &ctx.interstageDelaysR)

    // 7. Saturation stage 2 — barely there in kitchen
    let d2: Float = kitchen ? 0.9 : ctx.drive2
    let b2: Float = kitchen ? 0.03 : ctx.bias2
    asymmetricSaturate(data, n: n, drive: d2, bias: b2, dcOffset: tanhf(b2 * d2))

    // 8. Tape de-emphasis (skip in kitchen)
    if !kitchen {
        biquad(ctx.deEmphasisSetup, &ctx.deEmphDelays, &ctx.deEmphDelaysR)
    }

    // 9. Compressor
    applyCompressor(data, frameCount: frameCount, ctx: ctx, isLeft: isLeft)

    // 10. Low-pass — wall absorption
    if kitchen {
        // Aggressive cascaded LP: walls kill everything above ~800 Hz
        biquad(ctx.kitchenLP1Setup, &ctx.kitchenLP1Delays, &ctx.kitchenLP1DelaysR)
        biquad(ctx.kitchenLP2Setup, &ctx.kitchenLP2Delays, &ctx.kitchenLP2DelaysR)
    } else {
        biquad(ctx.lowPassSetup, &ctx.lowPassDelays, &ctx.lowPassDelaysR)
    }

    // 11. Bass resonance / room color
    if kitchen {
        biquad(ctx.kitchenRoomSetup, &ctx.kitchenRoomDelays, &ctx.kitchenRoomDelaysR)
    } else {
        biquad(ctx.bassBoostSetup, &ctx.bassBoostDelays, &ctx.bassBoostDelaysR)
    }

    if kitchen {
        // 12. Feedback delay — kitchen wall reflections.
        // A ~15ms delay with 0.35 feedback creates a decaying series of reflections
        // (15ms, 30ms, 45ms...) simulating the small kitchen's reverberant field.
        // High wet mix (0.5) for that unmistakable "other room" washy quality.
        let delay = ctx.kitchenDelaySamples
        let bufLen = ctx.kitchenDelayBuf.count
        let feedback: Float = 0.35
        let wet: Float = 0.50
        let dry: Float = 0.55
        for i in 0..<frameCount {
            let readIdx = (ctx.kitchenDelayIdx - delay + bufLen) % bufLen
            let delayed = ctx.kitchenDelayBuf[readIdx]
            // Feed back into the delay buffer for decaying reflections
            ctx.kitchenDelayBuf[ctx.kitchenDelayIdx] = data[i] + delayed * feedback
            ctx.kitchenDelayIdx = (ctx.kitchenDelayIdx + 1) % bufLen
            data[i] = data[i] * dry + delayed * wet
        }

        // 13. Distance attenuation — far corner to far corner (~-14 dB)
        var gain: Float = 0.20
        vDSP_vsmul(data, 1, &gain, data, 1, n)
    }
}

// MARK: - Asymmetric tube saturation

private func asymmetricSaturate(_ data: UnsafeMutablePointer<Float>, n: vDSP_Length, drive: Float, bias: Float, dcOffset: Float) {
    // Add bias
    var b = bias
    vDSP_vsadd(data, 1, &b, data, 1, n)

    // Apply drive
    var d = drive
    vDSP_vsmul(data, 1, &d, data, 1, n)

    // tanh saturation
    var count = Int32(n)
    vvtanhf(data, data, &count)

    // Remove DC offset from bias
    var negDC = -dcOffset
    vDSP_vsadd(data, 1, &negDC, data, 1, n)
}

// MARK: - Soft-knee RMS compressor

private func applyCompressor(_ data: UnsafeMutablePointer<Float>, frameCount: Int, ctx: TapContext, isLeft: Bool) {
    let n = vDSP_Length(frameCount)

    // Compute RMS of this block
    var meansq: Float = 0
    vDSP_measqv(data, 1, &meansq, n)
    let rms = sqrtf(meansq)

    // Smooth envelope
    var envelope = isLeft ? ctx.compEnvelopeL : ctx.compEnvelopeR
    let coeff = rms > envelope ? ctx.compAttackCoeff : ctx.compReleaseCoeff
    envelope = coeff * envelope + (1 - coeff) * rms
    if isLeft { ctx.compEnvelopeL = envelope } else { ctx.compEnvelopeR = envelope }

    // Soft-knee gain calculation
    let threshold = ctx.compThreshold
    let knee = ctx.compKneeWidth
    let ratio = ctx.compRatio

    var gainReduction: Float = 1.0

    if envelope > threshold + knee / 2 {
        // Above knee — full compression
        let overDB = 20 * log10f(envelope / threshold)
        let compressedDB = overDB / ratio
        gainReduction = powf(10, (compressedDB - overDB) / 20)
    } else if envelope > threshold - knee / 2 {
        // In the knee — gradual onset
        let x = envelope - (threshold - knee / 2)
        let kneeRatio = x / knee  // 0..1 through the knee
        let effectiveRatio = 1.0 + (ratio - 1.0) * kneeRatio
        let overDB = 20 * log10f(envelope / threshold)
        let compressedDB = overDB / effectiveRatio
        gainReduction = powf(10, (compressedDB - overDB) / 20)
    }

    if gainReduction < 1.0 {
        vDSP_vsmul(data, 1, &gainReduction, data, 1, n)
    }
}

// MARK: - MTAudioProcessingTap creation (handles SDK bridging differences)

// C-level MTAudioProcessingTapCreate always takes a CFTypeRef* (void**) output.
// The Swift bridging changed between SDK versions (Unmanaged vs direct), so we
// call the C function directly to avoid type mismatches.
@_silgen_name("MTAudioProcessingTapCreate")
private func _MTAudioProcessingTapCreate(
    _ allocator: CFAllocator?,
    _ callbacks: UnsafePointer<MTAudioProcessingTapCallbacks>,
    _ flags: MTAudioProcessingTapCreationFlags,
    _ tapOut: UnsafeMutablePointer<Unmanaged<MTAudioProcessingTap>?>
) -> OSStatus

private func createProcessingTap(_ callbacks: inout MTAudioProcessingTapCallbacks) -> MTAudioProcessingTap? {
    var tap: Unmanaged<MTAudioProcessingTap>?
    let status = _MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PostEffects, &tap)
    guard status == noErr else { return nil }
    return tap?.takeRetainedValue()
}

// MARK: - RadioPlayer

@MainActor
@Observable
final class RadioPlayer {
    nonisolated init() {}

    private var player: AVPlayer?
    private var tapContext: TapContext?
    private var playerObservation: NSKeyValueObservation?

    private(set) var currentStation: Station?
    private(set) var isPlaying = false
    private(set) var isMuted = false
    private(set) var kitchenMode = false

    func play(station: Station) async {
        if currentStation == station && player != nil {
            stop()
            return
        }

        stop()
        currentStation = station

        let asset = AVURLAsset(url: station.url)
        let item = AVPlayerItem(asset: asset)

        let ctx = TapContext()
        self.tapContext = ctx
        let ctxPointer = Unmanaged.passUnretained(ctx).toOpaque()

        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: ctxPointer,
            init: tapInit,
            finalize: tapFinalize,
            prepare: tapPrepare,
            unprepare: tapUnprepare,
            process: tapProcess
        )

        let resolvedTap: MTAudioProcessingTap? = createProcessingTap(&callbacks)

        if let tap = resolvedTap {
            let audioMix = AVMutableAudioMix()
            if let audioTrack = try? await asset.loadTracks(withMediaType: .audio).first {
                let params = AVMutableAudioMixInputParameters(track: audioTrack)
                params.audioTapProcessor = tap
                audioMix.inputParameters = [params]
                item.audioMix = audioMix
            }
        }

        let avPlayer = AVPlayer(playerItem: item)
        self.player = avPlayer

        playerObservation = avPlayer.observe(\.timeControlStatus) { [weak self] _, _ in
            let captured = self
            Task { @MainActor in
                captured?.updateState()
            }
        }

        avPlayer.play()
        updateState()
    }

    func stop() {
        player?.pause()
        player = nil
        playerObservation = nil
        tapContext = nil
        currentStation = nil
        updateState()
    }

    func toggleMute() {
        guard let player else { return }
        player.isMuted.toggle()
        isMuted = player.isMuted
    }

    func toggleKitchenMode() {
        kitchenMode.toggle()
        tapContext?.kitchenMode = kitchenMode
    }

    private func updateState() {
        isPlaying = player?.timeControlStatus == .playing || player?.timeControlStatus == .waitingToPlayAtSpecifiedRate
        isMuted = player?.isMuted ?? false
    }
}
