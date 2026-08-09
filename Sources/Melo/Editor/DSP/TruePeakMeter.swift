// Melo/Editor/DSP/TruePeakMeter.swift
import Accelerate
import Foundation

/// True-peak measurement, ITU-R BS.1770-4 Annex 2.
///
/// Nothing else in Melo measures true peak. `vDSP_maxmgv` and the manual scan
/// at `ProcessTapController.swift:2119` both read *sample* peak, which is blind
/// to the inter-sample peaks a −1 dBTP ceiling exists to catch.
///
/// The signal is 4× oversampled by the polyphase FIR the standard tabulates
/// (four phases of twelve taps) and the largest magnitude of the oversampled
/// signal is the true peak. The 12.04 dB attenuate/restore step in the standard
/// is a fixed-point overflow guard and is omitted here: this is Float32.
enum TruePeakMeter {

    /// BS.1770-4 Annex 2 4× interpolation filter, one row per phase.
    ///
    /// The shape a correct table has, if this ever needs re-deriving: evaluate
    /// the interleaved 48-tap response and it runs +11.93 dB at DC rising to
    /// +12.14 dB at 0.4·fs — the standard's stated passband ripple around the
    /// ×4 interpolation gain of +12.04 dB — and −30 dB or better above 0.6·fs.
    /// A transposed or mis-ordered table does not produce that shape. Nothing
    /// automated checks it; `verify-cutting-room.py` exercises the meter's
    /// output, not the coefficients.
    static let phases: [[Float]] = [
        [ 0.0017089843750,  0.0109863281250, -0.0196533203125,  0.0332031250000,
         -0.0594482421875,  0.1373291015625,  0.9721679687500, -0.1022949218750,
          0.0476074218750, -0.0266113281250,  0.0148925781250, -0.0083007812500],
        [-0.0291748046875,  0.0292968750000, -0.0517578125000,  0.0891113281250,
         -0.1665039062500,  0.4650878906250,  0.7797851562500, -0.2003173828125,
          0.1015625000000, -0.0582275390625,  0.0330810546875, -0.0189208984375],
        [-0.0189208984375,  0.0330810546875, -0.0582275390625,  0.1015625000000,
         -0.2003173828125,  0.7797851562500,  0.4650878906250, -0.1665039062500,
          0.0891113281250, -0.0517578125000,  0.0292968750000, -0.0291748046875],
        [-0.0083007812500,  0.0148925781250, -0.0266113281250,  0.0476074218750,
         -0.1022949218750,  0.9721679687500,  0.1373291015625, -0.0594482421875,
          0.0332031250000, -0.0196533203125,  0.0109863281250,  0.0017089843750]
    ]

    static let tapCount = 12
    /// Whole base samples of group delay in the interpolator, used to line the
    /// envelope back up with the sample that caused each peak.
    private static let groupDelay = 6
    private static let chunkFrames = 1 << 16

    // MARK: - Measurement

    /// Highest true-peak magnitude across every channel, linear.
    static func peakMagnitude(_ block: PCMBlock,
                              progress: (@Sendable (Double) -> Void)? = nil) throws -> Float {
        var highest: Float = 0
        let channels = block.channelCount
        for index in 0..<channels {
            let samples = block.channel(index)
            try oversampledEnvelope(samples) { envelope, _ in
                var chunkPeak: Float = 0
                vDSP_maxv(envelope.baseAddress!, 1, &chunkPeak, vDSP_Length(envelope.count))
                highest = max(highest, chunkPeak)
            }
            progress?(Double(index + 1) / Double(channels))
        }
        return highest
    }

    /// True peak in dBTP.
    static func truePeakDBTP(_ block: PCMBlock,
                             progress: (@Sendable (Double) -> Void)? = nil) throws -> Double {
        let magnitude = try peakMagnitude(block, progress: progress)
        return 20 * log10(Double(max(magnitude, 1e-9)))
    }

    /// Per-frame true-peak magnitude, maximised across channels and shifted
    /// back by the interpolator's group delay so `envelope[n]` describes the
    /// inter-sample peaks around input frame `n`.
    ///
    /// This is what the limiter reduces gain against; the meter above and the
    /// limiter therefore cannot disagree about where a peak is.
    static func frameEnvelope(_ block: PCMBlock) throws -> [Float] {
        let frames = block.frameCount
        guard frames > 0 else { return [] }

        var delayed = [Float](repeating: 0, count: frames)
        for index in 0..<block.channelCount {
            let samples = block.channel(index)
            var cursor = 0
            try oversampledEnvelope(samples) { envelope, count in
                delayed.withUnsafeMutableBufferPointer { dst in
                    vDSP_vmaxmg(dst.baseAddress! + cursor, 1,
                                envelope.baseAddress!, 1,
                                dst.baseAddress! + cursor, 1,
                                vDSP_Length(count))
                }
                cursor += count
            }
        }

        // Undo the group delay, keeping the neighbours so a half-sample error
        // in the alignment cannot put a peak outside the window the limiter
        // holds against it.
        var aligned = [Float](repeating: 0, count: frames)
        delayed.withUnsafeBufferPointer { src in
            aligned.withUnsafeMutableBufferPointer { dst in
                for frame in 0..<frames {
                    var best: Float = 0
                    for offset in (groupDelay - 1)...(groupDelay + 1) {
                        let index = frame + offset
                        if index < frames { best = max(best, src[index]) }
                    }
                    dst[frame] = best
                }
            }
        }
        return aligned
    }

    // MARK: - Core

    /// Feeds `body` the per-input-sample maximum magnitude over the four
    /// oversampled phases, one chunk at a time. Chunked because a whole-file
    /// oversampled buffer would be four times the source and the source may
    /// already be two hours of Float32.
    private static func oversampledEnvelope(
        _ samples: [Float],
        _ body: (UnsafeMutableBufferPointer<Float>, Int) throws -> Void
    ) throws {
        let total = samples.count
        guard total > 0 else { return }

        let history = tapCount - 1
        var padded = [Float](repeating: 0, count: history + min(chunkFrames, total))
        var accumulator = [Float](repeating: 0, count: min(chunkFrames, total))
        var envelope = [Float](repeating: 0, count: min(chunkFrames, total))

        var start = 0
        while start < total {
            let count = min(chunkFrames, total - start)

            for slot in 0..<history {
                let index = start - history + slot
                padded[slot] = index >= 0 ? samples[index] : 0
            }
            for slot in 0..<count { padded[history + slot] = samples[start + slot] }

            for phase in 0..<phases.count {
                var taps = phases[phase]
                accumulator.withUnsafeMutableBufferPointer { acc in
                    vDSP_vclr(acc.baseAddress!, 1, vDSP_Length(count))
                    padded.withUnsafeBufferPointer { src in
                        for tap in 0..<tapCount {
                            vDSP_vsma(src.baseAddress! + (history - tap), 1,
                                      &taps[tap],
                                      acc.baseAddress!, 1,
                                      acc.baseAddress!, 1,
                                      vDSP_Length(count))
                        }
                    }
                }
                envelope.withUnsafeMutableBufferPointer { env in
                    accumulator.withUnsafeBufferPointer { acc in
                        if phase == 0 {
                            vDSP_vabs(acc.baseAddress!, 1, env.baseAddress!, 1, vDSP_Length(count))
                        } else {
                            vDSP_vmaxmg(env.baseAddress!, 1, acc.baseAddress!, 1,
                                        env.baseAddress!, 1, vDSP_Length(count))
                        }
                    }
                }
            }

            try Task.checkCancellation()
            try envelope.withUnsafeMutableBufferPointer { try body($0, count) }
            start += count
        }
    }
}
