import Foundation

/// One card in a spotlight walkthrough. The tour used to be a hardcoded enum,
/// which meant the only walkthrough that could ever exist was the first-run one.
/// Describing a step as data lets the What's New flow build a tour out of the
/// release notes and drive the same overlay.
///
/// `target` is optional because a release note can describe something with no
/// on-screen anchor (a new app icon, a policy change). Those steps render as a
/// centred card with no cutout and no pointer.
struct SpotlightStep: Identifiable, Sendable {
    let id: String
    let title: String
    let message: String
    let target: GuidedTourTarget?
}

@Observable
@MainActor
final class GuidedTourCoordinator {
    /// The first-run walkthrough, carried over verbatim from when it was an enum
    /// plus a `copy(for:)` switch. The ids are the old case names: the overlay
    /// still keys its pointer placement off them, and the verify scripts match
    /// on them.
    static let firstRunTour: [SpotlightStep] = [
        SpotlightStep(
            id: "appList",
            title: "Each app gets its own volume",
            message: "Play audio in an app, then move only that app’s slider. Other apps and your main output stay where they are.",
            target: .apps
        ),
        SpotlightStep(
            id: "appControls",
            title: "More controls live inside each row",
            message: "Expand an app to mute it, route it to one or several devices, raise it beyond 100%, adjust stereo balance, and open its equalizer.",
            target: .apps
        ),
        SpotlightStep(
            id: "devices",
            title: "Choose speakers, displays, or headphones",
            message: "Select the main output here. Melo remembers your device priority and restores preferred devices when they reconnect.",
            target: .devices
        ),
        SpotlightStep(
            id: "autoEQ",
            title: "AutoEQ corrects supported headphones",
            message: "The wand beside a supported output searches headphone profiles and applies measured correction. This is device correction, separate from an app’s creative EQ.",
            target: .devices
        ),
        SpotlightStep(
            id: "smartAudio",
            title: "Smart Sound adapts automatically",
            message: "This control can smooth loudness, protect transients, and make gentle content-aware adjustments. Start at Low or Medium and compare before using High.",
            target: .smartAudio
        ),
        SpotlightStep(
            id: "equalizer",
            title: "EQ changes the tone of one app",
            message: "Use a preset or move the ten frequency bands. The switch bypasses the curve without deleting it, and custom curves can be saved as presets.",
            target: .equalizer
        ),
        SpotlightStep(
            id: "search",
            title: "Search finds actions, not only labels",
            message: "Open search with this button or ⌘K. Natural phrases such as ‘quiet apps,’ ‘headphones,’ ‘updates,’ or ‘volume keys’ lead to the relevant control.",
            target: .search
        ),
        SpotlightStep(
            id: "settings",
            title: "Settings holds the deeper options",
            message: "Use Settings for themes, shortcuts, updates, accessibility, quiet-app behavior, diagnostics, and replaying this tutorial.",
            target: .settings
        )
    ]

    private let settings: SettingsManager

    private(set) var isActive = false
    private(set) var steps: [SpotlightStep] = []
    private(set) var index = 0

    /// Only the first-run tour owns the `guidedTourPending` /
    /// `guidedTourVersionCompleted` lifecycle. A What's New walkthrough must not
    /// stamp those, or taking it would silently cancel a setup tour the user has
    /// not seen yet.
    private var ownsFirstRunLifecycle = false

    var currentStep: SpotlightStep? {
        steps.indices.contains(index) ? steps[index] : nil
    }

    var isFirstStep: Bool { index <= 0 }
    var isLastStep: Bool { index >= steps.count - 1 }

    init(settings: SettingsManager) {
        self.settings = settings
    }

    func beginIfPending() {
        guard settings.appSettings.guidedTourPending,
              settings.appSettings.guidedTourVersionCompleted < MeloExperienceVersion.guidedTour else {
            return
        }
        start(Self.firstRunTour, ownsFirstRunLifecycle: true)
    }

    func begin() {
        var appSettings = settings.appSettings
        appSettings.guidedTourPending = true
        settings.appSettings = appSettings
        start(Self.firstRunTour, ownsFirstRunLifecycle: true)
    }

    /// Runs an arbitrary walkthrough — the What's New flow builds one out of the
    /// release notes. An empty list is ignored rather than putting an overlay on
    /// screen with nothing in it.
    func begin(steps: [SpotlightStep]) {
        guard !steps.isEmpty else { return }
        start(steps, ownsFirstRunLifecycle: false)
    }

    private func start(_ steps: [SpotlightStep], ownsFirstRunLifecycle: Bool) {
        self.steps = steps
        self.ownsFirstRunLifecycle = ownsFirstRunLifecycle
        index = 0
        isActive = true
    }

    func next() {
        guard index + 1 < steps.count else {
            finish()
            return
        }
        index += 1
    }

    func back() {
        guard index > 0 else { return }
        index -= 1
    }

    /// Completes only the tour. Quiet-app behavior remains the user's existing
    /// setting and defaults to Never on a fresh install; setup no longer asks
    /// for this choice or changes it during updates.
    func finish() {
        if ownsFirstRunLifecycle {
            var appSettings = settings.appSettings
            appSettings.guidedTourPending = false
            appSettings.guidedTourVersionCompleted = MeloExperienceVersion.guidedTour
            settings.appSettings = appSettings
        }
        ownsFirstRunLifecycle = false
        isActive = false
    }

    func skip() {
        finish()
    }
}
