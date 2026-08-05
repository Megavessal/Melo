import Foundation

enum AdaptiveAudioIntensity: String, Codable, CaseIterable, Identifiable, Sendable, CustomStringConvertible {
    case low
    case medium
    case high

    var id: String { rawValue }

    var description: String { rawValue.capitalized }

    var eqStrengthDb: Float {
        switch self {
        case .low: return 0.8
        case .medium: return 1.5
        case .high: return 2.4
        }
    }

    var peakCeilingDb: Float {
        switch self {
        case .low: return -1.5
        case .medium: return -2.5
        case .high: return -4.0
        }
    }

    var silenceSpikeCeilingDb: Float {
        switch self {
        case .low: return -6
        case .medium: return -9
        case .high: return -12
        }
    }

    var maxLevelerBoostDb: Float {
        switch self {
        case .low: return 1
        case .medium: return 2
        case .high: return 3
        }
    }

    var maxLevelerCutDb: Float {
        switch self {
        case .low: return 3
        case .medium: return 6
        case .high: return 9
        }
    }

    var compressionRatio: Float {
        switch self {
        case .low: return 1.25
        case .medium: return 1.55
        case .high: return 2.0
        }
    }
}

nonisolated struct AdaptiveAudioSettings: Codable, Equatable, Sendable {
    var enabled: Bool = false
    var contentAwareEQEnabled: Bool = true
    var smartNormalizationEnabled: Bool = true
    var dialogueBoostEnabled: Bool = false
    var intensity: AdaptiveAudioIntensity = .medium

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        contentAwareEQEnabled = try c.decodeIfPresent(Bool.self, forKey: .contentAwareEQEnabled) ?? true
        smartNormalizationEnabled = try c.decodeIfPresent(Bool.self, forKey: .smartNormalizationEnabled) ?? true
        dialogueBoostEnabled = try c.decodeIfPresent(Bool.self, forKey: .dialogueBoostEnabled) ?? false
        intensity = try c.decodeIfPresent(AdaptiveAudioIntensity.self, forKey: .intensity) ?? .medium
    }
}
