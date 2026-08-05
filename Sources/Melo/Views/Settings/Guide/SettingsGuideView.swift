import SwiftUI

@MainActor
struct SettingsGuideView: View {
    /// Switches the enclosing Settings window to another tab. Defaulted so the
    /// view still stands alone in previews.
    var onNavigate: (SettingsDestination) -> Void = { _ in }

    @State private var searchText = ""
    @State private var selectedCategory: SettingsGuideCategory?
    @FocusState private var searchFocused: Bool

    private var trimmedQuery: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var entries: [SettingsGuideEntry] {
        let scoped = SettingsGuideEntry.all.filter {
            selectedCategory == nil || $0.category == selectedCategory
        }
        guard !trimmedQuery.isEmpty else { return scoped }
        // A guide that answers "volume" with forty topics has not answered
        // anything. `rank` keeps only results close to the best one.
        return IntentSearch.rank(scoped, limit: 12) { $0.searchScore(trimmedQuery) }
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
            Text("Melo Guide")
                .font(.system(size: 23, weight: .semibold, design: .rounded))
            Text("Search by feature, problem, or what you want Melo to do.")
                .font(DesignTokens.Typography.Scale.body())
                .foregroundStyle(.secondary)
        }
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
        .frame(height: 38)
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
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var resultList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: DesignTokens.Spacing.sm2) {
                ForEach(entries) { entry in
                    guideCard(entry)
                }
            }
            .padding(.bottom, DesignTokens.Spacing.xl)
        }
        .scrollIndicators(.never)
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
            }
            .foregroundStyle(selected ? Color.primary : Color.secondary)
            .padding(.horizontal, DesignTokens.Spacing.sm2)
            .frame(height: 34)
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

    private func guideCard(_ entry: SettingsGuideEntry) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs2) {
            HStack(alignment: .firstTextBaseline) {
                Text(entry.title)
                    .font(DesignTokens.Typography.Scale.headline())
                Spacer()
                Text(entry.category.rawValue)
                    .font(DesignTokens.Typography.Scale.caption2(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(DesignTokens.Colors.glassFillStrong))
            }
            Text(entry.summary)
                .font(DesignTokens.Typography.Scale.body())
            if !entry.details.isEmpty {
                Text(entry.details)
                    .font(DesignTokens.Typography.Scale.footnote())
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let destination = entry.destination {
                showMeButton(destination)
            }
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignTokens.Dimensions.Shape.md.fill(DesignTokens.Colors.glassFill))
        .overlay(
            DesignTokens.Dimensions.Shape.md
                .strokeBorder(DesignTokens.Colors.glassRowBorder, lineWidth: 0.5)
        )
    }

    /// Reading what a setting does and then having to hunt for it is the point
    /// at which a guide stops being help. Entries that name a real control take
    /// the reader to it.
    private func showMeButton(_ destination: SettingsDestination) -> some View {
        Button {
            onNavigate(destination)
        } label: {
            HStack(spacing: DesignTokens.Spacing.xs) {
                Text("Show me")
                Image(systemName: "arrow.forward")
                    .font(DesignTokens.Typography.Scale.caption2(.semibold))
            }
            .font(DesignTokens.Typography.Scale.footnote(.medium))
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, DesignTokens.Spacing.sm2)
            .frame(height: 24)
            .background(DesignTokens.Dimensions.Shape.sm.fill(Color.accentColor.opacity(0.12)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, DesignTokens.Spacing.xxs)
        .accessibilityLabel("Show me in \(destination.tabTitle)")
        .help("Open \(destination.tabTitle)")
    }

    private func symbol(for category: SettingsGuideCategory) -> String {
        switch category {
        case .gettingStarted: return "sparkles"
        case .everyday: return "house"
        case .general: return "gearshape"
        case .volume: return "speaker.wave.2"
        case .apps: return "square.stack.3d.up"
        case .devices: return "hifispeaker.2"
        case .sound: return "waveform"
        case .shortcuts: return "command"
        case .privacy: return "hand.raised"
        }
    }
}
