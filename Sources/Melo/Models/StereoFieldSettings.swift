import Foundation

/// Per-app stereo balance. `position` ranges from hard left (-1) through
/// center (0) to hard right (1).
nonisolated struct StereoFieldSettings: Codable, Equatable, Sendable {
    static let minimumPosition: Float = -1
    static let maximumPosition: Float = 1

    var isEnabled: Bool
    var position: Float

    init(isEnabled: Bool = false, position: Float = 0) {
        self.isEnabled = isEnabled
        self.position = Self.clamp(position)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
        position = Self.clamp(
            try container.decodeIfPresent(Float.self, forKey: .position) ?? 0
        )
    }

    /// A sanitized copy suitable for persistence and lock-free DSP state.
    var normalized: StereoFieldSettings {
        StereoFieldSettings(isEnabled: isEnabled, position: position)
    }

    /// Linear balance gains: the favored channel remains at unity while the
    /// opposite channel fades toward silence. Center is transparent (1, 1).
    var channelGains: (left: Float, right: Float) {
        let safePosition = Self.clamp(position)
        guard isEnabled else { return (1, 1) }
        if safePosition < 0 {
            return (1, 1 + safePosition)
        }
        return (1 - safePosition, 1)
    }

    static let centered = StereoFieldSettings()

    @inline(__always)
    private static func clamp(_ value: Float) -> Float {
        guard value.isFinite else { return 0 }
        return min(maximumPosition, max(minimumPosition, value))
    }
}
