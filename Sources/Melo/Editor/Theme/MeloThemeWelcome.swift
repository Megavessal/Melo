// Melo/Editor/Theme/MeloThemeWelcome.swift
//
// What Melo Edit says the first time it opens on Melo's own theme, and
// the four one-tap starts underneath it.
//
// Shown once and then never again: it is bound to the stack being empty, so
// pressing any starter dismisses it by making the condition false. There is no
// preference to remember and nothing to forget.

import SwiftUI

/// The welcome, bound to the store. Renders nothing unless the open document is
/// the theme and nothing has been done to it yet.
@MainActor
struct MeloThemeWelcome: View {
    @ObservedObject var store: EditorStore
    @State private var isDismissed = false

    init(store: EditorStore) {
        self.store = store
    }

    private var themeDocument: EditorDocument? {
        guard let document = store.document,
              document.source.origin == .meloTheme,
              document.moves.isEmpty
        else { return nil }
        return document
    }

    var body: some View {
        if let document = themeDocument, !isDismissed {
            MeloThemeWelcomeCard(
                themeDuration: document.source.duration,
                onStart: start(_:),
                onDismiss: { isDismissed = true }
            )
            .transition(.opacity)
            .animation(DesignTokens.Animation.hover, value: isDismissed)
        }
    }

    /// A starter lands as **one** undo step, via `replaceMoves`.
    ///
    /// The alternative was `apply` per move, which is the store's natural grain
    /// and peels the starter back a move at a time. Two things decided it
    /// against that. First, this piece's whole promise is that a novice cannot
    /// hurt anything, and "press one thing, press ⌘Z, you are back where you
    /// started" is that promise kept literally — with four `apply`s the middle
    /// of the peel is a state no starter produced, where the user has undone
    /// the thing and it still sounds wrong. Second, the argument for fine
    /// grain was that peeling teaches the stack, and it does not: the stack
    /// inspector already teaches it *better*, because `setEnabled` switches a
    /// single move off in place, visibly, by name, reversibly, and without
    /// spending an undo. A blind ⌘Z is the worse version of a control that
    /// exists. It also makes a starter behave exactly like a destination
    /// proposal, which uses `replaceMoves` for the same reason.
    ///
    /// Appending to whatever is on the stack rather than assuming it is empty:
    /// the guard above means it always is, and building the array this way
    /// means a stale frame cannot turn one press into a discarded edit.
    private func start(_ starter: MeloThemeStarter) {
        guard let live = store.document else { return }
        store.replaceMoves(live.moves + starter.moves(forThemeOfLength: live.source.duration))
    }
}

/// The card itself, with no store in it, so it can be rendered in a snapshot
/// scene from a duration alone — the harness never plays audio and should not
/// need any to see this.
@MainActor
struct MeloThemeWelcomeCard: View {
    let themeDuration: TimeInterval
    let onStart: (MeloThemeStarter) -> Void
    let onDismiss: () -> Void

    init(themeDuration: TimeInterval,
         onStart: @escaping (MeloThemeStarter) -> Void,
         onDismiss: @escaping () -> Void) {
        self.themeDuration = themeDuration
        self.onStart = onStart
        self.onDismiss = onDismiss
    }

    private let columns = [
        GridItem(.adaptive(minimum: 210), spacing: DesignTokens.Spacing.sm)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            header
            LazyVGrid(columns: columns, spacing: DesignTokens.Spacing.sm) {
                ForEach(MeloThemeStarter.allCases) { starter in
                    starterTile(starter)
                }
            }
        }
        .padding(DesignTokens.Spacing.lg)
        // Glass in the background, never wrapped around the content — an island
        // is composited by the window server and takes its content with it.
        .background {
            Color.clear.meloGlassSurface(cornerRadius: 14)
        }
        .meloElevation(DesignTokens.Elevation.card)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.sm2) {
            Image(systemName: "music.note")
                .font(DesignTokens.Typography.Scale.title3())
                .foregroundStyle(DesignTokens.Colors.accentPrimary)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                Text("Melo's theme, on the table")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(DesignTokens.Colors.textPrimary)
                Text("Ninety seconds of boom-bap, copied so you can't hurt the original. Start anywhere.")
                    .font(DesignTokens.Typography.Scale.footnote())
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: DesignTokens.Spacing.sm)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(DesignTokens.Typography.Scale.caption(.semibold))
                    .foregroundStyle(DesignTokens.Colors.textTertiary)
                    .frame(
                        width: DesignTokens.Dimensions.minTouchTarget,
                        height: DesignTokens.Dimensions.minTouchTarget
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.meloHover)
            .accessibilityLabel("Dismiss the theme welcome")
        }
    }

    private func starterTile(_ starter: MeloThemeStarter) -> some View {
        Button {
            onStart(starter)
        } label: {
            HStack(alignment: .top, spacing: DesignTokens.Spacing.sm) {
                Image(systemName: starter.symbolName)
                    .font(DesignTokens.Typography.Scale.body())
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
                    .frame(width: DesignTokens.Dimensions.iconSizeSmall)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                    Text(starter.title)
                        .font(DesignTokens.Typography.Scale.headline())
                        .foregroundStyle(DesignTokens.Colors.textPrimary)
                    Text(starter.blurb)
                        .font(DesignTokens.Typography.Scale.caption())
                        .foregroundStyle(DesignTokens.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    // Says a stack is coming before they press, which is the
                    // whole point of the starters: the result is inspectable.
                    Text(starter.moveCountLabel(forThemeOfLength: themeDuration))
                        .font(DesignTokens.Typography.Scale.caption2())
                        .monospacedDigit()
                        .foregroundStyle(DesignTokens.Colors.textTertiary)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, DesignTokens.Spacing.sm2)
            .padding(.vertical, DesignTokens.Spacing.sm)
            .frame(minHeight: DesignTokens.Dimensions.minTouchTarget, alignment: .topLeading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.meloHover)
        .accessibilityLabel("\(starter.title). \(starter.blurb)")
        .accessibilityHint("Adds \(starter.moveCountLabel(forThemeOfLength: themeDuration)) to the stack.")
    }
}

#Preview("Theme welcome") {
    MeloThemeWelcomeCard(
        themeDuration: MeloThemeRemix.measuredDuration,
        onStart: { _ in },
        onDismiss: {}
    )
    .padding(DesignTokens.Spacing.xl)
    .frame(width: 660)
}
