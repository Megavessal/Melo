import AppKit
import Observation
import SwiftUI

/// Closing the window with the title-bar button is a deliberate "I've read
/// enough", so it counts the same as Done. Without this the build is only ever
/// stamped by the buttons, and anyone who closes the window is shown the same
/// release notes at every launch until they next update.
@MainActor
private final class WhatsNewWindowCloseObserver: NSObject, NSWindowDelegate {
    let onClose: () -> Void

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }
}

@Observable
@MainActor
final class WhatsNewCoordinator {
    private let settings: SettingsManager
    private let guidedTour: GuidedTourCoordinator
    private let popupController: MenuBarPopupController

    @ObservationIgnored private var window: UnpromptedWindowPanel?
    @ObservationIgnored private var closeObserver: WhatsNewWindowCloseObserver?

    init(
        settings: SettingsManager,
        guidedTour: GuidedTourCoordinator,
        popupController: MenuBarPopupController
    ) {
        self.settings = settings
        self.guidedTour = guidedTour
        self.popupController = popupController
    }

    static var currentBuild: Int {
        Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0") ?? 0
    }

    /// Whether release notes are actually on screen. Read straight after
    /// `showIfNeeded(suppressedByOnboarding:)` by the launch sequence, so the
    /// analytics prompt can stand down for this launch instead of opening a
    /// second window on top of this one.
    var isPresenting: Bool { window != nil }

    // MARK: - Presentation

    /// - Parameter suppressedByOnboarding: true when first-run setup is about to
    ///   appear. Two windows fighting for the same launch is the worst version of
    ///   this feature, and setup already introduces everything a What's New note
    ///   could point at, so setup wins and the build is stamped as seen.
    func showIfNeeded(suppressedByOnboarding: Bool) {
        let current = Self.currentBuild
        let lastSeen = settings.appSettings.lastSeenReleaseBuild

        // Zero means this key has never been written: a fresh install, or an
        // upgrade from a release that predates it. Neither skipped anything they
        // need telling about, so stamp and stay quiet.
        guard lastSeen > 0 else {
            stamp(current)
            return
        }
        guard lastSeen < current else { return }
        guard !suppressedByOnboarding else {
            stamp(current)
            return
        }

        let pending = MeloReleaseNotes.notes(after: lastSeen, upTo: current)
        // A build with no notes of its own — a hotfix between releases — should
        // not open an empty window.
        guard !pending.isEmpty else {
            stamp(current)
            return
        }
        present(pending, showsFullHistory: false)
    }

    /// Reopened from Settings → About. Shows everything released up to and
    /// including the running build, not just what was missed, because someone
    /// asking for it wants the history rather than a delta.
    func replay() {
        window?.close()
        window = nil
        let history = MeloReleaseNotes.notes(after: 0, upTo: Self.currentBuild)
        present(history.isEmpty ? MeloReleaseNotes.all : history, showsFullHistory: true)
    }

    private func present(_ notes: [MeloReleaseNote], showsFullHistory: Bool) {
        MainThreadStall.beginReport()
        if let window {
            MainThreadStall.measure("whatsNew.represent") { window.presentUnprompted() }
            return
        }

        // Opens by itself a moment after launch, so it is subject to the same
        // activation refusal first-run setup is. See `UnpromptedWindowPanel`.
        let window = UnpromptedWindowPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
            styleMask: UnpromptedWindowPanel.styleMask(),
            backing: .buffered,
            defer: false
        )
        window.title = "What's New in Melo"
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.hidesOnDeactivate = false
        window.becomesKeyOnlyIfNeeded = false
        window.center()

        let view = WhatsNewView(
            notes: notes,
            showsFullHistory: showsFullHistory,
            onDone: { [weak self, weak window] in
                self?.stampCurrentBuild()
                window?.close()
            },
            onShowMe: { [weak self, weak window] in
                window?.close()
                self?.startTour(for: notes)
            }
        )
        let controller = MainThreadStall.measure("whatsNew.hostingController") {
            NSHostingController(rootView: view)
        }
        MainThreadStall.measure("whatsNew.firstLayout") {
            window.contentViewController = controller
        }
        window.isReleasedWhenClosed = false

        let observer = WhatsNewWindowCloseObserver { [weak self] in
            self?.stampCurrentBuild()
            self?.window = nil
        }
        window.delegate = observer
        closeObserver = observer

        self.window = window
        MainThreadStall.measure("whatsNew.present") { window.presentUnprompted() }
        MainThreadStall.report("What's New")
        TelemetryService.shared.send(.whatsNewShown(noteCount: TelemetryBucket(count: notes.count)))
    }

    // MARK: - Spotlight walkthrough

    /// Only items with an anchor can be spotlighted; the rest were already read
    /// in the window. Order follows the notes, so the newest release is toured
    /// first.
    ///
    /// One control is toured once. Several of these releases changed something
    /// that lives behind the Settings gear, and every one of them claimed it:
    /// four consecutive steps cut an identical hole around the same button
    /// while the cards described an app icon, a Bluetooth prompt and a theme.
    /// The first note to claim a control is the only one that points at it, and
    /// the rest are still read in the window above.
    static func tourSteps(for notes: [MeloReleaseNote]) -> [SpotlightStep] {
        var claimed: Set<GuidedTourTarget> = []
        var steps: [SpotlightStep] = []
        for note in notes {
            for item in note.items {
                guard let target = item.target, claimed.insert(target).inserted else { continue }
                steps.append(
                    SpotlightStep(
                        id: item.id,
                        title: item.title,
                        message: item.detail,
                        target: target,
                        // The first-run tour hand-writes these. A tour built out
                        // of data has no author to write them, so a future note
                        // about an app control would have rendered as a centred
                        // card with no spotlight and no pointer, its copy still
                        // describing a control that was not there.
                        unavailable: target.absenceFallback.map { fallback in
                            SpotlightStep.Alternate(
                                target: fallback.target,
                                pointerTarget: fallback.pointer,
                                title: item.title,
                                message: "\(item.detail) \(fallback.note)"
                            )
                        }
                    )
                )
            }
        }
        return steps
    }

    private func startTour(for notes: [MeloReleaseNote]) {
        let steps = Self.tourSteps(for: notes)
        guard !steps.isEmpty else { return }
        guidedTour.begin(steps: steps)
        // The overlay lives inside the menu bar popup and reads its anchors from
        // it, so there is nothing to point at until the popup is on screen. The
        // delay lets the What's New window finish closing first, exactly as
        // onboarding does when it hands over to the first-run tour.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self else { return }
            self.popupController.toggle()
        }
    }

    // MARK: - Bookkeeping

    private func stampCurrentBuild() {
        stamp(Self.currentBuild)
    }

    /// Never moves backwards: a downgrade must not re-arm notes the user has
    /// already read.
    private func stamp(_ build: Int) {
        guard settings.appSettings.lastSeenReleaseBuild < build else { return }
        var appSettings = settings.appSettings
        appSettings.lastSeenReleaseBuild = build
        settings.appSettings = appSettings
    }
}
