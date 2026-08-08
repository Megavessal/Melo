// Melo/Views/MenuBar/MenuBarIconCoordinator.swift
// Owns NSStatusBarButton.image mutation. FluidMenuBarExtra sets the image
// once at init and never touches it again, so we locate the button by
// walking NSApp.windows for the NSStatusBarButton whose accessibilityTitle
// was set to "Melo" by the library, and crossfade images directly.

@preconcurrency import AppKit
import AudioToolbox
import Combine
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
    private let logger = Logger(subsystem: "io.github.megavessal.Melo", category: "MenuBarIconCoordinator")

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
    private var cancellables: Set<AnyCancellable> = []

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
        schedulePendingUpdateTracking()
        syncLevelTimer()
        syncMotionTimer()
    }

    /// `SparkleUpdateController` is an `ObservableObject` rather than
    /// `@Observable`, so it is outside `withObservationTracking`. Delivering on
    /// the main run loop rather than reacting inline matters: `@Published`
    /// fires in `willSet`, and `apply()` has to read the committed value or the
    /// badge lags one update behind.
    private func schedulePendingUpdateTracking() {
        appSupport.updates.$updateReminder
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.apply() }
            }
            .store(in: &cancellables)
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
        cancellables.removeAll()
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
        let waiting = appSupport.updates.updateReminder
        guard var image = state.image.nsImage(
            accessibilityDescription: waiting.map { "Melo — \($0.displayName) is available" } ?? "Melo",
            motionOffsetCells: motion.offsetCells
        ) else { return }
        if waiting != nil {
            image = Self.badged(image)
        }
        addFadeTransition(to: button)
        button.image = image
        let title = menuBarInfoTitle()
        button.title = title
        button.imagePosition = title.isEmpty ? .imageOnly : .imageLeading
        button.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        let base = title.isEmpty ? "Melo" : "Melo — \(title)"
        button.toolTip = waiting.map { "\(base)\n\($0.displayName) is available" } ?? base
    }

    /// Marks the icon the user already chose, rather than adding one they did
    /// not. A menu bar extra is a template image, so a coloured dot is not
    /// available: the badge has to read as a *shape*. It is drawn as a filled
    /// dot inside a punched-out ring, so it stays a separate mark against the
    /// artwork underneath instead of merging into it, and it stays inside the
    /// existing 22×18 canvas so the item's width — and every neighbour's
    /// position — does not move when an update arrives.
    ///
    /// **The two constants below are load-bearing and were measured, not
    /// chosen.** At the previous `diameter: 6, gap: 1.5` the punched ring had a
    /// 4.5pt radius centred at (17.5, 13.5), which swallowed the pixel mark's
    /// entire right-hand peak — rows 1–4, columns 12–15 of `pixelMarkRows` —
    /// plus five cells of its baseline bar, and cut the outer arc off
    /// `speaker.wave.3.fill`. The badge did not sit beside the glyph, it
    /// replaced a third of it, and the result read as a blob with a crumb
    /// beside it rather than as Melo's mark wearing a badge.
    ///
    /// At `diameter: 4, gap: 0.75` the cleared disc has a 2.75pt radius centred
    /// at (19.25, 15.25). The pixel mark is empty above row 4 and right of
    /// column 15, so that disc lands entirely in the void and removes **no**
    /// cell of the mark at 1x or 2x; on the SF Symbol styles it takes only the
    /// tip of the outermost wave, which stays three waves. Anything larger
    /// starts eating artwork again, so do not grow these without rendering the
    /// `menubar-icon-after` frame and counting cells.
    ///
    /// Rejected, both on rendered evidence rather than taste:
    /// - **`arrow.down.circle.fill` at badge size** — the macOS vocabulary for
    ///   "an update is available", and the glyph `PendingUpdateBanner` already
    ///   uses for this exact fact. Rasterized at 22×18pt it is a grey donut at
    ///   1x *and* 2x: the stem and head are below one device pixel. To resolve
    ///   at all it needs ~8pt, which destroys the mark outright.
    /// - **A square on the mark's own 1pt pixel grid** — equally harmless to
    ///   the pixel mark and more consistent with it, but this one function
    ///   badges all five icon styles and three of them are SF Symbols, beside
    ///   which a hard square reads as a rendering artefact rather than a mark.
    ///
    /// A monochrome dot cannot, by itself, say "update". Nothing available to a
    /// template image can: Apple's own convention for this is a red numeric
    /// Dock badge, and a menu bar extra has neither colour nor room for a
    /// numeral. What carries the meaning is what the dot is attached to — the
    /// `accessibilityDescription` and tooltip below both name the waiting
    /// version, and the first item of the menu it opens is that version. The
    /// dot's job is the same as an unread dot in a Mail sidebar: *something
    /// here is new*, with the surface it opens saying what.
    private static func badged(_ base: NSImage) -> NSImage {
        let size = MenuBarIconImage.canvasSize
        let diameter: CGFloat = 4
        let gap: CGFloat = 0.75
        // Inset by the gap as well as the radius, so the punched ring's outer
        // edge lands on the canvas edge rather than past it — a clipped ring
        // would leave the dot fused to the artwork on two sides.
        let center = NSPoint(
            x: size.width - diameter / 2 - gap,
            y: size.height - diameter / 2 - gap
        )
        let badged = NSImage(size: size, flipped: false) { _ in
            base.draw(in: NSRect(origin: .zero, size: size))
            let ring = NSRect(
                x: center.x - diameter / 2 - gap,
                y: center.y - diameter / 2 - gap,
                width: diameter + gap * 2,
                height: diameter + gap * 2
            )
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(ovalIn: ring).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            NSColor.black.setFill()
            NSBezierPath(ovalIn: NSRect(
                x: center.x - diameter / 2,
                y: center.y - diameter / 2,
                width: diameter,
                height: diameter
            )).fill()
            return true
        }
        badged.isTemplate = true
        badged.accessibilityDescription = base.accessibilityDescription
        return badged
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

        // A waiting update goes at the top of the menu the badge is attached
        // to, so the badge is explicable from the thing it is drawn on. Melo
        // used to answer this with a second status item of its own, which the
        // HIG forbids twice over: the user decides what is in their menu bar,
        // and an app must not depend on an extra being visible, because the
        // system hides them when the bar is crowded.
        if let waiting = appSupport.updates.updateReminder {
            let header = NSMenuItem(
                title: "\(waiting.displayName) is available",
                action: nil,
                keyEquivalent: ""
            )
            header.isEnabled = false
            menu.addItem(header)

            let install = NSMenuItem(
                title: "Update Now",
                action: #selector(installUpdateFromStatusItem),
                keyEquivalent: ""
            )
            install.target = self
            menu.addItem(install)

            if waiting.notesURL != nil {
                let notes = NSMenuItem(
                    title: "What’s New…",
                    action: #selector(openUpdateNotesFromStatusItem),
                    keyEquivalent: ""
                )
                notes.target = self
                menu.addItem(notes)
            }

            // Deferring has to be as easy as refusing, or the permanent answer
            // becomes the one people click to get quiet.
            let later = NSMenuItem(
                title: "Remind Me Later",
                action: #selector(remindLaterFromStatusItem),
                keyEquivalent: ""
            )
            later.target = self
            menu.addItem(later)

            // "Skip This Version", worded exactly as Settings → Updates words
            // it. This said "Skip Melo 2.9.5" — the same act under two names in
            // one app, which is the rule PendingUpdateBanner already follows
            // for Remind Me Later. The version is named by the item directly
            // above this one, so nothing is lost by dropping it here.
            let skip = NSMenuItem(
                title: "Skip This Version",
                action: #selector(skipUpdateFromStatusItem),
                keyEquivalent: ""
            )
            skip.target = self
            menu.addItem(skip)

            menu.addItem(.separator())
        }

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

    @objc private func installUpdateFromStatusItem() {
        appSupport.updates.installPendingUpdate()
    }

    @objc private func openUpdateNotesFromStatusItem() {
        appSupport.updates.openPendingReleaseNotes()
    }

    @objc private func remindLaterFromStatusItem() {
        appSupport.updates.remindLater()
    }

    @objc private func skipUpdateFromStatusItem() {
        appSupport.updates.skipPendingUpdate()
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
