// Melo/Editor/Views/Stack/MoveInspector.swift
import SwiftUI

/// What opens when a row in the stack is disclosed: the concrete numbers of one
/// move, and nothing else.
///
/// The inspector never explains what the move is — the row already said that in
/// words. This is the second depth, and the whole reason the row above it can
/// stay short.
@MainActor
struct MoveInspector: View {
    let move: Move
    /// Length of the source, which is the ceiling on every position and length
    /// in a `trim` or a fade.
    let duration: TimeInterval
    /// Reaches only the EQ inspector, which needs it for "Save to Melo" and the
    /// user-preset list. Deliberately **not** defaulted: a hop that can be
    /// forgotten silently is a hop that will be, and the symptom is a missing
    /// row rather than an error.
    let settings: SettingsManager?
    /// Hands back a replacement `MoveKind`. The caller owns writing it to the
    /// store, so the inspectors stay pure enough to render without one.
    let onChange: (MoveKind) -> Void

    /// Whether disclosing this move would show anything. `reverse` has no
    /// numbers, so its row draws no chevron rather than opening onto a panel
    /// that says "nothing to set" — a disclosure that discloses nothing is a
    /// small lie the user only catches by clicking it.
    @MainActor
    static func hasInspector(_ kind: MoveKind) -> Bool {
        if case .reverse = kind { return false }
        return true
    }

    var body: some View {
        switch move.kind {

        // Cut
        case let .trim(start, end):
            TrimInspector(start: start, end: end, duration: duration, onChange: onChange)
        case let .removeSilence(thresholdDB, minimumLength, leaveTail):
            RemoveSilenceInspector(
                thresholdDB: thresholdDB,
                minimumLength: minimumLength,
                leaveTail: leaveTail,
                onChange: onChange
            )
        case .reverse:
            EmptyView()
        case let .speed(rate):
            SpeedInspector(rate: rate, onChange: onChange)

        // Level
        case let .gain(dB):
            GainInspector(dB: dB, onChange: onChange)
        case let .normalize(appliedGainDB, measuredLUFS, targetLUFS):
            NormalizeInspector(
                appliedGainDB: appliedGainDB,
                measuredLUFS: measuredLUFS,
                targetLUFS: targetLUFS,
                onChange: onChange
            )
        case let .limiter(ceilingDBTP, releaseMS):
            LimiterInspector(ceilingDBTP: ceilingDBTP, releaseMS: releaseMS, onChange: onChange)
        case let .fadeIn(length, curve):
            FadeInspector(
                length: length,
                curve: curve,
                duration: duration,
                isFadeIn: true,
                onChange: onChange
            )
        case let .fadeOut(length, curve):
            FadeInspector(
                length: length,
                curve: curve,
                duration: duration,
                isFadeIn: false,
                onChange: onChange
            )

        // Tone
        case let .equalizer(bands, preampDB):
            EqualizerInspector(
                bands: bands,
                preampDB: preampDB,
                settings: settings,
                onChange: onChange
            )
        case let .highPass(frequency):
            HighPassInspector(frequency: frequency, onChange: onChange)
        case let .noiseGate(thresholdDB, attackMS, releaseMS):
            NoiseGateInspector(
                thresholdDB: thresholdDB,
                attackMS: attackMS,
                releaseMS: releaseMS,
                onChange: onChange
            )

        // Shape
        case let .channels(mode):
            ChannelsInspector(mode: mode, onChange: onChange)
        case let .fixDCOffset(measuredOffset):
            FixDCOffsetInspector(measuredOffset: measuredOffset)
        }
    }
}
