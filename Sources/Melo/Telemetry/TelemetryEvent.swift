// Melo/Telemetry/TelemetryEvent.swift
import Foundation

/// A coarse count. Melo taps other applications' audio, so anything that counts
/// *which* apps a person uses is one join away from a list of what they run.
/// Buckets keep the product question answerable ("do people adjust one app or
/// many?") without the exact number, which at small user counts is itself a
/// weak identifier.
enum TelemetryBucket: String, Sendable {
    case one
    case twoToFive
    case sixToTen
    case moreThanTen

    init(count: Int) {
        switch count {
        case ..<2: self = .one
        case 2...5: self = .twoToFive
        case 6...10: self = .sixToTen
        default: self = .moreThanTen
        }
    }
}

/// Every signal Melo is capable of sending, and the only way to send one.
///
/// This is a closed enum on purpose. There is deliberately no
/// `send(_ name: String)` anywhere in this module: a free-form string API is
/// how an app name or a bundle identifier eventually ends up on a server —
/// somebody interpolates one into an event name in a hurry and no reviewer
/// notices. Making the type system the redaction guard means a leak has to be
/// a new enum case, which is a visible diff. `scripts/verify-telemetry.py`
/// fails the build if a string-taking send API reappears.
///
/// The same reasoning applies to every payload below: they are enums and
/// buckets, never identifiers, names, paths, or free text.
enum TelemetryEvent: Sendable, Equatable {
    // MARK: Lifecycle
    case appLaunched

    // MARK: First-run experience
    case onboardingCompleted(startedTour: Bool)
    case onboardingSkipped(atPage: TelemetryBucket)
    case guidedTourSkipped(atStep: TelemetryBucket)
    case whatsNewShown(noteCount: TelemetryBucket)

    // MARK: Everyday use
    /// `appsAdjusted` is how many *distinct* apps the user has moved a slider
    /// for in this session, bucketed. Which apps they were is not collected and
    /// must never become collectable.
    case appVolumeAdjusted(appsAdjusted: TelemetryBucket, direction: VolumeDirection)
    case eqPresetApplied(kind: EQPresetKind)
    case autoEQProfileApplied(source: AutoEQSource)
    case sceneCreated(actionCount: TelemetryBucket)
    case automationCreated(trigger: AutomationTrigger)

    // MARK: Appearance
    case themeChanged(kind: ThemeKind)
    case menuBarStyleChanged(kind: MenuBarStyleKind)

    // MARK: Updates
    case updateCheckPerformed(source: UpdateCheckSource)
    case updateInstalled(source: UpdateCheckSource)

    // MARK: Settings
    case settingsSearchUsed(resultCount: TelemetryBucket)

    // MARK: - Payload vocabularies

    enum VolumeDirection: String, Sendable { case up, down, muted, unmuted }

    /// Which *class* of preset, not which preset. Melo lets people name their
    /// own presets, and a user-chosen name is free text — the one thing that
    /// must never be forwarded.
    enum EQPresetKind: String, Sendable { case builtIn, userSaved, flat }

    enum AutoEQSource: String, Sendable { case suggested, searched, manual }

    enum AutomationTrigger: String, Sendable { case focusMode, deviceConnected, schedule, shortcut }

    enum ThemeKind: String, Sendable { case systemAccent, custom, space, galaxy, aurora, generated }

    enum MenuBarStyleKind: String, Sendable { case iconOnly, withVolume, withDevice, withLevel }

    enum UpdateCheckSource: String, Sendable { case automatic, manual }

    // MARK: - Wire form

    /// The signal name as it appears on the vendor's dashboard. Written out
    /// case by case rather than derived from the enum case name so that
    /// renaming a Swift case cannot silently split a metric in two, and so the
    /// full list of everything that can ever be sent is readable in one place.
    var signalName: String {
        switch self {
        case .appLaunched: return "app.launched"
        case .onboardingCompleted: return "onboarding.completed"
        case .onboardingSkipped: return "onboarding.skipped"
        case .guidedTourSkipped: return "tour.skipped"
        case .whatsNewShown: return "whatsNew.shown"
        case .appVolumeAdjusted: return "volume.appAdjusted"
        case .eqPresetApplied: return "eq.presetApplied"
        case .autoEQProfileApplied: return "eq.autoProfileApplied"
        case .sceneCreated: return "scene.created"
        case .automationCreated: return "automation.created"
        case .themeChanged: return "appearance.themeChanged"
        case .menuBarStyleChanged: return "appearance.menuBarStyleChanged"
        case .updateCheckPerformed: return "update.checked"
        case .updateInstalled: return "update.installed"
        case .settingsSearchUsed: return "settings.searchUsed"
        }
    }

    /// The payload. Every value here is one of the closed vocabularies above or
    /// a bucket — there is no branch that can produce caller-supplied text.
    var parameters: [String: String] {
        switch self {
        case .appLaunched:
            return [:]
        case .onboardingCompleted(let startedTour):
            return ["startedTour": startedTour ? "true" : "false"]
        case .onboardingSkipped(let atPage):
            return ["atPage": atPage.rawValue]
        case .guidedTourSkipped(let atStep):
            return ["atStep": atStep.rawValue]
        case .whatsNewShown(let noteCount):
            return ["noteCount": noteCount.rawValue]
        case .appVolumeAdjusted(let appsAdjusted, let direction):
            return ["appsAdjusted": appsAdjusted.rawValue, "direction": direction.rawValue]
        case .eqPresetApplied(let kind):
            return ["kind": kind.rawValue]
        case .autoEQProfileApplied(let source):
            return ["source": source.rawValue]
        case .sceneCreated(let actionCount):
            return ["actionCount": actionCount.rawValue]
        case .automationCreated(let trigger):
            return ["trigger": trigger.rawValue]
        case .themeChanged(let kind):
            return ["kind": kind.rawValue]
        case .menuBarStyleChanged(let kind):
            return ["kind": kind.rawValue]
        case .updateCheckPerformed(let source):
            return ["source": source.rawValue]
        case .updateInstalled(let source):
            return ["source": source.rawValue]
        case .settingsSearchUsed(let resultCount):
            return ["resultCount": resultCount.rawValue]
        }
    }
}
