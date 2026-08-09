// Melo/Editor/DSP/OfflineBiquadChain.swift
import Accelerate
import Foundation

/// A biquad cascade run offline over any channel count.
///
/// The coefficients come from `BiquadMath` and the arithmetic is `vDSP_biquad`,
/// exactly as in `BiquadProcessor.process` — this is the same filter, not a
/// second one. What differs is the stride: `BiquadProcessor` hardcodes 2 for
/// interleaved stereo (`BiquadProcessor.swift:220-221`), and an editor block
/// can be mono, stereo or 5.1. Special-casing stereo onto `BiquadProcessor` and
/// everything else onto this would be two implementations of one rule that have
/// to agree, which is the defect class recorded at `CLAUDE.md:138`. One path.
///
/// `EQProcessor` is not the right reuse here for a separate reason: it only
/// carries `EQSettings`, the fixed ten-band graphic (gain only, Q = 1.4), and
/// the editor's EQ move is `[AutoEQFilter]` with frequency and Q unlocked.
final class OfflineBiquadChain {

    private let setup: vDSP_biquad_Setup
    private let sectionCount: Int

    /// - Parameter coefficients: flat `[b0, b1, b2, a1, a2]` per section, as
    ///   every `BiquadMath` entry point already returns.
    init?(coefficients: [Double], sectionCount: Int) {
        guard sectionCount > 0, coefficients.count == sectionCount * 5 else { return nil }
        guard let setup = coefficients.withUnsafeBufferPointer({ pointer in
            vDSP_biquad_CreateSetup(pointer.baseAddress!, vDSP_Length(sectionCount))
        }) else { return nil }
        self.setup = setup
        self.sectionCount = sectionCount
    }

    deinit {
        vDSP_biquad_DestroySetup(setup)
    }

    /// Runs the cascade over every channel in place. Each channel gets its own
    /// zeroed delay line, so channels cannot bleed into one another.
    func process(_ block: inout PCMBlock) {
        let frames = block.frameCount
        guard frames > 0 else { return }
        let channels = block.channelCount
        let delaySize = (2 * sectionCount) + 2

        var delay = [Float](repeating: 0, count: delaySize)
        block.samples.withUnsafeMutableBufferPointer { samples in
            guard let base = samples.baseAddress else { return }
            for channel in 0..<channels {
                for index in 0..<delaySize { delay[index] = 0 }
                delay.withUnsafeMutableBufferPointer { state in
                    vDSP_biquad(setup, state.baseAddress!,
                                base + channel, vDSP_Stride(channels),
                                base + channel, vDSP_Stride(channels),
                                vDSP_Length(frames))
                }
            }
            // Pathological coefficients produce NaN that would poison every
            // later stage. `BiquadProcessor` carries the same guard.
            if let first = samples.first, first.isNaN {
                vDSP_vclr(base, 1, vDSP_Length(samples.count))
            }
        }
    }
}
