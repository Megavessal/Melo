import AppKit
import OSLog

/// The one place that calls `NSApp.setActivationPolicy`, so that a Dock tile can
/// be asked for by more than one thing at a time.
///
/// Melo is `LSUIElement`: no Dock tile, no ⌘-Tab entry. A window Melo opens by
/// itself therefore has exactly one route back when another app takes focus in
/// front of it, and that route is the menu bar. First-run setup and a replayed
/// tutorial are the two flows where that is not enough — there the window *is*
/// the task, and losing it behind someone else's browser meant fishing for it.
/// Those flows borrow a Dock tile for as long as they are on screen.
///
/// A set of claims rather than a `show()` / `hide()` pair, because the two flows
/// overlap. Setup's last button closes its window *and* starts the guided tour in
/// the same turn, and Settings › Replay closes the setup window and immediately
/// reopens it. A show/hide pair blinks the tile off and back on across both
/// handoffs; here the tile drops only when the last claim goes, and even then not
/// until the current turn has finished handing over.
///
/// The user's own `showInDock` preference is the third, implicit claim, and the
/// one that outlives the others. It is re-read on every evaluation rather than
/// captured once, so an answer given *during* setup — the toggle on setup's last
/// page writes that same preference — is still in force when setup lets go, and
/// releasing a claim can never turn off a tile the user asked to keep.
@MainActor
final class DockPresence {
    static let shared = DockPresence()

    private nonisolated static let logger = Logger(
        subsystem: "io.github.megavessal.Melo",
        category: "DockPresence"
    )

    /// Who is asking. A set rather than a counter, so `claim` is idempotent per
    /// owner: a coordinator that starts a second walkthrough before finishing the
    /// first would otherwise leave behind a count that nothing ever releases, and
    /// the tile would stay for the rest of the session.
    enum Reason: Hashable {
        case firstRunSetup
        case guidedTour
        /// The Cutting Room. Unlike the other two this is not a flow that ends on
        /// its own — the window stays open for as long as someone is working, and
        /// the whole time it is the task. It is also the only claim a user can
        /// hold while switching to another app on purpose, to drag a file in or
        /// copy a link, which is exactly the case a menu-bar-only route serves
        /// worst.
        case cuttingRoom
    }

    private var claims: Set<Reason> = []
    private var evaluationScheduled = false
    private var keyWindowObservers: [NSObjectProtocol] = []
    private weak var keyWindowToRestore: NSWindow?

    /// Held weakly and read on every evaluation. `AppSupportCoordinator` writes
    /// this preference, Settings › General and the status-item menu toggle it,
    /// and setup's last page asks the same question — all four have to be able to
    /// change the answer while a temporary claim is outstanding.
    private weak var settings: SettingsManager?

    private init() {}

    /// Called once, from `AppSupportCoordinator.init`, which `FineTuneApp` builds
    /// synchronously at startup before any view can put setup or a tour on
    /// screen. Without it the preference reads as "no permanent tile", which
    /// would take the Dock icon away from someone who had chosen to keep it the
    /// first time a temporary claim was released.
    func configure(settings: SettingsManager) {
        self.settings = settings
    }

    /// Borrows a Dock tile for as long as `reason` needs one.
    func claim(_ reason: Reason) {
        guard claims.insert(reason).inserted else { return }
        // Applied now rather than deferred: the caller is about to put a window
        // on screen, and the tile has to exist before the user can lose that
        // window behind another app.
        evaluate(deferringForKeyWindow: false)
    }

    /// Gives back `reason`'s claim. The tile stays if anything else still wants
    /// it, including the user's preference.
    func release(_ reason: Reason) {
        guard claims.remove(reason) != nil else { return }
        // Deferred, and this is the whole point of the type. Setup's close
        // handler closes its window and then starts the tour in the same turn,
        // and `OnboardingWindowController.replay()` closes the window and
        // reopens it in the same turn. Evaluating synchronously would see a
        // momentary zero in both and flick the tile off and straight back on.
        scheduleEvaluation()
    }

    /// Re-applies the user's `showInDock` preference immediately — the launch
    /// path and the Settings/menu toggles. Immediate rather than deferred
    /// because this one is a direct answer to something the user just did, and
    /// a toggle that takes a beat to do anything reads as a broken toggle.
    ///
    /// `activate` is honoured even when the policy did not change: turning the
    /// preference on while a tour already holds the tile still means "bring Melo
    /// to the front", which is what the Settings toggle has always done.
    func reapplyPreference(activate: Bool) {
        evaluate(deferringForKeyWindow: false)
        if activate {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    // MARK: - Evaluation

    private func scheduleEvaluation() {
        guard !evaluationScheduled else { return }
        evaluationScheduled = true
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                let presence = DockPresence.shared
                presence.evaluationScheduled = false
                presence.evaluate(deferringForKeyWindow: true)
            }
        }
    }

    private func evaluate(deferringForKeyWindow: Bool) {
        cancelKeyWindowWait()

        let wanted = !claims.isEmpty || (settings?.appSettings.showInDock ?? false)
        let policy: NSApplication.ActivationPolicy = wanted ? .regular : .accessory
        guard NSApp.activationPolicy() != policy else { return }

        if policy == .accessory, deferringForKeyWindow, let blocker = windowThatWouldLoseKey() {
            // Leaving `.regular` deactivates the app, and the window that was key
            // when that happens is either dead or gone. Dead: visible, draggable,
            // and ignoring every click — the exact defect `UnpromptedWindowPanel`
            // was written to prevent, and a regression this project has already
            // paid for once. Gone: the menu-bar popup calls `dismissWindow()`
            // straight out of `windowDidResignKey`, so dropping the tile the
            // moment the tour's last card is dismissed would tear the popup off
            // the screen underneath it. Wait for whatever is key to stop being
            // key of its own accord, then drop the tile.
            waitForKeyWindowToClear(blocker)
            return
        }

        apply(policy)
    }

    /// The key window that would be harmed by losing key status, if there is one.
    ///
    /// Panels only, and that is the whole distinction. An ordinary window — the
    /// Settings window is the one that matters — survives the app being
    /// deactivated: it stays visible, and clicking it activates Melo again, which
    /// is exactly what happens today when the Settings toggle turns the Dock icon
    /// off. Waiting on one of those would pin a Dock tile up for as long as
    /// Settings stayed open, which is the tile appearing outside setup and the
    /// tour. Panels are the ones with no way back: `UnpromptedWindowPanel` is
    /// `.nonactivatingPanel` precisely because it could not be made key
    /// otherwise, and the menu-bar popup dismisses itself out of
    /// `windowDidResignKey`.
    ///
    /// Nil when nothing is key, which is the ordinary state of an accessory app
    /// and needs no waiting: a window that is not key cannot lose key status.
    private func windowThatWouldLoseKey() -> NSPanel? {
        guard let panel = NSApp.keyWindow as? NSPanel, panel.isVisible, panel.alphaValue >= 1 else {
            return nil
        }
        return panel
    }

    private func apply(_ policy: NSApplication.ActivationPolicy) {
        keyWindowToRestore = NSApp.keyWindow

        guard NSApp.setActivationPolicy(policy) else {
            Self.logger.error("Could not change Dock visibility")
            return
        }

        // A tile that has just appeared takes whatever icon is set at that
        // moment, so the appearance-matched artwork has to be re-asserted rather
        // than assumed to have survived.
        if policy == .regular {
            DockIconAppearanceCoordinator.shared.apply()
        }

        // Deliberately no `NSApp.activate` here. Claiming a tile happens while
        // setup or a tour is coming up, and those flows request activation
        // themselves through `UnpromptedWindowPanel.presentUnprompted()`;
        // activating again from here would pull Melo in front at moments the
        // user did not ask for it. Only `reapplyPreference` activates, and only
        // when the user operated the toggle.
        reassertKey()
        // Once more on the next turn: the resign can land after
        // `setActivationPolicy` returns, in which case the synchronous check
        // above sees a window that is still key and correctly does nothing.
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                DockPresence.shared.reassertKey()
            }
        }
    }

    /// Puts key status back where the policy change took it from. A window that
    /// is visible but not key is the failure mode this project already shipped
    /// once — buttons that draw and do nothing.
    ///
    /// Reads `keyWindowToRestore` rather than taking the window as an argument so
    /// that the deferred second attempt carries nothing across the hop: the
    /// reference is weak, and a window closed in between is then simply gone
    /// rather than kept alive by a closure to be re-ordered onto the screen.
    private func reassertKey() {
        guard let window = keyWindowToRestore, window.isVisible, !window.isKeyWindow else { return }
        // `alphaValue` separates "lost key" from "on its way out". The menu-bar
        // popup dismisses by animating alpha to zero, and the animator proxy
        // writes the model value straight away, so a window that is still
        // `isVisible` at zero alpha is mid-dismissal; re-keying it would fight
        // an animation whose completion handler is going to order it out anyway.
        guard window.alphaValue >= 1 else { return }
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: - Waiting for key status to clear

    private func waitForKeyWindowToClear(_ window: NSWindow) {
        let center = NotificationCenter.default
        // `willClose` as well as `didResignKey`, because a window that is closed
        // outright is a path where the resign notification is not something to
        // rely on — and a claim that never gets re-evaluated is a Dock icon that
        // never goes away.
        for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification] {
            let observer = center.addObserver(forName: name, object: window, queue: .main) { _ in
                MainActor.assumeIsolated {
                    // Straight back through `evaluate`, which tears these
                    // observers down and re-arms if something else has taken key
                    // status in the meantime.
                    DockPresence.shared.evaluate(deferringForKeyWindow: true)
                }
            }
            keyWindowObservers.append(observer)
        }
    }

    private func cancelKeyWindowWait() {
        guard !keyWindowObservers.isEmpty else { return }
        for observer in keyWindowObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        keyWindowObservers.removeAll()
    }
}
