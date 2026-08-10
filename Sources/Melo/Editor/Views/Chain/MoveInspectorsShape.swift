// Melo/Editor/Views/Chain/MoveInspectorsShape.swift
import SwiftUI

// The two moves that change what the sound is, rather than how it sounds.

// MARK: - Channels

@MainActor
struct ChannelsInspector: View {
    let mode: ChannelMode
    let onChange: (MoveKind) -> Void

    var body: some View {
        MoveInspectorBody {
            MoveChoiceRow(
                label: "Channels",
                selection: Binding(
                    get: { mode },
                    set: { onChange(.channels($0)) }
                ),
                options: ChannelMode.allCases.map { ($0, $0.title) }
            )

            Text(explanation)
                .font(DesignTokens.Typography.Scale.caption2())
                .foregroundStyle(DesignTokens.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var explanation: String {
        switch mode {
        case .keep: "Leaves the channel count alone."
        case .mono: "Folds both sides down to one. Halves the file."
        case .stereo: "Copies one channel to both sides. No new width."
        }
    }
}

// MARK: - DC offset

/// Nothing here is a setting. The offset is what Melo measured in this file,
/// and the move subtracts it; a field that let you type over the measurement
/// would only let you make the correction wrong.
@MainActor
struct FixDCOffsetInspector: View {
    let measuredOffset: Double

    var body: some View {
        MoveInspectorBody {
            MoveFactRow(
                label: "Measured offset",
                value: EditorFormat.number(measuredOffset, places: 4),
                note: "Subtracted from every sample. Buys back the headroom it was eating."
            )
        }
    }
}
