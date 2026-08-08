import AppKit
import SwiftUI

/// The window class for anything Melo puts on screen that the user did not ask
/// for — first-run setup and What's New, both of which open by themselves a
/// moment after launch.
///
/// Melo is `LSUIElement`, so it runs as an accessory app and is never frontmost
/// unless the system says so. `NSApplication.activate()` documents outright that
/// "the framework also does not guarantee that the app will be activated at
/// all", and measured on macOS 26 an accessory app that opens a plain `NSWindow`
/// while another app is frontmost gets exactly that refusal: three runs out of
/// three, `isVisible == true` and `isKeyWindow == false`, still false two
/// seconds later. That is a window that draws and can be dragged and whose
/// controls do nothing, which is the bug this class exists for. Reordering the
/// activate and the `makeKeyAndOrderFront`, and swapping in the non-deprecated
/// `activate()`, change none of it — measured, the plain window is never key
/// either way.
///
/// `.nonactivatingPanel` is the AppKit facility for precisely this: a panel that
/// takes key status without requiring its app to be active. In the same probe it
/// is the only variant that ever did — key at the call site, three runs out of
/// three, with or without an activation being granted. `canBecomeKey` has to be
/// overridden because `NSPanel` answers it from the style mask, and
/// `hidesOnDeactivate` has to be turned off because `NSPanel` defaults it to
/// `true` — left alone, setup would vanish the instant the user clicked
/// anything else. Same reasoning, and the same lines, as
/// `PopoverHost.KeyablePanel`.
///
/// Activation is still requested, in Apple's documented order (activate, then
/// make key) and through the API that is not deprecated, because when the system
/// *does* grant it the right outcome is Melo in front rather than a panel
/// floating over someone else's work.
final class UnpromptedWindowPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// Style mask for a panel that looks and behaves like an ordinary titled
    /// window. `.nonactivatingPanel` is the load-bearing member; the rest are
    /// what the caller would have passed to `NSWindow`.
    static func styleMask(_ extra: NSWindow.StyleMask = []) -> NSWindow.StyleMask {
        let base: NSWindow.StyleMask = [.titled, .closable, .fullSizeContentView, .nonactivatingPanel]
        return base.union(extra)
    }

    /// Puts the panel on screen and takes key status, whether or not macOS lets
    /// Melo come to the front.
    func presentUnprompted() {
        NSApp.activate()
        makeKeyAndOrderFront(nil)
    }
}

/// Treats closing the welcome window with the title-bar button exactly like Skip.
/// Without this, completion is only ever written by the Skip and Show Me
/// buttons, so anyone who closes the window is shown first-run setup again at
/// every launch, forever.
@MainActor
private final class OnboardingWindowCloseObserver: NSObject, NSWindowDelegate {
    let onClose: () -> Void

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }
}

@MainActor
final class OnboardingWindowController {
    private var window: UnpromptedWindowPanel?
    private var closeObserver: OnboardingWindowCloseObserver?
    private let settings: SettingsManager
    private let accessibility: AccessibilityPermissionService
    private let audioPrimer: FirstRunAudioPrimer
    private let guidedTour: GuidedTourCoordinator
    private let popupController: MenuBarPopupController
    private let audioEngine: AudioEngine
    /// `nonisolated(unsafe)` because `deinit` is nonisolated under Swift 6 and
    /// this token has to be unregistered there — a `@MainActor` property read
    /// from `deinit` does not compile. The access is safe in fact: the token is
    /// written once from the main actor in `observeGuideRequests()` and read
    /// only in `deinit`, which cannot run concurrently with anything else on
    /// this instance.
    nonisolated(unsafe) private var guideRequestObserver: NSObjectProtocol?

    init(
        settings: SettingsManager,
        accessibility: AccessibilityPermissionService,
        audioPrimer: FirstRunAudioPrimer,
        guidedTour: GuidedTourCoordinator,
        popupController: MenuBarPopupController,
        audioEngine: AudioEngine
    ) {
        self.settings = settings
        self.accessibility = accessibility
        self.audioPrimer = audioPrimer
        self.guidedTour = guidedTour
        self.popupController = popupController
        self.audioEngine = audioEngine
        observeGuideRequests()
    }

    deinit {
        if let guideRequestObserver {
            NotificationCenter.default.removeObserver(guideRequestObserver)
        }
    }

    /// The Guide can ask for a control to be shown, and most of Melo's controls
    /// are in the menu bar popup rather than in a Settings tab. This controller
    /// is the one place that holds both the popup controller and the tour
    /// coordinator, so it is where that request is served; the Guide posts
    /// rather than calls because `SettingsRootView` is built by `FineTuneApp`
    /// and cannot be handed either dependency from here.
    private func observeGuideRequests() {
        guideRequestObserver = NotificationCenter.default.addObserver(
            forName: .meloShowControlInPopup,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let request = note.object as? GuideSpotlightRequest else { return }
            MainActor.assumeIsolated {
                self?.showInPopup(request)
            }
        }
    }

    private func showInPopup(_ request: GuideSpotlightRequest) {
        guidedTour.begin(steps: [
            SpotlightStep(
                id: "guide-\(request.id)",
                title: request.title,
                message: request.message,
                target: request.target,
                // A Guide entry names a control; its target is often the region
                // that holds it. Without this the mark landed on whatever sits
                // at the centre of that region, which for the device list is the
                // row's mute button — a different control from the one the entry
                // was written about.
                pointerTarget: request.target?.regionPointer,
                // The Guide's copy is written for a Settings page, so it says
                // nothing about the control being absent. A step whose target is
                // off screen otherwise draws a centred card describing a control
                // that is not there — which is what the What's New walkthrough
                // already avoids this same way.
                unavailable: request.target?.absenceFallback.map { fallback in
                    SpotlightStep.Alternate(
                        target: fallback.target,
                        pointerTarget: fallback.pointer,
                        title: request.title,
                        message: "\(request.message) \(fallback.note)"
                    )
                }
            )
        ])
        // Same handoff the end of setup uses: the overlay has to be armed before
        // the popup opens, or the first layout pass has nothing to spotlight.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.popupController.toggle()
        }
    }

    /// Whether `showIfNeeded()` would actually put setup on screen. Exposed so
    /// the What's New flow can stand down for this launch rather than racing
    /// setup for the same moment.
    var isSetupPending: Bool {
        settings.appSettings.onboardingVersionCompleted < MeloExperienceVersion.onboarding
    }

    func showIfNeeded() {
        // Completion is compared with the onboarding experience version, not the
        // app version: routine updates must never replay setup, but adding pages
        // that ask a new question (Bluetooth, update policy) has to reach people
        // who already finished an older, shorter version of this flow.
        guard isSetupPending else { return }
        show()
    }

    /// Closing the window is a deliberate "I'm done here", so it counts as setup
    /// completed — the same as Skip. Replaying the tutorial is available on demand
    /// from General settings.
    private func markCompletedIfNeeded() {
        audioPrimer.cancel()
        guard settings.appSettings.onboardingVersionCompleted < MeloExperienceVersion.onboarding else { return }
        var appSettings = settings.appSettings
        appSettings.onboardingVersionCompleted = MeloExperienceVersion.onboarding
        appSettings.guidedTourVersionCompleted = MeloExperienceVersion.guidedTour
        appSettings.guidedTourPending = false
        // Closing the window without answering the analytics page is a no. The
        // alternative — leaving it `.unasked` — would pop the standalone prompt
        // at the next launch, i.e. re-ask a question they closed a window on.
        if appSettings.analyticsConsent == .unasked {
            appSettings.analyticsConsent = .denied
        }
        settings.appSettings = appSettings
        TelemetryService.shared.refreshConsent()
    }

    func replay() {
        audioPrimer.cancel()
        window?.close()
        window = nil
        show()
    }

    func show() {
        if let window {
            window.presentUnprompted()
            return
        }

        let window = UnpromptedWindowPanel(
            contentRect: NSRect(x: 0, y: 0, width: 590, height: 560),
            // Resizable vertically: the view is fixed at 590 wide but grows
            // downwards, and at large accessibility text sizes a 470pt window
            // makes every page a scroller. Letting it be dragged taller is the
            // difference between reading a permission ask and scrolling one.
            styleMask: UnpromptedWindowPanel.styleMask(.resizable),
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to Melo"
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.hidesOnDeactivate = false
        window.becomesKeyOnlyIfNeeded = false
        window.contentMinSize = NSSize(width: 590, height: 480)
        window.contentMaxSize = NSSize(width: 590, height: 1200)
        window.center()

        let view = FirstRunOnboardingView(
            settings: settings,
            accessibility: accessibility,
            audioPrimer: audioPrimer,
            audioEngine: audioEngine,
            onClose: { [weak self, weak window] startTour in
                guard let self else { return }
                self.audioPrimer.cancel()
                window?.close()
                guard startTour else { return }

                self.guidedTour.begin()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    self.popupController.toggle()
                }
            }
        )
        window.contentViewController = NSHostingController(rootView: view)
        window.isReleasedWhenClosed = false

        let observer = OnboardingWindowCloseObserver { [weak self] in
            self?.markCompletedIfNeeded()
        }
        window.delegate = observer
        closeObserver = observer

        self.window = window
        window.presentUnprompted()
    }
}
