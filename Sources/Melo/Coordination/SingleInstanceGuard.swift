import AppKit
import Foundation
import os

/// One Melo at a time. A second launch hands the user over to the copy that is
/// already running and then gets out of the way.
///
/// ## Why this is needed at all — macOS does not do it
///
/// Measured on this machine (macOS 27.0) with a pair of throwaway `LSUIElement`
/// app bundles that shared one `CFBundleIdentifier`, ad-hoc signed exactly as
/// Melo is:
///
/// | what was done                                   | processes after |
/// | ----------------------------------------------- | --------------- |
/// | `open A.app`                                    | 1               |
/// | `open A.app` again                              | 1               |
/// | `open B.app` — same bundle id, different path   | **2**           |
/// | `open -n A.app`                                 | **3**           |
/// | ran `A.app/Contents/MacOS/…` directly           | **4**           |
///
/// So LaunchServices de-duplicates on the **bundle path**, not on the bundle
/// identifier. Double-clicking the same Melo twice is already safe and always
/// was. What is not safe is two copies of Melo at two paths — `/Applications`
/// plus a fresh `outputs/Melo.app`, plus anything still in `~/Downloads` or
/// running translocated — which is the ordinary state of this machine and
/// yields two menu-bar items, two audio engines and two sets of process taps.
/// That is the case this type refuses, and it is the only one macOS was never
/// going to refuse for us.
///
/// ## Mechanism, and what it beat
///
/// Detection is `NSRunningApplication.runningApplications(withBundleIdentifier:)`.
/// Handover is a distributed notification. Neither does the whole job alone:
///
/// - **`NSRunningApplication` alone** can find the incumbent, but the only verb
///   it offers is `activate()`, and activating a menu-bar agent that has no
///   window puts *nothing* on the screen. The user who launched Melo because
///   they could not find it would watch the launch do nothing at all — the
///   silent-exit outcome, wearing a different hat.
/// - **A distributed notification alone** cannot detect. Silence from the
///   incumbent is indistinguishable from there being no incumbent, so every
///   ordinary first launch would pay the timeout.
///
/// Together they are exact: the running-applications list decides whether to
/// ask, and the incumbent's reply decides whether to quit. **No reply, no
/// quit** — an instance that cannot hand over keeps running rather than
/// vanishing, because two Melos is a nuisance and a launch that does nothing is
/// a bug report.
///
/// Round-trip latency measured with the same two-bundle probe, posted before
/// `NSApplication.run()` on the asking side and answered from the incumbent's
/// main queue: **1–2 ms**, over four trials, including one where the asking
/// process was started by exec rather than by `open`.
///
/// ## The one thing this changes that is not an improvement
///
/// A document open — "Open With Melo" on an audio file — arrives as an Apple
/// Event *after* launch, in `application(_:open:)`. It is not in `argv` and it
/// cannot be read here, so a handover cannot carry it. With one Melo installed
/// this never comes up: LaunchServices delivers the document straight to the
/// running copy at that path and starts no second process. But asking a
/// *second* copy at a different path to open a file will now bring the running
/// Melo forward and drop the file, where before it would have opened in a
/// second Melo. Judged the better trade — a stray copy quietly editing audio in
/// its own window is the state this type exists to end — and named here because
/// it is a real loss, not an oversight.
@MainActor
enum SingleInstanceGuard {
    private static let logger = Logger(
        subsystem: "io.github.megavessal.Melo",
        category: "SingleInstanceGuard"
    )

    /// "Someone launched me and you were already here — come forward."
    private static let handoverRequest = Notification.Name(
        "io.github.megavessal.Melo.handover-request"
    )

    /// "Heard you. I am on screen; you may go."
    private static let handoverAcknowledgement = Notification.Name(
        "io.github.megavessal.Melo.handover-acknowledgement"
    )

    /// How long a starting instance waits to be answered before deciding the
    /// other process is not going to answer and staying up.
    ///
    /// Three orders of magnitude above the measured 1–2 ms round trip, and it
    /// costs a normal launch nothing: the wait is only entered when another
    /// process with this bundle identifier already exists, which on a healthy
    /// machine means the handover is about to succeed anyway.
    private static let acknowledgementTimeout: TimeInterval = 1.0

    /// Set by the acknowledgement observer, read by the wait loop below. A
    /// static rather than a captured local because the observer block is
    /// `@Sendable` and cannot mutate one.
    private static var acknowledged = false

    /// Held weakly and read inside the observer rather than captured by it, the
    /// same shape `DockPresence` uses for its settings reference. Both live for
    /// the lifetime of the app.
    private static weak var popupController: (any MenuBarPopupControlling)?
    private static weak var popupVisibility: PopupVisibilityService?
    private static var isListening = false

    // MARK: - The exemption

    /// Two ways of starting Melo are *supposed* to produce an extra process,
    /// and refusing either of them breaks the build rather than the app.
    ///
    /// **This looks exactly like a hole someone should close. Do not close it.**
    ///
    /// 1. **The render harness.** `scripts/dev-verify-locked.sh` runs
    ///    `open -n --env MELO_SNAPSHOT_DIR=… "$STAGE/Melo.app"` — a forced new
    ///    instance, from a staged copy in a temp directory, while the user's own
    ///    Melo is almost certainly running. It is the only way any part of this
    ///    app is ever looked at, and a guard that fired here would stop all 222
    ///    frames from rendering. The failure would present as the harness dying
    ///    partway through, which has really happened here three times and cost
    ///    hours each time.
    ///
    ///    The signal is `SnapshotHarness.isRequested` — the same `MELO_SNAPSHOT_DIR`
    ///    read the harness itself gates on, deliberately not a second flag that
    ///    could drift away from it. `SnapshotHarness` is `#if MELO_DEV` in its
    ///    entirety, so this branch does not exist in a release build; neither
    ///    does the harness, so there is nothing there to exempt.
    ///
    ///    An exempt process also never *listens* (see `beginListening`). A
    ///    harness holding a window open for `scripts/ax-check.sh` must not be
    ///    the thing that answers a handover request and drag a scene forward
    ///    mid-render, and it must not be mistaken for a healthy incumbent that
    ///    another launch can hand itself over to.
    ///
    ///    **The harness exemption is enforced twice, and the outer one is the
    ///    real one.** `MeloApp.init()` tests `SnapshotHarness.isRequested`
    ///    itself and does not call into this type at all under the harness, so
    ///    a render run never copies an argument list, never builds an
    ///    environment dictionary, never boxes an existential for
    ///    `beginListening`, and never touches `SingleInstanceGuard` as a type.
    ///    The check below is what keeps this type correct on its own terms for
    ///    any future caller. The reason for the belt as well as the braces is
    ///    recorded rather than assumed: a render regression was attributed to
    ///    this guard while the only thing it did under the harness was return,
    ///    and "returns immediately" turned out to be a much weaker thing to be
    ///    able to say than "is never called".
    ///
    /// 2. **`--melo-preflight`.** `scripts/build-app.sh:157` runs the binary it
    ///    just built with that flag as a launch test, and
    ///    `UpdateInstallationCoordinator` does the same to a staged bundle
    ///    before replacing a running copy — by definition with the user's Melo
    ///    alive. Both are direct execs, which the table above shows LaunchServices
    ///    does not de-duplicate. A guard that refused them would fail every build
    ///    made while Melo was running, and abort every in-app update.
    ///
    ///    Ordering already covers this: `handlePreflightAndExitIfNeeded()` is
    ///    the first statement of `MeloApp.init()` and calls `exit(0)`, so a
    ///    preflight process is gone before it reaches the guard. The check is
    ///    named here anyway so the guard is correct on its own terms rather than
    ///    because of a line number someone could reorder.
    private static var isExempt: Bool {
        if CommandLine.arguments.contains(UpdateStartupConfirmation.preflightArgument) {
            return true
        }
        #if MELO_DEV
        if SnapshotHarness.isRequested {
            return true
        }
        #endif
        return false
    }

    // MARK: - Starting up

    /// Called as early in `MeloApp.init()` as the preflight check allows.
    ///
    /// Returns normally when this process is the one Melo that should be
    /// running. Does not return — the process exits — when another Melo has
    /// confirmed it is here and has brought itself forward.
    ///
    /// Nothing has been built yet when this runs, which is the point: a second
    /// instance must not construct an `AudioEngine`, install a process tap, or
    /// add a status item on its way out of the world.
    static func claimOrHandOff() {
        guard !isExempt else { return }
        guard let bundleID = Bundle.main.bundleIdentifier else { return }

        let me = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != me && !$0.isTerminated }
        guard !others.isEmpty else { return }

        logger.info("Another Melo is running (\(others.count, privacy: .public)); asking it to come forward")

        acknowledged = false
        let center = DistributedNotificationCenter.default()
        // A distributed notification is delivered to its own sender as well, so
        // every message in this exchange carries the pid that sent it and every
        // observer drops its own.
        let observer = center.addObserver(
            forName: handoverAcknowledgement,
            object: nil,
            queue: .main
        ) { note in
            guard note.object as? String != String(me) else { return }
            MainActor.assumeIsolated { SingleInstanceGuard.acknowledged = true }
        }
        center.postNotificationName(
            handoverRequest,
            object: String(me),
            userInfo: nil,
            deliverImmediately: true
        )

        // The run loop has to be pumped by hand: this is before
        // `NSApplication.run()`, so nothing else is turning it. Short slices so
        // the wait ends on the reply rather than on the deadline — in the
        // ordinary case this loop runs once.
        let deadline = Date().addingTimeInterval(acknowledgementTimeout)
        while !acknowledged, Date() < deadline {
            CFRunLoopRunInMode(.defaultMode, 0.02, true)
        }
        center.removeObserver(observer)

        guard acknowledged else {
            // Nobody answered. Possible: the other process is the render
            // harness, is still starting up, or is wedged. Staying up is the
            // safe direction — see the type comment.
            logger.notice("No Melo answered the handover request; continuing to launch")
            return
        }
        logger.info("Handed over to the running Melo; exiting")
        exit(0)
    }

    /// Makes this process answerable to a later launch. Called from
    /// `MeloApp.init()` once the popup controller exists.
    ///
    /// Separate from `claimOrHandOff()` because the two need different things:
    /// the guard has to run before anything is constructed, and the answer has
    /// to be able to reach a popup that does not exist yet at that point.
    static func beginListening(
        popupController: any MenuBarPopupControlling,
        popupVisibility: PopupVisibilityService
    ) {
        guard !isExempt, !isListening else { return }
        isListening = true
        Self.popupController = popupController
        Self.popupVisibility = popupVisibility

        let me = ProcessInfo.processInfo.processIdentifier
        DistributedNotificationCenter.default().addObserver(
            forName: handoverRequest,
            object: nil,
            queue: .main
        ) { note in
            guard note.object as? String != String(me) else { return }
            MainActor.assumeIsolated {
                SingleInstanceGuard.comeForward()
                DistributedNotificationCenter.default().postNotificationName(
                    handoverAcknowledgement,
                    object: String(me),
                    userInfo: nil,
                    deliverImmediately: true
                )
            }
        }
    }

    // MARK: - Answering

    /// What a second launch actually buys the person who performed it.
    ///
    /// Someone launching Melo again is asking for Melo, and nearly always
    /// because they cannot see it: the app is `LSUIElement`, so there is no Dock
    /// tile unless something claimed one, and a menu-bar item is easy to lose in
    /// a crowded bar. Quitting the new process without showing them anything
    /// would be indistinguishable, from the outside, from Melo being broken.
    private static func comeForward() {
        // Melo Edit first. When it is open it is the window someone is working
        // in, it already holds a Dock claim, and `show()` re-activates and
        // re-keys it.
        if EditorWindowController.shared.isOpen {
            logger.info("Handover: bringing Melo Edit forward")
            EditorWindowController.shared.show()
            return
        }

        NSApp.activate(ignoringOtherApps: true)
        // `toggle()` is a toggle. Called while the popup is already up it would
        // close the one thing the person is asking to see, so the visibility
        // service — which is driven by the popup window's own key notifications
        // — decides whether there is anything to open.
        guard popupVisibility?.isVisible != true else {
            logger.info("Handover: popup is already open; activated only")
            return
        }
        logger.info("Handover: opening the popup")
        popupController?.toggle()
    }
}
