import Foundation

/// Local, content-aware tonal balancing and transient protection.
///
/// This processor is intentionally deterministic and explainable: it analyzes
/// three broad frequency regions, crest factor, recent silence, and sustained
/// loudness. It does not record audio, use the network, or infer semantic labels.
/// All state is owned by one Core Audio callback thread after initialization.
final class AdaptiveAudioProcessor: @unchecked Sendable {
    private let settings: AdaptiveAudioSettings
    private let sampleRate: Float
    private let lowCoefficient: Float
    private let highCoefficient: Float
    private let gainAttackCoefficient: Float
    private let gainReleaseCoefficient: Float

    private var analysisLow: Float = 0
    private var analysisHighLowPass: Float = 0
    private var leftLow: Float = 0
    private var rightLow: Float = 0
    private var leftHighLowPass: Float = 0
    private var rightHighLowPass: Float = 0
    private var currentGain: Float = 1
    private var quietSampleCount: Int = 0

    init(settings: AdaptiveAudioSettings, sampleRate: Float) {
        self.settings = settings
        self.sampleRate = max(8_000, sampleRate)
        lowCoefficient = Self.onePoleCoefficient(cutoff: 250, sampleRate: self.sampleRate)
        highCoefficient = Self.onePoleCoefficient(cutoff: 4_000, sampleRate: self.sampleRate)
        gainAttackCoefficient = 1 - exp(-1 / (self.sampleRate * 0.006))
        gainReleaseCoefficient = 1 - exp(-1 / (self.sampleRate * 1.6))
    }

    var isEnabled: Bool {
        settings.enabled && (
            settings.contentAwareEQEnabled
                || settings.smartNormalizationEnabled
                || settings.dialogueBoostEnabled
        )
    }

    /// In-place safe, interleaved stereo processing. The current buffer is
    /// analyzed before it is emitted, so an isolated wake-up spike is reduced
    /// from its first output block rather than one analysis window later.
    func process(
        input: UnsafePointer<Float>,
        output: UnsafeMutablePointer<Float>,
        frameCount: Int,
        channelCount: Int
    ) {
        guard isEnabled, frameCount > 0, channelCount == 2 else {
            if input != UnsafePointer(output) {
                memcpy(output, input, frameCount * channelCount * MemoryLayout<Float>.size)
            }
            return
        }

        var squareSum: Float = 0
        var peak: Float = 0
        var lowSquareSum: Float = 0
        var midSquareSum: Float = 0
        var highSquareSum: Float = 0

        for frame in 0..<frameCount {
            let base = frame * 2
            let mono = (input[base] + input[base + 1]) * 0.5
            analysisLow += lowCoefficient * (mono - analysisLow)
            analysisHighLowPass += highCoefficient * (mono - analysisHighLowPass)
            let high = mono - analysisHighLowPass
            let mid = mono - analysisLow - high

            squareSum += mono * mono
            lowSquareSum += analysisLow * analysisLow
            midSquareSum += mid * mid
            highSquareSum += high * high
            peak = max(peak, max(abs(input[base]), abs(input[base + 1])))
        }

        let inverseFrames = 1 / Float(frameCount)
        let rms = sqrt(max(squareSum * inverseFrames, 0))
        let totalBandEnergy = max(lowSquareSum + midSquareSum + highSquareSum, 0.000_000_1)
        let lowRatio = lowSquareSum / totalBandEnergy
        let midRatio = midSquareSum / totalBandEnergy
        let highRatio = highSquareSum / totalBandEnergy
        let crestFactor = peak / max(rms, 0.000_001)

        let wasQuietLongEnough = quietSampleCount >= Int(sampleRate * 0.18)
        let wakeUpSpike = wasQuietLongEnough && peak > Self.dbToLinear(-9) && crestFactor > 2.2
        let cinematicImpact = !wasQuietLongEnough && lowRatio > 0.42 && crestFactor > 2.0
        let speechForward = midRatio > 0.48 && lowRatio < 0.36

        let tonalGains = tonalBalance(
            lowRatio: lowRatio,
            midRatio: midRatio,
            highRatio: highRatio,
            speechForward: speechForward,
            cinematicImpact: cinematicImpact
        )
        let targetGain = normalizationTarget(
            rms: rms,
            peak: peak * max(tonalGains.low, max(tonalGains.mid, tonalGains.high)),
            wakeUpSpike: wakeUpSpike,
            cinematicImpact: cinematicImpact
        )

        // Peak protection is block-aware and wins immediately. A wake-up spike
        // receives the stricter ceiling; ongoing content gets the gentler one.
        let exceedsOrdinaryCeiling = peak > Self.dbToLinear(settings.intensity.peakCeilingDb)
        if targetGain < currentGain && (wakeUpSpike || exceedsOrdinaryCeiling) {
            currentGain = targetGain
        }

        for frame in 0..<frameCount {
            let base = frame * 2
            let coefficient = targetGain < currentGain ? gainAttackCoefficient : gainReleaseCoefficient
            currentGain += coefficient * (targetGain - currentGain)

            if settings.contentAwareEQEnabled || settings.dialogueBoostEnabled {
                output[base] = balancedSample(
                    input[base],
                    lowState: &leftLow,
                    highLowPassState: &leftHighLowPass,
                    gains: tonalGains
                ) * currentGain
                output[base + 1] = balancedSample(
                    input[base + 1],
                    lowState: &rightLow,
                    highLowPassState: &rightHighLowPass,
                    gains: tonalGains
                ) * currentGain
            } else {
                output[base] = input[base] * currentGain
                output[base + 1] = input[base + 1] * currentGain
            }
        }

        if rms < Self.dbToLinear(-52) {
            quietSampleCount = min(quietSampleCount + frameCount, Int(sampleRate * 2))
        } else {
            quietSampleCount = 0
        }
    }

    private func tonalBalance(
        lowRatio: Float,
        midRatio: Float,
        highRatio: Float,
        speechForward: Bool,
        cinematicImpact: Bool
    ) -> (low: Float, mid: Float, high: Float) {
        guard settings.contentAwareEQEnabled || settings.dialogueBoostEnabled else { return (1, 1, 1) }
        let strength = settings.intensity.eqStrengthDb
        var lowDb: Float = 0
        var midDb: Float = 0
        var highDb: Float = 0

        if cinematicImpact {
            // Keep the intended weight of an impact, adding only mild clarity.
            midDb = strength * 0.22
            highDb = strength * 0.12
        } else if speechForward {
            lowDb = -strength * 0.28
            midDb = strength * 0.62
            highDb = strength * 0.22
        } else {
            if lowRatio > 0.56 { lowDb = -strength * 0.35 }
            if lowRatio < 0.20 { lowDb = strength * 0.20 }
            if midRatio < 0.32 { midDb = strength * 0.32 }
            if highRatio < 0.07 { highDb = strength * 0.30 }
            if highRatio > 0.24 { highDb = -strength * 0.28 }
        }

        if settings.dialogueBoostEnabled {
            // A broad, restrained voice lift rather than a technical equalizer control.
            lowDb -= 0.35
            midDb += 1.25
            highDb += 0.30
        }

        return (Self.dbToLinear(lowDb), Self.dbToLinear(midDb), Self.dbToLinear(highDb))
    }

    private func normalizationTarget(
        rms: Float,
        peak: Float,
        wakeUpSpike: Bool,
        cinematicImpact: Bool
    ) -> Float {
        guard settings.smartNormalizationEnabled else { return 1 }
        let intensity = settings.intensity
        let rmsDb = Self.linearToDb(rms)
        var desiredDb: Float = 0

        if rmsDb > -15 {
            let rawCut = (rmsDb + 15) * (1 - 1 / intensity.compressionRatio)
            let preservation: Float = cinematicImpact ? 0.45 : 1
            desiredDb = -min(intensity.maxLevelerCutDb, rawCut * preservation)
        } else if rmsDb > -42 && rmsDb < -22 {
            desiredDb = min(intensity.maxLevelerBoostDb, (-22 - rmsDb) * 0.12)
        }

        if peak > 0.000_001 {
            let ceilingDb = wakeUpSpike ? intensity.silenceSpikeCeilingDb : intensity.peakCeilingDb
            let peakLimitedDb = ceilingDb - Self.linearToDb(peak)
            desiredDb = min(desiredDb, peakLimitedDb)
        }
        return Self.dbToLinear(desiredDb)
    }

    private func balancedSample(
        _ sample: Float,
        lowState: inout Float,
        highLowPassState: inout Float,
        gains: (low: Float, mid: Float, high: Float)
    ) -> Float {
        lowState += lowCoefficient * (sample - lowState)
        highLowPassState += highCoefficient * (sample - highLowPassState)
        let high = sample - highLowPassState
        let mid = sample - lowState - high
        return lowState * gains.low + mid * gains.mid + high * gains.high
    }

    private static func onePoleCoefficient(cutoff: Float, sampleRate: Float) -> Float {
        1 - exp(-2 * .pi * min(cutoff, sampleRate * 0.45) / sampleRate)
    }

    private static func dbToLinear(_ db: Float) -> Float { pow(10, db / 20) }
    private static func linearToDb(_ linear: Float) -> Float { 20 * log10(max(linear, 0.000_001)) }
}
