// Melo/Editor/Views/Stack/MoveStackEmptyState.swift
import SwiftUI

/// What the stack says when there is nothing on it, which for the least
/// knowledgeable user is most of the time.
///
/// It points **up**, at the destination picker, not at the add menu. The novice
/// path is "tell it where this is going"; being offered a compressor by name is
/// the moment that user decides this app is not for them. The add menu stays in
/// the header for anyone who came here to reach for one.
@MainActor
struct MoveStackEmptyState: View {
    enum Reason: Equatable {
        /// No sound open. Nothing to say about a stack yet.
        case noSource
        /// A sound, no destination. This is the one that matters.
        case noDestination
        /// Destination picked, measurement still running.
        case measuring
        /// Measured, and the proposer has moves waiting that nobody has applied
        /// yet. This is what the novice sees the moment they pick a destination,
        /// and it used to be reported as `nothingToFix` — the stack calling the
        /// file clean while the picker beside it offered eight moves.
        case readyToFix(moveCount: Int)
        /// Measured against a destination, and the proposer genuinely returned
        /// nothing. Only reachable by asking it.
        case nothingToFix(destination: String)
    }

    let reason: Reason

    var body: some View {
        VStack(spacing: DesignTokens.Spacing.xs2) {
            Image(systemName: symbol)
                .font(DesignTokens.Typography.Scale.title3(.regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(DesignTokens.Colors.textTertiary)
                .accessibilityHidden(true)

            Text(title)
                .font(DesignTokens.Typography.Scale.body(.medium))
                .foregroundStyle(DesignTokens.Colors.textSecondary)

            Text(detail)
                .font(DesignTokens.Typography.Scale.footnote())
                .foregroundStyle(DesignTokens.Colors.textTertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DesignTokens.Spacing.lg)
        .padding(.horizontal, DesignTokens.Spacing.sm)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title) \(detail)")
    }

    private var symbol: String {
        switch reason {
        case .noSource: "waveform"
        // Both of these used to be `arrow.up`, pointing at a picker that sat
        // directly above. The sidebar is an accordion now — one pane open at a
        // time — so when the stack is showing, that picker is collapsed behind
        // its header and an arrow points at a chevron. These say *what* to look
        // for instead of *where*, which survives the panes being rearranged
        // again.
        case .noDestination: "signpost.right"
        case .measuring: "waveform.badge.magnifyingglass"
        case .readyToFix: "wand.and.rays"
        case .nothingToFix: "checkmark.circle"
        }
    }

    private var title: String {
        switch reason {
        case .noSource: "Nothing open yet."
        case .noDestination: "Nothing here yet."
        // Was "Having a listen." — which is the same joke the analysis pane
        // already tells with "Still listening." One feature telling it twice in
        // two panes reads as a tic rather than as voice, and the plain word is
        // what a status line is for. The personality in this view is in
        // "Nothing here yet." and "Nothing to fix.", which are not duplicated
        // anywhere.
        case .measuring: "Measuring."
        case let .readyToFix(count):
            count == 1 ? "1 move ready." : "\(count) moves ready."
        case .nothingToFix: "Nothing to fix."
        }
    }

    /// Names the section a reader has to open, never a direction to look in.
    ///
    /// The accordion keeps all three headers on screen at all times and expands
    /// whichever one is clicked, so a section *title* is a reliable landmark
    /// where "above" is not. The title is read off `SidebarSection` rather than
    /// retyped, so renaming that pane carries this copy with it.
    private var detail: String {
        switch reason {
        case .noSource:
            return "Open a sound and this fills in."
        case .noDestination:
            // Ends on the pane's own question, which is also the sentence's.
            return "Melo fills this in once you answer \(Self.destinationPane)"
        case .measuring:
            return "Checking this file against where it's headed."
        case .readyToFix:
            return "Fix it for me is under \(Self.destinationPane)"
        case let .nothingToFix(destination):
            return "This one already lands where \(destination) wants it."
        }
    }

    /// The destination pane's name, ready to end a sentence.
    ///
    /// It reads "Where's it going?" today, so a sentence naming it needs no
    /// full stop of its own — and adding one would print "?." If that title
    /// ever stops carrying its own punctuation, this supplies the terminator
    /// instead of leaving the sentence hanging.
    private static var destinationPane: String {
        let title = CuttingRoomRootView.SidebarSection.destination.title
        let alreadyTerminated = title.hasSuffix("?") || title.hasSuffix(".") || title.hasSuffix("!")
        return alreadyTerminated ? title : title + "."
    }
}
