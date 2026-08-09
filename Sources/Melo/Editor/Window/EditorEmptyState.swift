import SwiftUI

/// The first screen, and the one that decides whether someone who has never used
/// an audio editor stays.
///
/// Four ways in, each named by what it does rather than by what it is, and each
/// with one line saying what comes out. No explanation of what an editor is, no
/// tour, no "get started" that starts nothing. The window is also a drop target
/// everywhere, so the fifth way in is the one people try first without being
/// told — that is what the second line is for.
///
/// Knows nothing about how any of it works: five closures and a list.
@MainActor
struct EditorEmptyState: View {
    let onOpenFile: () -> Void
    let onPasteLink: () -> Void
    let onRecord: () -> Void
    let onRemixTheme: () -> Void
    let onOpenRecent: (EditorRecent) -> Void

    @ObservedObject private var recents: EditorRecents

    /// `onOpenRecent` and `recents` are defaulted so existing four-closure call
    /// sites still compile unchanged.
    init(
        onOpenFile: @escaping () -> Void,
        onPasteLink: @escaping () -> Void,
        onRecord: @escaping () -> Void,
        onRemixTheme: @escaping () -> Void,
        onOpenRecent: @escaping (EditorRecent) -> Void = { _ in },
        recents: EditorRecents = .shared
    ) {
        self.onOpenFile = onOpenFile
        self.onPasteLink = onPasteLink
        self.onRecord = onRecord
        self.onRemixTheme = onRemixTheme
        self.onOpenRecent = onOpenRecent
        _recents = ObservedObject(wrappedValue: recents)
    }

    /// Wide enough for two cards side by side and narrow enough that the copy is
    /// still one comfortable measure at a 1400pt window width.
    private static let columnWidth: CGFloat = 620

    var body: some View {
        // Centred while it fits, scrolls when it does not. At the 520pt minimum
        // window height with five recents showing, it does not fit — and a first
        // screen with its fourth option below a hard clip is the specific failure
        // this screen exists to avoid.
        GeometryReader { geometry in
            ScrollView {
                content
                    .frame(maxWidth: Self.columnWidth)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, DesignTokens.Spacing.xxl)
                    .padding(.vertical, DesignTokens.Spacing.xl)
                    .frame(minHeight: geometry.size.height)
            }
            .scrollIndicators(.automatic)
        }
    }

    private var content: some View {
        VStack(spacing: DesignTokens.Spacing.xl) {
            EditorMark(size: 68)
                .meloElevation(DesignTokens.Elevation.card)

            VStack(spacing: DesignTokens.Spacing.xs2) {
                Text("Bring me a sound.")
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .accessibilityAddTraits(.isHeader)

                Text("Drop a file anywhere in this window, or start one of these.")
                    .font(DesignTokens.Typography.Scale.body())
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Two independent conditions in one block, so the note sits tight
            // under the list it qualifies rather than a full column gap away.
            // Independent because the folder can hold more than the five rows
            // the list shows, and can hold a recording after the list has been
            // forgotten — someone hunting for audio they made needs the route
            // in both cases.
            if !recents.visible.isEmpty || recents.hasKeptSources {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                    if !recents.visible.isEmpty {
                        recentsList
                    }
                    if recents.hasKeptSources {
                        keptSourcesNote
                    }
                }
            }

            entryGrid
        }
    }

    // MARK: - Recents

    private var recentsList: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
            SectionHeader(title: "Recent")
                .padding(.horizontal, DesignTokens.Spacing.sm)
                .padding(.bottom, DesignTokens.Spacing.xxs)

            ForEach(recents.visible) { recent in
                Button {
                    onOpenRecent(recent)
                } label: {
                    HStack(spacing: DesignTokens.Spacing.sm) {
                        Image(systemName: recent.kind.symbolName)
                            .font(DesignTokens.Typography.Scale.body())
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(DesignTokens.Colors.textSecondary)
                            .accessibilityHidden(true)

                        Text(recent.displayName)
                            .font(DesignTokens.Typography.Scale.headline(.medium))
                            .lineLimit(1)
                            .truncationMode(.middle)

                        Spacer(minLength: DesignTokens.Spacing.sm)

                        Text(detail(for: recent))
                            .font(DesignTokens.Typography.Scale.caption())
                            .monospacedDigit()
                            .foregroundStyle(DesignTokens.Colors.textTertiary)
                            .lineLimit(1)
                    }
                    .frame(minHeight: DesignTokens.Dimensions.minTouchTarget)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // Flat at rest, hover is the signal — the same rows the popup
                // and Settings draw.
                .hoverableRow()
                // Costs no pixels and is where a Mac user already looks for
                // "where is this actually". Both verbs are deliberately mild:
                // Forget drops the row, nothing deletes audio.
                .contextMenu {
                    Button("Show in Finder") { recents.reveal(recent) }
                    Button("Forget This One") { recents.forget(recent) }
                }
                .accessibilityLabel("Open \(recent.displayName)")
                .accessibilityHint(detail(for: recent))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One line, and only for people who have something in the folder.
    ///
    /// Recordings and link audio now live in `EditorSourceStore.directory`
    /// permanently — nothing prunes it, by decision — so the user needs a way to
    /// reach their own audio. It says "keeps" rather than anything cache-shaped
    /// because that is the whole point of the change: this is their recording,
    /// not Melo's scratch space.
    ///
    /// Caption weight, below the list, and absent entirely for anyone who has
    /// only ever opened files. It must not read as a fifth way in — the four
    /// cards are why someone is on this screen.
    private var keptSourcesNote: some View {
        HStack(spacing: DesignTokens.Spacing.xs2) {
            Text("Melo keeps your recordings and link audio.")
                .font(DesignTokens.Typography.Scale.caption())
                .foregroundStyle(DesignTokens.Colors.textTertiary)

            Button("Show in Finder") {
                recents.revealKeptSources()
            }
            .buttonStyle(.meloHover)
            .font(DesignTokens.Typography.Scale.caption(.medium))
            .foregroundStyle(DesignTokens.Colors.interactiveDefault)
            .frame(minHeight: DesignTokens.Dimensions.minTouchTarget)
            .contentShape(Rectangle())

            Spacer(minLength: 0)
        }
        .padding(.horizontal, DesignTokens.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func detail(for recent: EditorRecent) -> String {
        "\(recent.formatDescription) · \(EditorFormat.timecode(recent.duration))"
    }

    // MARK: - The four ways in

    private var entryGrid: some View {
        LazyVGrid(
            columns: [
                GridItem(.flexible(), spacing: DesignTokens.Spacing.md),
                GridItem(.flexible(), spacing: DesignTokens.Spacing.md)
            ],
            spacing: DesignTokens.Spacing.md
        ) {
            EntryCard(
                symbol: "folder",
                title: "Open a file",
                blurb: "Whatever your Mac can already play.",
                action: onOpenFile
            )
            EntryCard(
                symbol: "link",
                title: "Paste a link",
                blurb: "Take the sound off a page.",
                action: onPasteLink
            )
            EntryCard(
                symbol: "record.circle",
                title: "Record this Mac",
                blurb: "Catch what’s playing right now.",
                action: onRecord
            )
            EntryCard(
                symbol: "music.quarternote.3",
                title: "Remix the theme",
                blurb: "Melo’s own song. Go on.",
                action: onRemixTheme
            )
        }
    }
}

/// A card, not a row — so unlike a row it carries a resting surface. The lifted
/// card is the same treatment Settings sections and the EQ panel use, which is
/// what makes four of them read as a set of doors rather than four labels
/// floating on the glass.
private struct EntryCard: View {
    let symbol: String
    let title: String
    let blurb: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs2) {
                Image(systemName: symbol)
                    .font(.system(size: 18, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Color.accentColor)
                    .frame(height: 22)
                    .accessibilityHidden(true)

                Text(title)
                    .font(DesignTokens.Typography.Scale.headline())
                    .foregroundStyle(DesignTokens.Colors.textPrimary)

                Text(blurb)
                    .font(DesignTokens.Typography.Scale.footnote())
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(DesignTokens.Spacing.md)
            .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
            .background {
                DesignTokens.Dimensions.Shape.md
                    .fill(isHovered ? DesignTokens.Colors.hoverSurface : Color.clear)
            }
            .background {
                DesignTokens.Dimensions.Shape.md
                    .fill(DesignTokens.Colors.eqCardBackground)
            }
            .overlay {
                DesignTokens.Dimensions.Shape.md
                    .strokeBorder(DesignTokens.Colors.eqCardBorder, lineWidth: 0.5)
            }
            .meloElevation(DesignTokens.Elevation.card)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(DesignTokens.Animation.hover, value: isHovered)
        // The title is the whole label; the blurb is what it gets you, which is
        // a hint. Same split the command palette uses.
        .accessibilityLabel(title)
        .accessibilityHint(blurb)
    }
}
