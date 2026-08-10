// Melo/Editor/Analysis/DestinationPicker.swift
import SwiftUI

/// Where the sound is going, and the one button the least-knowledgeable user
/// ever has to press.
///
/// The list is `DestinationCatalogue.all`. Choosing one writes it into the
/// document; the chosen row opens to show the published numbers behind it,
/// because a destination that will not tell you what it is aiming for is a
/// preset with better manners.
///
/// The button is the whole novice path. Its label is never a lie: it says
/// "Measuring" while there is nothing to work from, "Nothing to fix" when the
/// file already meets the destination, and how many moves it is about to make
/// when there is something to do. Pressing it lands the proposal as a single
/// undo step, so changing your mind is one keystroke.
///
/// The section header ("Where's it going?") belongs to `EditorRootView`.
@MainActor
struct DestinationPicker: View {
    @ObservedObject private var store: EditorStore

    init(store: EditorStore) {
        _store = ObservedObject(wrappedValue: store)
    }

    @State private var hovered: String?

    private var chosen: Destination? { store.document?.destination }
    private var report: AnalysisReport? { store.document?.analysis }
    private var source: EditorSource? { store.document?.source }

    /// The proposal for the current destination, or `nil` when there is not
    /// enough to propose from. Recomputed on every body evaluation on purpose:
    /// it is pure, it is microseconds, and a cached proposal that disagrees with
    /// the button pressing it is the defect this feature cannot afford.
    private var proposal: [Move]? {
        guard let chosen, let report, let source else { return nil }
        return MoveProposer.propose(for: report, destination: chosen, source: source)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            VStack(spacing: 0) {
                ForEach(DestinationCatalogue.all) { destination in
                    row(destination)
                }
            }

            applyButton
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(DesignTokens.Animation.rowChange, value: chosen?.id)
    }

    // MARK: - A destination

    @ViewBuilder
    private func row(_ destination: Destination) -> some View {
        let isSelected = chosen?.id == destination.id
        let isHovered = hovered == destination.id

        Button {
            choose(destination)
        } label: {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                HStack(spacing: DesignTokens.Spacing.sm) {
                    Image(systemName: destination.symbolName)
                        .font(DesignTokens.Typography.Scale.footnote())
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(
                            isSelected
                                ? DesignTokens.Colors.accentPrimary
                                : DesignTokens.Colors.textSecondary
                        )
                        .frame(width: DesignTokens.Dimensions.iconSizeSmall)
                        .accessibilityHidden(true)

                    Text(destination.title)
                        .font(DesignTokens.Typography.Scale.body(isSelected ? .medium : .regular))
                        .foregroundStyle(DesignTokens.Colors.textPrimary)

                    Spacer(minLength: DesignTokens.Spacing.xs)

                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(DesignTokens.Typography.Scale.caption(.semibold))
                            .foregroundStyle(DesignTokens.Colors.accentPrimary)
                            .accessibilityHidden(true)
                    }
                }
                .frame(minHeight: DesignTokens.Dimensions.minTouchTarget)

                // Only the chosen one explains itself. Six blurbs at once is a
                // wall of text in a 320pt sidebar, and the blurb's job is to
                // confirm a choice rather than to advertise five alternatives.
                if isSelected {
                    Text(destination.blurb)
                        .font(DesignTokens.Typography.Scale.caption())
                        .foregroundStyle(DesignTokens.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)

                    Text(targetLine(destination))
                        .font(DesignTokens.Typography.Scale.caption2())
                        .monospacedDigit()
                        .foregroundStyle(DesignTokens.Colors.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)

                    Color.clear.frame(height: DesignTokens.Spacing.xxs)
                }
            }
            .padding(.horizontal, DesignTokens.Spacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                DesignTokens.Dimensions.Shape.sm
                    .fill(isHovered ? DesignTokens.Colors.hoverSurface : Color.clear)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .whenHovered { hovering in
            withAnimation(DesignTokens.Animation.hover) {
                hovered = hovering ? destination.id : nil
            }
        }
        // The row is one control, so the symbol, the title, the checkmark and
        // two lines of small print are not four things to swipe through.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(destination.title). \(destination.blurb)")
        .accessibilityValue(targetLine(destination))
        .accessibilityAddTraits(isSelected ? AccessibilityTraits.isSelected : [])
    }

    /// The numbers spelled out, **with who says so**. A row that reads
    /// "Apple Podcasts asks for −16.0 LUFS" and one that reads "Melo's own
    /// target is −12.0 LUFS" are making different promises, and the user is
    /// entitled to know which one they are being handed.
    ///
    /// The channel correction is applied here too, so a mono file's row says
    /// −19 and a file that arrives at −19 is told it is already right.
    private func targetLine(_ destination: Destination) -> String {
        let target = source.map { MoveProposer.effectiveTargetLUFS(for: destination, source: $0) }
            ?? destination.targetLUFS
        return destination.targetPhrase(effectiveLUFS: target)
            + " · peaks under \(EditorFormat.number(destination.truePeakCeilingDBTP, places: 1)) dBTP"
    }

    private func choose(_ destination: Destination) {
        guard chosen?.id != destination.id else { return }
        Haptics.step()
        store.setDestination(destination)
    }

    // MARK: - The button

    private var applyButton: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
            Button {
                applyProposal()
            } label: {
                Text(buttonTitle)
                    .font(DesignTokens.Typography.Scale.body(.medium))
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: DesignTokens.Dimensions.minTouchTarget - 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!canApply)
            .accessibilityLabel(buttonTitle)
            .accessibilityHint(buttonCaption ?? "")

            if let buttonCaption {
                Text(buttonCaption)
                    .font(DesignTokens.Typography.Scale.caption2())
                    .foregroundStyle(DesignTokens.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, DesignTokens.Spacing.xxs)
            }
        }
        .padding(.top, DesignTokens.Spacing.xxs)
    }

    private var canApply: Bool {
        guard let proposal else { return false }
        return !proposal.isEmpty
    }

    private var buttonTitle: String {
        guard chosen != nil else { return "Fix it for me" }
        guard let proposal else { return "Measuring" }
        if proposal.isEmpty { return "Nothing to fix" }
        return store.document?.moves.isEmpty == false ? "Fix it again" : "Fix it for me"
    }

    private var buttonCaption: String? {
        guard chosen != nil else { return "Pick a destination first." }
        guard let proposal else { return nil }
        if proposal.isEmpty { return "This file already meets that spec." }
        let moves = proposal.count == 1 ? "1 move" : "\(proposal.count) moves"
        if store.document?.moves.isEmpty == false {
            return "\(moves), replacing the Chain. Undo puts it back."
        }
        return "\(moves), and every number stays editable."
    }

    /// One edit, not one per move: the whole proposal is a single undo step, so
    /// somebody who presses the button and does not like it gets back exactly
    /// where they were with one keystroke.
    private func applyProposal() {
        guard let proposal, !proposal.isEmpty else { return }
        store.replaceMoves(proposal)
    }
}
