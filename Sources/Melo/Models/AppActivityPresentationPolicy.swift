import Foundation

/// How long a quiet app remains in the main list before moving to the
/// collapsible Inactive section.
///
/// This is presentation-only. Audio-engine lifetime, process-tap activation,
/// and privacy behavior are intentionally independent of this UI grace period.
/// "Always show" keeps a row visible; it never means "keep audio captured."
enum QuietMoveDelayOption: String, Codable, CaseIterable, Identifiable, Sendable {
    case off
    case fifteenSeconds
    case thirtySeconds
    case oneMinute
    case never

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: return "Off"
        case .fifteenSeconds: return "15 sec"
        case .thirtySeconds: return "30 sec"
        case .oneMinute: return "1 min"
        case .never: return "Never"
        }
    }

    var explanation: String {
        switch self {
        case .off: return "Move quiet apps right away"
        case .fifteenSeconds: return "Wait 15 seconds before moving them"
        case .thirtySeconds: return "Wait 30 seconds before moving them"
        case .oneMinute: return "Wait 1 minute before moving them"
        case .never: return "Keep quiet apps in the main list"
        }
    }

    /// nil means no automatic move. Zero means move immediately.
    var delaySeconds: TimeInterval? {
        switch self {
        case .off: return 0
        case .fifteenSeconds: return 15
        case .thirtySeconds: return 30
        case .oneMinute: return 60
        case .never: return nil
        }
    }
}

enum AppActivityPresentationPolicy {
    static let defaultQuietMoveDelay: QuietMoveDelayOption = .never

    static func shouldStayInLiveLane(
        identifier: String,
        activeIdentifiers: Set<String>,
        recentlyActiveIdentifiers: Set<String>
    ) -> Bool {
        activeIdentifiers.contains(identifier)
            || recentlyActiveIdentifiers.contains(identifier)
    }
}
