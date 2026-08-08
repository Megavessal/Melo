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
    /// What a step says when its target is not on screen. A first run usually
    /// has nothing playing, so the steps about app rows had been spotlighting an
    /// empty rectangle and describing controls that were not there — the exact
    /// shape of a tutorial that is fluff. Those steps now point at the "nothing
    /// is playing" placeholder and say something true about it.
    struct Alternate: Sendable {
        let target: GuidedTourTarget?
        /// Same job as the step's own `pointerTarget`, and needed for the same
        /// reason: an alternate that falls back to a region puts the pointer on
        /// whatever control sits at its centre.
        let pointerTarget: GuidedTourTarget?
        let title: String
        let message: String

        init(
            target: GuidedTourTarget?,
            pointerTarget: GuidedTourTarget? = nil,
            title: String,
            message: String
        ) {
            self.target = target
            self.pointerTarget = pointerTarget
            self.title = title
            self.message = message
        }
    }

    let id: String
    let title: String
    let message: String
    let target: GuidedTourTarget?
    /// Where the pointer goes when `target` is a region rather than one
    /// control. The centre of a region is whatever control happens to sit
    /// there, which for the device list is the mute button — the opposite of
    /// what the step asks you to click.
    let pointerTarget: GuidedTourTarget?
    let unavailable: Alternate?

    init(
        id: String,
        title: String,
        message: String,
        target: GuidedTourTarget?,
        pointerTarget: GuidedTourTarget? = nil,
        unavailable: Alternate? = nil
    ) {
        self.id = id
        self.title = title
        self.message = message
        self.target = target
        self.pointerTarget = pointerTarget
        self.unavailable = unavailable
    }
}

@Observable
@MainActor
final class GuidedTourCoordinator {
    /// The first-run walkthrough. The ids are the old enum case names, which the
    /// popup's reveal mapping and the verify scripts both match on.
    ///
    /// Each step names one control and points at that control: a highlight
    /// around a whole row while the card talks about the equalizer inside it
    /// teaches the row, not the equalizer. Every step's control is reachable
    /// through the cutout while the step is on screen, so a step is an
    /// invitation to do the thing rather than a caption about it. The steps
    /// that need an app row carry an `unavailable` alternate, because a first
    /// run usually has nothing playing.
    static let firstRunTour: [SpotlightStep] = [
        SpotlightStep(
            id: "appList",
            title: "Each app gets its own volume",
            message: "Melo opened this app's row. Drag the highlighted slider — only this app moves, and every other app and your main output stay where they are.",
            target: .appVolume,
            unavailable: SpotlightStep.Alternate(
                target: .emptyApps,
                title: "Apps show up here as they play",
                message: "Nothing is making sound yet. The moment an app plays audio it takes a row here with a volume of its own, independent of every other app and of the main output."
            )
        ),
        SpotlightStep(
            id: "appControls",
            title: "More controls live inside each row",
            message: "This arrow opens and closes an app's row. Everything for that app is inside it: mute, routing to one device or several, boost past 100%, balance, and its equalizer.",
            target: .appDisclosure,
            unavailable: SpotlightStep.Alternate(
                target: .emptyApps,
                title: "More controls live inside each row",
                message: "No app has a row yet. When one does, the arrow beside its name opens mute, device routing, boost past 100%, stereo balance, and that app’s equalizer."
            )
        ),
        SpotlightStep(
            id: "devices",
            title: "Choose speakers, displays, or headphones",
            message: "Every output you can use is in this list, and it is live — click a row to make that device the main output. Melo remembers your order and restores a preferred device when it reconnects.",
            target: .devices,
            pointerTarget: .deviceSelection
        ),
        SpotlightStep(
            id: "autoEQ",
            title: "AutoEQ corrects supported headphones",
            message: "This wand searches measured headphone profiles and applies the correction for your model. That is device correction, separate from an app’s creative EQ.",
            target: .autoEQ,
            unavailable: SpotlightStep.Alternate(
                target: .devices,
                pointerTarget: .deviceSelection,
                title: "AutoEQ corrects supported headphones",
                message: "Nothing connected right now supports it. Connect headphones Melo has a profile for and a wand appears in their row here, applying measured correction for that model."
            )
        ),
        SpotlightStep(
            id: "smartAudio",
            title: "Smart Sound adapts automatically",
            message: "Smart Sound smooths loudness and protects transients. Pick a level here — start at Low or Medium and compare before trying High.",
            target: .smartSoundLevel
        ),
        SpotlightStep(
            id: "equalizer",
            title: "EQ changes the tone of one app",
            message: "These ten bands shape this app and nothing else. Start from a preset, then move a band. The switch bypasses a curve without deleting it.",
            target: .equalizer,
            pointerTarget: .eqPreset,
            unavailable: SpotlightStep.Alternate(
                target: .emptyApps,
                title: "EQ changes the tone of one app",
                message: "Each row that appears here carries its own ten-band equalizer: presets to start from, a switch that bypasses a curve without deleting it, and saving for curves you want again."
            )
        ),
        SpotlightStep(
            id: "search",
            title: "Search finds actions, not only labels",
            message: "Press ⌘K, or click the highlighted button. Plain phrases such as ‘quiet apps,’ ‘headphones,’ ‘updates,’ or ‘volume keys’ go straight to the control that does it.",
            target: .search
        ),
        SpotlightStep(
            id: "settings",
            title: "Settings holds the deeper options",
            message: "Themes, shortcuts, updates, accessibility, quiet-app behavior, diagnostics — and a button that replays this tour whenever you want it again.",
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

    #if MELO_DEV
    /// Which walkthrough a snapshot frame should be showing.
    enum SnapshotTour {
        case firstRun
        case custom([SpotlightStep])
    }

    /// Places the tour on an exact step so the render harness can capture each
    /// one. Deliberately bypasses `start` / `next`: stepping there from zero
    /// each frame would fire the first-run lifecycle and stamp
    /// `guidedTourVersionCompleted`, which would mean taking snapshots silently
    /// cancelled the real tour for whoever ran them.
    func jump(to index: Int, in tour: SnapshotTour) {
        switch tour {
        case .firstRun: steps = Self.firstRunTour
        case .custom(let custom): steps = custom
        }
        ownsFirstRunLifecycle = false
        self.index = max(0, min(index, steps.count - 1))
        isActive = !steps.isEmpty
    }
    #endif
}
