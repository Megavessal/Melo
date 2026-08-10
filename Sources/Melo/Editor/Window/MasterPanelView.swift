// Melo/Editor/Window/MasterPanelView.swift
//
// The master section: what the mix sounds like, and what is being done to all
// of it at once.
//
// ## What this says that no other panel says
//
// "What I found" reads `EditorDocument.analysis`, whose own doc comment is
// explicit that it "Describes the *first source*, not the rendered mix, so it
// survives every edit". That is the right thing for a measurement to be and it
// is not the question a master strip answers. This one reads
// `EditorStore.waveform` — the *rendered* overview of everything summed, after
// every clip, every track's moves, gain, pan, mute and solo, and the master
// chain — so it is the only place in the window that says how loud the thing
// you are about to export actually is.
//
// **There is no master fader here and that is not an omission.**
// `EditorDocument` has no master gain field; adding one is a change to the
// document model, the sidecar, the undo stack and the render path, and those
// types are owned elsewhere. A slider that moved nothing would be the
// dead-control failure this project has already shipped once. The way to move
// the whole mix today is a Gain move on the master chain, which is what the
// Chain row below points at.

import SwiftUI

/// Full mode's extra panel. See `EditorMode.Extra.master`.
@MainActor
struct MasterPanelView: View {

    @ObservedObject var store: EditorStore

    private var document: EditorDocument? { store.document }

    private var reading: EditorLevelReading {
        EditorLevelReading.forMix(store.waveform)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs2) {
            meter
            numbers
            audibility
            chainLine
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Master")
    }

    /// The mix's own bar, with the ladder under it.
    ///
    /// The scale is drawn here unconditionally rather than through
    /// `store.mode.shows(.meterScale)`, and that is not an inconsistency: this
    /// whole panel is Full-only, so gating a Full-only detail inside it would
    /// be a branch with one reachable arm — the thing the project anchor calls
    /// a branch nobody can prove right.
    private var meter: some View {
        EditorLevelMeter(
            reading: reading,
            showsScale: true,
            reservesScale: false,
            subject: "Master"
        )
    }

    private var numbers: some View {
        HStack(spacing: DesignTokens.Spacing.md) {
            figure("Peak", EditorLevelReading.label(reading.peakDB))
            figure("Average", EditorLevelReading.label(reading.rmsDB))
            figure("Headroom", headroom)
            Spacer(minLength: 0)
        }
    }

    /// How much is left before full scale. The number an export actually turns
    /// on, and the one a peak reading makes you do arithmetic for.
    private var headroom: String {
        guard reading.peakDB.isFinite else { return "—" }
        return EditorFormat.decibels(max(0, -reading.peakDB))
    }

    private func figure(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title.uppercased())
                .font(DesignTokens.Typography.Scale.caption2(.semibold))
                .foregroundStyle(DesignTokens.Colors.textTertiary)
            Text(value)
                .font(DesignTokens.Typography.Scale.footnote(.medium))
                .monospacedDigit()
                .foregroundStyle(DesignTokens.Colors.textPrimary)
        }
        .accessibilityElement(children: .combine)
    }

    /// "3 of 4 tracks audible". Read through `EditorDocument.audibleTrackIDs`,
    /// which is the same property the render engine consults, so this line
    /// cannot tell the user something the mix disagrees with — the rule
    /// `TrackHeaderRow.isAudible` already follows, one level up.
    @ViewBuilder
    private var audibility: some View {
        if let document, document.tracks.count > 1 {
            let heard = document.audibleTrackIDs.count
            Text("\(heard) of \(document.tracks.count) tracks audible")
                .font(DesignTokens.Typography.Scale.caption())
                .monospacedDigit()
                .foregroundStyle(
                    heard == document.tracks.count
                        ? DesignTokens.Colors.textTertiary
                        : DesignTokens.Colors.accentPrimary
                )
        }
    }

    /// What the master chain is doing, and nothing more.
    ///
    /// A count and a switched-off count, not a list. The Chain panel is four
    /// inches away and owns the rows; a second rendering of them here would be
    /// two lists to keep in step, and the one that is not the drag target would
    /// be the one that goes stale.
    private var chainLine: some View {
        let moves = document?.master ?? []
        let off = moves.filter { !$0.isEnabled }.count
        return Text(summary(count: moves.count, off: off))
            .font(DesignTokens.Typography.Scale.caption())
            .foregroundStyle(
                off > 0 ? DesignTokens.Colors.accentPrimary : DesignTokens.Colors.textTertiary
            )
            .accessibilityLabel("Master chain, \(summary(count: moves.count, off: off))")
    }

    private func summary(count: Int, off: Int) -> String {
        guard count > 0 else { return "Nothing on the master chain" }
        let moves = count == 1 ? "1 move" : "\(count) moves"
        guard off > 0 else { return "\(moves) on the master chain" }
        return "\(moves) on the master chain, \(off) switched off"
    }
}
