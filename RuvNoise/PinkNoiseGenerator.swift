import Foundation

/// Voss-McCartney pink noise generator — safe for real-time audio threads.
/// No allocations after init. Call `next()` to get samples in roughly [-1, 1].
struct PinkNoiseGenerator {
    // 16 rows of running random values
    private static let numRows = 16
    private var rows = [Float](repeating: 0, count: numRows)
    private var runningSum: Float = 0
    private var index: Int = 0

    /// Amplitude scaler — targets roughly -40 dB (0.01)
    var amplitude: Float = 0.01

    init() {
        // Seed rows
        for i in 0..<PinkNoiseGenerator.numRows {
            let white = Float.random(in: -1...1)
            rows[i] = white
            runningSum += white
        }
    }

    /// Returns the next pink noise sample, scaled by `amplitude`.
    mutating func next() -> Float {
        // Voss-McCartney: use trailing zeros of index to pick which row to update
        let numTrailingZeros = index == 0 ? PinkNoiseGenerator.numRows - 1 : (index & -index).trailingZeroBitCount
        let row = min(numTrailingZeros, PinkNoiseGenerator.numRows - 1)

        runningSum -= rows[row]
        let newRandom = Float.random(in: -1...1)
        rows[row] = newRandom
        runningSum += newRandom

        index = (index + 1) & 0xFFFF

        // Normalize: sum of numRows uniform randoms has stddev ~sqrt(numRows/3)
        let normalized = runningSum / Float(PinkNoiseGenerator.numRows)
        return normalized * amplitude
    }
}
