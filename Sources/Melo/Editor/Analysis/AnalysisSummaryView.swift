// Melo/Editor/Analysis/AnalysisSummaryView.swift
import SwiftUI

/// What Melo found, in the order a person would ask.
///
/// The pane's job is to be *read*, not consulted. "−23.1 LUFS" tells the target
/// audience nothing on its own, so every number arrives with the sentence that
/// says what it is. The verdict at the top is the only thing most people will
/// look at: it names the destination's number and the gap in one breath.
///
/// The measured facts are `MoveFactRow`s — the same control the move inspectors
/// use for a number Melo measured and the user cannot type over. A field that
/// lets you edit a measurement is a field that lets the app lie about the file.
///
/// The section header ("What I found") belongs to `EditorRootView`, which
/// draws it for all three sidebar panes. This view starts at its content.
@MainActor
struct AnalysisSummaryView: View {
    @ObservedObject private var store: EditorStore

    init(store: EditorStore) {
        _store = ObservedObject(wrappedValue: store)
    }

    private var report: AnalysisReport? { store.document?.analysis }
    private var source: EditorSource? { store.document?.source }
    private var destination: Destination? { store.document?.destination }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            if let report, let source {
                verdict(report: report, source: source)
                facts(report: report, source: source)
            } else {
                notMeasuredYet
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Before there is anything to say

    private var notMeasuredYet: some View {
        Text("Still listening.")
            .font(DesignTokens.Typography.Scale.footnote())
            .foregroundStyle(DesignTokens.Colors.textTertiary)
            .accessibilityLabel("Melo is still measuring this file")
    }

    // MARK: - The verdict

    /// Two short sentences: the number the destination wants, and how far off
    /// this file is. Everything below is detail; this is the answer.
    @ViewBuilder
    private func verdict(report: AnalysisReport, source: EditorSource) -> some View {
        if let destination {
            let loudness = MoveProposer.loudnessAssessment(
                report: report, destination: destination, source: source
            )
            VStack(alignment: .leading, spacing: 1) {
                // Who wants it, not just what it is. "Apple Podcasts asks for
                // −16.0 LUFS." and "Melo's own target is −12.0 LUFS." are the
                // same shape of sentence making very different claims.
                Text("\(destination.targetPhrase(effectiveLUFS: loudness.targetLUFS)).")
                    .font(DesignTokens.Typography.Scale.body(.medium))
                    .monospacedDigit()
                    .foregroundStyle(DesignTokens.Colors.textPrimary)

                Text(gapSentence(loudness))
                    .font(DesignTokens.Typography.Scale.footnote())
                    .monospacedDigit()
                    .foregroundStyle(
                        loudness.isAlreadyThere
                            ? DesignTokens.Colors.textSecondary
                            : DesignTokens.Colors.textPrimary
                    )
            }
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
        } else {
            Text("Pick a destination and Melo will say how far off this is.")
                .font(DesignTokens.Typography.Scale.footnote())
                .foregroundStyle(DesignTokens.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func gapSentence(_ loudness: MoveProposer.LoudnessAssessment) -> String {
        guard !loudness.isAlreadyThere else { return "You're already there." }
        let direction = loudness.deltaDB > 0 ? "under" : "over"
        return "You're \(EditorFormat.decibels(abs(loudness.deltaDB))) \(direction)."
    }

    // MARK: - The facts

    @ViewBuilder
    private func facts(report: AnalysisReport, source: EditorSource) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs2) {
            MoveFactRow(
                label: "Loudness",
                value: "\(EditorFormat.number(report.integratedLUFS, places: 1)) LUFS",
                note: "How loud it feels overall, averaged across the whole thing."
            )

            MoveFactRow(
                label: "True peak",
                value: "\(EditorFormat.number(report.truePeakDBTP, places: 1)) dBTP",
                note: "The loudest instant, measured the way an encoder will hear it."
            )

            MoveFactRow(
                label: "Dynamic range",
                value: "\(EditorFormat.number(report.loudnessRangeLU, places: 1)) LU",
                note: "The distance between the quiet parts and the loud ones."
            )

            MoveFactRow(
                label: "Noise floor",
                value: "\(EditorFormat.number(report.noiseFloorDBFS, places: 1)) dBFS",
                note: "How loud the room is when nobody is making a sound."
            )

            if let deadAir = deadAirValue(report) {
                MoveFactRow(
                    label: "Dead air",
                    value: deadAir,
                    note: "Silence before the first sound and after the last."
                )
            }

            if let gaps = interiorGapValue(report) {
                MoveFactRow(
                    label: "Long pauses",
                    value: gaps,
                    note: "Gaps of more than a second and a half in the middle."
                )
            }

            if report.clippedSampleCount > 0 {
                MoveFactRow(
                    label: "Clipping",
                    value: "\(MoveProposer.sampleCount(report.clippedSampleCount)) samples",
                    note: "Already flattened at the top before Melo saw it. "
                        + "Nothing can put that back — a limiter only stops it getting worse."
                )
            }

            if source.channelCount > 1 && report.isEffectivelyMono {
                MoveFactRow(
                    label: "Channels",
                    value: "\(source.channelCount), identical",
                    note: "It is a stereo file carrying a single signal, so mono costs nothing."
                )
            }

            if abs(report.dcOffset) >= 0.001 {
                MoveFactRow(
                    label: "DC offset",
                    value: "\(EditorFormat.number(abs(report.dcOffset) * 100, places: 2))%",
                    note: "The waveform sits off centre, which costs headroom and clicks at edits."
                )
            }
        }
    }

    /// `nil` when there is barely any, because a row saying "0.02s" is a row
    /// about nothing. The threshold matches the one `MoveProposer` trims at, so
    /// the pane never reports dead air the button then refuses to remove.
    private func deadAirValue(_ report: AnalysisReport) -> String? {
        let lead = report.leadingSilence
        let tail = report.trailingSilence
        let floor = 0.35
        switch (lead >= floor, tail >= floor) {
        case (true, true):
            return "\(EditorFormat.seconds(lead)) front, \(EditorFormat.seconds(tail)) end"
        case (true, false):
            return "\(EditorFormat.seconds(lead)) at the front"
        case (false, true):
            return "\(EditorFormat.seconds(tail)) at the end"
        case (false, false):
            return nil
        }
    }

    private func interiorGapValue(_ report: AnalysisReport) -> String? {
        let long = report.interiorSilences.filter { $0.upperBound - $0.lowerBound >= 1.5 }
        guard !long.isEmpty else { return nil }
        let total = long.reduce(0.0) { $0 + ($1.upperBound - $1.lowerBound) }
        let count = long.count == 1 ? "1 gap" : "\(long.count) gaps"
        return "\(count), \(EditorFormat.seconds(total))"
    }
}
