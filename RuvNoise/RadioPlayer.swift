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

    // Biquad filter state — high-pass 300 Hz + low-pass 4 kHz
    // We'll set these up in prepare() once we know the sample rate
    var highPassSetup: OpaquePointer?
    var lowPassSetup: OpaquePointer?
    var highPassDelays = [Float](repeating: 0, count: 2 + 2) // vDSP_deq22 needs N+2
    var lowPassDelays = [Float](repeating: 0, count: 2 + 2)

    // Second channel filter state (for stereo before mono collapse)
    var highPassDelaysR = [Float](repeating: 0, count: 2 + 2)
    var lowPassDelaysR = [Float](repeating: 0, count: 2 + 2)

    var sampleRate: Float = 44100

    // Saturation drive
    let drive: Float = 1.8

    deinit {
        if let s = highPassSetup { vDSP_biquad_DestroySetup(s) }
        if let s = lowPassSetup { vDSP_biquad_DestroySetup(s) }
    }

    func configureBiquads(sampleRate: Double) {
        self.sampleRate = Float(sampleRate)

        // High-pass at 300 Hz (second-order Butterworth)
        let hpCoeffs = Self.highPassCoefficients(cutoff: 300, sampleRate: sampleRate)
        if let s = highPassSetup { vDSP_biquad_DestroySetup(s) }
        highPassSetup = vDSP_biquad_CreateSetup(hpCoeffs, 1)
        highPassDelays = [Float](repeating: 0, count: 2 + 2)
        highPassDelaysR = [Float](repeating: 0, count: 2 + 2)

        // Low-pass at 4000 Hz (second-order Butterworth)
        let lpCoeffs = Self.lowPassCoefficients(cutoff: 4000, sampleRate: sampleRate)
        if let s = lowPassSetup { vDSP_biquad_DestroySetup(s) }
        lowPassSetup = vDSP_biquad_CreateSetup(lpCoeffs, 1)
        lowPassDelays = [Float](repeating: 0, count: 2 + 2)
        lowPassDelaysR = [Float](repeating: 0, count: 2 + 2)
    }

    // Butterworth high-pass coefficients for vDSP_biquad (b0,b1,b2,a1,a2)
    private static func highPassCoefficients(cutoff: Double, sampleRate: Double) -> [Double] {
        let w0 = 2.0 * Double.pi * cutoff / sampleRate
        let alpha = sin(w0) / (2.0 * sqrt(2.0)) // Q = sqrt(2)/2 for Butterworth
        let cosW0 = cos(w0)
        let a0 = 1.0 + alpha
        let b0 = ((1.0 + cosW0) / 2.0) / a0
        let b1 = (-(1.0 + cosW0)) / a0
        let b2 = ((1.0 + cosW0) / 2.0) / a0
        let a1 = (-2.0 * cosW0) / a0
        let a2 = (1.0 - alpha) / a0
        return [b0, b1, b2, a1, a2]
    }

    // Butterworth low-pass coefficients for vDSP_biquad
    private static func lowPassCoefficients(cutoff: Double, sampleRate: Double) -> [Double] {
        let w0 = 2.0 * Double.pi * cutoff / sampleRate
        let alpha = sin(w0) / (2.0 * sqrt(2.0))
        let cosW0 = cos(w0)
        let a0 = 1.0 + alpha
        let b0 = ((1.0 - cosW0) / 2.0) / a0
        let b1 = (1.0 - cosW0) / a0
        let b2 = ((1.0 - cosW0) / 2.0) / a0
        let a1 = (-2.0 * cosW0) / a0
        let a2 = (1.0 - alpha) / a0
        return [b0, b1, b2, a1, a2]
    }
}

// MARK: - MTAudioProcessingTap callbacks

private func tapInit(
    tap: MTAudioProcessingTap,
    clientInfo: UnsafeMutableRawPointer?,
    tapStorageOut: UnsafeMutablePointer<UnsafeMutableRawPointer?>
) {
    // Pass through the context pointer
    tapStorageOut.pointee = clientInfo
}

private func tapFinalize(tap: MTAudioProcessingTap) {
    // Context is owned by RadioPlayer, nothing to free here
}

private func tapPrepare(
    tap: MTAudioProcessingTap,
    maxFrames: CMItemCount,
    processingFormat: UnsafePointer<AudioStreamBasicDescription>
) {
    let ctx = Unmanaged<TapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
    ctx.configureBiquads(sampleRate: processingFormat.pointee.mSampleRate)
}

private func tapUnprepare(tap: MTAudioProcessingTap) {
    // Nothing to clean up
}

private func tapProcess(
    tap: MTAudioProcessingTap,
    numberFrames: CMItemCount,
    flags: MTAudioProcessingTapFlags,
    bufferListInOut: UnsafeMutablePointer<AudioBufferList>,
    numberFramesOut: UnsafeMutablePointer<CMItemCount>,
    flagsOut: UnsafeMutablePointer<MTAudioProcessingTapFlags>
) {
    // Get source audio
    var sourceFlags = MTAudioProcessingTapFlags(rawValue: 0)
    let status = MTAudioProcessingTapGetSourceAudio(tap, numberFrames, bufferListInOut, &sourceFlags, nil, numberFramesOut)
    guard status == noErr else { return }

    let ctx = Unmanaged<TapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
    let frameCount = Int(numberFramesOut.pointee)

    // Access audio buffers
    let ablPointer = UnsafeMutableAudioBufferListPointer(bufferListInOut)
    let channelCount = ablPointer.count

    guard channelCount >= 1, let data0 = ablPointer[0].mData?.assumingMemoryBound(to: Float.self) else { return }

    // Process left channel (or mono)
    processChannel(data0, frameCount: frameCount, ctx: ctx, isLeft: true)

    if channelCount >= 2, let data1 = ablPointer[1].mData?.assumingMemoryBound(to: Float.self) {
        // Process right channel
        processChannel(data1, frameCount: frameCount, ctx: ctx, isLeft: false)

        // Mono collapse: average L and R, write to both
        vDSP_vadd(data0, 1, data1, 1, data0, 1, vDSP_Length(frameCount))
        var half: Float = 0.5
        vDSP_vsmul(data0, 1, &half, data0, 1, vDSP_Length(frameCount))
        // Copy mono to right channel
        memcpy(data1, data0, frameCount * MemoryLayout<Float>.size)
    }

    // Add pink noise
    for i in 0..<frameCount {
        let noise = ctx.noiseGen.next()
        data0[i] += noise
        if channelCount >= 2, let data1 = ablPointer[1].mData?.assumingMemoryBound(to: Float.self) {
            data1[i] += noise
        }
    }
}

private func processChannel(_ data: UnsafeMutablePointer<Float>, frameCount: Int, ctx: TapContext, isLeft: Bool) {
    let n = vDSP_Length(frameCount)

    // 1. High-pass filter at 300 Hz
    if let setup = ctx.highPassSetup {
        if isLeft {
            vDSP_biquad(setup, &ctx.highPassDelays, data, 1, data, 1, n)
        } else {
            vDSP_biquad(setup, &ctx.highPassDelaysR, data, 1, data, 1, n)
        }
    }

    // 2. Low-pass filter at 4 kHz
    if let setup = ctx.lowPassSetup {
        if isLeft {
            vDSP_biquad(setup, &ctx.lowPassDelays, data, 1, data, 1, n)
        } else {
            vDSP_biquad(setup, &ctx.lowPassDelaysR, data, 1, data, 1, n)
        }
    }

    // 3. Soft saturation: tanh(x * drive)
    var drive = ctx.drive
    vDSP_vsmul(data, 1, &drive, data, 1, n)

    var count = Int32(frameCount)
    vvtanhf(data, data, &count)
}

// MARK: - RadioPlayer

final class RadioPlayer: NSObject {
    private var player: AVPlayer?
    private var tapContext: TapContext?
    private var playerObservation: NSKeyValueObservation?

    private(set) var currentStation: Station?
    var onStateChange: (() -> Void)?

    var isPlaying: Bool {
        player?.timeControlStatus == .playing || player?.timeControlStatus == .waitingToPlayAtSpecifiedRate
    }

    func play(station: Station) {
        // If same station is playing, toggle off
        if currentStation == station && player != nil {
            stop()
            return
        }

        stop()
        currentStation = station

        let asset = AVURLAsset(url: station.url)
        let item = AVPlayerItem(asset: asset)

        // Set up audio processing tap
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

        var tap: Unmanaged<MTAudioProcessingTap>?
        let status = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PostEffects, &tap)

        if status == noErr, let tap = tap {
            let audioMix = AVMutableAudioMix()
            let params = AVMutableAudioMixInputParameters(track: asset.tracks(withMediaType: .audio).first)
            params.audioTapProcessor = tap.takeRetainedValue()
            audioMix.inputParameters = [params]
            item.audioMix = audioMix
        }

        let avPlayer = AVPlayer(playerItem: item)
        self.player = avPlayer

        // Observe playback state
        playerObservation = avPlayer.observe(\.timeControlStatus) { [weak self] _, _ in
            DispatchQueue.main.async { self?.onStateChange?() }
        }

        avPlayer.play()
        onStateChange?()
    }

    func stop() {
        player?.pause()
        player = nil
        playerObservation = nil
        tapContext = nil
        currentStation = nil
        onStateChange?()
    }

    func toggleMute() {
        guard let player else { return }
        player.isMuted.toggle()
    }

    var isMuted: Bool {
        player?.isMuted ?? false
    }
}
