// Melo/Views/MenuBar/MenuBarIconCoordinator.swift
// Owns NSStatusBarButton.image mutation. FluidMenuBarExtra sets the image
// once at init and never touches it again, so we locate the button by
// walking NSApp.windows for the NSStatusBarButton whose accessibilityTitle
// was set to "Melo" by the library, and crossfade images directly.

@preconcurrency import AppKit
import AudioToolbox
import Observation
import os

@MainActor
final class MenuBarIconCoordinator: NSObject, MediaKeyIconFlashing {
    private let deviceVolumeMonitor: DeviceVolumeMonitor
    private let deviceProvider: any AudioDeviceProviding
    private let settings: SettingsManager
    private let appSupport: AppSupportCoordinator
    private let popupController: MenuBarPopupController
    private let levelProvider: @MainActor () -> Float
    private let logger = Logger(subsystem: "dev.local.Melo", category: "MenuBarIconCoordinator")

    private weak var cachedButton: NSStatusBarButton?
    private var rightMouseMonitor: Any?
    private var globalRightMouseMonitor: Any?
    private var lastContextMenuOpenTime: TimeInterval = 0
    private var lastLocalRightClickTime: TimeInterval = 0
    private var flashWorkItem: DispatchWorkItem?
    private var flashActiveSymbol: String?
    private var lastObservedDeviceID: AudioDeviceID?
    private var started = false
    private var levelTimer: Timer?
    private var motionPollTimer: Timer?
    private let motion = MenuBarIconMotion()

    init(
        deviceVolumeMonitor: DeviceVolumeMonitor,
        deviceProvider: any AudioDeviceProviding,
        settings: SettingsManager,
        appSupport: AppSupportCoordinator,
        popupController: MenuBarPopupController,
        levelProvider: @escaping @MainActor () -> Float = { 0 }
    ) {
        self.deviceVolumeMonitor = deviceVolumeMonitor
        self.deviceProvider = deviceProvider
        self.settings = settings
        self.appSupport = appSupport
        self.popupController = popupController
        self.levelProvider = levelProvider
        super.init()
    }

    /// Begin observing volume / mute / style and apply state to the menu bar button.
    /// Idempotent; safe to call from the app-init path even before the status item exists.
    func start() {
        guard !started else { return }
        started = true
        lastObservedDeviceID = deviceVolumeMonitor.defaultDeviceID
        attemptInitialApply(retriesLeft: 20)
        scheduleApplyTracking()
        scheduleDeviceChangeTracking()
        syncLevelTimer()
        syncMotionTimer()
    }

    /// Cancel pending work and drop references. Called on app termination.
    func stop() {
        flashWorkItem?.cancel()
        flashWorkItem = nil
        levelTimer?.invalidate()
        levelTimer = nil
        motionPollTimer?.invalidate()
        motionPollTimer = nil
        motion.stop()
        if let rightMouseMonitor {
            NSEvent.removeMonitor(rightMouseMonitor)
        }
        if let globalRightMouseMonitor {
            NSEvent.removeMonitor(globalRightMouseMonitor)
        }
        rightMouseMonitor = nil
        globalRightMouseMonitor = nil
        cachedButton = nil
    }

    /// Transient device-icon flash. Applies to every style; fires on media keys and device changes.
    /// If the same symbol is already flashing, extends the timer rather than restarting the fade —
    /// prevents mid-fade pops when device-change and media-key triggers coincide.
    func flashDevice() {
        let symbol = currentDeviceSymbol()
        let alreadyShowingSame = (flashActiveSymbol == symbol)
        flashActiveSymbol = symbol
        if !alreadyShowingSame {
            apply()
        }

        flashWorkItem?.cancel()
        let duration = flashDuration()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.flashActiveSymbol = nil
            self.apply()
        }
        flashWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: item)
    }

    // MARK: - State

    private func computeState() -> MenuBarIconState {
        if let symbol = flashActiveSymbol {
            return .deviceFlash(symbol: symbol)
        }
        let id = deviceVolumeMonitor.defaultDeviceID
        let volume = deviceVolumeMonitor.volumes[id] ?? 0
        let muted = deviceVolumeMonitor.muteStates[id] ?? false
        return MenuBarIconState.baseline(
            style: settings.appSettings.menuBarIconStyle,
            volume: volume,
            muted: muted,
            deviceSymbol: currentDeviceSymbol()
        )
    }

    private func currentDeviceSymbol() -> String {
        MenuBarDeviceIconResolver.resolveSymbol(
            priorityOrder: settings.devicePriorityOrder,
            outputDevices: deviceProvider.outputDevices,
            defaultDeviceID: deviceVolumeMonitor.defaultDeviceID,
            overrideForUID: { [settings] in settings.getDeviceIconOverride(for: $0) }
        )
    }

    private func flashDuration() -> TimeInterval {
        // Matches HUDWindowController.hideDelay so the icon and HUD fade in lockstep.
        return 1.1
    }

    // MARK: - Apply

    private func apply() {
        guard let button = resolveButton() else { return }
        let state = computeState()
        guard let image = state.image.nsImage(motionOffsetCells: motion.offsetCells) else { return }
        addFadeTransition(to: button)
        button.image = image
        let title = menuBarInfoTitle()
        button.title = title
        button.imagePosition = title.isEmpty ? .imageOnly : .imageLeading
        button.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        button.toolTip = title.isEmpty ? "Melo" : "Melo — \(title)"
    }

    private func menuBarInfoTitle() -> String {
        let style = settings.appSettings.menuBarInfoStyle
        let id = deviceVolumeMonitor.defaultDeviceID
        switch style {
        case .iconOnly:
            return ""
        case .volume:
            let muted = deviceVolumeMonitor.muteStates[id] ?? false
            if muted { return "Muted" }
            let volume = deviceVolumeMonitor.volumes[id] ?? 0
            return "\(Int((max(0, min(1, volume)) * 100).rounded()))%"
        case .device:
            let name = deviceProvider.outputDevices.first(where: { $0.id == id })?.name ?? "No Output"
            return name.count > 18 ? String(name.prefix(17)) + "…" : name
        case .level:
            let level = max(0, min(1, levelProvider()))
            let count = Int((level * 4).rounded(.up))
            let filled = String(repeating: "▮", count: count)
            let empty = String(repeating: "▯", count: max(0, 4 - count))
            return filled + empty
        }
    }

    /// The live-level readout is the only menu-bar info style that needs a
    /// repeating tick. The timer used to be created in `start()` and check the
    /// style *inside* its callback, so the default (icon-only) style still paid
    /// ~6 main-thread wakeups a second for the entire life of the app to do
    /// nothing. Driven from `scheduleApplyTracking` instead, which already
    /// observes `menuBarInfoStyle`.
    private func syncLevelTimer() {
        guard settings.appSettings.menuBarInfoStyle == .level else {
            levelTimer?.invalidate()
            levelTimer = nil
            return
        }
        guard levelTimer == nil else { return }
        levelTimer = Timer.scheduledTimer(withTimeInterval: 0.16, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.apply()
            }
        }
    }

    /// The mark only moves while something is actually playing through Melo.
    /// Polling once a second is enough to notice playback starting and stopping —
    /// the animation's own timing lives in MenuBarIconMotion, and this timer does
    /// nothing but answer "is there audio".
    private func syncMotionTimer() {
        let wantsMotion = settings.appSettings.menuBarIconMotion
            && settings.appSettings.menuBarIconStyle == .default
        guard wantsMotion else {
            motionPollTimer?.invalidate()
            motionPollTimer = nil
            motion.setAudioActive(false, enabled: false)
            return
        }
        guard motionPollTimer == nil else { return }
        motionPollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // A floor rather than "greater than zero": silence between
                // tracks still reports tiny non-zero levels.
                self.motion.setAudioActive(self.levelProvider() > 0.01, enabled: true)
            }
        }
    }

    private func attemptInitialApply(retriesLeft: Int) {
        if resolveButton() != nil {
            apply()
            return
        }
        guard retriesLeft > 0 else {
            logger.error("Menu bar button not found after 20 tries (1s); icon will remain at FluidMenuBarExtra placeholder until next state change")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.attemptInitialApply(retriesLeft: retriesLeft - 1)
        }
    }

    private func scheduleApplyTracking() {
        withObservationTracking {
            let id = deviceVolumeMonitor.defaultDeviceID
            _ = deviceVolumeMonitor.volumes[id]
            _ = deviceVolumeMonitor.muteStates[id]
            _ = settings.appSettings.menuBarIconStyle
            _ = settings.appSettings.menuBarInfoStyle
            _ = settings.appSettings.menuBarIconMotion
            // Redraws the button on each animation frame.
            _ = motion.offsetCells
            _ = settings.appSettings.hudStyle
            _ = settings.devicePriorityOrder
            // Deliberate dependency so the device-style icon refreshes when the user picks a new symbol; explicit because observation granularity is per stored property.
            _ = settings.deviceIconOverrides
            _ = deviceProvider.outputDevices
        } onChange: { [weak self] in
            // onChange fires in willSet — the tracked properties are still at their
            // pre-change values inside this closure. Re-register synchronously so the
            // next mutation isn't dropped, then defer apply() to a Task so it reads
            // committed (post-setter) values.
            MainActor.assumeIsolated { [weak self] in
                self?.scheduleApplyTracking()
            }
            Task { @MainActor [weak self] in
                self?.syncLevelTimer()
                self?.syncMotionTimer()
                self?.apply()
            }
        }
    }

    private func scheduleDeviceChangeTracking() {
        withObservationTracking {
            _ = deviceVolumeMonitor.defaultDeviceID
        } onChange: { [weak self] in
            // See scheduleApplyTracking — deferred read so flashDevice sees the NEW
            // defaultDeviceID, not the pre-change value. Otherwise the flash shows
            // the old device's icon (e.g. AirPods while we just switched to MacBook).
            MainActor.assumeIsolated { [weak self] in
                self?.scheduleDeviceChangeTracking()
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                let newID = self.deviceVolumeMonitor.defaultDeviceID
                if let prev = self.lastObservedDeviceID, prev != newID, newID.isValid {
                    self.flashDevice()
                }
                self.lastObservedDeviceID = newID
            }
        }
    }

    // MARK: - Button + image

    private func resolveButton() -> NSStatusBarButton? {
        if let cached = cachedButton { return cached }
        for window in NSApp.windows {
            guard let contentView = window.contentView else { continue }
            if let button = findStatusBarButton(in: contentView, matching: "Melo") {
                button.wantsLayer = true
                installRightClickMenu(on: button)
                cachedButton = button
                return button
            }
        }
        return nil
    }

    /// FluidMenuBarExtra owns normal left-click behavior. AppKit delivers
    /// status-item secondary clicks through the app's local event stream, so
    /// intercept only a right-click that lands inside Melo's status button.
    private func installRightClickMenu(on button: NSStatusBarButton) {
        guard rightMouseMonitor == nil, globalRightMouseMonitor == nil else { return }

        rightMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown]) { [weak self, weak button] event in
            guard let self, let button, let window = button.window,
                  event.windowNumber == window.windowNumber else { return event }
            let location = button.convert(event.locationInWindow, from: nil)
            guard button.bounds.contains(location) else { return event }
            self.lastLocalRightClickTime = Date.timeIntervalSinceReferenceDate
            self.presentContextMenu(for: button, event: event)
            return nil
        }

        // Some menu-bar hosts consume the secondary click before it reaches the
        // local monitor. The global monitor is a narrow fallback: it opens the
        // menu only when the pointer is physically inside Melo's status window.
        globalRightMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.rightMouseDown]) { [weak self] _ in
            let observedAt = Date.timeIntervalSinceReferenceDate
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      observedAt - self.lastLocalRightClickTime > 0.75,
                      let button = self.cachedButton,
                      let window = button.window,
                      window.frame.contains(NSEvent.mouseLocation) else { return }
                self.presentContextMenu(for: button, event: nil)
            }
        }
    }

    private func presentContextMenu(for button: NSStatusBarButton, event: NSEvent?) {
        let now = Date.timeIntervalSinceReferenceDate
        guard now - lastContextMenuOpenTime > 0.42 else { return }
        lastContextMenuOpenTime = now

        let menu = makeStatusItemContextMenu()
        if let event {
            NSMenu.popUpContextMenu(menu, with: event, for: button)
        } else {
            menu.popUp(
                positioning: nil,
                at: NSPoint(x: button.bounds.midX, y: button.bounds.minY - 3),
                in: button
            )
        }
    }

    func makeStatusItemContextMenu() -> NSMenu {
        let menu = NSMenu(title: "Melo")

        let openItem = NSMenuItem(
            title: "Open Melo",
            action: #selector(openPopupFromStatusItem),
            keyEquivalent: ""
        )
        openItem.target = self
        menu.addItem(openItem)

        let settingsItem = NSMenuItem(
            title: "Settings…",
            action: #selector(openSettingsFromStatusItem),
            keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(settingsItem)

        let tutorialItem = NSMenuItem(
            title: "Replay Tutorial",
            action: #selector(replayTutorialFromStatusItem),
            keyEquivalent: ""
        )
        tutorialItem.target = self
        menu.addItem(tutorialItem)

        menu.addItem(.separator())

        let dockItem = NSMenuItem(
            title: "Show Melo in Dock",
            action: #selector(toggleDockFromStatusItem),
            keyEquivalent: ""
        )
        dockItem.target = self
        dockItem.state = settings.appSettings.showInDock ? .on : .off
        menu.addItem(dockItem)

        let loginItem = NSMenuItem(
            title: "Launch at Login",
            action: #selector(toggleLaunchAtLoginFromStatusItem),
            keyEquivalent: ""
        )
        loginItem.target = self
        loginItem.state = settings.appSettings.launchAtLogin ? .on : .off
        menu.addItem(loginItem)

        let updateItem = NSMenuItem(
            title: "Check for Updates…",
            action: #selector(checkForUpdatesFromStatusItem),
            keyEquivalent: ""
        )
        updateItem.target = self
        updateItem.isEnabled = appSupport.canCheckForPublishedUpdates
        menu.addItem(updateItem)

        let reportItem = NSMenuItem(
            title: "Report a Problem…",
            action: #selector(reportProblemFromStatusItem),
            keyEquivalent: ""
        )
        reportItem.target = self
        menu.addItem(reportItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Quit Melo",
            action: #selector(quitFromStatusItem),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)
        return menu
    }

    @objc private func openPopupFromStatusItem() {
        popupController.toggle()
    }

    @objc private func openSettingsFromStatusItem() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: self)
    }

    @objc private func replayTutorialFromStatusItem() {
        appSupport.replayTutorial()
    }

    @objc private func toggleDockFromStatusItem() {
        appSupport.toggleDockVisibility()
    }

    @objc private func toggleLaunchAtLoginFromStatusItem() {
        var appSettings = settings.appSettings
        appSettings.launchAtLogin.toggle()
        settings.appSettings = appSettings
    }

    @objc private func checkForUpdatesFromStatusItem() {
        appSupport.checkForUpdates()
    }

    @objc private func reportProblemFromStatusItem() {
        appSupport.createDiagnosticReport()
    }

    @objc private func quitFromStatusItem() {
        NSApp.terminate(nil)
    }

    private func findStatusBarButton(in view: NSView, matching title: String) -> NSStatusBarButton? {
        if let button = view as? NSStatusBarButton, button.accessibilityTitle() == title {
            return button
        }
        for subview in view.subviews {
            if let match = findStatusBarButton(in: subview, matching: title) {
                return match
            }
        }
        return nil
    }

    private func addFadeTransition(to button: NSStatusBarButton) {
        let transition = CATransition()
        transition.type = .fade
        transition.duration = 0.18
        transition.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        button.layer?.add(transition, forKey: "iconFade")
    }
}
