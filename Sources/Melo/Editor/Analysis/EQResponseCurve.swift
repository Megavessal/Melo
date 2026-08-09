// Melo/Editor/Analysis/EQResponseCurve.swift
import Foundation

/// The equalizer's magnitude response, computed from the same biquad
/// coefficients the audio path will run.
///
/// **Not an approximation of the curve — the curve.** `BiquadMath` produces
/// `[b0, b1, b2, a1, a2]` for each band, and this evaluates
/// `|H(e^{jω})| = |b0 + b1z⁻¹ + b2z⁻²| / |1 + a1z⁻¹ + a2z⁻²|` on those exact
/// numbers. Drawing a rough bell per band instead is how a project ends up with
/// an equalizer that is visibly real and audibly inert: the picture agrees with
/// nothing, so nobody notices when the sound stops following it. This project's
/// own anchor records that failure, which is why the drawing goes through the
/// DSP's arithmetic rather than beside it.
///
/// Pure and `nonisolated`, so it can be exercised without a view.
enum EQResponseCurve {

    /// The rate the curve is drawn at. Melo's AutoEQ profiles are optimised for
    /// 48 kHz (`AutoEQProfile.optimizedSampleRate`), and the editor's canonical
    /// block is whatever the file is — but a response plotted at 44.1 and one at
    /// 48 differ only in the top half-octave, and the drawing is not a
    /// measurement of the output file.
    static let drawingSampleRate: Double = 48000

    /// Everything a person can hear, and the range the ten bands span.
    static let minimumFrequency: Double = 20
    static let maximumFrequency: Double = 20000

    /// `EQSettings` clamps a band to ±12 dB; shelves and overlapping peaks can
    /// sum past that, so the axis leaves three decibels of room at each end.
    static let displayRangeDB: Double = 15

    // MARK: - Magnitude

    /// The combined response, in dB, at one frequency.
    nonisolated static func magnitudeDB(
        bands: [AutoEQFilter],
        preampDB: Double,
        at frequency: Double,
        sampleRate: Double = drawingSampleRate
    ) -> Double {
        // `profileOptimizedRate: sampleRate` disables pre-warping. The editor's
        // bands were authored at this rate by definition — they are the
        // document's own numbers, not an imported profile measured elsewhere.
        let coefficients = BiquadMath.coefficientsForAutoEQFilters(
            bands, sampleRate: sampleRate, profileOptimizedRate: sampleRate
        )
        guard coefficients.count >= 5 else { return preampDB }

        let omega = 2 * Double.pi * frequency / sampleRate
        // z⁻¹ = e^{-jω}, z⁻² = e^{-2jω}
        let cos1 = cos(omega), sin1 = -sin(omega)
        let cos2 = cos(2 * omega), sin2 = -sin(2 * omega)

        var total = preampDB
        var index = 0
        while index + 4 < coefficients.count {
            let b0 = coefficients[index]
            let b1 = coefficients[index + 1]
            let b2 = coefficients[index + 2]
            let a1 = coefficients[index + 3]
            let a2 = coefficients[index + 4]
            index += 5

            let numeratorReal = b0 + b1 * cos1 + b2 * cos2
            let numeratorImaginary = b1 * sin1 + b2 * sin2
            let denominatorReal = 1 + a1 * cos1 + a2 * cos2
            let denominatorImaginary = a1 * sin1 + a2 * sin2

            let numerator = numeratorReal * numeratorReal + numeratorImaginary * numeratorImaginary
            let denominator = denominatorReal * denominatorReal
                + denominatorImaginary * denominatorImaginary
            guard denominator > 0, numerator > 0 else { continue }

            // 10·log₁₀ rather than 20·log₁₀ because both sides are already squared.
            total += 10 * log10(numerator / denominator)
        }
        return total
    }

    /// `count` points across the audible range, log-spaced, for drawing.
    nonisolated static func curve(
        bands: [AutoEQFilter],
        preampDB: Double,
        count: Int = 240,
        sampleRate: Double = drawingSampleRate
    ) -> [Double] {
        guard count > 1 else { return [] }
        return (0..<count).map { step in
            let position = Double(step) / Double(count - 1)
            return magnitudeDB(
                bands: bands,
                preampDB: preampDB,
                at: frequency(atPosition: position),
                sampleRate: sampleRate
            )
        }
    }

    // MARK: - Axes

    /// 0…1 across the drawing to a frequency, logarithmically — the only spacing
    /// in which an equalizer's bands look evenly distributed, because that is
    /// how hearing is spaced.
    nonisolated static func frequency(atPosition position: Double) -> Double {
        let low = log10(minimumFrequency)
        let high = log10(maximumFrequency)
        return pow(10, low + (high - low) * min(max(position, 0), 1))
    }

    nonisolated static func position(ofFrequency frequency: Double) -> Double {
        let low = log10(minimumFrequency)
        let high = log10(maximumFrequency)
        guard frequency > 0, high > low else { return 0 }
        return min(max((log10(frequency) - low) / (high - low), 0), 1)
    }

    /// dB to 0…1 from the top of the plot, so it can be multiplied by a height.
    nonisolated static func verticalPosition(ofDB value: Double) -> Double {
        let clamped = min(max(value, -displayRangeDB), displayRangeDB)
        return (displayRangeDB - clamped) / (displayRangeDB * 2)
    }

    nonisolated static func decibels(atVerticalPosition position: Double) -> Double {
        displayRangeDB - min(max(position, 0), 1) * displayRangeDB * 2
    }

    // MARK: - Projection onto Melo's ten bands

    /// The parametric curve read back onto Melo's ten graphic bands by
    /// *evaluating* it at each of the ten frequencies.
    ///
    /// Deliberately different from `EQSettings.init(autoEQFilters:)`, which
    /// takes the nearest band's gain and drops anything shelving. That is the
    /// right rule for showing a curve; this is the right rule for **becoming**
    /// one, because it keeps the shape of a shelf or of two overlapping peaks
    /// instead of throwing it away.
    ///
    /// It is not an exact inverse — ten Q=1.4 peaks overlap and sum, so the
    /// result reads a little stronger than the original. Approximate and
    /// visible beats exact and unavailable, and the panel says so in a line
    /// before it does it.
    nonisolated static func flattenedToGraphicBands(
        bands: [AutoEQFilter],
        preampDB: Double
    ) -> [AutoEQFilter] {
        EQSettings.frequencies.map { frequency in
            let value = magnitudeDB(bands: bands, preampDB: preampDB, at: frequency)
            let clamped = min(
                max(value, Double(EQSettings.minGainDB)),
                Double(EQSettings.maxGainDB)
            )
            return AutoEQFilter(
                type: .peaking,
                frequency: frequency,
                gainDB: Float((clamped * 10).rounded() / 10),
                q: BiquadMath.graphicEQQ
            )
        }
    }

    /// True when this array *is* Melo's ten-band graphic EQ — same count, same
    /// frequencies, same Q, all peaking. When it is, the graphic view is exact
    /// and switching depth back and forth loses nothing.
    nonisolated static func isGraphicShaped(_ bands: [AutoEQFilter]) -> Bool {
        guard bands.count == EQSettings.bandCount else { return false }
        for (band, frequency) in zip(bands, EQSettings.frequencies) {
            guard band.type == .peaking,
                  abs(band.frequency - frequency) < 0.51,
                  abs(band.q - BiquadMath.graphicEQQ) < 0.01
            else { return false }
        }
        return true
    }

    /// Melo's ten bands, flat. The starting point when a new equalizer move is
    /// added with nothing in it.
    nonisolated static var flatGraphicBands: [AutoEQFilter] {
        EQSettings.flat.autoEQFilters
    }

    /// The automatic headroom, applied to the whole array rather than to the
    /// ten-band projection of it.
    ///
    /// The rule and its reasoning belong to `EQSettings.preampDB`: cut by the
    /// largest positive band gain so the curve keeps its shape and a boosting
    /// preset reads as a tone change rather than as "louder". This generalises
    /// it to shelves and to bands off Melo's grid, which the projection cannot
    /// see. A cut-only curve gets no preamp — it already has headroom.
    nonisolated static func automaticPreampDB(for bands: [AutoEQFilter]) -> Double {
        let peak = bands.map { Double($0.gainDB) }.max() ?? 0
        return peak > 0 ? -peak : 0
    }
}
