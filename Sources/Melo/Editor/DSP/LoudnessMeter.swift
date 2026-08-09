// Melo/Editor/DSP/LoudnessMeter.swift
import Foundation

/// Integrated loudness to ITU-R BS.1770-4, and loudness range to EBU Tech 3342.
///
/// What already exists in Melo is the pre-filter and nothing after it.
/// `KWeightingFilter` is BS.1770 stages 1 and 2 and is reused here unchanged.
/// `LoudnessEqualizer` then takes a smoothed RMS of it, downmixed to mono, with
/// no −0.691 offset and no gating — a K-weighted level in dBFS, which is a
/// useful control signal for a leveller and is not LUFS. Everything below the
/// filter is new: 400 ms blocks at 75 % overlap, per-channel weights, the
/// absolute gate at −70 LUFS and the relative gate at −10 LU.
enum LoudnessMeter {

    /// The absolute gate, and the value reported for material with no block
    /// above it. −70 LUFS is the floor of the scale, not a measurement.
    static let silenceLUFS: Double = -70.0

    /// BS.1770 equation 2. Present so nothing has to rediscover why the number
    /// is not zero: it is the calibration constant that puts a 997 Hz sine at
    /// its own dBFS value once K-weighting's +0.69 dB at that frequency is in.
    private static let offsetLU: Double = -0.691

    struct Result: Sendable, Equatable {
        var integratedLUFS: Double
        var loudnessRangeLU: Double
    }

    // MARK: - Measurement

    static func measure(_ block: PCMBlock,
                        progress: (@Sendable (Double) -> Void)? = nil) throws -> Result {
        let segmentFrames = Int((block.sampleRate * 0.1).rounded())
        guard segmentFrames > 0, block.frameCount >= segmentFrames else {
            return Result(integratedLUFS: silenceLUFS, loudnessRangeLU: 0)
        }

        let segmentCount = block.frameCount / segmentFrames
        let weights = channelWeights(block.channelCount)

        // Weighted mean square per 100 ms segment, summed across channels.
        // Every window the standard asks for — 400 ms momentary, 3 s
        // short-term — is a run of these, so the K-weighting pass happens once.
        var segmentPower = [Double](repeating: 0, count: segmentCount)

        for channel in 0..<block.channelCount {
            let weight = weights[channel]
            guard weight > 0 else { continue }
            let samples = block.channel(channel)
            let filter = KWeightingFilter(sampleRate: Float(block.sampleRate))
            var cursor = 0
            for segment in 0..<segmentCount {
                var sum = 0.0
                for _ in 0..<segmentFrames {
                    let filtered = Double(filter.processSample(samples[cursor]))
                    sum += filtered * filtered
                    cursor += 1
                }
                segmentPower[segment] += weight * sum
            }
            try Task.checkCancellation()
            progress?(Double(channel + 1) / Double(block.channelCount))
        }

        let framesPerSegment = Double(segmentFrames)
        /// Mean square of a run of segments, already channel-weighted.
        func power(from start: Int, span: Int) -> Double {
            var sum = 0.0
            for index in start..<(start + span) { sum += segmentPower[index] }
            return sum / (framesPerSegment * Double(span))
        }

        return Result(
            integratedLUFS: integrated(segmentCount: segmentCount, power: power),
            loudnessRangeLU: loudnessRange(segmentCount: segmentCount, power: power)
        )
    }

    // MARK: - Integrated, BS.1770-4 §2 and Annex 1

    /// 400 ms blocks stepping 100 ms (75 % overlap), absolute gate at −70 LUFS,
    /// then a relative gate 10 LU below the mean of what survived it.
    private static func integrated(segmentCount: Int,
                                   power: (Int, Int) -> Double) -> Double {
        let span = 4
        guard segmentCount >= span else { return silenceLUFS }

        var powers: [Double] = []
        powers.reserveCapacity(segmentCount - span + 1)
        for start in 0...(segmentCount - span) { powers.append(power(start, span)) }

        let absoluteGated = powers.filter { loudness(of: $0) > -70.0 }
        guard !absoluteGated.isEmpty else { return silenceLUFS }

        let relativeThreshold = loudness(of: mean(absoluteGated)) - 10.0
        let gated = absoluteGated.filter { loudness(of: $0) > relativeThreshold }
        guard !gated.isEmpty else { return silenceLUFS }

        return loudness(of: mean(gated))
    }

    // MARK: - Loudness range, EBU Tech 3342

    /// 3 s short-term windows, absolute gate at −70 LUFS, relative gate 20 LU
    /// below the mean of the survivors, then the 10th to 95th percentile spread.
    ///
    /// The window step is 100 ms rather than the 1 s most descriptions use. The
    /// specification asks for at least 2/3 overlap and 100 ms satisfies it; the
    /// reason to take it is that the segment powers are already computed, and a
    /// three-minute file yields 1780 short-term values instead of 178, which is
    /// the difference between a percentile and a guess.
    private static func loudnessRange(segmentCount: Int,
                                      power: (Int, Int) -> Double) -> Double {
        let span = 30
        guard segmentCount >= span else { return 0 }

        var values: [Double] = []
        values.reserveCapacity(segmentCount - span + 1)
        for start in 0...(segmentCount - span) {
            let candidate = power(start, span)
            if loudness(of: candidate) > -70.0 { values.append(candidate) }
        }
        guard values.count >= 2 else { return 0 }

        let relativeThreshold = loudness(of: mean(values)) - 20.0
        var gated = values.map(loudness(of:)).filter { $0 > relativeThreshold }
        guard gated.count >= 2 else { return 0 }

        gated.sort()
        return percentile(gated, 95) - percentile(gated, 10)
    }

    // MARK: - Helpers

    /// BS.1770-4 equation 2.
    private static func loudness(of meanSquare: Double) -> Double {
        guard meanSquare > 0 else { return -.infinity }
        return offsetLU + 10 * log10(meanSquare)
    }

    private static func mean(_ values: [Double]) -> Double {
        values.reduce(0, +) / Double(values.count)
    }

    /// Linear interpolation between closest ranks, over a sorted array.
    private static func percentile(_ sorted: [Double], _ percent: Double) -> Double {
        let position = (percent / 100) * Double(sorted.count - 1)
        let lower = Int(position.rounded(.down))
        let upper = min(lower + 1, sorted.count - 1)
        let fraction = position - Double(lower)
        return sorted[lower] + (sorted[upper] - sorted[lower]) * fraction
    }

    /// BS.1770-4 Table 3. L, R and C weigh 1; the surrounds weigh 1.41; LFE is
    /// excluded. A six-channel block is read as 5.1 in AVFoundation's channel
    /// order. Every other count is unity throughout, which is what the standard
    /// prescribes for mono and stereo and the only defensible reading of an
    /// unlabelled four- or eight-channel file.
    private static func channelWeights(_ channelCount: Int) -> [Double] {
        guard channelCount == 6 else {
            return Array(repeating: 1.0, count: channelCount)
        }
        return [1.0, 1.0, 1.0, 0.0, 1.41, 1.41]
    }
}
