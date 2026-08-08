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

        var title: String {
            switch self {
            case .everyday: return "Everyday"
            case .general: return "General"
            case .audio: return "Audio"
            case .effects: return "Effects"
            case .shortcuts: return "Shortcuts"
            case .guide: return "Guide"
            case .updates: return "Updates"
            case .about: return "About"
            }
        }

        /// The glyphs the `.tabItem` labels used, carried over unchanged: the
        /// tab bar is drawn by this file now, but it is the same eight tabs and
        /// a reader should not have to relearn them.
        var symbol: String {
            switch self {
            case .everyday: return "house"
            case .general: return "gearshape"
            case .audio: return "speaker.wave.2"
            case .effects: return "waveform.path"
            case .shortcuts: return "command"
            case .guide: return "questionmark.circle"
            case .updates: return "arrow.triangle.2.circlepath"
            case .about: return "info.circle"
            }
        }
    }

    @State private var selection: Section = .everyday
    /// The section the reader was sent to, handed to whichever tab holds it so
    /// that tab scrolls to it.
    @State private var sectionTarget: SettingsSectionTarget?
    /// Numbers each navigation so asking for the same section twice is two
    /// different values. See `SettingsSectionTarget.serial`.
    @State private var navigationCount = 0
    /// Which way the pages are travelling. Read by the transition, so a jump
    /// from Guide back to Audio slides the other way from Audio to Guide —
    /// travel that ignores direction is animation rather than orientation.
    @State private var travellingForward = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @Namespace private var tabBubble

    /// The search row sits above the tabs rather than inside them, so the window
    /// grows by its height instead of stealing it from whichever tab is showing.
    private static let searchBarHeight: CGFloat = 44
    private static let tabBarHeight: CGFloat = 54

    var body: some View {
        VStack(spacing: 0) {
            SettingsSearchField(onSelect: { navigate(to: $0, location: $1) })
                .frame(height: Self.searchBarHeight)
                // The results list is an overlay that hangs past the row's own
                // bounds; without a raised zIndex the pages below paint over it.
                .zIndex(2)

            Divider()

            tabBar
                .zIndex(1)

            Divider()

            pages
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
            selectByHand(.guide)
        }
    }

    /// The Guide's model deliberately does not depend on this view, so the two
    /// enums are matched by raw value. An unknown case leaves the tab alone
    /// rather than guessing.
    ///
    /// Switching tab is only half the answer — Audio holds six sections and
    /// General six more, so a bare tab switch can land a reader well above the
    /// thing they asked for. The section the location line names is handed to
    /// the tab, which scrolls to it.
    ///
    /// This replaced a bar that printed "Settings › Audio › Calls" across the
    /// top of the window and left the reader to find Calls themselves. Telling
    /// someone where a control is, in a window that could simply show it to
    /// them, is a description of the feature rather than the feature.
    private func navigate(to destination: SettingsDestination, location: String?) {
        guard let section = Section(rawValue: destination.rawValue) else { return }
        navigationCount += 1
        let target = SettingsGuideEntry.sectionTitle(inLocation: location).map {
            SettingsSectionTarget(section: $0, serial: navigationCount)
        }
        sectionTarget = target
        travel(to: section)
    }

    /// A tab pressed by hand. The section target is dropped: nobody asked to be
    /// shown a particular setting, so leaving the last one marked would mark a
    /// section the reader did not ask about, on a page they opened themselves.
    private func selectByHand(_ section: Section) {
        sectionTarget = nil
        travel(to: section)
    }

    private func travel(to section: Section) {
        guard section != selection else { return }
        travellingForward = index(of: section) > index(of: selection)
        withAnimation(pageTravelAnimation) {
            selection = section
        }
    }

    private func index(of section: Section) -> Int {
        Section.allCases.firstIndex(of: section) ?? 0
    }

    private func step(by delta: Int) {
        let all = Section.allCases
        let next = (index(of: selection) + delta + all.count) % all.count
        selectByHand(all[next])
    }

    /// Reduce Motion gets the destination without the journey: no travel, no
    /// sliding bubble, just the page it asked for. `DesignTokens.Animation`
    /// grades every other animation in the app this way; the page container is
    /// the one place where the graded 0.10s would still be *translation*, so the
    /// substitution here is a cross-fade rather than a faster slide.
    private var pageTravelAnimation: SwiftUI.Animation {
        reduceMotion ? DesignTokens.Animation.reduced : SettingsGuidedNavigation.pageTravelAnimation
    }

    private var pageTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .move(edge: travellingForward ? .trailing : .leading),
            removal: .move(edge: travellingForward ? .leading : .trailing)
        )
    }

    // MARK: - Tab bar

    /// Replaces `TabView(selection:)`.
    ///
    /// `TabView` on macOS cross-fades between tabs and offers no way in to that
    /// — there is no style, no transition and no proxy that makes it travel
    /// sideways. Rejected alternatives: an `HStack` of all eight pages offset by
    /// the selected index, which slides the right distance but builds every tab
    /// at once and drags three blank pages past the reader on a jump from Guide
    /// to Audio; and a paging `ScrollView(.horizontal)`, which has the same
    /// eight-pages-alive cost plus a scroll position that is now two sources of
    /// truth with `selection`. A transition on a `switch` keeps exactly one page
    /// alive, makes every journey one page-width regardless of distance, and
    /// leaves `selection` the only state there is.
    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(Array(Section.allCases.enumerated()), id: \.element) { index, section in
                tabButton(section, ordinal: index + 1)
            }
            cycleShortcuts
        }
        .padding(.horizontal, DesignTokens.Spacing.sm)
        .frame(height: Self.tabBarHeight)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Settings sections")
    }

    private func tabButton(_ section: Section, ordinal: Int) -> some View {
        let selected = section == selection
        return Button {
            selectByHand(section)
        } label: {
            VStack(spacing: 2) {
                Image(systemName: section.symbol)
                    .font(.system(size: 15, weight: .medium))
                    .frame(height: 17)
                Text(section.title)
                    .font(DesignTokens.Typography.Scale.caption2(selected ? .semibold : .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(selected ? Color.primary : Color.secondary)
            .frame(maxWidth: .infinity)
            .frame(height: 42)
            .background { selectionBubble(isSelected: selected) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(KeyEquivalent(Character("\(ordinal)")), modifiers: .command)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityLabel(section.title)
        .help(section.title)
    }

    /// The travelling bubble.
    ///
    /// The glass sits in a `background`, not around the label, on purpose: a
    /// `glassEffect` island is composited by the window server and takes its
    /// content with it, so wrapping the icon and the title in one would erase
    /// the selected tab's own name from every captured frame. As a sibling
    /// beneath them, the label is still drawn by the layer tree.
    @ViewBuilder
    private func selectionBubble(isSelected: Bool) -> some View {
        if isSelected {
            if reduceMotion {
                bubbleShape
            } else {
                bubbleShape
                    .matchedGeometryEffect(id: "settings-tab-bubble", in: tabBubble)
            }
        }
    }

    private var bubbleShape: some View {
        Color.clear
            .meloGlassSurface(cornerRadius: 12, tint: .accentColor, interactive: true)
    }

    /// `TabView` answered ⌃Tab and ⌃⇧Tab; those keys leave with it, so they are
    /// re-bound here alongside ⌘1–⌘8 on the tabs themselves.
    private var cycleShortcuts: some View {
        ZStack {
            Button("Next Section") { step(by: 1) }
                .keyboardShortcut(.tab, modifiers: .control)
            Button("Previous Section") { step(by: -1) }
                .keyboardShortcut(.tab, modifiers: [.control, .shift])
        }
        .buttonStyle(.plain)
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }

    // MARK: - Pages

    private var pages: some View {
        ZStack {
            page
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(pageTransition)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Without this the outgoing page is drawn across the search row and the
        // tab bar on its way off screen.
        .clipped()
    }

    /// One branch per tab, and each tab built by its own property.
    ///
    /// Inlining the eight initializers into this switch compiles, but it hands
    /// the release-mode type checker one expression holding every tab's full
    /// argument list — the shape this project has already had blow up on it
    /// once, in the guide catalog.
    @ViewBuilder
    private var page: some View {
        switch selection {
        case .everyday: everydayPage
        case .general: generalPage
        case .audio: audioPage
        case .effects: effectsPage
        case .shortcuts: shortcutsPage
        case .guide: guidePage
        case .updates: updatesPage
        case .about: aboutPage
        }
    }

    private var everydayPage: some View {
        EverydayTab(
            settings: settings,
            audioEngine: audioEngine,
            automationManager: consumerAutomationManager,
            sleepTimer: sleepTimerManager,
            sectionTarget: sectionTarget
        )
    }

    private var generalPage: some View {
        GeneralTab(
            settings: settings,
            appSupport: appSupport,
            audioEngine: audioEngine,
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
            },
            sectionTarget: sectionTarget
        )
    }

    private var audioPage: some View {
        AudioTab(
            settings: settings,
            audioEngine: audioEngine,
            deviceVolumeMonitor: deviceVolumeMonitor,
            callDuckingManager: callDuckingManager,
            powerSourceMonitor: powerSourceMonitor,
            sectionTarget: sectionTarget
        )
    }

    private var effectsPage: some View {
        AudioUnitsTab(host: audioEngine.audioUnitHost, audioEngine: audioEngine)
    }

    private var shortcutsPage: some View {
        ShortcutsTab(
            settings: settings,
            accessibility: accessibility,
            mediaKeyStatus: mediaKeyStatus,
            mediaKeyMonitor: mediaKeyMonitor,
            shortcutsRegistry: shortcutsRegistry,
            sectionTarget: sectionTarget
        )
    }

    private var guidePage: some View {
        SettingsGuideView(onNavigate: { navigate(to: $0, location: $1) })
    }

    private var updatesPage: some View {
        UpdatesTab(
            sparkle: sparkleUpdateController,
            developerUpdates: developerUpdateManager
        )
    }

    private var aboutPage: some View {
        AboutTab(appSupport: appSupport)
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
    /// The location travels with the destination, so a result found here lands
    /// on the same heading the Guide's own "Take Me There" lands on.
    let onSelect: (SettingsDestination, String?) -> Void

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
        // The glass goes behind the row rather than around it: a `glassEffect`
        // island is composited by the window server and takes its content with
        // it, so wrapping the field would erase the magnifier, the placeholder
        // and whatever has been typed from every captured frame.
        .background {
            Color.clear.meloGlassSurface(
                cornerRadius: SettingsSearchField.fieldHeight / 2,
                interactive: true
            )
        }
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
        // Was an `NSVisualEffectView` with a `.menu` material and a hairline.
        // The results panel is the second half of the search bubble and should
        // be made of the same thing it is; on macOS 26 that is Liquid Glass, and
        // below it `meloGlassSurface` still resolves to a material and a
        // hairline, so nothing is lost on 15.4.
        .background {
            Color.clear.meloGlassSurface(cornerRadius: 14)
        }
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
        onSelect(destination(for: entry), entry.location)
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
