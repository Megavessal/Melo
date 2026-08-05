// Melo/Views/MenuBarPopupView.swift
import AudioToolbox
import SwiftUI
import UniformTypeIdentifiers

struct MenuBarPopupView: View {
    @Bindable var audioEngine: AudioEngine
    @Bindable var deviceVolumeMonitor: DeviceVolumeMonitor
    @ObservedObject var sparkleUpdateController: SparkleUpdateController

    let permission: AudioRecordingPermission

    /// Accessibility trust state — forwarded to the Settings window for the
    /// media-keys section. Bindable so live re-renders occur when trust flips.
    @Bindable var accessibility: AccessibilityPermissionService

    /// Transient status (offline, suppressionDegraded) for the media-keys banner.
    @Bindable var mediaKeyStatus: MediaKeyStatus

    /// Shared popup visibility flag — mirrored to this service so `MediaKeyMonitor`
    /// can skip HUD display while the popup is the "HUD".
    @Bindable var popupVisibility: PopupVisibilityService

    /// Preview HUD button hook in Settings.
    let hudController: HUDWindowController

    /// Needed so the popup can reconcile the tap state when the user toggles
    /// `mediaKeyControlEnabled` inside Settings. Trust-flip reconciliation is
    /// handled globally via `AccessibilityPermissionService.onTrustChanged`
    /// wired in `MeloApp.init`.
    let mediaKeyMonitor: MediaKeyMonitor

    @Bindable var guidedTour: GuidedTourCoordinator

    /// Memoized sorted output devices - only recomputed when device list or default changes
    @State private var sortedDevices: [AudioDevice] = []

    /// Memoized sorted input devices
    @State private var sortedInputDevices: [AudioDevice] = []

    /// Which device tab is selected (false = output, true = input)
    @State private var showingInputDevices = false

    /// Output/input tabs and their device rows collapse as one unit from the header.
    @State private var areDevicesExpanded = true

    /// Expands the compact list of hidden apps beneath the Apps section.
    @State private var areHiddenAppsExpanded = false

    /// Active apps always remain visible. Open-but-quiet and pinned apps live
    /// behind the Apps disclosure so the mixer stays focused on sound that is
    /// actually playing.
    @State private var areInactiveAppsExpanded = false

    /// Stable identifiers retained in the live lane for the user's chosen grace
    /// period after Core Audio reports silence. This changes section placement only;
    /// it never extends process-tap lifetime or audio access.
    @State private var recentlyActiveAppIDs: Set<String> = []
    @State private var lastActiveAppIDs: Set<String> = []
    @State private var inactiveMoveTasks: [String: Task<Void, Never>] = [:]

    /// Track which app has its EQ panel expanded (only one at a time)
    /// Uses DisplayableApp.id (String) to work with both active and inactive apps
    @State private var expandedRowID: String?

    /// Debounce EQ toggle to prevent rapid clicks during animation
    @State private var isEQAnimating = false

    /// Track popup visibility to pause VU meter polling when hidden
    @State private var isPopupVisible = true

    /// Error message shown when AutoEQ profile import fails
    @State private var autoEQImportError: String?
    /// Task that auto-clears the import error after 3 seconds
    @State private var importErrorClearTask: Task<Void, Never>?

    /// Memoized paired Bluetooth devices
    @State private var pairedDevices: [PairedBluetoothDevice] = []

    /// Whether Bluetooth hardware is powered on
    @State private var isBluetoothOn = false

    /// Whether edit mode is active (affects both device priority and app visibility)
    @State private var isEditingDevicePriority = false

    /// Tracks which tab was active when edit mode started (for correct save on exit)
    @State private var wasEditingInputDevices = false

    /// Editable copy of device order for drag-and-drop reordering
    @State private var editableDeviceOrder: [AudioDevice] = []

    /// Device whose inline detail panel is expanded in edit mode (nil when
    /// collapsed). Mirrors the `expandedRowID` pattern used for per-app EQ.
    @State private var expandedDeviceUID: String?

    /// Namespace for device toggle animation
    @Namespace private var deviceToggleNamespace

    /// Carries an app row between the live lane and quiet-app tray.
    @Namespace private var appActivityNamespace

    @State private var navModel = PopupKeyboardNavModel()
    /// Logical keyboard-nav selection. Plain @State (not @FocusState) so reads
    /// and writes are synchronous within a single event handler — using
    /// @FocusState here raced with SwiftUI's auto-focus-on-key-window claim
    /// (WWDC23 "SwiftUI cookbook for focus" calls this anti-pattern). A single
    /// focusable anchor on the popup body root receives key events; rows
    /// render their selection state purely from this @State value.
    @State private var selectedRow: PopupKeyboardNavModel.RowID? = nil
    /// True once the user presses any nav-vocabulary key. Gates the row-highlight
    /// visual so a fresh popup opens clean even though `selectedRow` may be set.
    @State private var hasKeyboardEngaged: Bool = false
    /// Mouse-selected app target for contextual four-arrow volume control.
    @State private var lastTouchedAppID: String?
    /// `.onKeyPress` only fires when the modifier-owning view (or a focused
    /// descendant) has focus, so the body root holds a focus anchor.
    @FocusState private var anchorFocused: Bool
    /// Owns keyboard percentage entry (buffer + commit/restore signals), broadcast to
    /// rows via the environment. First responder stays on the nav anchor throughout.
    @State private var textEntry = PopupTextEntryCoordinator()
    @State private var showCommandPalette = false

    @Environment(\.openSettings) private var openSettings

    // MARK: - Resolved Dimensions

    private var popupDimensions: PopupDimensions {
        audioEngine.settingsManager.appSettings.popupSize.dimensions
    }

    private var visualTheme: MeloVisualTheme {
        audioEngine.settingsManager.appSettings.visualTheme
    }

    private var themeAccent: Color {
        visualTheme.accentColor(
            customHex: audioEngine.settingsManager.appSettings.customAccentHex,
            generatedTheme: audioEngine.settingsManager.appSettings.generatedTheme
        )
    }

    var body: some View {
        popupKeyboardLayer
    }

    // MARK: - Popup composition
    //
    // The popup is intentionally divided into several opaque view layers.
    // Keeping the complete UI, lifecycle observers, window notifications, and
    // keyboard modifiers in one generic expression caused Swift 6 release
    // builds to exceed the type checker's complexity limit.

    private var popupContentLayer: some View {
        ZStack {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                floatingHeader

                ScrollViewReader { proxy in
                    ScrollView {
                        mainContent(scrollProxy: proxy)
                    }
                    .scrollIndicators(.never)
                    .frame(maxHeight: popupDimensions.maxContentHeight)
                    .onChange(of: selectedRow) { _, newFocus in
                        guard let newFocus else { return }
                        withAnimation(DesignTokens.Animation.scrollToRow) {
                            proxy.scrollTo(newFocus, anchor: .center)
                        }
                    }
                }
            }
            .opacity(showCommandPalette ? 0 : 1)
            .allowsHitTesting(!showCommandPalette)

            if showCommandPalette {
                ConsumerCommandPalette(
                    audioEngine: audioEngine,
                    sparkleUpdateController: sparkleUpdateController,
                    onOpenSettings: openSettingsWindow,
                    onClose: closeCommandPalette
                )
                .frame(height: popupDimensions.maxContentHeight + 48)
                .clipShape(DesignTokens.Dimensions.Shape.lg)
                .transition(.opacity.combined(with: .scale(scale: 0.985)))
            }
        }
    }

    private var popupAppearanceLayer: some View {
        popupContentLayer
            // Re-enables focus effects inside the popup. The keyboard layer
            // disables them so the invisible full-popup focus anchor doesn't
            // draw a ring around the entire window; without this override that
            // one call also erased the focus ring from every control inside,
            // so Full Keyboard Access could move focus but never show it.
            .focusEffectDisabled(false)
            .padding(popupDimensions.contentPadding)
            .frame(width: popupDimensions.width)
            .background(
                WindowAppearanceBridge(appearance: resolvedPopupAppearance)
                    .frame(width: 0, height: 0)
            )
            .meloThemeBackground(
                theme: visualTheme,
                customAccentHex: audioEngine.settingsManager.appSettings.customAccentHex,
                generatedTheme: audioEngine.settingsManager.appSettings.generatedTheme,
                // Star fields and the rocket ran their timelines whether or not the
                // popup was on screen, so a closed menu-bar app kept animating.
                isVisible: isPopupVisible
            )
            .tint(themeAccent)
            .overlayPreferenceValue(GuidedTourTargetPreferenceKey.self) { anchors in
                GeometryReader { geometry in
                    if guidedTour.isActive && !showCommandPalette {
                        GuidedTourOverlay(
                            coordinator: guidedTour,
                            anchors: anchors,
                            geometry: geometry
                        )
                    }
                }
            }
            .preferredColorScheme(resolvedPopupColorScheme)
            .environment(
                \.appearancePreference,
                audioEngine.settingsManager.appSettings.appearance
            )
    }

    private var popupDeviceObservationLayer: some View {
        popupAppearanceLayer
            .onAppear(perform: handlePopupAppear)
            .onChange(of: audioEngine.outputDevices) { _, _ in
                handleOutputDevicesChanged()
            }
            .onChange(of: audioEngine.inputDevices) { _, _ in
                handleInputDevicesChanged()
            }
            .onChange(of: showingInputDevices) { _, _ in
                handleShowingInputDevicesChanged()
            }
            .onChange(of: areDevicesExpanded) { _, _ in
                syncNavOrder()
            }
    }

    private var popupApplicationObservationLayer: some View {
        popupDeviceObservationLayer
            .onChange(of: audioEngine.apps) { _, newApps in
                updateAppActivityPresentation(newApps)
                syncNavOrder()
            }
            .onChange(of: audioEngine.settingsManager.appSettings.quietMoveDelay) { _, _ in
                rescheduleQuietAppMoves()
                syncNavOrder()
            }
            .onChange(of: guidedTour.step) { _, newStep in
                prepareGuidedTour(for: newStep)
            }
            .onChange(of: guidedTour.isActive) { _, active in
                handleGuidedTourActivityChanged(active)
            }
            .onChange(of: areInactiveAppsExpanded) { _, _ in
                syncNavOrder()
            }
            .onChange(of: isEditingDevicePriority) { _, editing in
                handlePriorityEditingChanged(editing)
            }
    }

    private var popupPeripheralObservationLayer: some View {
        popupApplicationObservationLayer
            .onChange(of: audioEngine.bluetoothDeviceMonitor.pairedDevices) { _, newValue in
                pairedDevices = newValue
            }
            .onChange(of: audioEngine.bluetoothDeviceMonitor.isBluetoothOn) { _, newValue in
                isBluetoothOn = newValue
            }
            .onChange(of: deviceVolumeMonitor.defaultDeviceID) { _, _ in
                updateSortedDevices()
            }
    }

    private var popupWindowObservationLayer: some View {
        popupPeripheralObservationLayer
            .onReceive(
                NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification),
                perform: handlePopupWindowBecameKey
            )
            .onReceive(
                NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification),
                perform: handlePopupWindowResignedKey
            )
            .onReceive(
                NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)
            ) { _ in
                // SwiftUI Menu tracking can make the popup resign key without
                // deactivating the process. App-level deactivation is the reliable
                // point at which to leave device-priority edit mode.
                exitEditModeSaving()
            }
    }

    private var popupKeyboardLayer: some View {
        popupWindowObservationLayer
            .focusable()
            // Scoped to the anchor itself; `popupAppearanceLayer` turns focus
            // effects back on for the actual controls.
            .focusEffectDisabled()
            .focused($anchorFocused)
            .onKeyPress(phases: [.down, .repeat], action: processPopupKeyPress)
            .environment(textEntry)
            .onChange(of: textEntry.navRestoreNonce) { _, _ in
                anchorFocused = true
            }
            .background {
                Button("", action: handleEscape)
                    .keyboardShortcut(.escape, modifiers: [])
                    .hidden()
            }
    }

    private var resolvedPopupAppearance: NSAppearance? {
        if visualTheme.prefersDarkAppearance {
            return visualTheme.resolvedNSAppearance
        }
        return audioEngine.settingsManager.appSettings.appearance.nsAppearance
    }

    private var resolvedPopupColorScheme: ColorScheme? {
        visualTheme.resolvedColorScheme(
            appearance: audioEngine.settingsManager.appSettings.appearance
        )
    }

    private func closeCommandPalette() {
        withAnimation(DesignTokens.Animation.panel) {
            showCommandPalette = false
        }
    }

    private func handlePopupAppear() {
        updateSortedDevices()
        updateSortedInputDevices()
        pairedDevices = audioEngine.bluetoothDeviceMonitor.pairedDevices
        isBluetoothOn = audioEngine.bluetoothDeviceMonitor.isBluetoothOn

        let identifiers: [String] = audioEngine.apps.map { app in
            app.persistenceIdentifier
        }
        lastActiveAppIDs = Set(identifiers)

        // popupVisibility.isVisible is driven by the filtered NSWindow key
        // notifications below, not by .onAppear. SwiftUI mounts this view before
        // the popup is actually shown.
    }

    private func handleOutputDevicesChanged() {
        if isEditingDevicePriority && !wasEditingInputDevices {
            mergeDeviceChanges(from: audioEngine.outputDevices)
        }
        updateSortedDevices()
        syncNavOrder()
    }

    private func handleInputDevicesChanged() {
        if isEditingDevicePriority && wasEditingInputDevices {
            mergeDeviceChanges(from: audioEngine.inputDevices)
        }
        updateSortedInputDevices()
        syncNavOrder()
    }

    private func handleShowingInputDevicesChanged() {
        exitEditModeSaving()
        syncNavOrder()
        if hasKeyboardEngaged {
            selectedRow = navModel.defaultFocus(
                defaultOutputUID: currentDefaultDeviceUID()
            )
        }
    }

    private func handleGuidedTourActivityChanged(_ active: Bool) {
        if active {
            prepareGuidedTour(for: guidedTour.step)
        } else {
            expandedRowID = nil
        }
    }

    private func handlePriorityEditingChanged(_ editing: Bool) {
        if editing {
            selectedRow = nil
            hasKeyboardEngaged = false
        }
        syncNavOrder()
    }

    private func handlePopupWindowBecameKey(_ notification: Notification) {
        guard let window = fluidMenuBarWindow(from: notification) else { return }

        MenuBarPopupPositioner.anchor(window: window, statusItemTitle: "Melo")
        isPopupVisible = true
        popupVisibility.isVisible = true
        audioEngine.bluetoothDeviceMonitor.refresh()
        syncNavOrder()
        hasKeyboardEngaged = false
        selectedRow = nil
        anchorFocused = true
        textEntry.buffer = nil
    }

    private func handlePopupWindowResignedKey(_ notification: Notification) {
        guard fluidMenuBarWindow(from: notification) != nil else { return }

        isPopupVisible = false
        popupVisibility.isVisible = false
        hasKeyboardEngaged = false
        selectedRow = nil
    }

    private func fluidMenuBarWindow(from notification: Notification) -> NSWindow? {
        guard let window = notification.object as? NSWindow else { return nil }
        let typeName = String(describing: type(of: window))
        return typeName.contains("FluidMenuBarExtra") ? window : nil
    }

    // MARK: - Edit Priority Button

    /// The header is intentionally its own elevated glass island. It keeps the
    /// active listening context and primary navigation visible without wrapping
    /// every mixer row in a heavy material card.
    private var floatingHeader: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            HStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [themeAccent, themeAccent.opacity(0.55)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    Image(nsImage: MenuBarIconImage.meloMark.nsImage() ?? NSImage())
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 20, height: 14)
                        .foregroundStyle(.white)
                }
                .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: 0) {
                    Text("Melo")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                    HStack(spacing: 4) {
                        Circle()
                            .fill(audioStatusColor)
                            .frame(width: 5, height: 5)
                        Text(audioStatusText)
                            .font(DesignTokens.Typography.Scale.caption2(.medium))
                            .foregroundStyle(DesignTokens.Colors.textTertiary)
                    }
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Melo, \(audioStatusText)")

            Button {
                if areDevicesExpanded && isEditingDevicePriority {
                    exitEditModeSaving()
                }
                withAnimation(DesignTokens.Animation.rowChange) {
                    areDevicesExpanded.toggle()
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.down")
                        .font(DesignTokens.Typography.Scale.caption2(.bold))
                        .rotationEffect(.degrees(areDevicesExpanded ? 0 : -90))
                    Text("Audio")
                        .font(DesignTokens.Typography.Scale.caption(.semibold))
                }
                .padding(.horizontal, 6)
                .frame(minHeight: DesignTokens.Dimensions.minTouchTarget)
                .contentShape(Rectangle())
            }
            .buttonStyle(.meloHover)
            .foregroundStyle(DesignTokens.Colors.interactiveDefault)
            .help(areDevicesExpanded ? "Hide audio devices" : "Show audio devices")
            .accessibilityLabel(areDevicesExpanded ? "Hide audio devices" : "Show audio devices")

            if areDevicesExpanded {
                deviceTabsHeader
            }

            if isEditingDevicePriority {
                Spacer(minLength: 4)
                Text("Set device priority")
                    .font(DesignTokens.Typography.Scale.caption(.medium))
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
            }

            Spacer(minLength: 4)
            commandPaletteButton
            editPriorityButton
            settingsButton
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .meloGlassSurface(cornerRadius: 16, tint: themeAccent.opacity(0.14))
        .padding(.bottom, DesignTokens.Spacing.xs)
    }

    private var audioStatusText: String {
        switch permission.status {
        case .authorized: return "Audio active"
        case .unknown: return "Ready for audio"
        case .denied: return "Access needed"
        case .unavailable: return "Audio unavailable"
        }
    }

    private var audioStatusColor: Color {
        switch permission.status {
        case .authorized: return .green
        case .unknown: return .cyan
        case .denied, .unavailable: return .orange
        }
    }

    // MARK: - Header Actions

    private var commandPaletteButton: some View {
        Button("Find an action", systemImage: "magnifyingglass") {
            exitEditModeSaving()
            showCommandPalette = true
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.meloHover)
        .font(DesignTokens.Typography.Scale.body(.regular))
        .symbolRenderingMode(.hierarchical)
        .foregroundStyle(DesignTokens.Colors.interactiveDefault)
        .frame(
            minWidth: DesignTokens.Dimensions.minTouchTarget,
            minHeight: DesignTokens.Dimensions.minTouchTarget
        )
        .keyboardShortcut("k", modifiers: [.command])
        .contentShape(Rectangle())
        .help("Find an action (⌘K)")
        .guidedTourTarget(.search)
    }

    private var editPriorityButton: some View {
        Button(isEditingDevicePriority ? "Done reordering" : "Reorder devices",
               systemImage: isEditingDevicePriority ? "checkmark" : "pencil") {
            if !areDevicesExpanded {
                areDevicesExpanded = true
            }
            toggleDevicePriorityEdit()
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.meloHover)
        .font(DesignTokens.Typography.Scale.body(isEditingDevicePriority ? .bold : .regular))
        .symbolRenderingMode(.hierarchical)
        .foregroundStyle(DesignTokens.Colors.interactiveDefault)
        .frame(
            minWidth: DesignTokens.Dimensions.minTouchTarget,
            minHeight: DesignTokens.Dimensions.minTouchTarget
        )
        .contentShape(Rectangle())
        .animation(DesignTokens.Animation.panel, value: isEditingDevicePriority)
        .help(isEditingDevicePriority ? "Done reordering" : "Reorder devices")
    }

    private var settingsButton: some View {
        Button("Settings", systemImage: "gearshape.fill") {
            openSettingsWindow()
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.meloHover)
        .font(DesignTokens.Typography.Scale.body(.regular))
        .symbolRenderingMode(.hierarchical)
        .foregroundStyle(DesignTokens.Colors.interactiveDefault)
        .frame(
            minWidth: DesignTokens.Dimensions.minTouchTarget,
            minHeight: DesignTokens.Dimensions.minTouchTarget
        )
        .contentShape(Rectangle())
        .help("Settings")
        .guidedTourTarget(.settings)
    }

    /// Handles Escape key: closes EQ first, then dismisses the popup.
    /// Escape order: expanded device detail → edit mode → expanded app EQ →
    /// popup dismiss. Expanded device detail is checked before
    /// `isEditingDevicePriority` so Escape collapses the row first rather than
    /// tearing down edit mode entirely.
    private func handleEscape() {
        if showCommandPalette {
            withAnimation(DesignTokens.Animation.panel) {
                showCommandPalette = false
            }
            return
        }
        // The hidden Escape keyboardShortcut button can win over `.onKeyPress`, so an
        // in-progress keyboard entry is cancelled here too.
        if textEntry.buffer != nil {
            textEntry.buffer = nil
            return
        }
        if expandedDeviceUID != nil {
            withAnimation(DesignTokens.Animation.panel) {
                expandedDeviceUID = nil
            }
        } else if isEditingDevicePriority {
            toggleDevicePriorityEdit()
        } else if expandedRowID != nil {
            // Collapse any expanded app EQ panel
            withAnimation(DesignTokens.Animation.panel) {
                expandedRowID = nil
            }
        } else {
            NSApp.keyWindow?.resignKey()
        }
    }

    private func openSettingsWindow() {
        exitEditModeSaving()
        NSApp.keyWindow?.resignKey()
        NSApp.activate(ignoringOtherApps: true)
        openSettings()
    }

    private var quickScenesSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Label("Scenes", systemImage: "square.stack.3d.up.fill")
                    .font(DesignTokens.Typography.Scale.caption(.semibold))
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
                Spacer()
                if audioEngine.consumerUndoManager.canUndo {
                    Button("Undo", systemImage: "arrow.uturn.backward") {
                        audioEngine.undoLastConsumerChange()
                    }
                    .buttonStyle(.meloHover)
                    .font(DesignTokens.Typography.Scale.caption(.medium))
                    .help(audioEngine.consumerUndoManager.latest?.label ?? "Undo last change")
                }
            }

            ScrollView(.horizontal) {
                HStack(spacing: 7) {
                    ForEach(audioEngine.settingsManager.consumerScenes) { scene in
                        Button {
                            audioEngine.applyConsumerScene(scene)
                        } label: {
                            Label(scene.name, systemImage: scene.symbolName)
                                .font(DesignTokens.Typography.Scale.caption(.medium))
                                .padding(.horizontal, 9)
                                .padding(.vertical, 6)
                                .background(
                                    Capsule()
                                        .fill(themeAccent.opacity(0.13))
                                )
                                .overlay(
                                    Capsule()
                                        .strokeBorder(themeAccent.opacity(0.22), lineWidth: 0.5)
                                )
                        }
                        .buttonStyle(.plain)
                        .help("Use \(scene.name)")
                    }
                }
            }
            .scrollIndicators(.never)
        }
    }

    // MARK: - Main Content

    @ViewBuilder
    private func mainContent(scrollProxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            if areDevicesExpanded {
                // Output/input controls and rows collapse together.
                devicesSection
                    .guidedTourTarget(.devices)

                Divider()
                    .padding(.vertical, DesignTokens.Spacing.xs)
            }

            if !audioEngine.settingsManager.consumerScenes.isEmpty {
                quickScenesSection

                Divider()
                    .padding(.vertical, DesignTokens.Spacing.xs)
            }

            // Apps section (active + pinned inactive + hidden in edit mode)
            appsSection(scrollProxy: scrollProxy)
                .guidedTourTarget(.apps)

            Divider()
                .padding(.vertical, DesignTokens.Spacing.xs)

            // Footer
            HStack {
                Spacer()

                Button {
                    NSApplication.shared.terminate(nil)
                } label: {
                    HStack(spacing: 6) {
                        Text("Quit")
                        Text("⌘Q")
                            .foregroundStyle(DesignTokens.Colors.textTertiary)
                    }
                }
                .buttonStyle(.meloHover)
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.Colors.textSecondary)
                .glassButtonStyle()
                .accessibilityLabel("Quit Melo")
                .help("Quit Melo (⌘Q)")
            }
        }
    }

    // MARK: - Device Toggle

    /// Icon-only pill toggle for switching between Output and Input devices
    private var deviceTabsHeader: some View {
        let iconSize: CGFloat = 13
        let buttonSize: CGFloat = 26

        return HStack(spacing: 2) {
            // Output (speaker) button
            Button {
                withAnimation(DesignTokens.Animation.panel) {
                    showingInputDevices = false
                }
            } label: {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: iconSize, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(showingInputDevices ? DesignTokens.Colors.textTertiary : DesignTokens.Colors.textPrimary)
                    .frame(width: buttonSize, height: buttonSize)
                    .background {
                        if !showingInputDevices {
                            DesignTokens.Dimensions.Shape.sm
                                .fill(DesignTokens.Colors.glassFillStrong)
                                .matchedGeometryEffect(id: "deviceToggle", in: deviceToggleNamespace)
                        }
                    }
                    .contentShape(Rectangle())
            }
            .buttonStyle(.meloHover)
            .help("Output Devices")

            // Input (mic) button
            Button {
                withAnimation(DesignTokens.Animation.panel) {
                    showingInputDevices = true
                }
            } label: {
                Image(systemName: "mic.fill")
                    .font(.system(size: iconSize, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(showingInputDevices ? DesignTokens.Colors.textPrimary : DesignTokens.Colors.textTertiary)
                    .frame(width: buttonSize, height: buttonSize)
                    .background {
                        if showingInputDevices {
                            DesignTokens.Dimensions.Shape.sm
                                .fill(DesignTokens.Colors.glassFillStrong)
                                .matchedGeometryEffect(id: "deviceToggle", in: deviceToggleNamespace)
                        }
                    }
                    .contentShape(Rectangle())
            }
            .buttonStyle(.meloHover)
            .help("Input Devices")
        }
        .padding(3)
        .background(
            DesignTokens.Dimensions.Shape.custom(DesignTokens.Dimensions.buttonRadius + 3)
                .fill(DesignTokens.Colors.glassFill)
                .overlay(
                    DesignTokens.Dimensions.Shape.custom(DesignTokens.Dimensions.buttonRadius + 3)
                        .strokeBorder(DesignTokens.Colors.glassRowBorder, lineWidth: 0.5)
                )
        )
    }

    // MARK: - Subviews

    @ViewBuilder
    private var devicesSection: some View {
        devicesContent
    }

    private var devicesContent: some View {
        VStack(spacing: 0) {
            if isEditingDevicePriority {
                // Edit mode: drag-and-drop reordering (works for both output and input)
                let defaultDeviceID = showingInputDevices
                    ? deviceVolumeMonitor.defaultInputDeviceID
                    : deviceVolumeMonitor.defaultDeviceID
                ForEach(Array(editableDeviceOrder.enumerated()), id: \.element.uid) { index, device in
                    editableDeviceRow(device: device, index: index, defaultDeviceID: defaultDeviceID)
                }

                // Paired Bluetooth devices (output tab only)
                if !showingInputDevices {
                    if !isBluetoothOn {
                        Text("Turn on Bluetooth to connect devices")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.top, DesignTokens.Spacing.xs)
                    } else {
                        // Filter out any device already in the output list (handles
                        // IOBluetooth/CoreAudio timing desync where both report the device).
                        let connectedNames = Set(editableDeviceOrder.map(\.name))
                        let filteredPaired = pairedDevices.filter { !connectedNames.contains($0.name) }
                        if !filteredPaired.isEmpty {
                            SectionHeader(title: "Paired")
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.top, DesignTokens.Spacing.xs)

                            ForEach(filteredPaired) { device in
                                PairedDeviceRow(
                                    device: device,
                                    isConnecting: audioEngine.bluetoothDeviceMonitor.connectingIDs.contains(device.id),
                                    errorMessage: audioEngine.bluetoothDeviceMonitor.connectionErrors[device.id],
                                    onConnect: {
                                        audioEngine.bluetoothDeviceMonitor.connect(device: device)
                                    }
                                )
                            }
                        }
                    }
                }
            } else if showingInputDevices {
                ForEach(sortedInputDevices) { device in
                    InputDeviceRow(
                        device: device,
                        isDefault: device.id == deviceVolumeMonitor.defaultInputDeviceID,
                        volume: deviceVolumeMonitor.inputVolumes[device.id] ?? 1.0,
                        isMuted: deviceVolumeMonitor.inputMuteStates[device.id] ?? false,
                        onSetDefault: {
                            audioEngine.setLockedInputDevice(device)
                        },
                        onVolumeChange: { volume in
                            deviceVolumeMonitor.setInputVolume(for: device.id, to: volume)
                        },
                        onMuteToggle: {
                            let currentMute = deviceVolumeMonitor.inputMuteStates[device.id] ?? false
                            deviceVolumeMonitor.setInputMute(for: device.id, to: !currentMute)
                        },
                        isFocused: hasKeyboardEngaged && selectedRow == .device(uid: device.uid),
                        iconOverrideSymbol: audioEngine.settingsManager.getDeviceIconOverride(for: device.uid)
                    )
                    .id(PopupKeyboardNavModel.RowID.device(uid: device.uid))
                }
            } else {
                ForEach(sortedDevices) { device in
                    let selection = audioEngine.getAutoEQSelection(for: device.uid)
                    let profileName: String? = {
                        guard let sel = selection else { return nil }
                        return audioEngine.autoEQProfileManager.profile(for: sel.profileID)?.name
                            ?? audioEngine.autoEQProfileManager.catalogEntry(for: sel.profileID)?.name
                    }()

                    DeviceRow(
                        device: device,
                        isDefault: device.id == deviceVolumeMonitor.defaultDeviceID,
                        volume: deviceVolumeMonitor.volumes[device.id] ?? 1.0,
                        isMuted: deviceVolumeMonitor.muteStates[device.id] ?? false,
                        volumeBackend: audioEngine.outputVolumeBackend(for: device.id),
                        onSetDefault: {
                            audioEngine.setDefaultOutputDevice(device.id)
                        },
                        onVolumeChange: { volume in
                            audioEngine.setOutputDeviceVolume(for: device.id, to: volume)
                        },
                        onMuteToggle: {
                            let currentMute = deviceVolumeMonitor.muteStates[device.id] ?? false
                            audioEngine.setOutputDeviceMute(for: device.id, to: !currentMute)
                        },
                        autoEQProfileName: profileName,
                        autoEQEnabled: selection?.isEnabled ?? false,
                        onAutoEQToggle: { enabled in
                            audioEngine.setAutoEQEnabled(for: device.uid, enabled: enabled)
                        },
                        autoEQProfileManager: audioEngine.autoEQProfileManager,
                        autoEQSelection: selection,
                        autoEQFavoriteIDs: audioEngine.settingsManager.favoriteAutoEQProfileIDs,
                        onAutoEQSelect: { profile in
                            audioEngine.setAutoEQProfile(for: device.uid, profileID: profile?.id)
                        },
                        onAutoEQImport: {
                            importAutoEQFile(for: device.uid)
                        },
                        onAutoEQToggleFavorite: { id in
                            if audioEngine.settingsManager.isAutoEQFavorite(id: id) {
                                audioEngine.settingsManager.unfavoriteAutoEQProfile(id: id)
                            } else {
                                audioEngine.settingsManager.favoriteAutoEQProfile(id: id)
                            }
                        },
                        autoEQImportError: autoEQImportError,
                        autoEQPreampEnabled: audioEngine.autoEQPreampEnabled,
                        onAutoEQPreampToggle: {
                            audioEngine.setAutoEQPreampEnabled(!audioEngine.autoEQPreampEnabled)
                        },
                        isFocused: hasKeyboardEngaged && selectedRow == .device(uid: device.uid),
                        iconOverrideSymbol: audioEngine.settingsManager.getDeviceIconOverride(for: device.uid)
                    )
                    .id(PopupKeyboardNavModel.RowID.device(uid: device.uid))
                }

            }
        }
    }

    /// Builds a single row for the priority-edit list. Extracted from
    /// `devicesContent` because the inline expression exceeded Swift's
    /// type-check budget once hide + expand + drop-destination were combined.
    @ViewBuilder
    private func editableDeviceRow(
        device: AudioDevice,
        index: Int,
        defaultDeviceID: AudioDeviceID
    ) -> some View {
        let isDeviceHidden = showingInputDevices
            ? audioEngine.settingsManager.isInputDeviceHidden(device.uid)
            : audioEngine.settingsManager.isOutputDeviceHidden(device.uid)

        DeviceEditRow(
            device: device,
            iconOverrideSymbol: audioEngine.settingsManager.getDeviceIconOverride(for: device.uid),
            priorityIndex: index,
            isDefault: device.id == defaultDeviceID,
            isInputDevice: showingInputDevices,
            deviceCount: editableDeviceOrder.count,
            isExpanded: expandedDeviceUID == device.uid,
            isHidden: isDeviceHidden,
            onReorder: { newIndex in
                guard let fromIndex = editableDeviceOrder.firstIndex(where: { $0.uid == device.uid }) else { return }
                guard newIndex != fromIndex, newIndex >= 0, newIndex < editableDeviceOrder.count else { return }
                withAnimation(DesignTokens.Animation.rowChange) {
                    editableDeviceOrder.move(
                        fromOffsets: IndexSet(integer: fromIndex),
                        toOffset: newIndex > fromIndex ? newIndex + 1 : newIndex
                    )
                }
            },
            onToggleExpand: {
                // Input devices have no per-device detail to show —
                // only output devices carry a volume-tier override.
                guard !showingInputDevices else { return }
                withAnimation(DesignTokens.Animation.panel) {
                    expandedDeviceUID = (expandedDeviceUID == device.uid) ? nil : device.uid
                }
            },
            onToggleHidden: {
                if showingInputDevices {
                    audioEngine.settingsManager.toggleInputDeviceHidden(uid: device.uid)
                } else {
                    audioEngine.settingsManager.toggleOutputDeviceHidden(uid: device.uid)
                }
            },
            onIconSelect: { symbol in
                audioEngine.settingsManager.setDeviceIconOverride(for: device.uid, to: symbol)
            },
            expandedContent: {
                // Only render when actually expanded. Input devices skip
                // the expand, so this is never hit for them.
                if !showingInputDevices && expandedDeviceUID == device.uid {
                    DeviceDetailSheet(
                        device: device,
                        transportType: device.id.readTransportType(),
                        autoDetectedTier: deviceVolumeMonitor.autoDetectedOutputVolumeBackend(for: device.id),
                        currentOverride: audioEngine.settingsManager.getDeviceVolumeTierOverride(for: device.uid),
                        onOverrideChange: { newTier in
                            audioEngine.settingsManager.setDeviceVolumeTierOverride(for: device.uid, to: newTier)
                            deviceVolumeMonitor.applyTierOverrideChange(for: device.id)
                        },
                        onDismiss: {}
                    )
                }
            }
        )
        .draggable(device.uid) {
            Text(device.name)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.ultraThinMaterial, in: DesignTokens.Dimensions.Shape.sm)
        }
        .dropDestination(for: String.self) { droppedUIDs, _ in
            guard let droppedUID = droppedUIDs.first,
                  let fromIndex = editableDeviceOrder.firstIndex(where: { $0.uid == droppedUID }),
                  let toIndex = editableDeviceOrder.firstIndex(where: { $0.uid == device.uid }),
                  fromIndex != toIndex else { return false }
            withAnimation(DesignTokens.Animation.rowChange) {
                editableDeviceOrder.move(fromOffsets: IndexSet(integer: fromIndex), toOffset: toIndex > fromIndex ? toIndex + 1 : toIndex)
            }
            return true
        }
    }

    @ViewBuilder
    private var emptyStateView: some View {
        HStack {
            Spacer()
            VStack(spacing: DesignTokens.Spacing.sm) {
                Image(systemName: "speaker.slash")
                    .font(.title)
                    .foregroundStyle(DesignTokens.Colors.textTertiary)
                Text("No user apps are open")
                    .font(.callout)
                    .foregroundStyle(DesignTokens.Colors.textSecondary)

                if !hiddenApps.isEmpty {
                    Text("Use Hidden Apps above to restore one")
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(DesignTokens.Colors.textTertiary)
                }
            }
            Spacer()
        }
        .padding(.vertical, DesignTokens.Spacing.xl)
    }

    @ViewBuilder
    private func appsSection(scrollProxy: ScrollViewProxy) -> some View {
        HStack(spacing: 4) {
            Button {
                withAnimation(DesignTokens.Animation.panel) {
                    areInactiveAppsExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    SectionHeader(title: "Apps")

                    Image(systemName: "chevron.right")
                        .font(DesignTokens.Typography.Scale.caption2(.bold))
                        .rotationEffect(.degrees(areInactiveAppsExpanded ? 90 : 0))

                    if !inactiveDisplayableApps.isEmpty {
                        Text("\(inactiveDisplayableApps.count) quiet")
                            .font(DesignTokens.Typography.Scale.caption2(.medium))
                            .foregroundStyle(DesignTokens.Colors.textTertiary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.meloHover)
            .help(areInactiveAppsExpanded ? "Hide quiet and remembered apps" : "Show quiet and remembered apps")

            Spacer()
            if !hiddenApps.isEmpty && !isEditingDevicePriority {
                Button {
                    withAnimation(DesignTokens.Animation.rowChange) {
                        areHiddenAppsExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "chevron.right")
                            .font(DesignTokens.Typography.Scale.caption2(.semibold))
                            .rotationEffect(.degrees(areHiddenAppsExpanded ? 90 : 0))
                        Text("Hidden Apps (\(hiddenApps.count))")
                    }
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.meloHover)
                .help(areHiddenAppsExpanded ? "Hide hidden apps" : "Show hidden apps")
            }
        }
        .padding(.bottom, DesignTokens.Spacing.xs)

        if !isEditingDevicePriority {
            SmartAutoEQControl(
                settings: audioEngine.settingsManager.appSettings.adaptiveAudio,
                onSettingsChange: { audioEngine.setAdaptiveAudioSettings($0) }
            )
            .guidedTourTarget(.smartAudio)
            .padding(.bottom, DesignTokens.Spacing.sm)
        }

        // Permission/setup state is informational, not a gate: open apps and
        // their remembered controls remain visible while Core Audio starts.
        if permission.status == .denied || permission.status == .unavailable {
            PermissionBannerView(permission: permission)
                .padding(.bottom, DesignTokens.Spacing.sm)
        }

        if isEditingDevicePriority {
            appEditModeContent
        } else if audioEngine.displayableApps.isEmpty {
            emptyStateView
        } else {
            if activeDisplayableApps.isEmpty {
                noActiveAudioView
            } else {
                appsContent(activeDisplayableApps, scrollProxy: scrollProxy)
            }

            if areInactiveAppsExpanded && !inactiveDisplayableApps.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "moon.zzz.fill")
                    Text("Quiet & Remembered")
                }
                .font(DesignTokens.Typography.Scale.caption2(.semibold))
                .foregroundStyle(DesignTokens.Colors.textTertiary)
                .textCase(.uppercase)
                .tracking(0.6)
                .padding(.top, DesignTokens.Spacing.sm)
                .padding(.horizontal, DesignTokens.Spacing.sm)

                appsContent(inactiveDisplayableApps, scrollProxy: scrollProxy)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }

        if !isEditingDevicePriority && areHiddenAppsExpanded && !hiddenApps.isEmpty {
            hiddenAppsContent
                .padding(.top, DesignTokens.Spacing.xs)
        }
    }

    private var guidedTourEqualizerAppID: String? {
        activeDisplayableApps.first?.id ?? inactiveDisplayableApps.first?.id
    }

    private func prepareGuidedTour(for step: GuidedTourCoordinator.Step) {
        guard guidedTour.isActive else { return }

        switch step {
        case .devices, .autoEQ:
            areDevicesExpanded = true
            expandedRowID = nil
        case .equalizer:
            guard let targetID = guidedTourEqualizerAppID else { return }
            let activeIDs = Set(activeDisplayableApps.map(\.id))
            if !activeIDs.contains(targetID) {
                areInactiveAppsExpanded = true
            }
            expandedRowID = targetID
        case .appList, .appControls, .smartAudio, .search, .settings:
            expandedRowID = nil
        }
    }

    private var activeDisplayableApps: [DisplayableApp] {
        let activeIDs = Set(audioEngine.apps.map(\.persistenceIdentifier))
        return audioEngine.displayableApps.filter {
            AppActivityPresentationPolicy.shouldStayInLiveLane(
                identifier: $0.id,
                activeIdentifiers: activeIDs,
                recentlyActiveIdentifiers: recentlyActiveAppIDs
            )
        }
    }

    private var inactiveDisplayableApps: [DisplayableApp] {
        let activeIDs = Set(activeDisplayableApps.map(\.id))
        return audioEngine.displayableApps.filter { !activeIDs.contains($0.id) }
    }

    @ViewBuilder
    private var noActiveAudioView: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Image(systemName: "waveform.slash")
                .foregroundStyle(DesignTokens.Colors.textTertiary)
            Text("No apps are playing audio")
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.Colors.textSecondary)
            Spacer()
        }
        .padding(.horizontal, DesignTokens.Spacing.sm)
        .padding(.vertical, DesignTokens.Spacing.sm)
    }

    private var hiddenApps: [IgnoredAppInfo] {
        audioEngine.settingsManager.getIgnoredAppInfo()
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    private var hiddenAppsContent: some View {
        LazyVGrid(columns: appEditColumns, spacing: DesignTokens.Spacing.xs) {
            ForEach(hiddenApps, id: \.persistenceIdentifier) { info in
                Button {
                    let wasLastHiddenApp = hiddenApps.count == 1
                    audioEngine.unignoreApp(info.persistenceIdentifier)
                    if wasLastHiddenApp {
                        areHiddenAppsExpanded = false
                    }
                } label: {
                    HStack(spacing: 7) {
                        Image(nsImage: DisplayableApp.loadIcon(bundleID: info.bundleID))
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 18, height: 18)

                        Text(info.displayName)
                            .font(DesignTokens.Typography.Scale.footnote(.medium))
                            .lineLimit(1)

                        Spacer(minLength: 4)

                        Image(systemName: "eye")
                            .font(DesignTokens.Typography.Scale.caption(.semibold))
                            .foregroundStyle(themeAccent)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(DesignTokens.Colors.glassFillStrong, in: DesignTokens.Dimensions.Shape.custom(9))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.meloHover)
                .help("Show \(info.displayName) again")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Hidden apps")
    }

    /// Edit mode content for apps: simplified rows with eye toggle + hidden section at bottom.
    private let appEditColumns = [
        GridItem(.flexible(), spacing: DesignTokens.Spacing.xs),
        GridItem(.flexible(), spacing: DesignTokens.Spacing.xs)
    ]

    @ViewBuilder
    private var appEditModeContent: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            // Visible apps in 2-column grid
            LazyVGrid(columns: appEditColumns, spacing: DesignTokens.Spacing.xs) {
                ForEach(audioEngine.displayableApps) { displayableApp in
                    switch displayableApp {
                    case .active(let app), .openInactive(let app):
                        AppEditRow(
                            icon: app.icon,
                            name: app.name,
                            isIgnored: false,
                            isPinned: audioEngine.isPinned(app),
                            onToggleVisibility: { audioEngine.ignoreApp(app) },
                            onTogglePin: {
                                if audioEngine.isPinned(app) {
                                    audioEngine.unpinApp(app.persistenceIdentifier)
                                } else {
                                    audioEngine.pinApp(app)
                                }
                            }
                        )
                    case .pinnedInactive(let info):
                        AppEditRow(
                            icon: displayableApp.icon,
                            name: info.displayName,
                            isIgnored: false,
                            isPinned: true,
                            onToggleVisibility: {
                                let hiddenInfo = IgnoredAppInfo(
                                    persistenceIdentifier: info.persistenceIdentifier,
                                    displayName: info.displayName,
                                    bundleID: info.bundleID
                                )
                                audioEngine.settingsManager.ignoreApp(info.persistenceIdentifier, info: hiddenInfo)
                            },
                            onTogglePin: {
                                audioEngine.unpinApp(info.persistenceIdentifier)
                            }
                        )
                    }
                }
            }

            // Ignored apps section
            let ignoredApps = audioEngine.settingsManager.getIgnoredAppInfo()
                .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
            if !ignoredApps.isEmpty {
                Divider()
                    .padding(.vertical, DesignTokens.Spacing.xs)

                Text("Hidden Apps")
                    .sectionHeaderStyle()
                    .padding(.bottom, DesignTokens.Spacing.xs)

                LazyVGrid(columns: appEditColumns, spacing: DesignTokens.Spacing.xs) {
                    ForEach(ignoredApps, id: \.persistenceIdentifier) { info in
                        AppEditRow(
                            icon: DisplayableApp.loadIcon(bundleID: info.bundleID),
                            name: info.displayName,
                            isIgnored: true,
                            isPinned: false,
                            onToggleVisibility: { audioEngine.unignoreApp(info.persistenceIdentifier) },
                            onTogglePin: {}
                        )
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func appsContent(
        _ apps: [DisplayableApp],
        scrollProxy: ScrollViewProxy
    ) -> some View {
        let presets = audioEngine.settingsManager.getUserPresets()
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(apps) { displayableApp in
                Group {
                    switch displayableApp {
                    case .active(let app):
                        activeAppRow(app: app, displayableApp: displayableApp, userPresets: presets, scrollProxy: scrollProxy)

                    case .openInactive(let app):
                        let info = PinnedAppInfo(
                            persistenceIdentifier: app.persistenceIdentifier,
                            displayName: app.name,
                            bundleID: app.bundleID
                        )
                        inactiveAppRow(
                            info: info,
                            openApp: app,
                            displayableApp: displayableApp,
                            userPresets: presets,
                            scrollProxy: scrollProxy
                        )

                    case .pinnedInactive(let info):
                        inactiveAppRow(info: info, displayableApp: displayableApp, userPresets: presets, scrollProxy: scrollProxy)
                    }
                }
                .matchedGeometryEffect(id: "app-row-\(displayableApp.id)", in: appActivityNamespace)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(DesignTokens.Animation.panel, value: apps.map(\.id))
    }

    /// Row for an active app (currently producing audio)
    @ViewBuilder
    private func activeAppRow(app: AudioApp, displayableApp: DisplayableApp, userPresets: [UserEQPreset], scrollProxy: ScrollViewProxy) -> some View {
        if let deviceUID = audioEngine.getDeviceUID(for: app) {
            AppRowWithLevelPolling(
                app: app,
                volume: audioEngine.getVolume(for: app),
                isMuted: audioEngine.getMute(for: app),
                devices: sortedDevices,
                deviceIconOverrides: audioEngine.settingsManager.deviceIconOverrides,
                selectedDeviceUID: deviceUID,
                selectedDeviceUIDs: audioEngine.getSelectedDeviceUIDs(for: app),
                isFollowingDefault: audioEngine.isFollowingDefault(for: app),
                defaultDeviceUID: deviceVolumeMonitor.defaultDeviceUID,
                deviceSelectionMode: audioEngine.getDeviceSelectionMode(for: app),
                boost: audioEngine.getBoost(for: app),
                onBoostChange: { boost in
                    audioEngine.setBoost(for: app, to: boost)
                },
                getAudioLevel: { audioEngine.getAudioLevel(for: app) },
                isPopupVisible: isPopupVisible,
                onVolumeChange: { volume in
                    audioEngine.setVolume(for: app, to: volume)
                },
                onMuteChange: { muted in
                    audioEngine.setMute(for: app, to: muted)
                },
                onDeviceSelected: { newDeviceUID in
                    audioEngine.setDevice(for: app, deviceUID: newDeviceUID)
                },
                onDevicesSelected: { uids in
                    audioEngine.setSelectedDeviceUIDs(for: app, to: uids)
                },
                onDeviceModeChange: { mode in
                    audioEngine.setDeviceSelectionMode(for: app, to: mode)
                },
                onSelectFollowDefault: {
                    audioEngine.setDevice(for: app, deviceUID: nil)
                },
                onAppActivate: {
                    activateApp(pid: app.id, bundleID: app.bundleID)
                },
                eqSettings: audioEngine.getEQSettings(for: app),
                stereoFieldSettings: audioEngine.getStereoFieldSettings(for: app),
                userPresets: userPresets,
                onEQChange: { settings in
                    audioEngine.setEQSettings(settings, for: app)
                },
                onStereoFieldChange: { settings in
                    audioEngine.setStereoFieldSettings(settings, for: app)
                },
                onUserPresetSelected: { userPreset in
                    // Apply only bandGains — preserve app's current isEnabled state
                    var current = audioEngine.getEQSettings(for: app)
                    current.bandGains = userPreset.settings.bandGains
                    audioEngine.setEQSettings(current, for: app)
                },
                onSavePreset: { name, settings in
                    audioEngine.settingsManager.createUserPreset(name: name, settings: settings)
                },
                onDeleteUserPreset: { id in
                    audioEngine.settingsManager.deleteUserPreset(id: id)
                },
                onRenameUserPreset: { id, newName in
                    audioEngine.settingsManager.updateUserPreset(id: id, name: newName)
                },
                isEQExpanded: expandedRowID == displayableApp.id,
                onEQToggle: {
                    toggleEQ(for: displayableApp.id, scrollProxy: scrollProxy)
                },
                isFocused: hasKeyboardEngaged && selectedRow == .app(persistenceID: displayableApp.id)
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .guidedTourTarget(
                .equalizer,
                when: displayableApp.id == guidedTourEqualizerAppID
            )
            .contentShape(Rectangle())
            .id(PopupKeyboardNavModel.RowID.app(persistenceID: displayableApp.id))
            .contextMenu {
                Button(audioEngine.getMute(for: app) ? "Unmute" : "Mute",
                       systemImage: audioEngine.getMute(for: app) ? "speaker.wave.2" : "speaker.slash") {
                    audioEngine.setMute(for: app, to: !audioEngine.getMute(for: app))
                }
                Divider()
                Button("Hide App", systemImage: "eye.slash") {
                    if lastTouchedAppID == displayableApp.id {
                        lastTouchedAppID = nil
                    }
                    audioEngine.ignoreApp(app)
                }
            }
            .simultaneousGesture(TapGesture().onEnded {
                touchAppForKeyboard(displayableApp.id)
            })
        } else {
            // Keep the app visible if permission or device setup has not yet
            // established a route. Its saved controls still apply on activation.
            inactiveAppRow(
                info: PinnedAppInfo(
                    persistenceIdentifier: app.persistenceIdentifier,
                    displayName: app.name,
                    bundleID: app.bundleID
                ),
                openApp: app,
                displayableApp: displayableApp,
                userPresets: userPresets,
                scrollProxy: scrollProxy
            )
        }
    }

    /// Row for either an open app waiting for Core Audio or a closed pinned app.
    @ViewBuilder
    private func inactiveAppRow(
        info: PinnedAppInfo,
        openApp: AudioApp? = nil,
        displayableApp: DisplayableApp,
        userPresets: [UserEQPreset],
        scrollProxy: ScrollViewProxy
    ) -> some View {
        let identifier = info.persistenceIdentifier
        InactiveAppRow(
            appInfo: info,
            icon: displayableApp.icon,
            isAppOpen: openApp != nil,
            onAppActivate: {
                if let openApp {
                    activateApp(pid: openApp.id, bundleID: openApp.bundleID)
                }
            },
            volume: audioEngine.getVolumeForInactive(identifier: identifier),
            devices: sortedDevices,
            deviceIconOverrides: audioEngine.settingsManager.deviceIconOverrides,
            selectedDeviceUID: audioEngine.getDeviceRoutingForInactive(identifier: identifier),
            selectedDeviceUIDs: audioEngine.getSelectedDeviceUIDsForInactive(identifier: identifier),
            isFollowingDefault: audioEngine.isFollowingDefaultForInactive(identifier: identifier),
            defaultDeviceUID: deviceVolumeMonitor.defaultDeviceUID,
            deviceSelectionMode: audioEngine.getDeviceSelectionModeForInactive(identifier: identifier),
            isMuted: audioEngine.getMuteForInactive(identifier: identifier),
            boost: audioEngine.getBoostForInactive(identifier: identifier),
            onBoostChange: { boost in
                audioEngine.setBoostForInactive(identifier: identifier, to: boost)
            },
            onVolumeChange: { volume in
                audioEngine.setVolumeForInactive(identifier: identifier, to: volume)
            },
            onMuteChange: { muted in
                audioEngine.setMuteForInactive(identifier: identifier, to: muted)
            },
            onDeviceSelected: { newDeviceUID in
                audioEngine.setDeviceRoutingForInactive(identifier: identifier, deviceUID: newDeviceUID)
            },
            onDevicesSelected: { uids in
                audioEngine.setSelectedDeviceUIDsForInactive(identifier: identifier, to: uids)
            },
            onDeviceModeChange: { mode in
                audioEngine.setDeviceSelectionModeForInactive(identifier: identifier, to: mode)
            },
            onSelectFollowDefault: {
                audioEngine.setDeviceRoutingForInactive(identifier: identifier, deviceUID: nil)
            },
            eqSettings: audioEngine.getEQSettingsForInactive(identifier: identifier),
            stereoFieldSettings: audioEngine.getStereoFieldSettingsForInactive(identifier: identifier),
            userPresets: userPresets,
            onEQChange: { settings in
                audioEngine.setEQSettingsForInactive(settings, identifier: identifier)
            },
            onStereoFieldChange: { settings in
                audioEngine.setStereoFieldSettingsForInactive(settings, identifier: identifier)
            },
            onUserPresetSelected: { userPreset in
                // Apply only bandGains — preserve app's current isEnabled state
                var current = audioEngine.getEQSettingsForInactive(identifier: identifier)
                current.bandGains = userPreset.settings.bandGains
                audioEngine.setEQSettingsForInactive(current, identifier: identifier)
            },
            onSavePreset: { name, settings in
                audioEngine.settingsManager.createUserPreset(name: name, settings: settings)
            },
            onDeleteUserPreset: { id in
                audioEngine.settingsManager.deleteUserPreset(id: id)
            },
            onRenameUserPreset: { id, newName in
                audioEngine.settingsManager.updateUserPreset(id: id, name: newName)
            },
            isEQExpanded: expandedRowID == displayableApp.id,
            onEQToggle: {
                toggleEQ(for: displayableApp.id, scrollProxy: scrollProxy)
            },
            isFocused: hasKeyboardEngaged && selectedRow == .app(persistenceID: displayableApp.id)
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        .guidedTourTarget(
            .equalizer,
            when: displayableApp.id == guidedTourEqualizerAppID
        )
        .contentShape(Rectangle())
        .id(PopupKeyboardNavModel.RowID.app(persistenceID: displayableApp.id))
        .contextMenu {
            Button(audioEngine.getMuteForInactive(identifier: identifier) ? "Unmute" : "Mute",
                   systemImage: audioEngine.getMuteForInactive(identifier: identifier) ? "speaker.wave.2" : "speaker.slash") {
                let muted = audioEngine.getMuteForInactive(identifier: identifier)
                audioEngine.setMuteForInactive(identifier: identifier, to: !muted)
            }
            Divider()
            Button("Hide App", systemImage: "eye.slash") {
                if lastTouchedAppID == displayableApp.id {
                    lastTouchedAppID = nil
                }
                if let openApp {
                    audioEngine.ignoreApp(openApp)
                } else {
                    let hiddenInfo = IgnoredAppInfo(
                        persistenceIdentifier: info.persistenceIdentifier,
                        displayName: info.displayName,
                        bundleID: info.bundleID
                    )
                    audioEngine.settingsManager.ignoreApp(identifier, info: hiddenInfo)
                }
            }
        }
        .simultaneousGesture(TapGesture().onEnded {
            touchAppForKeyboard(displayableApp.id)
        })
    }

    /// Toggle EQ panel for an app (shared between active and inactive rows)
    private func toggleEQ(for appID: String, scrollProxy: ScrollViewProxy) {
        guard !isEQAnimating else { return }
        isEQAnimating = true

        let isExpanding = expandedRowID != appID
        withAnimation(DesignTokens.Animation.panel) {
            if expandedRowID == appID {
                expandedRowID = nil
            } else {
                expandedRowID = appID
            }
            if isExpanding {
                scrollProxy.scrollTo(PopupKeyboardNavModel.RowID.app(persistenceID: appID), anchor: .top)
            }
        }

        Task {
            try? await Task.sleep(for: .seconds(0.4))
            isEQAnimating = false
        }
    }

    // MARK: - Device Priority Edit

    private func toggleDevicePriorityEdit() {
        if isEditingDevicePriority {
            // Exiting edit mode: persist to the correct priority list and
            // collapse any expanded device detail (the inline body only lives
            // inside edit mode, so it must collapse when the mode does).
            persistEditableOrder()
            isEditingDevicePriority = false
            expandedDeviceUID = nil
            if wasEditingInputDevices {
                updateSortedInputDevices()
            } else {
                updateSortedDevices()
            }
        } else {
            // Entering edit mode: use the full (unfiltered) device list so hidden devices are also shown.
            wasEditingInputDevices = showingInputDevices
            editableDeviceOrder = showingInputDevices
                ? audioEngine.prioritySortedInputDevices
                : audioEngine.prioritySortedOutputDevices
            isEditingDevicePriority = true
        }
    }

    /// Persists the editable order to the correct priority list, preserving disconnected device positions.
    private func persistEditableOrder() {
        let connectedOrder = editableDeviceOrder.map(\.uid)
        if wasEditingInputDevices {
            audioEngine.settingsManager.mergeInputDevicePriorityOrder(
                oldPriority: audioEngine.settingsManager.inputDevicePriorityOrder,
                connectedOrder: connectedOrder
            )
        } else {
            audioEngine.settingsManager.mergeDevicePriorityOrder(
                oldPriority: audioEngine.settingsManager.devicePriorityOrder,
                connectedOrder: connectedOrder
            )
        }
    }

    /// Exits edit mode, saving the current order. Called on edge cases like device changes.
    private func exitEditModeSaving() {
        guard isEditingDevicePriority else { return }
        persistEditableOrder()
        isEditingDevicePriority = false
        expandedDeviceUID = nil
    }

    /// Merges device list changes into `editableDeviceOrder` while preserving the user's reordering.
    /// Existing devices are refreshed (CoreAudio may reassign AudioDeviceIDs), removed devices are
    /// dropped, and reconnecting devices are inserted at their saved priority position.
    private func mergeDeviceChanges(from latest: [AudioDevice]) {
        let latestByUID = Dictionary(latest.map { ($0.uid, $0) }, uniquingKeysWith: { _, new in new })
        let priorityOrder = wasEditingInputDevices
            ? audioEngine.settingsManager.inputDevicePriorityOrder
            : audioEngine.settingsManager.devicePriorityOrder

        withAnimation(DesignTokens.Animation.rowChange) {
            // Remove devices that disappeared
            editableDeviceOrder.removeAll { latestByUID[$0.uid] == nil }

            // Refresh existing devices in case AudioDeviceID changed
            for i in editableDeviceOrder.indices {
                if let updated = latestByUID[editableDeviceOrder[i].uid] {
                    editableDeviceOrder[i] = updated
                }
            }

            // Insert reconnecting devices at their saved priority position
            let existingUIDs = Set(editableDeviceOrder.map(\.uid))
            let newDevices = latest.filter { !existingUIDs.contains($0.uid) }
            for device in newDevices {
                let index = Self.priorityInsertionIndex(
                    for: device.uid,
                    in: editableDeviceOrder.map(\.uid),
                    priorityOrder: priorityOrder
                )
                editableDeviceOrder.insert(device, at: index)
            }
        }
    }

    /// Finds the best insertion index for a reconnecting device based on saved priority order.
    ///
    /// Walks `priorityOrder` to find the UIDs that come before and after `uid`, then
    /// places the device between them in `currentOrder`. Falls back to appending at the end
    /// if the device isn't in the priority list or no neighbors are present.
    ///
    /// - Parameters:
    ///   - uid: The device UID to insert.
    ///   - currentOrder: The current list of device UIDs.
    ///   - priorityOrder: The saved full priority list.
    /// - Returns: The index at which to insert the device.
    static func priorityInsertionIndex(for uid: String, in currentOrder: [String], priorityOrder: [String]) -> Int {
        guard let priorityIndex = priorityOrder.firstIndex(of: uid) else {
            // Brand new device not in priority list — append at end
            return currentOrder.count
        }

        // Find the closest priority neighbor that exists in currentOrder and comes AFTER uid in priority.
        // Insert before that neighbor so uid takes its correct position.
        for i in (priorityIndex + 1)..<priorityOrder.count {
            let successor = priorityOrder[i]
            if let currentIndex = currentOrder.firstIndex(of: successor) {
                return currentIndex
            }
        }

        // No successor found — insert at end
        return currentOrder.count
    }

    // MARK: - Helpers

    /// Keeps a formerly-live row in the primary lane for the selected grace
    /// period, then lets SwiftUI carry it into the Inactive section. A resumed
    /// app cancels the pending move immediately. This function never controls
    /// audio capture or process-tap lifetime.
    private func updateAppActivityPresentation(_ activeApps: [AudioApp]) {
        let activeIDs = Set(activeApps.map(\.persistenceIdentifier))
        let becameQuiet = lastActiveAppIDs.subtracting(activeIDs)

        for identifier in activeIDs {
            inactiveMoveTasks.removeValue(forKey: identifier)?.cancel()
            recentlyActiveAppIDs.remove(identifier)
        }

        for identifier in becameQuiet {
            guard audioEngine.displayableApps.contains(where: { $0.id == identifier }) else { continue }
            scheduleQuietMove(for: identifier)
        }

        lastActiveAppIDs = activeIDs
    }

    private func scheduleQuietMove(for identifier: String) {
        inactiveMoveTasks.removeValue(forKey: identifier)?.cancel()
        let choice = audioEngine.settingsManager.appSettings.quietMoveDelay

        guard let delay = choice.delaySeconds else {
            recentlyActiveAppIDs.insert(identifier)
            return
        }

        guard delay > 0 else {
            recentlyActiveAppIDs.remove(identifier)
            return
        }

        recentlyActiveAppIDs.insert(identifier)
        inactiveMoveTasks[identifier] = Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            guard !self.audioEngine.apps.contains(where: {
                $0.persistenceIdentifier == identifier
            }) else { return }

            _ = withAnimation(DesignTokens.Animation.panel) {
                self.recentlyActiveAppIDs.remove(identifier)
            }
            self.inactiveMoveTasks.removeValue(forKey: identifier)
            self.syncNavOrder()
        }
    }

    private func rescheduleQuietAppMoves() {
        for task in inactiveMoveTasks.values { task.cancel() }
        inactiveMoveTasks.removeAll()

        let activeIDs = Set(audioEngine.apps.map(\.persistenceIdentifier))
        let quietIDs = Set(audioEngine.displayableApps.map(\.id)).subtracting(activeIDs)
        recentlyActiveAppIDs.subtract(activeIDs)
        for identifier in quietIDs {
            scheduleQuietMove(for: identifier)
        }
    }

    /// Recomputes sorted output devices, filtering hidden ones.
    /// The current default output device is always kept visible even if hidden.
    /// Falls back to the unfiltered list if the filter produces an empty
    /// result — `defaultDeviceUID` can be briefly nil during device switchover
    /// and we don't want the main view to show zero rows in that window.
    private func updateSortedDevices() {
        let all = audioEngine.prioritySortedOutputDevices
        let defaultUID = deviceVolumeMonitor.defaultDeviceUID
        let filtered = all.filter { device in
            device.uid == defaultUID || !audioEngine.settingsManager.isOutputDeviceHidden(device.uid)
        }
        sortedDevices = filtered.isEmpty ? all : filtered
    }

    /// Recomputes sorted input devices, filtering hidden ones.
    /// The current default input device is always kept visible even if hidden.
    /// Empty-filter fallback mirrors `updateSortedDevices`.
    private func updateSortedInputDevices() {
        let all = audioEngine.prioritySortedInputDevices
        let defaultUID = deviceVolumeMonitor.defaultInputDeviceUID
        let filtered = all.filter { device in
            device.uid == defaultUID || !audioEngine.settingsManager.isInputDeviceHidden(device.uid)
        }
        sortedInputDevices = filtered.isEmpty ? all : filtered
    }

    /// Opens a file panel to import a ParametricEQ.txt for a device
    private func importAutoEQFile(for deviceUID: String) {
        // Dismiss the main popup so the file picker isn't obscured
        NSApp.keyWindow?.resignKey()

        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType.plainText]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Select an AutoEQ ParametricEQ.txt file"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            let name = url.deletingPathExtension().lastPathComponent
            Task { @MainActor in
                if let profile = audioEngine.autoEQProfileManager.importProfile(from: url, name: name) {
                    audioEngine.setAutoEQProfile(for: deviceUID, profileID: profile.id)
                    autoEQImportError = nil
                } else {
                    autoEQImportError = "Could not read profile — check file format"
                    importErrorClearTask?.cancel()
                    importErrorClearTask = Task {
                        try? await Task.sleep(for: .seconds(3))
                        guard !Task.isCancelled else { return }
                        withAnimation { autoEQImportError = nil }
                    }
                }
            }
        }
    }

    // MARK: - Keyboard Navigation

    /// Kept as a named action rather than an inline closure so the SwiftUI body
    /// remains tractable for the Swift 6 release-mode type checker.
    private func processPopupKeyPress(_ keyPress: KeyPress) -> KeyPress.Result {
        guard !showCommandPalette else { return .ignored }
        return handleKeyPress(keyPress)
    }

    private func syncNavOrder() {
        let activeDevices = areDevicesExpanded
            ? (showingInputDevices ? sortedInputDevices : sortedDevices)
            : []
        navModel.syncOrder(
            activeDevices: activeDevices,
            appPersistenceIDs: (
                activeDisplayableApps
                    + (areInactiveAppsExpanded ? inactiveDisplayableApps : [])
            ).map(\.id),
            isEditingPriority: isEditingDevicePriority
        )
    }

    private func currentDefaultDeviceUID() -> String? {
        showingInputDevices
            ? deviceVolumeMonitor.defaultInputDeviceUID
            : deviceVolumeMonitor.defaultDeviceUID
    }

    private func handleKeyPress(_ keyPress: KeyPress) -> KeyPress.Result {
        // `.onKeyPress` also fires for focused descendants; yield while a TextField is editing so its Return commits via onSubmit instead of activating a row.
        if NSApp.keyWindow?.firstResponder is NSTextView { return .ignored }
        // Keyboard entry mode: the popup owns every key so the anchor keeps first responder.
        if textEntry.buffer != nil {
            return handleKeyboardEditKey(keyPress)
        }

        // Once an app row has been clicked, all four arrows belong to that app
        // until another app row is clicked. This makes keyboard volume control
        // spatial/contextual instead of using ↑/↓ to move away from the row.
        if let appID = lastTouchedAppID {
            switch keyPress.key {
            case .upArrow, .rightArrow:
                return adjustTouchedAppVolume(appID, direction: 1)
            case .downArrow, .leftArrow:
                return adjustTouchedAppVolume(appID, direction: -1)
            default:
                break
            }
        }
        if isDeviceTabSwapKey(keyPress) {
            guard keyPress.phase == .down else { return .handled }
            toggleDeviceTab()
            Haptics.commit()
            return .handled
        }
        let mods = keyPress.modifiers
        let isM = keyPress.key == KeyEquivalent("m")
        let editSeed = digitSeed(for: keyPress)
        let isRecognized: Bool = {
            switch keyPress.key {
            case .upArrow, .downArrow, .leftArrow, .rightArrow, .return, .space:
                return true
            default:
                return isM || editSeed != nil
            }
        }()
        // Wake gate: compute target locally so first-press actions never read a
        // stale selection. ↑/↓ wake without moving; action keys wake and act on
        // the default in the same press.
        let target: PopupKeyboardNavModel.RowID?
        let wokeUp: Bool
        if !hasKeyboardEngaged && isRecognized {
            hasKeyboardEngaged = true
            target = navModel.defaultFocus(defaultOutputUID: currentDefaultDeviceUID())
            selectedRow = target
            wokeUp = true
        } else {
            target = selectedRow
            wokeUp = false
        }
        switch keyPress.key {
        case .upArrow:
            if wokeUp { return target == nil ? .ignored : .handled }
            if let next = navModel.previous(before: target) {
                selectedRow = next
                return .handled
            }
            return .ignored
        case .downArrow:
            if wokeUp { return target == nil ? .ignored : .handled }
            if let next = navModel.next(after: target) {
                selectedRow = next
                return .handled
            }
            return .ignored
        case .leftArrow:
            return adjustVolumeWithFeedback(at: target, direction: -1, modifiers: mods)
        case .rightArrow:
            return adjustVolumeWithFeedback(at: target, direction: +1, modifiers: mods)
        case .return, .space:
            return activate(target)
        default:
            if let editSeed, keyPress.phase == .down, target != nil {
                textEntry.buffer = editSeed
                return .handled
            }
            return isM ? toggleMuteWithFeedback(for: target) : .ignored
        }
    }

    /// Consumes every key while entry is active so editing keystrokes never leak to navigation.
    private func handleKeyboardEditKey(_ keyPress: KeyPress) -> KeyPress.Result {
        // The Mac ⌫ key arrives as DEL (U+007F), which `KeyEquivalent.delete` doesn't match.
        if keyPress.characters == "\u{7f}" || keyPress.key == .delete {
            let next = String((textEntry.buffer ?? "").dropLast())
            textEntry.buffer = next.isEmpty ? nil : next
            return .handled
        }
        switch keyPress.key {
        case .return:
            textEntry.commitNonce += 1
            return .handled
        case .escape:
            textEntry.buffer = nil
            return .handled
        default:
            if let digit = digitSeed(for: keyPress), keyPress.phase == .down {
                let current = textEntry.buffer ?? ""
                if current.count < 4 {
                    textEntry.buffer = current + digit
                }
            }
            return .handled
        }
    }

    /// The bare digit `0`–`9` for this key press, or nil (modifier combos excluded).
    private func digitSeed(for keyPress: KeyPress) -> String? {
        guard keyPress.modifiers.intersection([.command, .control, .option]).isEmpty,
              keyPress.characters.count == 1,
              let ch = keyPress.characters.first,
              ("0"..."9").contains(ch)
        else { return nil }
        return String(ch)
    }

    /// ⌥⇥, ⌘[ and ⌘] swap the Input/Output device list.
    ///
    /// Plain Tab used to do this. That is the one key macOS reserves for
    /// moving focus, so Full Keyboard Access could never walk the popup — the
    /// keypress was consumed before it reached the responder chain.
    private func isDeviceTabSwapKey(_ keyPress: KeyPress) -> Bool {
        let mods = keyPress.modifiers
        if keyPress.key == .tab { return mods.contains(.option) }
        guard mods.contains(.command) else { return false }
        return keyPress.key == KeyEquivalent("[") || keyPress.key == KeyEquivalent("]")
    }

    /// Keyboard-driven volume changes tick; media-key and external changes
    /// don't. Same gating the sliders use, so a hotkey pressed while the popup
    /// is closed never buzzes twice.
    private func adjustVolumeWithFeedback(
        at target: PopupKeyboardNavModel.RowID?,
        direction: Int,
        modifiers: EventModifiers
    ) -> KeyPress.Result {
        let result = adjustVolume(at: target, direction: direction, modifiers: modifiers)
        if case .handled = result { Haptics.step() }
        return result
    }

    private func toggleMuteWithFeedback(for target: PopupKeyboardNavModel.RowID?) -> KeyPress.Result {
        let result = toggleMute(for: target)
        if case .handled = result { Haptics.step() }
        return result
    }

    private func adjustVolume(
        at target: PopupKeyboardNavModel.RowID?,
        direction: Int,
        modifiers: EventModifiers
    ) -> KeyPress.Result {
        guard let target else { return .ignored }
        let baseStep = audioEngine.settingsManager.appSettings.volumeHotkeyStep.sliderDelta
        // Option (and ⇧⌥) quarter the step, the macOS precision convention.
        // Shift alone deliberately does nothing now: it used to *double* the
        // step, which is the inverse of what Shift means everywhere else on
        // the platform, so the app's only modifier was the wrong one.
        let step = modifiers.contains(.option) ? baseStep * 0.25 : baseStep
        let delta = step * Double(direction)
        switch target {
        case .app(let persistenceID):
            if let app = audioEngine.apps.first(where: { $0.persistenceIdentifier == persistenceID }) {
                applyAppVolumeStep(
                    currentGain: audioEngine.currentVolume(for: app),
                    currentMute: audioEngine.isMuted(for: app),
                    direction: direction,
                    delta: delta,
                    setGain: { audioEngine.setVolume(for: app, to: $0) },
                    setMute: { audioEngine.setMute(for: app, to: $0) }
                )
                return .handled
            }
            applyAppVolumeStep(
                currentGain: audioEngine.getVolumeForInactive(identifier: persistenceID),
                currentMute: audioEngine.getMuteForInactive(identifier: persistenceID),
                direction: direction,
                delta: delta,
                setGain: { audioEngine.setVolumeForInactive(identifier: persistenceID, to: $0) },
                setMute: { audioEngine.setMuteForInactive(identifier: persistenceID, to: $0) }
            )
            return .handled
        case .device(let uid):
            if showingInputDevices {
                guard let device = sortedInputDevices.first(where: { $0.uid == uid }) else {
                    return .ignored
                }
                let current = Double(deviceVolumeMonitor.inputVolumes[device.id] ?? 1.0)
                let next = Float(max(0.0, min(1.0, current + delta)))
                deviceVolumeMonitor.setInputVolume(for: device.id, to: next)
            } else {
                guard let device = sortedDevices.first(where: { $0.uid == uid }) else {
                    return .ignored
                }
                let current = Double(deviceVolumeMonitor.volumes[device.id] ?? 1.0)
                let next = Float(max(0.0, min(1.0, current + delta)))
                audioEngine.setOutputDeviceVolume(for: device.id, to: next)
            }
            return .handled
        }
    }

    private func touchAppForKeyboard(_ persistenceID: String) {
        lastTouchedAppID = persistenceID
        selectedRow = .app(persistenceID: persistenceID)
        hasKeyboardEngaged = true
        anchorFocused = true
    }

    private func adjustTouchedAppVolume(_ persistenceID: String, direction: Int) -> KeyPress.Result {
        guard audioEngine.displayableApps.contains(where: { $0.id == persistenceID }) else {
            lastTouchedAppID = nil
            return .ignored
        }

        if let app = audioEngine.apps.first(where: { $0.persistenceIdentifier == persistenceID }) {
            applyFivePercentAppStep(
                volume: audioEngine.getVolume(for: app),
                boost: audioEngine.getBoost(for: app),
                isMuted: audioEngine.getMute(for: app),
                direction: direction,
                setVolume: { audioEngine.setVolume(for: app, to: $0) },
                setBoost: { audioEngine.setBoost(for: app, to: $0) },
                setMute: { audioEngine.setMute(for: app, to: $0) }
            )
        } else {
            applyFivePercentAppStep(
                volume: audioEngine.getVolumeForInactive(identifier: persistenceID),
                boost: audioEngine.getBoostForInactive(identifier: persistenceID),
                isMuted: audioEngine.getMuteForInactive(identifier: persistenceID),
                direction: direction,
                setVolume: { audioEngine.setVolumeForInactive(identifier: persistenceID, to: $0) },
                setBoost: { audioEngine.setBoostForInactive(identifier: persistenceID, to: $0) },
                setMute: { audioEngine.setMuteForInactive(identifier: persistenceID, to: $0) }
            )
        }
        Haptics.step()
        return .handled
    }

    private func applyFivePercentAppStep(
        volume: Float,
        boost: BoostLevel,
        isMuted: Bool,
        direction: Int,
        setVolume: (Float) -> Void,
        setBoost: (BoostLevel) -> Void,
        setMute: (Bool) -> Void
    ) {
        let currentEffectiveGain = volume * boost.rawValue
        let nextEffectiveGain = VolumeMapping.effectiveGainBySteppingFivePercent(
            from: currentEffectiveGain,
            direction: direction
        )
        let components = VolumeMapping.components(forEffectiveGain: nextEffectiveGain)
        setBoost(components.boost)
        setVolume(components.volume)

        if nextEffectiveGain <= 0 {
            if !isMuted { setMute(true) }
        } else if isMuted {
            setMute(false)
        }
    }

    /// Mirrors `ShortcutsRegistry.adjustTargetVolume`'s mute-edge semantics for
    /// both active and pinned-inactive app rows.
    private func applyAppVolumeStep(
        currentGain: Float,
        currentMute: Bool,
        direction: Int,
        delta: Double,
        setGain: (Float) -> Void,
        setMute: (Bool) -> Void
    ) {
        let currentSlider = VolumeMapping.gainToSlider(currentGain)
        let nextSlider = max(0.0, min(1.0, currentSlider + delta))
        let nextGain = VolumeMapping.sliderToGain(nextSlider)
        let willBeSilent = nextSlider <= 0.001
        if direction > 0 {
            if currentMute { setMute(false) }
        } else if currentMute && !willBeSilent {
            setMute(false)
        } else if !currentMute && willBeSilent {
            setMute(true)
        }
        setGain(nextGain)
    }

    private func toggleMute(for target: PopupKeyboardNavModel.RowID?) -> KeyPress.Result {
        guard let target else { return .ignored }
        switch target {
        case .app(let persistenceID):
            if let app = audioEngine.apps.first(where: { $0.persistenceIdentifier == persistenceID }) {
                audioEngine.toggleMute(for: app)
                return .handled
            }
            let current = audioEngine.getMuteForInactive(identifier: persistenceID)
            audioEngine.setMuteForInactive(identifier: persistenceID, to: !current)
            return .handled
        case .device(let uid):
            if showingInputDevices {
                guard let device = sortedInputDevices.first(where: { $0.uid == uid }) else {
                    return .ignored
                }
                let current = deviceVolumeMonitor.inputMuteStates[device.id] ?? false
                deviceVolumeMonitor.setInputMute(for: device.id, to: !current)
            } else {
                guard let device = sortedDevices.first(where: { $0.uid == uid }) else {
                    return .ignored
                }
                let current = deviceVolumeMonitor.muteStates[device.id] ?? false
                audioEngine.setOutputDeviceMute(for: device.id, to: !current)
            }
            return .handled
        }
    }

    private func activate(_ target: PopupKeyboardNavModel.RowID?) -> KeyPress.Result {
        guard let target else { return .ignored }
        switch target {
        case .device(let uid):
            if showingInputDevices {
                guard let device = sortedInputDevices.first(where: { $0.uid == uid }) else {
                    return .ignored
                }
                audioEngine.setLockedInputDevice(device)
            } else {
                guard let device = sortedDevices.first(where: { $0.uid == uid }) else {
                    return .ignored
                }
                audioEngine.setDefaultOutputDevice(device.id)
            }
            NSApp.keyWindow?.resignKey()
            return .handled
        case .app(let persistenceID):
            withAnimation(DesignTokens.Animation.panel) {
                expandedRowID = (expandedRowID == persistenceID) ? nil : persistenceID
            }
            return .handled
        }
    }

    private func toggleDeviceTab() {
        withAnimation(DesignTokens.Animation.panel) {
            showingInputDevices.toggle()
        }
    }

    /// Activates an app, bringing it to foreground and restoring minimized windows
    private func activateApp(pid: pid_t, bundleID: String?) {
        // Step 1: Always activate via NSRunningApplication (reliable for non-minimized)
        let runningApp = NSWorkspace.shared.runningApplications.first { $0.processIdentifier == pid }
        runningApp?.activate()

        // Step 2: Try to restore minimized windows via AppleScript
        if let bundleID = bundleID {
            // reopen + activate restores minimized windows for most apps
            let script = NSAppleScript(source: """
                tell application id "\(bundleID)"
                    reopen
                    activate
                end tell
                """)
            script?.executeAndReturnError(nil)
        }
    }
}

// MARK: - Previews

#Preview("Menu Bar Popup") {
    // Note: This preview requires mock AudioEngine and DeviceVolumeMonitor
    // For now, just show the structure
    PreviewContainer {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            SectionHeader(title: "Output Devices")
                .padding(.bottom, DesignTokens.Spacing.xs)

            ForEach(MockData.sampleDevices.prefix(2)) { device in
                DeviceRow(
                    device: device,
                    isDefault: device == MockData.sampleDevices[0],
                    volume: 0.75,
                    isMuted: false,
                    onSetDefault: {},
                    onVolumeChange: { _ in },
                    onMuteToggle: {}
                )
            }

            Divider()
                .padding(.vertical, DesignTokens.Spacing.xs)

            SectionHeader(title: "Apps")
                .padding(.bottom, DesignTokens.Spacing.xs)

            ForEach(MockData.sampleApps.prefix(3)) { app in
                AppRow(
                    app: app,
                    volume: Float.random(in: 0.5...1.5),
                    audioLevel: Float.random(in: 0...0.7),
                    devices: MockData.sampleDevices,
                    selectedDeviceUID: MockData.sampleDevices[0].uid,
                    isMuted: false,
                    onVolumeChange: { _ in },
                    onMuteChange: { _ in },
                    onDeviceSelected: { _ in }
                )
            }

            Divider()
                .padding(.vertical, DesignTokens.Spacing.xs)

            Button {} label: {
                HStack(spacing: 6) {
                    Text("Quit")
                    Text("⌘Q")
                        .foregroundStyle(DesignTokens.Colors.textTertiary)
                }
            }
            .buttonStyle(.meloHover)
            .foregroundStyle(DesignTokens.Colors.textTertiary)
            .font(DesignTokens.Typography.caption)
        }
    }
}
