// Melo/MeloApp.swift
import SwiftUI
import UserNotifications
import AppIntents
import FluidMenuBarExtra
import AppKit
import os

private let logger = Logger(subsystem: "io.github.megavessal.Melo", category: "App")

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    var audioEngine: AudioEngine?
    var menuBarPopupController: MenuBarPopupController?
    /// `UNUserNotificationCenter` allows exactly one delegate and macOS expects
    /// it to be the app delegate, so a notification response arrives here and
    /// nowhere else. The controller decides what each button means; this only
    /// gets the message to it.
    var sparkleUpdateController: SparkleUpdateController?

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let audioEngine = audioEngine else {
            return
        }
        let urlHandler = URLHandler(audioEngine: audioEngine)

        for url in urls {
            if url.scheme == "melo", url.host == "toggle-popup" {
                menuBarPopupController?.toggle()
            } else {
                urlHandler.handleURL(url)
            }
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner])
    }

    /// Without this the update notification was a dead end: the system's
    /// default response is to activate the app, and Melo is an `LSUIElement`
    /// with no Dock tile and no window, so tapping the one thing that announces
    /// a new version brought nothing at all to the screen.
    ///
    /// Only Sendable values cross the isolation hop — `UNNotificationResponse`
    /// is not Sendable, so the two identifiers are read here and the object
    /// itself is left behind.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let actionIdentifier = response.actionIdentifier
        let categoryIdentifier = response.notification.request.content.categoryIdentifier
        // Called here rather than inside the Task below. The completion handler
        // is not Sendable, so it cannot cross the hop to the main actor — and
        // it does not need to: its contract is "everything I needed from this
        // response has been read", which is true on the line above. What
        // follows is Melo's own work on its own state, not the system's.
        completionHandler()
        Task { @MainActor in
            self.sparkleUpdateController?.handleNotificationResponse(
                actionIdentifier: actionIdentifier,
                categoryIdentifier: categoryIdentifier
            )
        }
    }

    /// LSUIElement agent — closing the Settings window must not terminate the app.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        if !flag { menuBarPopupController?.toggle() }
        return true
    }
}

@main
struct MeloApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var audioEngine: AudioEngine
    @State private var accessibility: AccessibilityPermissionService
    @State private var mediaKeyStatus: MediaKeyStatus
    @State private var popupVisibility: PopupVisibilityService
    @State private var hudController: HUDWindowController
    @State private var mediaKeyMonitor: MediaKeyMonitor
    @State private var feedbackPlayer: VolumeFeedbackPlayer
    @State private var iconCoordinator: MenuBarIconCoordinator
    @State private var menuBarPopupController: MenuBarPopupController
    @State private var shortcutsRegistry: ShortcutsRegistry
    @State private var consumerAutomationManager: ConsumerAutomationManager
    @State private var callDuckingManager: CallDuckingManager
    @State private var sleepTimerManager: SleepTimerManager
    @State private var powerSourceMonitor: PowerSourceMonitor
    @State private var onboardingController: OnboardingWindowController
    @State private var installLocationCoordinator: InstallLocationCoordinator
    @State private var guidedTourCoordinator: GuidedTourCoordinator
    @State private var whatsNewCoordinator: WhatsNewCoordinator
    @State private var analyticsConsentPrompt: AnalyticsConsentPrompt
    @State private var resolver: TargetAppResolver
    @State private var appSupportCoordinator: AppSupportCoordinator
    @StateObject private var sparkleUpdateController: SparkleUpdateController
    @StateObject private var developerUpdateManager: DeveloperUpdateManager
    @State private var showMenuBarExtra = true

    /// Snapshot icon computed at launch from the user's chosen style and the current
    /// default-device volume/mute. The coordinator keeps it in sync afterwards.
    private let launchIconImage: NSImage

    var body: some Scene {
        // Declared before FluidMenuBarExtra so this Settings scene wins over
        // FluidMenuBarExtra's `Settings {}` placeholder. Both ⌘, and the
        // gear button route here via openSettings().
        Settings {
            SettingsRootView(
                settings: audioEngine.settingsManager,
                audioEngine: audioEngine,
                deviceVolumeMonitor: audioEngine.deviceVolumeMonitor as! DeviceVolumeMonitor,
                accessibility: accessibility,
                mediaKeyStatus: mediaKeyStatus,
                mediaKeyMonitor: mediaKeyMonitor,
                shortcutsRegistry: shortcutsRegistry,
                sparkleUpdateController: sparkleUpdateController,
                developerUpdateManager: developerUpdateManager,
                consumerAutomationManager: consumerAutomationManager,
                callDuckingManager: callDuckingManager,
                sleepTimerManager: sleepTimerManager,
                powerSourceMonitor: powerSourceMonitor,
                appSupport: appSupportCoordinator
            )
        }
        FluidMenuBarExtra("Melo", image: launchIconImage, isInserted: $showMenuBarExtra) {
            menuBarContent
        }
    }

    @ViewBuilder
    private var menuBarContent: some View {
        // `deviceVolumeMonitor` is declared as `any DeviceVolumeProviding` on
        // AudioEngine so tests can inject mocks; in production it's always the
        // concrete `DeviceVolumeMonitor` that this view consumes directly.
        MenuBarPopupView(
            audioEngine: audioEngine,
            deviceVolumeMonitor: audioEngine.deviceVolumeMonitor as! DeviceVolumeMonitor,
            sparkleUpdateController: sparkleUpdateController,
            permission: audioEngine.permission,
            accessibility: accessibility,
            mediaKeyStatus: mediaKeyStatus,
            popupVisibility: popupVisibility,
            hudController: hudController,
            mediaKeyMonitor: mediaKeyMonitor,
            guidedTour: guidedTourCoordinator
        )
        .task {
            // Idempotent: subsequent task runs (popup re-open) are no-ops inside start().
            shortcutsRegistry.start()
            consumerAutomationManager.start()
            callDuckingManager.start()
            powerSourceMonitor.start()
            developerUpdateManager.start()
            guidedTourCoordinator.beginIfPending()
        }
    }

    init() {
        // Must be first. The update installer launches a staged bundle with
        // `--melo-preflight` to prove it links and starts before replacing the
        // running copy; anything above this line would run during that check.
        UpdateStartupConfirmation.handlePreflightAndExitIfNeeded()

        // Before the first line that reads UserDefaults. Melo's bundle identifier
        // changed from its pre-2.9.4 placeholder, and macOS keys the defaults
        // store by identifier and nothing else — so on the first launch after the rename
        // the two constructors below would find an empty domain and treat an
        // upgrade as a first install. SparkleUpdateController's initialiser reads
        // the skip and the check settings; DeveloperUpdateManager's reads the
        // folder-check flag. Both must see the migrated values, not the defaults.
        LegacyDefaultsMigration.runIfNeeded()

        let sparkleUpdater = SparkleUpdateController()
        let developerUpdater = DeveloperUpdateManager()
        _sparkleUpdateController = StateObject(wrappedValue: sparkleUpdater)
        _developerUpdateManager = StateObject(wrappedValue: developerUpdater)

        // Install crash handler to clean up aggregate devices on abnormal exit
        CrashGuard.install()
        // Destroy any orphaned aggregate devices from previous crashes
        OrphanedTapCleanup.destroyOrphanedDevices()

        let settings = SettingsManager()
        let profileManager = AutoEQProfileManager()
        let permission = AudioRecordingPermission()
        let engine = AudioEngine(permission: permission, settingsManager: settings, autoEQProfileManager: profileManager)
        _audioEngine = State(initialValue: engine)
        let automationManager = ConsumerAutomationManager(audioEngine: engine)
        _consumerAutomationManager = State(initialValue: automationManager)
        let callManager = CallDuckingManager(audioEngine: engine)
        _callDuckingManager = State(initialValue: callManager)
        let sleepTimer = SleepTimerManager(deviceVolumeMonitor: engine.deviceVolumeMonitor)
        _sleepTimerManager = State(initialValue: sleepTimer)
        let powerMonitor = PowerSourceMonitor(audioEngine: engine)
        _powerSourceMonitor = State(initialValue: powerMonitor)
        DispatchQueue.main.async {
            automationManager.start()
            callManager.start()
            powerMonitor.start()
            developerUpdater.start()
        }

        // Media keys / HUD services — instantiated at app scope so the tap
        // and HUD panel outlive popup open/close cycles.
        let accessibilityService = AccessibilityPermissionService()
        let popupController = MenuBarPopupController()
        let guidedTour = GuidedTourCoordinator(settings: settings)
        let audioPrimer = FirstRunAudioPrimer(audioEngine: engine)
        let onboarding = OnboardingWindowController(
            settings: settings,
            accessibility: accessibilityService,
            audioPrimer: audioPrimer,
            guidedTour: guidedTour,
            popupController: popupController,
            audioEngine: engine
        )
        _onboardingController = State(initialValue: onboarding)
        let installLocation = InstallLocationCoordinator()
        _installLocationCoordinator = State(initialValue: installLocation)
        _guidedTourCoordinator = State(initialValue: guidedTour)
        let whatsNew = WhatsNewCoordinator(
            settings: settings,
            guidedTour: guidedTour,
            popupController: popupController
        )
        _whatsNewCoordinator = State(initialValue: whatsNew)
        let analyticsConsent = AnalyticsConsentPrompt(settings: settings)
        _analyticsConsentPrompt = State(initialValue: analyticsConsent)
        // Reads the stored answer and, only if it is already `.granted` from a
        // previous run, starts the vendor SDKs. On a fresh install and on any
        // install that declined, this call starts nothing at all.
        TelemetryService.shared.configure(settings: settings)
        let appSupport = AppSupportCoordinator(
            settings: settings,
            onboarding: onboarding,
            whatsNew: whatsNew,
            audioEngine: engine,
            sparkle: sparkleUpdater
        )
        _appSupportCoordinator = State(initialValue: appSupport)
        DispatchQueue.main.async { [appSupport] in
            appSupport.applyDockPreferenceAtLaunch()
            DockIconAppearanceCoordinator.shared.start()
        }
        let statusService = MediaKeyStatus()
        let popupService = PopupVisibilityService()
        let hud = HUDWindowController(settingsManager: settings, mediaKeyStatus: statusService, popupVisibility: popupService)
        let feedbackPlayer = VolumeFeedbackPlayer()

        // Wire the interactive Tahoe slider back to the device volume monitor.
        // Mirrors the mute semantics applied for media-key drags (auto-unmute
        // when ramping above 0 from muted; auto-mute when dragging down to 0)
        // so the HUD slider and F11/F12 behave identically.
        hud.volumeWriter = { [weak engine] sliderFraction in
            guard let engine else { return }
            let volumeMonitor = engine.deviceVolumeMonitor
            let deviceID = volumeMonitor.defaultDeviceID
            guard deviceID.isValid else { return }
            let tier = volumeMonitor.outputVolumeBackend(for: deviceID)
            let currentMute = volumeMonitor.muteStates[deviceID] ?? false
            let willBeSilent = sliderFraction <= 0.001
            if currentMute && !willBeSilent {
                engine.setOutputDeviceMute(for: deviceID, to: false)
            } else if !currentMute && willBeSilent {
                engine.setOutputDeviceMute(for: deviceID, to: true)
            }
            let gain = VolumeMapping.systemGain(forSliderFraction: sliderFraction, tier: tier)
            engine.setOutputDeviceVolume(for: deviceID, to: gain)
            feedbackPlayer.requestFeedback(
                gain: VolumeFeedback.gain(tier: tier, sliderFraction: sliderFraction)
            )
        }

        let monitor = MediaKeyMonitor(
            decoder: IOKitMediaKeyDecoder(),
            audioEngine: engine,
            settingsManager: settings,
            accessibility: accessibilityService,
            hudController: hud,
            popupVisibility: popupService,
            mediaKeyStatus: statusService
        )
        monitor.feedbackPlayer = feedbackPlayer
        _accessibility = State(initialValue: accessibilityService)
        _mediaKeyStatus = State(initialValue: statusService)
        _popupVisibility = State(initialValue: popupService)
        _hudController = State(initialValue: hud)
        _mediaKeyMonitor = State(initialValue: monitor)
        _feedbackPlayer = State(initialValue: feedbackPlayer)

        let coordinator = MenuBarIconCoordinator(
            deviceVolumeMonitor: engine.deviceVolumeMonitor as! DeviceVolumeMonitor,
            deviceProvider: engine.deviceMonitor,
            settings: settings,
            appSupport: appSupport,
            popupController: popupController,
            levelProvider: { engine.audioLevels.values.max() ?? 0 }
        )
        monitor.iconCoordinator = coordinator
        // Defer start() so NSApplication.shared is fully bootstrapped before we walk NSApp.windows.
        DispatchQueue.main.async { [coordinator] in coordinator.start() }
        _iconCoordinator = State(initialValue: coordinator)

        // Render the scene's first frame with the user's chosen style instead of a generic
        // placeholder, so non-speaker styles don't briefly flash a speaker icon at launch.
        let launchVolumeMonitor = engine.deviceVolumeMonitor
        let launchID = launchVolumeMonitor.defaultDeviceID
        let launchState = MenuBarIconState.baseline(
            style: settings.appSettings.menuBarIconStyle,
            volume: launchVolumeMonitor.volumes[launchID] ?? 1.0,
            muted: launchVolumeMonitor.muteStates[launchID] ?? false,
            deviceSymbol: MenuBarDeviceIconResolver.resolveSymbol(
                priorityOrder: settings.devicePriorityOrder,
                outputDevices: engine.deviceMonitor.outputDevices,
                defaultDeviceID: launchID,
                overrideForUID: { settings.getDeviceIconOverride(for: $0) }
            )
        )
        // The fallback must go through the shared canvas too, or the status
        // item launches at natural symbol width and jumps on the first apply().
        launchIconImage = launchState.image.nsImage()
            ?? MenuBarIconImage.systemSymbol("speaker.wave.2").nsImage()!

        // Start Accessibility polling immediately so `isTrustedCached` is live
        // before the user first opens Settings. The trust-flip callback wires
        // the monitor to reconcile its tap state whenever trust changes — this
        // is the single source of truth for retroactive start/stop (a `.onChange`
        // inside MenuBarPopupView would miss flips when the popup is closed).
        accessibilityService.onTrustChanged = { [weak monitor] _ in
            monitor?.reconcile()
        }
        accessibilityService.start()
        monitor.reconcile()

        // Global hotkeys (KeyboardShortcuts SPM, Carbon-backed; no Accessibility
        // permission required for the hotkey itself). Registry start() is deferred
        // to a SwiftUI `.task` on the popup content so the FluidMenuBarExtra
        // status item has been materialized before any hotkey can fire.
        let resolver = TargetAppResolver(
            ownBundleID: Bundle.main.bundleIdentifier ?? "io.github.megavessal.Melo"
        )
        resolver.start()
        let registry = ShortcutsRegistry(
            settings: settings,
            popupController: popupController,
            resolver: resolver,
            audioEngine: engine,
            hud: hud
        )
        _menuBarPopupController = State(initialValue: popupController)
        _shortcutsRegistry = State(initialValue: registry)
        _resolver = State(initialValue: resolver)

        // Pass engine to AppDelegate
        _appDelegate.wrappedValue.audioEngine = engine
        _appDelegate.wrappedValue.menuBarPopupController = popupController
        // Assigned before the delegate is set below, so a notification response
        // can never arrive at a delegate that has nothing to route it to.
        _appDelegate.wrappedValue.sparkleUpdateController = sparkleUpdater

        // DeviceVolumeMonitor is now created and started inside AudioEngine
        // This ensures proper initialization order: deviceMonitor.start() -> deviceVolumeMonitor.start()

        // Set delegate before requesting authorization so willPresent is called
        UNUserNotificationCenter.current().delegate = _appDelegate.wrappedValue

        // Notification permission is requested when it becomes relevant, not with a
        // cold prompt during launch. See NotificationAuthorization.
        NotificationAuthorization.requestAtLaunchIfAppropriate(settings)

        MeloIntentBridge.shared.configure(audioEngine: engine, sleepTimer: sleepTimer)
        MeloAppShortcuts.updateAppShortcutParameters()
        // Install location first. It can relaunch the app from a new path, so
        // running it ahead of onboarding avoids starting setup in a copy that is
        // about to be replaced. It is a no-op unless Melo is somewhere it cannot
        // update itself from.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            installLocation.showIfNeeded()
            // Read before showing: `showIfNeeded()` writes nothing, but setup
            // marks itself complete as soon as it is dismissed, so asking
            // afterwards could report "not pending" while its window is open.
            let setupPending = onboarding.isSetupPending
            onboarding.showIfNeeded()
            whatsNew.showIfNeeded(suppressedByOnboarding: setupPending)
            // Last, and only if the launch is otherwise quiet. New users answer
            // this inside setup; this window exists for people who upgraded into
            // the release that added the question. Both suppressions are passed
            // as facts rather than inferred from a delay — `isPresenting` is read
            // after `showIfNeeded` precisely because that is when the answer is
            // known.
            analyticsConsent.showIfNeeded(
                suppressedByOnboarding: setupPending,
                suppressedByWhatsNew: whatsNew.isPresenting
            )
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            UpdateStartupConfirmation.confirmCurrentBuild()
        }

        #if MELO_DEV
        // Renders the real UI offscreen and exits. Scheduled after the windows
        // above so nothing races a setup sheet into the capture, and gated on an
        // environment variable so a normal `--dev` build is unaffected.
        if SnapshotHarness.isRequested {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                MainActor.assumeIsolated { () -> Void in
                    SnapshotHarness.run(
                        SnapshotScenes.all(
                            audioEngine: engine,
                            deviceVolumeMonitor: engine.deviceVolumeMonitor as! DeviceVolumeMonitor,
                            sparkle: sparkleUpdater,
                            developerUpdates: developerUpdater,
                            permission: permission,
                            accessibility: accessibilityService,
                            mediaKeyStatus: statusService,
                            popupVisibility: popupService,
                            hudController: hud,
                            mediaKeyMonitor: monitor,
                            guidedTour: guidedTour,
                            settings: settings
                        )
                    )
                }
            }
        }
        #endif

        // Flush debounced settings + tear down the CGEventTap before dealloc.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [settings, monitor, accessibilityService, hud, coordinator, callManager, sleepTimer, powerMonitor] _ in
            MainActor.assumeIsolated {
                coordinator.stop()
                callManager.stop()
                sleepTimer.cancel()
                powerMonitor.stop()
                monitor.stop()
                accessibilityService.stop()
                hud.shutdown()
                engine.shutdown()
                settings.flushSync()
                engine.audioUnitHost.flushSync()
            }
        }
    }
}
