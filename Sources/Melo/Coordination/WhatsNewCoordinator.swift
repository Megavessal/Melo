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

    @ObservationIgnored private var window: NSWindow?
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
        present(pending)
    }

    /// Reopened from Settings → About. Shows everything released up to and
    /// including the running build, not just what was missed, because someone
    /// asking for it wants the history rather than a delta.
    func replay() {
        window?.close()
        window = nil
        let history = MeloReleaseNotes.notes(after: 0, upTo: Self.currentBuild)
        present(history.isEmpty ? MeloReleaseNotes.all : history)
    }

    private func present(_ notes: [MeloReleaseNote]) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "What's New in Melo"
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.center()

        let view = WhatsNewView(
            notes: notes,
            onDone: { [weak self, weak window] in
                self?.stampCurrentBuild()
                window?.close()
            },
            onShowMe: { [weak self, weak window] in
                window?.close()
                self?.startTour(for: notes)
            }
        )
        window.contentViewController = NSHostingController(rootView: view)
        window.isReleasedWhenClosed = false

        let observer = WhatsNewWindowCloseObserver { [weak self] in
            self?.stampCurrentBuild()
            self?.window = nil
        }
        window.delegate = observer
        closeObserver = observer

        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Spotlight walkthrough

    /// Only items with an anchor can be spotlighted; the rest were already read
    /// in the window. Order follows the notes, so the newest release is toured
    /// first.
    static func tourSteps(for notes: [MeloReleaseNote]) -> [SpotlightStep] {
        notes.flatMap { note in
            note.items.compactMap { item in
                guard let target = item.target else { return nil }
                return SpotlightStep(
                    id: item.id,
                    title: item.title,
                    message: item.detail,
                    target: target
                )
            }
        }
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
