// Melo/Views/Settings/SettingsRootView.swift
import SwiftUI

@MainActor
struct SettingsRootView: View {
    @Bindable var settings: SettingsManager
    @Bindable var audioEngine: AudioEngine
    @Bindable var deviceVolumeMonitor: DeviceVolumeMonitor
    @Bindable var accessibility: AccessibilityPermissionService
    @Bindable var mediaKeyStatus: MediaKeyStatus
    let mediaKeyMonitor: MediaKeyMonitor
    let shortcutsRegistry: ShortcutsRegistry
    @ObservedObject var sparkleUpdateController: SparkleUpdateController
    @ObservedObject var developerUpdateManager: DeveloperUpdateManager
    @Bindable var consumerAutomationManager: ConsumerAutomationManager
    @Bindable var callDuckingManager: CallDuckingManager
    @Bindable var sleepTimerManager: SleepTimerManager
    @Bindable var powerSourceMonitor: PowerSourceMonitor
    @Bindable var appSupport: AppSupportCoordinator

    enum Section: String, Hashable, CaseIterable, Identifiable {
        case everyday, general, audio, effects, shortcuts, guide, updates, about
        var id: Self { self }
    }

    @State private var selection: Section = .everyday

    /// The search row sits above the tabs rather than inside them, so the window
    /// grows by its height instead of stealing it from whichever tab is showing.
    private static let searchBarHeight: CGFloat = 44

    var body: some View {
        VStack(spacing: 0) {
            SettingsSearchField(onSelect: { navigate(to: $0) })
                .frame(height: Self.searchBarHeight)
                // The results list is an overlay that hangs past the row's own
                // bounds; without a raised zIndex the TabView below paints over it.
                .zIndex(1)

            Divider()

            tabs
        }
        .frame(width: 860, height: 650 + Self.searchBarHeight)
        .tint(
            settings.appSettings.visualTheme.accentColor(
                customHex: settings.appSettings.customAccentHex,
                generatedTheme: settings.appSettings.generatedTheme
            )
        )
        .preferredColorScheme(
            settings.appSettings.visualTheme.resolvedColorScheme(appearance: settings.appSettings.appearance)
        )
        .background(
            WindowAppearanceBridge(
                appearance: settings.appSettings.visualTheme.prefersDarkAppearance
                    ? settings.appSettings.visualTheme.resolvedNSAppearance
                    : settings.appSettings.appearance.nsAppearance
            )
        )
        .meloThemeBackground(
            theme: settings.appSettings.visualTheme,
            customAccentHex: settings.appSettings.customAccentHex,
            generatedTheme: settings.appSettings.generatedTheme
        )
        .background(WindowTitleBridge(title: "Melo Settings"))
        .onReceive(NotificationCenter.default.publisher(for: .meloOpenGuide)) { _ in
            selection = .guide
        }
    }

    /// The Guide's model deliberately does not depend on this view, so the two
    /// enums are matched by raw value. An unknown case leaves the tab alone
    /// rather than guessing.
    private func navigate(to destination: SettingsDestination) {
        guard let section = Section(rawValue: destination.rawValue) else { return }
        withAnimation(DesignTokens.Animation.quick) {
            selection = section
        }
    }

    private var tabs: some View {
        TabView(selection: $selection) {
            EverydayTab(
                settings: settings,
                audioEngine: audioEngine,
                automationManager: consumerAutomationManager,
                sleepTimer: sleepTimerManager
            )
            .tabItem { Label("Everyday", systemImage: "sparkles") }
            .tag(Section.everyday)

            GeneralTab(
                settings: settings,
                appSupport: appSupport,
                onResetAll: {
                    audioEngine.handleSettingsReset()
                    appSupport.setDockVisible(false)
                    deviceVolumeMonitor.setSystemFollowDefault()
                    callDuckingManager.checkNow()
                    powerSourceMonitor.refresh()
                    MeloAppShortcuts.updateAppShortcutParameters()
                },
                onSettingsRestored: {
                    audioEngine.handleSettingsImported()
                    callDuckingManager.checkNow()
                    powerSourceMonitor.refresh()
                    MeloAppShortcuts.updateAppShortcutParameters()
                }
            )
            .tabItem { Label("General", systemImage: "gearshape") }
            .tag(Section.general)

            AudioTab(
                settings: settings,
                audioEngine: audioEngine,
                deviceVolumeMonitor: deviceVolumeMonitor,
                callDuckingManager: callDuckingManager,
                powerSourceMonitor: powerSourceMonitor
            )
            .tabItem { Label("Audio", systemImage: "speaker.wave.2") }
            .tag(Section.audio)

            AudioUnitsTab(host: audioEngine.audioUnitHost, audioEngine: audioEngine)
                .tabItem { Label("Effects", systemImage: "waveform.path.ecg") }
                .tag(Section.effects)

            ShortcutsTab(
                settings: settings,
                accessibility: accessibility,
                mediaKeyStatus: mediaKeyStatus,
                mediaKeyMonitor: mediaKeyMonitor,
                shortcutsRegistry: shortcutsRegistry
            )
            .tabItem { Label("Shortcuts", systemImage: "command") }
            .tag(Section.shortcuts)

            SettingsGuideView(onNavigate: { navigate(to: $0) })
                .tabItem { Label("Guide", systemImage: "questionmark.circle") }
                .tag(Section.guide)

            UpdatesTab(
                sparkle: sparkleUpdateController,
                developerUpdates: developerUpdateManager
            )
                .tabItem { Label("Updates", systemImage: "arrow.triangle.2.circlepath") }
                .tag(Section.updates)

            AboutTab()
                .tabItem { Label("About", systemImage: "info.circle") }
                .tag(Section.about)
        }
    }
}

// MARK: - Settings Search

/// Search across every setting Melo has, using the Guide catalog as the index.
///
/// The catalog already names all 78 settings and now carries the tab each one
/// lives in, so there is no second list to keep in step: anything findable in
/// the Guide is findable here, and selecting a result opens its tab.
@MainActor
private struct SettingsSearchField: View {
    let onSelect: (SettingsDestination) -> Void

    @State private var query = ""
    @State private var selectedIndex = 0
    @FocusState private var focused: Bool

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var results: [SettingsGuideEntry] {
        guard !trimmedQuery.isEmpty else { return [] }
        return IntentSearch.rank(SettingsGuideEntry.all, limit: 7) { $0.searchScore(trimmedQuery) }
    }

    /// Entries that describe a control in the menu bar popup have no tab of
    /// their own; the Guide is where their explanation lives, so that is where
    /// the result goes.
    private func destination(for entry: SettingsGuideEntry) -> SettingsDestination {
        entry.destination ?? .guide
    }

    var body: some View {
        field
            .overlay(alignment: .topLeading) {
                if !results.isEmpty {
                    resultList
                        .offset(y: SettingsSearchField.fieldHeight + DesignTokens.Spacing.xs)
                }
            }
            .onChange(of: query) { _, _ in
                selectedIndex = 0
            }
            .onKeyPress(.downArrow) { moveSelection(by: 1) }
            .onKeyPress(.upArrow) { moveSelection(by: -1) }
            .onKeyPress(.return) { activateSelection() }
            .onKeyPress(.escape) { dismiss() }
    }

    private static let fieldHeight: CGFloat = 28
    private static let resultWidth: CGFloat = 380

    private var field: some View {
        HStack(spacing: DesignTokens.Spacing.xs2) {
            Image(systemName: "magnifyingglass")
                .font(DesignTokens.Typography.Scale.footnote())
                .foregroundStyle(.secondary)

            TextField("Search settings", text: $query)
                .textFieldStyle(.plain)
                .font(DesignTokens.Typography.Scale.body())
                .focused($focused)

            if !query.isEmpty {
                Button("Clear", systemImage: "xmark.circle.fill") { query = "" }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                    .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, DesignTokens.Spacing.sm)
        .frame(width: 260, height: SettingsSearchField.fieldHeight)
        .background(DesignTokens.Dimensions.Shape.sm.fill(DesignTokens.Colors.glassFillStrong))
        .overlay(
            DesignTokens.Dimensions.Shape.sm
                .strokeBorder(DesignTokens.Colors.glassBorder, lineWidth: 0.5)
        )
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.horizontal, DesignTokens.Spacing.md)
    }

    private var resultList: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(results.enumerated()), id: \.element.id) { index, entry in
                SettingsSearchRow(
                    entry: entry,
                    tabTitle: destination(for: entry).tabTitle,
                    isKeyboardSelected: index == selectedIndex,
                    onTap: { activate(entry) }
                )
            }
        }
        .padding(DesignTokens.Spacing.xs)
        .frame(width: SettingsSearchField.resultWidth, alignment: .leading)
        .background(
            VisualEffectBackground(material: .menu, blendingMode: .withinWindow)
                .clipShape(DesignTokens.Dimensions.Shape.md)
        )
        .overlay(
            DesignTokens.Dimensions.Shape.md
                .strokeBorder(DesignTokens.Colors.glassBorder, lineWidth: 0.5)
        )
        .meloElevation(DesignTokens.Elevation.floating)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.horizontal, DesignTokens.Spacing.md)
    }

    // MARK: - Keyboard

    private func moveSelection(by delta: Int) -> KeyPress.Result {
        guard !results.isEmpty else { return .ignored }
        let next = selectedIndex + delta
        selectedIndex = min(max(next, 0), results.count - 1)
        return .handled
    }

    private func activateSelection() -> KeyPress.Result {
        guard results.indices.contains(selectedIndex) else { return .ignored }
        activate(results[selectedIndex])
        return .handled
    }

    /// Escape clears the query first and only gives up focus once there is
    /// nothing left to clear — the same two-step every macOS search field uses.
    private func dismiss() -> KeyPress.Result {
        if !query.isEmpty {
            query = ""
            return .handled
        }
        if focused {
            focused = false
            return .handled
        }
        return .ignored
    }

    private func activate(_ entry: SettingsGuideEntry) {
        onSelect(destination(for: entry))
        query = ""
        focused = false
    }
}

@MainActor
private struct SettingsSearchRow: View {
    let entry: SettingsGuideEntry
    let tabTitle: String
    let isKeyboardSelected: Bool
    let onTap: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: DesignTokens.Spacing.sm) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.title)
                        .font(DesignTokens.Typography.Scale.body(.medium))
                        .foregroundStyle(.primary)
                    Text(entry.summary)
                        .font(DesignTokens.Typography.Scale.caption())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: DesignTokens.Spacing.sm)
                Text(tabTitle)
                    .font(DesignTokens.Typography.Scale.caption2(.medium))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, DesignTokens.Spacing.sm)
            .frame(minHeight: DesignTokens.Dimensions.minTouchTarget)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                DesignTokens.Dimensions.Shape.sm
                    .fill(isHovered ? DesignTokens.Colors.hoverSurface : Color.clear)
            )
            // Keyboard focus is a ring, hover is a fill. Using the same fill for
            // both leaves no way to tell what Return will do while the pointer
            // rests on some other row.
            .overlay(
                DesignTokens.Dimensions.Shape.sm
                    .strokeBorder(
                        isKeyboardSelected ? Color.accentColor : Color.clear,
                        lineWidth: 1.5
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .whenHovered { isHovered = $0 }
        .accessibilityAddTraits(isKeyboardSelected ? .isSelected : [])
        .accessibilityHint("Opens \(tabTitle)")
    }
}
