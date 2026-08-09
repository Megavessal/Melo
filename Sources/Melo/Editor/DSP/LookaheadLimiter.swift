// Melo/Editor/DSP/LookaheadLimiter.swift
import Accelerate
import Foundation

/// A lookahead limiter with a settable true-peak ceiling.
///
/// `SoftLimiter` stays where it is — it is the last safety clamp on the render,
/// as it is on the live path — but it is a stateless soft clip with a threshold
/// of 0.95 and a ceiling of 1.0 (`SoftLimiter.swift:18-21`). Neither number is
/// settable and clipping is not limiting, so a `−1 dBTP` ceiling cannot be
/// expressed by it at all.
///
/// The chain here is: true-peak envelope → required gain → sliding minimum over
/// the lookahead → release → box smoother the same length as the lookahead.
/// The last two steps only ever lower the gain relative to the sliding minimum,
/// and the sliding minimum already holds a peak's required gain for the whole
/// lookahead *before* the peak, so the smoothed gain at any peak is at or below
/// what that peak required. That is why the ceiling holds when measured rather
/// than approximately.
enum LookaheadLimiter {

    /// 2 ms. Long enough that the gain ramp into a transient carries no click
    /// and no audible edge, short enough that the duck before the transient is
    /// not heard as a separate event. 0.5 ms was rejected: at 48 kHz that is
    /// 24 samples, and a gain ramp that fast intermodulates with bass content.
    /// 10 ms was rejected: the pre-duck becomes audible on percussive material,
    /// which is the classic "limiter breathing before the hit".
    static let lookahead: TimeInterval = 0.002

    /// Applies limiting in place. `ceilingDBTP` is a true-peak ceiling, so the
    /// envelope it is compared against is the 4× oversampled one.
    static func apply(_ block: inout PCMBlock,
                      ceilingDBTP: Double,
                      releaseMS: Double) throws {
        let frames = block.frameCount
        guard frames > 0 else { return }

        let ceiling = Float(pow(10.0, ceilingDBTP / 20.0))
        guard ceiling > 0 else { return }

        let envelope = try TruePeakMeter.frameEnvelope(block)
        guard let loudest = envelope.max(), loudest > ceiling else { return }

        var required = [Float](repeating: 1, count: frames)
        for index in 0..<frames where envelope[index] > ceiling {
            required[index] = ceiling / envelope[index]
        }

        let window = max(1, Int((lookahead * block.sampleRate).rounded()))
        var gain = slidingMinimum(required, window: window)
        applyRelease(&gain, releaseMS: releaseMS, sampleRate: block.sampleRate)
        boxSmooth(&gain, window: window)

        for channel in 0..<block.channelCount {
            var samples = block.channel(channel)
            vDSP.multiply(samples, gain, result: &samples)
            block.setChannel(channel, samples)
        }
    }

    // MARK: - Stages

    /// `out[n] = min(values[n ... n + window])`. Monotonic deque, so the cost is
    /// linear in the sample count rather than in window × samples.
    private static func slidingMinimum(_ values: [Float], window: Int) -> [Float] {
        let count = values.count
        var out = [Float](repeating: 1, count: count)
        var deque = [Int]()
        deque.reserveCapacity(window + 1)

        var head = 0
        var next = 0
        for index in 0..<count {
            let limit = min(count - 1, index + window)
            while next <= limit {
                while deque.count > head, values[deque[deque.count - 1]] >= values[next] {
                    deque.removeLast()
                }
                deque.append(next)
                next += 1
            }
            while deque[head] < index { head += 1 }
            out[index] = values[deque[head]]
            if head > 1024 {
                deque.removeFirst(head)
                head = 0
            }
        }
        return out
    }

    /// One-pole recovery toward the held gain. Attack is instantaneous because
    /// the sliding minimum has already done the anticipating; this stage only
    /// governs how the gain comes back, and it can only ever hold the gain
    /// lower than the sliding minimum, never higher.
    private static func applyRelease(_ gain: inout [Float],
                                     releaseMS: Double,
                                     sampleRate: Double) {
        guard sampleRate > 0 else { return }
        let stepMS = Float(1000.0 / sampleRate)
        let coefficient = LoudnessEqualizerMath.timeConstantCoefficient(
            timeMs: Float(max(releaseMS, 1)), stepMs: stepMS)

        var current = gain.first ?? 1
        for index in 0..<gain.count {
            let target = gain[index]
            if target <= current {
                current = target
            } else {
                current += (target - current) * coefficient
            }
            gain[index] = current
        }
    }

    /// Backward moving average, the same length as the lookahead. Rounds the
    /// corner the sliding minimum leaves at the start of an attack.
    ///
    /// The edge is extended with `gain[0]` rather than with unity. Unity would
    /// raise the smoothed gain above the held value inside the first window and
    /// let a peak in the opening milliseconds through the ceiling.
    private static func boxSmooth(_ gain: inout [Float], window: Int) {
        let count = gain.count
        guard window > 1, count > 0 else { return }

        let leading = gain[0]
        var running = Double(leading) * Double(window)
        var out = [Float](repeating: 0, count: count)
        let inverse = 1.0 / Double(window)

        for index in 0..<count {
            let leaving = index - window >= 0 ? Double(gain[index - window]) : Double(leading)
            running += Double(gain[index]) - leaving
            out[index] = Float(running * inverse)
        }
        gain = out
    }
}
