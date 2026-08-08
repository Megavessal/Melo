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
        .background(DesignTokens.Dimensions.Shape.md.fill(DesignTokens.Colors.glassFillStrong))
        .overlay(
            DesignTokens.Dimensions.Shape.md
                .strokeBorder(DesignTokens.Colors.glassRowBorder, lineWidth: 0.5)
        )
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
            if entry.location != nil || entry.destination != nil || entry.showsInPopup {
                HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.sm) {
                    if let location = entry.location {
                        locationLine(location)
                    }
                    if entry.showsInPopup {
                        showInPopupButton(entry)
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
    /// section out of it and the tab scrolls there, so "Show me" ends with the
    /// heading this entry names at the top of the window.
    private func showMeButton(_ destination: SettingsDestination, location: String?) -> some View {
        actionChip(
            title: "Show me",
            symbol: "arrow.forward",
            accessibilityLabel: "Show me in \(destination.tabTitle)",
            help: "Open \(destination.tabTitle)"
        ) {
            onNavigate(destination, location)
        }
    }

    /// Two thirds of the catalog describes controls in the menu bar popup, which
    /// no Settings tab can display. Rather than leave those entries with nothing
    /// to press, this opens the popup and spotlights the control through the same
    /// overlay the guided tour uses.
    private func showInPopupButton(_ entry: SettingsGuideEntry) -> some View {
        actionChip(
            title: "Show me in Melo",
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
        case .shortcuts: return "command"
        case .privacy: return "hand.raised"
        }
    }
}
