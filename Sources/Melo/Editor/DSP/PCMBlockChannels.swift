// Melo/Editor/DSP/PCMBlockChannels.swift
import Accelerate
import Foundation

/// De-interleaving helpers shared by every offline stage.
///
/// `PCMBlock` is interleaved because Melo's live primitives are, but a biquad
/// cascade, a K-weighting pass and an FFT all want one channel at a time. The
/// strided copies below go through vDSP rather than a Swift loop: a strided
/// scalar loop is the one shape the optimiser reliably fails to vectorise.
extension PCMBlock {

    /// One channel's samples, de-interleaved.
    func channel(_ index: Int) -> [Float] {
        let frames = frameCount
        guard frames > 0 else { return [] }
        guard channelCount > 1 else { return samples }

        var out = [Float](repeating: 0, count: frames)
        var unity: Float = 1
        samples.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                vDSP_vsmul(src.baseAddress! + index, vDSP_Stride(channelCount),
                           &unity, dst.baseAddress!, 1, vDSP_Length(frames))
            }
        }
        return out
    }

    /// Writes one channel back into the interleaved store.
    mutating func setChannel(_ index: Int, _ values: [Float]) {
        guard channelCount > 1 else {
            samples = values
            return
        }
        var unity: Float = 1
        let frames = min(values.count, frameCount)
        values.withUnsafeBufferPointer { src in
            samples.withUnsafeMutableBufferPointer { dst in
                vDSP_vsmul(src.baseAddress!, 1, &unity,
                           dst.baseAddress! + index, vDSP_Stride(channelCount),
                           vDSP_Length(frames))
            }
        }
    }

    /// Builds a block from de-interleaved channels of equal length.
    static func interleaving(_ channels: [[Float]], sampleRate: Double) -> PCMBlock {
        let channelCount = channels.count
        guard channelCount > 0 else {
            return PCMBlock(samples: [], sampleRate: sampleRate, channelCount: 1)
        }
        guard channelCount > 1 else {
            return PCMBlock(samples: channels[0], sampleRate: sampleRate, channelCount: 1)
        }
        let frames = channels.map(\.count).min() ?? 0
        var out = [Float](repeating: 0, count: frames * channelCount)
        var unity: Float = 1
        out.withUnsafeMutableBufferPointer { dst in
            for (index, source) in channels.enumerated() {
                source.withUnsafeBufferPointer { src in
                    vDSP_vsmul(src.baseAddress!, 1, &unity,
                               dst.baseAddress! + index, vDSP_Stride(channelCount),
                               vDSP_Length(frames))
                }
            }
        }
        return PCMBlock(samples: out, sampleRate: sampleRate, channelCount: channelCount)
    }

    /// The frames in `range`, as a new block. `nil` returns the whole thing.
    func slice(_ range: ClosedRange<TimeInterval>?) -> PCMBlock {
        guard let range else { return self }
        let start = frameIndex(at: range.lowerBound)
        let end = max(start, frameIndex(at: range.upperBound))
        guard start > 0 || end < frameCount else { return self }
        let lower = start * channelCount
        let upper = end * channelCount
        return PCMBlock(samples: Array(samples[lower..<upper]),
                        sampleRate: sampleRate,
                        channelCount: channelCount)
    }

    /// Sum of every channel at each frame, divided by the channel count.
    /// Used by measurements that are about tonal balance or timing rather than
    /// about a particular channel.
    func monoSum() -> [Float] {
        guard channelCount > 1 else { return samples }
        var out = channel(0)
        for index in 1..<channelCount {
            let next = channel(index)
            vDSP.add(out, next, result: &out)
        }
        var scale = 1 / Float(channelCount)
        vDSP_vsmul(out, 1, &scale, &out, 1, vDSP_Length(out.count))
        return out
    }
}
