import SwiftUI

@MainActor
struct SettingsGuideView: View {
    /// Switches the enclosing Settings window to another tab. Defaulted so the
    /// view still stands alone in previews.
    /// Switches tab, and carries the entry's location so the window can keep
    /// pointing at the section after the guide text is off screen.
    var onNavigate: (SettingsDestination, String?) -> Void = { _, _ in }

    @State private var searchText: String
    @State private var selectedCategory: SettingsGuideCategory?
    @FocusState private var searchFocused: Bool

    init(
        onNavigate: @escaping (SettingsDestination, String?) -> Void = { _, _ in },
        initialQuery: String = ""
    ) {
        self.onNavigate = onNavigate
        _searchText = State(initialValue: initialQuery)
    }

    private var trimmedQuery: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isSearching: Bool { !trimmedQuery.isEmpty }

    private var entries: [SettingsGuideEntry] {
        let scoped = SettingsGuideEntry.all.filter {
            selectedCategory == nil || $0.category == selectedCategory
        }
        guard isSearching else { return scoped }
        // A guide that answers "volume" with forty topics has not answered
        // anything. `rank` keeps only results close to the best one.
        return IntentSearch.rank(scoped, limit: 12) { $0.searchScore(trimmedQuery) }
    }

    /// Browsing the whole catalog is reading, not searching, so it is presented
    /// as a document with headed sections. A single undivided run of eighty-odd
    /// cards is the thing that reads as filler regardless of what is in them.
    private var sections: [(category: SettingsGuideCategory, entries: [SettingsGuideEntry])] {
        let grouped = Dictionary(grouping: entries, by: \.category)
        return SettingsGuideCategory.allCases.compactMap { category in
            guard let matches = grouped[category], !matches.isEmpty else { return nil }
            return (category, matches)
        }
    }

    private var isGrouped: Bool { !isSearching && selectedCategory == nil }

    private func count(for category: SettingsGuideCategory?) -> Int {
        guard let category else { return SettingsGuideEntry.all.count }
        return SettingsGuideEntry.all.filter { $0.category == category }.count
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            content
        }
        .background(.ultraThinMaterial.opacity(0.34))
    }

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                categoryButton(
                    title: "All Topics",
                    symbol: "text.book.closed",
                    category: nil
                )

                ForEach(SettingsGuideCategory.allCases) { category in
                    categoryButton(
                        title: category.rawValue,
                        symbol: symbol(for: category),
                        category: category
                    )
                }
            }
            .padding(DesignTokens.Spacing.sm2)
        }
        .scrollIndicators(.never)
        .frame(minWidth: 188, idealWidth: 204, maxWidth: 220, maxHeight: .infinity)
        .background(DesignTokens.Colors.glassFill.opacity(0.56))
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.lg) {
            header
            searchField

            if entries.isEmpty {
                emptyState
            } else {
                resultList
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(selectedCategory?.rawValue ?? "Melo Guide")
                .font(.system(size: 23, weight: .semibold, design: .rounded))
            Text(subtitle)
                .font(DesignTokens.Typography.Scale.body())
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var subtitle: String {
        if isSearching {
            let found = entries.count
            return found == 1 ? "1 topic matches “\(trimmedQuery)”" : "\(found) topics match “\(trimmedQuery)”"
        }
        if let selectedCategory {
            return "\(count(for: selectedCategory)) topics in \(selectedCategory.rawValue)."
        }
        return "\(SettingsGuideEntry.all.count) topics. Search by feature, by problem, or by what you want Melo to do."
    }

    private var searchField: some View {
        HStack(spacing: DesignTokens.Spacing.sm2) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Try “keep Spotify visible” or “quieter calls”", text: $searchText)
                .textFieldStyle(.plain)
                .focused($searchFocused)
            if !searchText.isEmpty {
                Button("Clear", systemImage: "xmark.circle.fill") {
                    searchText = ""
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, DesignTokens.Spacing.md)
        .frame(minHeight: 38)
        // The same bubble as the Settings search field above it, made of the
        // same glass. Behind the row rather than around it, so the window server
        // does not composite the query away — see `SettingsSearchField.field`.
        .background {
            Color.clear.meloGlassSurface(cornerRadius: 19, interactive: true)
        }
    }

    private var emptyState: some View {
        VStack(spacing: DesignTokens.Spacing.sm) {
            Image(systemName: "questionmark.bubble")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(.tertiary)
            Text("No close match")
                .font(DesignTokens.Typography.Scale.headline())
            Text("Try a simpler phrase, such as “mute an app,” “headphones,” or “updates.”")
                .font(DesignTokens.Typography.Scale.footnote())
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            if selectedCategory != nil {
                Button("Search all topics") {
                    withAnimation(DesignTokens.Animation.quick) { selectedCategory = nil }
                }
                .buttonStyle(.link)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var resultList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if isGrouped {
                    ForEach(sections, id: \.category) { section in
                        Section {
                            ForEach(Array(section.entries.enumerated()), id: \.element.id) { index, entry in
                                guideEntry(
                                    entry,
                                    showsCategory: false,
                                    showsRule: index < section.entries.count - 1
                                )
                            }
                        } header: {
                            sectionHeader(section.category, count: section.entries.count)
                        }
                    }
                } else {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        guideEntry(
                            entry,
                            showsCategory: isSearching,
                            showsRule: index < entries.count - 1
                        )
                    }
                }
            }
            .padding(.bottom, DesignTokens.Spacing.xl)
        }
        .scrollIndicators(.never)
    }

    /// Deliberately not a pinned header: pinning forces an opaque backing, and
    /// an opaque bar drawn over a translucent Settings pane reads as a seam
    /// rather than as a heading.
    private func sectionHeader(_ category: SettingsGuideCategory, count: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: DesignTokens.Spacing.xs) {
                Image(systemName: symbol(for: category))
                    .font(DesignTokens.Typography.Scale.caption(.semibold))
                Text(category.rawValue.uppercased())
                    .font(DesignTokens.Typography.Scale.caption(.semibold))
                    .kerning(0.6)
                Text("\(count)")
                    .font(DesignTokens.Typography.Scale.caption2(.medium))
                    .foregroundStyle(.tertiary)
                Spacer(minLength: DesignTokens.Spacing.xs)
            }
            .foregroundStyle(Color.accentColor)
            .padding(.top, DesignTokens.Spacing.lg)
            .padding(.bottom, DesignTokens.Spacing.xs)

            Rectangle()
                .fill(DesignTokens.Colors.glassRowBorderHover)
                .frame(height: 1)
        }
        .accessibilityAddTraits(.isHeader)
    }

    private func categoryButton(
        title: String,
        symbol: String,
        category: SettingsGuideCategory?
    ) -> some View {
        let selected = selectedCategory == category
        return Button {
            withAnimation(DesignTokens.Animation.quick) {
                selectedCategory = category
            }
        } label: {
            HStack(spacing: 9) {
                Image(systemName: symbol)
                    .font(DesignTokens.Typography.Scale.body(.semibold))
                    .frame(width: 18)
                Text(title)
                    .font(DesignTokens.Typography.Scale.body(selected ? .semibold : .medium))
                    .lineLimit(1)
                Spacer(minLength: DesignTokens.Spacing.xs)
                Text("\(count(for: category))")
                    .font(DesignTokens.Typography.Scale.caption2(.medium))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            .foregroundStyle(selected ? Color.primary : Color.secondary)
            .padding(.horizontal, DesignTokens.Spacing.sm2)
            .frame(minHeight: 34)
            // Left as an accent fill rather than made glass like the tab bar's
            // selection bubble. Glass here renders as nothing at all in a layer
            // capture, and this pill is the only thing in the sidebar that says
            // which category is showing — trading the one selection cue every
            // frame can see for a finish no frame can see is not a trade worth
            // making on a surface the owner did not name.
            .background {
                if selected {
                    DesignTokens.Dimensions.Shape.sm
                        .fill(Color.accentColor.opacity(0.16))
                        .overlay(
                            DesignTokens.Dimensions.Shape.sm
                                .strokeBorder(Color.accentColor.opacity(0.25), lineWidth: 0.5)
                        )
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// Entries are laid out as a document — headed sections, a rule between
    /// topics — rather than as a stack of bordered cards. `glassFill` and
    /// `glassRowBorder` both resolve to `.clear`, so the cards this used to draw
    /// were invisible chrome: eighty identical blocks of text with no structure.
    private func guideEntry(
        _ entry: SettingsGuideEntry,
        showsCategory: Bool,
        showsRule: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs2) {
            HStack(alignment: .firstTextBaseline) {
                Text(entry.title)
                    .font(DesignTokens.Typography.Scale.headline())
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: DesignTokens.Spacing.xs)
                if showsCategory {
                    Text(entry.category.rawValue)
                        .font(DesignTokens.Typography.Scale.caption2(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(DesignTokens.Colors.glassFillStrong))
                }
            }
            Text(entry.summary)
                .font(DesignTokens.Typography.Scale.body())
                .fixedSize(horizontal: false, vertical: true)
            if !entry.details.isEmpty {
                Text(entry.details)
                    .font(DesignTokens.Typography.Scale.footnote())
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if entry.location != nil || entry.hasRoute {
                HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.sm) {
                    if let location = entry.location {
                        locationLine(location)
                    }
                    // Three routes, and no entry carries two — see
                    // `SettingsGuideEntry.opensCuttingRoom`. The order below is
                    // therefore a reading order, not a precedence rule.
                    if entry.showsInPopup {
                        showInPopupButton(entry)
                    } else if entry.opensCuttingRoom {
                        openCuttingRoomButton()
                    } else if let destination = entry.destination {
                        showMeButton(destination, location: entry.location)
                    }
                }
                .padding(.top, DesignTokens.Spacing.xxs)
            }

            if showsRule {
                Rectangle()
                    .fill(DesignTokens.Colors.glassRowBorderHover.opacity(0.6))
                    .frame(height: 1)
                    .padding(.top, DesignTokens.Spacing.md)
            }
        }
        .padding(.top, DesignTokens.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Most of Melo's controls are in the menu bar popup, where there is no tab
    /// to send anyone to. Naming the path is the difference between explaining a
    /// control and explaining a control the reader still cannot find.
    private func locationLine(_ location: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            // A path through the interface, not a place on a map:
            // `mappin.and.ellipse` is the glyph macOS uses for a geographic
            // location, and this line reads "Melo popup › Apps".
            Image(systemName: "arrow.turn.down.right")
                .font(DesignTokens.Typography.Scale.caption2())
                .foregroundStyle(.tertiary)
            Text(location)
                .font(DesignTokens.Typography.Scale.footnote())
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Found in \(location)")
    }

    /// Reading what a setting does and then having to hunt for it is the point
    /// at which a guide stops being help. Entries that name a real control take
    /// the reader to it.
    ///
    /// The location string travels with the destination because the tab is only
    /// half an address — Audio holds six sections. `SettingsRootView` reads the
    /// section out of it and the tab scrolls there, so "Take Me There" ends with
    /// the heading this entry names at the top of the window.
    ///
    /// Deliberately *not* "Show Me". That label belongs to the guided-tour
    /// overlay, and all three of its entry points now use it verbatim. This
    /// button does something else entirely — it moves the Settings window — and
    /// while it read "Show me" the only thing separating the two actions was a
    /// capital M. "There" is the location line immediately to its left, which
    /// already spells out the whole address.
    private func showMeButton(_ destination: SettingsDestination, location: String?) -> some View {
        actionChip(
            title: "Take Me There",
            symbol: "arrow.forward",
            accessibilityLabel: "Take me to \(destination.tabTitle)",
            help: "Open \(destination.tabTitle)"
        ) {
            onNavigate(destination, location)
        }
    }

    /// Two thirds of the catalog describes controls in the menu bar popup, which
    /// no Settings tab can display. Rather than leave those entries with nothing
    /// to press, this opens the popup and spotlights the control through the same
    /// overlay the guided tour uses.
    ///
    /// "Show Me", verbatim, because it *is* that overlay: this, the end of
    /// first-run setup, and What's New all call `guidedTour.begin` and then
    /// `popupController.toggle()` across the same 0.35s handoff. Naming the
    /// destination in the button — "Show me in Melo" — said in the label what
    /// `help:` and the accessibility label below already say, and left one
    /// action wearing three names.
    private func showInPopupButton(_ entry: SettingsGuideEntry) -> some View {
        actionChip(
            title: "Show Me",
            symbol: "arrow.up.forward.app",
            accessibilityLabel: "Show \(entry.title) in the Melo popup",
            help: "Open the Melo popup and point at this control"
        ) {
            NotificationCenter.default.post(
                name: .meloShowControlInPopup,
                object: entry.spotlightRequest
            )
        }
    }

    /// The third route, and the only one that leaves Settings for a window of
    /// Melo's own.
    ///
    /// The other two both had somewhere to send a reader: a Settings tab, or
    /// the menu bar popup through the tour overlay. The Cutting Room is neither,
    /// and `SettingsDestination` maps one-to-one by raw value onto
    /// `SettingsRootView.Section`, so it cannot be reached by inventing a
    /// destination without inventing a Settings tab to go with it. Sixteen
    /// topics that describe a window and cannot open it would be the exact
    /// thing this project's anchor calls a stub that looks like a feature.
    ///
    /// A direct call rather than the notification `showInPopupButton` posts.
    /// That one has to be posted because `SettingsRootView` is built by
    /// `FineTuneApp` and cannot be handed the popup controller or the tour
    /// coordinator; `CuttingRoomWindowController` is a singleton, so the call
    /// is available here and is checked by the compiler. A notification would
    /// need an observer registered somewhere at launch, and a button whose
    /// wiring can go missing without the build noticing is the failure mode
    /// this route exists to avoid.
    ///
    /// "Open the Cutting Room", not "Take Me There" — that label belongs to
    /// moving the Settings window, and this opens a different window — and not
    /// "Show Me", which is the tour overlay's, verbatim, in three places.
    private func openCuttingRoomButton() -> some View {
        actionChip(
            title: "Open the \(SettingsGuideEntry.cuttingRoomTitle)",
            symbol: "scissors",
            accessibilityLabel: "Open the \(SettingsGuideEntry.cuttingRoomTitle)",
            help: "Open Melo’s audio editor"
        ) {
            CuttingRoomWindowController.shared.show()
        }
    }

    private func actionChip(
        title: String,
        symbol: String,
        accessibilityLabel: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: DesignTokens.Spacing.xs) {
                Text(title)
                Image(systemName: symbol)
                    .font(DesignTokens.Typography.Scale.caption2(.semibold))
            }
            .font(DesignTokens.Typography.Scale.footnote(.medium))
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, DesignTokens.Spacing.sm2)
            .frame(minHeight: 24)
            // An accent fill, not glass, and measured rather than chosen.
            //
            // This chip was glass for one render. Every entry in the catalog
            // carries one, they are laid out in a `LazyVStack` inside a
            // `ScrollView`, and the chip has no definite width — and the
            // resulting islands unioned into a single surface the size of the
            // whole result list. `settings-guide.png` came back with the entire
            // catalog gone and only a section header left standing;
            // `settings-guide-search.png` lost the entry's title, category,
            // summary and location line and kept nothing but this chip's own
            // label. The two glass surfaces in this file that *are* safe — the
            // search field here and the results panel in `SettingsRootView` —
            // are each a single island with a definite frame.
            .background(DesignTokens.Dimensions.Shape.sm.fill(Color.accentColor.opacity(0.12)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .help(help)
    }

    private func symbol(for category: SettingsGuideCategory) -> String {
        switch category {
        case .gettingStarted: return "sparkles"
        case .everyday: return "house"
        case .general: return "gearshape"
        case .volume: return "speaker.wave.2"
        // Not `square.stack.3d.up`: its other three uses in this app all mean
        // Scenes — the popup menu, the Everyday tab, and the entry Melo
        // registers with the Shortcuts app, which puts it beyond Melo's reach to
        // change. One glyph cannot mean both a saved setup and the app list.
        case .apps: return "square.grid.2x2"
        case .devices: return "hifispeaker.2"
        case .sound: return "waveform"
        // `scissors` against the rule above, and the difference is worth
        // stating. `square.stack.3d.up` was refused because it would have
        // meant two *unrelated* things — a saved setup and the app list —
        // in surfaces a reader meets together. `scissors` already means two
        // things, but they are a container and its contents: the Cutting Room
        // (the popup's button at `MenuBarPopupView:565`, the palette's
        // "Open the Cutting Room", the Everyday section) and the trim move
        // inside it (`MoveKindDisplay:36`, `AddMoveMenu:29`). The two are never
        // on screen together, and every door into the window already wears
        // this glyph, so a different one here would be the inconsistency.
        // Nothing else in this sidebar uses it, and `waveform` — the obvious
        // alternative — is Sound's, one row above.
        case .cuttingRoom: return "scissors"
        case .shortcuts: return "command"
        case .privacy: return "hand.raised"
        }
    }
}
