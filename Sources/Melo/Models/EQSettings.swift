import Foundation

nonisolated struct EQSettings: Codable, Equatable {
    static let bandCount = 10
    static let maxGainDB: Float = 12.0
    static let minGainDB: Float = -12.0

    /// ISO standard frequencies for 10-band graphic EQ
    static let frequencies: [Double] = [
        31.25, 62.5, 125, 250, 500, 1000, 2000, 4000, 8000, 16000
    ]

    /// Gain in dB for each band (-12 to +12)
    var bandGains: [Float]

    /// Whether EQ processing is enabled
    var isEnabled: Bool

    init(bandGains: [Float] = Array(repeating: 0, count: 10), isEnabled: Bool = true) {
        self.bandGains = Self.normalizeBands(bandGains)
        self.isEnabled = isEnabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decoded = try container.decodeIfPresent([Float].self, forKey: .bandGains)
            ?? Array(repeating: 0, count: Self.bandCount)
        self.bandGains = Self.normalizeBands(decoded)
        self.isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
    }

    /// Normalize band gains array to exactly `bandCount` elements,
    /// padding with 0 or truncating as needed.
    private static func normalizeBands(_ gains: [Float]) -> [Float] {
        if gains.count == bandCount { return gains }
        if gains.count > bandCount { return Array(gains.prefix(bandCount)) }
        return gains + Array(repeating: Float(0), count: bandCount - gains.count)
    }

    /// Returns gains clamped to valid range
    var clampedGains: [Float] {
        bandGains.map { $0.isFinite ? max(Self.minGainDB, min(Self.maxGainDB, $0)) : 0 }
    }

    // MARK: - Headroom

    /// Automatic preamp, in dB, applied ahead of the band filters.
    ///
    /// A boosting curve adds level. `.electronic` is `[7, 6, 4, 0, -2, -2, 1, 3, 4, 3]`
    /// with no compensating cut anywhere, so a mix already mastered near full
    /// scale arrives at the limiter roughly 7 dB hot and comes out squashed —
    /// the user hears the preset as "louder and flatter" rather than as the tone
    /// change they asked for. Melo already applies exactly this discipline to
    /// *imported* AutoEQ profiles, where `AutoEQProfile.preampDB` is honoured
    /// and the Guide explains it under "Prevent Profile Clipping". This closes
    /// the same gap for Melo's own equalizer.
    ///
    /// The rule is the standard graphic-EQ auto-preamp: cut by the largest
    /// positive band gain, so the loudest band lands back at unity and the curve
    /// keeps its *shape* — every band moves by the same amount, so the tonal
    /// relationship between bands is untouched. A curve that only cuts gets no
    /// preamp; it already has headroom.
    ///
    /// This is deliberately not the true worst case. Ten overlapping peaking
    /// filters can sum above their own maximum, so `SoftLimiter` remains the
    /// backstop. What this removes is the *systematic* several-dB overdrive that
    /// every boosting preset shipped with.
    var preampDB: Float {
        guard isEnabled else { return 0 }
        let peak = clampedGains.max() ?? 0
        return peak > 0 ? -peak : 0
    }

    /// `preampDB` as a linear amplitude multiplier, for the audio path.
    /// `1.0` means "no headroom needed", and the DSP skips the multiply.
    var preampGainLinear: Float {
        let dB = preampDB
        return dB == 0 ? 1 : powf(10, dB / 20)
    }

    /// Flat EQ preset
    static let flat = EQSettings()
}
