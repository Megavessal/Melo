import AppKit
import SwiftUI

/// Treats closing the welcome window with the title-bar button exactly like Skip.
/// Without this, completion is only ever written by the Skip and Show Me Around
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
    private var window: NSWindow?
    private var closeObserver: OnboardingWindowCloseObserver?
    private let settings: SettingsManager
    private let accessibility: AccessibilityPermissionService
    private let audioPrimer: FirstRunAudioPrimer
    private let guidedTour: GuidedTourCoordinator
    private let popupController: MenuBarPopupController
    private let audioEngine: AudioEngine
    private let sparkle: SparkleUpdateController

    init(
        settings: SettingsManager,
        accessibility: AccessibilityPermissionService,
        audioPrimer: FirstRunAudioPrimer,
        guidedTour: GuidedTourCoordinator,
        popupController: MenuBarPopupController,
        audioEngine: AudioEngine,
        sparkle: SparkleUpdateController
    ) {
        self.settings = settings
        self.accessibility = accessibility
        self.audioPrimer = audioPrimer
        self.guidedTour = guidedTour
        self.popupController = popupController
        self.audioEngine = audioEngine
        self.sparkle = sparkle
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
        settings.appSettings = appSettings
    }

    func replay() {
        audioPrimer.cancel()
        window?.close()
        window = nil
        show()
    }

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 590, height: 470),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to Melo"
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.center()

        let view = FirstRunOnboardingView(
            settings: settings,
            accessibility: accessibility,
            audioPrimer: audioPrimer,
            audioEngine: audioEngine,
            sparkle: sparkle,
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
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
