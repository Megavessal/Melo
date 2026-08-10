// Melo/Editor/Views/Chain/MoveInspectorsCut.swift
import SwiftUI

// The three moves that change how long the sound is: trim, remove silence and
// speed. Reverse is not one of them — it runs the same samples backwards and
// the clip stays exactly as long.

// MARK: - Trim

@MainActor
struct TrimInspector: View {
    let start: TimeInterval
    let end: TimeInterval
    let duration: TimeInterval
    let onChange: (MoveKind) -> Void

    /// A trim on a source that has not reported a length yet still needs a
    /// range, and the existing handles are the only evidence of how long the
    /// sound is.
    private var ceiling: TimeInterval { max(duration, end, 1) }

    private var kept: TimeInterval { max(0, end - start) }

    var body: some View {
        MoveInspectorBody {
            MoveTimeRow(
                label: "Starts at",
                value: Binding(
                    get: { start },
                    // The handles cannot cross. Pushing start past end would
                    // otherwise store a negative-length trim, which the renderer
                    // has no sensible reading of.
                    set: { onChange(.trim(start: min($0, end), end: end)) }
                ),
                in: 0...ceiling
            )

            MoveTimeRow(
                label: "Ends at",
                value: Binding(
                    get: { end },
                    set: { onChange(.trim(start: start, end: max($0, start))) }
                ),
                in: 0...ceiling
            )

            MoveFactRow(label: "Keeps", value: EditorFormat.timecode(kept, decimals: 2))
        }
    }
}

// MARK: - Remove silence

@MainActor
struct RemoveSilenceInspector: View {
    let thresholdDB: Double
    let minimumLength: TimeInterval
    let leaveTail: TimeInterval
    let onChange: (MoveKind) -> Void

    var body: some View {
        MoveInspectorBody {
            MoveNumberRow(
                label: "Counts as silence below",
                value: Binding(
                    get: { thresholdDB },
                    set: {
                        onChange(.removeSilence(
                            thresholdDB: $0,
                            minimumLength: minimumLength,
                            leaveTail: leaveTail
                        ))
                    }
                ),
                in: -80...(-20),
                step: 1,
                unit: "dB",
                places: 0
            )

            MoveNumberRow(
                label: "Only gaps longer than",
                value: Binding(
                    get: { minimumLength },
                    set: {
                        onChange(.removeSilence(
                            thresholdDB: thresholdDB,
                            minimumLength: $0,
                            leaveTail: leaveTail
                        ))
                    }
                ),
                in: 0.05...5,
                step: 0.05,
                unit: "s",
                places: 2
            )

            MoveNumberRow(
                label: "Leaves behind",
                value: Binding(
                    get: { leaveTail },
                    set: {
                        onChange(.removeSilence(
                            thresholdDB: thresholdDB,
                            minimumLength: minimumLength,
                            leaveTail: $0
                        ))
                    }
                ),
                in: 0...1,
                step: 0.01,
                unit: "s",
                places: 2
            )
        }
    }
}

// MARK: - Speed

@MainActor
struct SpeedInspector: View {
    let rate: Double
    let onChange: (MoveKind) -> Void

    private static let range: ClosedRange<Double> = 0.5...2.0

    /// Speed is the one parameter in the Chain that really is a percentage, so
    /// it gets the app's percentage field rather than a "1.20 ×" of its own.
    private var percent: Binding<Int> {
        Binding(
            get: { Int((rate * 100).rounded()) },
            set: { onChange(.speed(rate: clampRate(Double($0) / 100))) }
        )
    }

    private func clampRate(_ candidate: Double) -> Double {
        MoveNumberField.snap(candidate, to: 0.01, in: Self.range)
    }

    var body: some View {
        MoveInspectorBody {
            HStack(spacing: DesignTokens.Spacing.xs) {
                Text("Speed")
                    .font(DesignTokens.Typography.Scale.caption())
                    .foregroundStyle(.secondary)
                Spacer(minLength: DesignTokens.Spacing.xs)
                EditablePercentage(percentage: percent, range: 50...200, subject: "Speed")
            }

            LiquidGlassSlider(
                value: Binding(
                    get: { rate },
                    set: { onChange(.speed(rate: clampRate($0))) }
                ),
                in: Self.range,
                showUnityMarker: true,
                accessibilityTitle: "Speed",
                valueDescription: { "\(Int(($0 * 100).rounded()))%" }
            )

            Text("Pitch stays where it is.")
                .font(DesignTokens.Typography.Scale.caption2())
                .foregroundStyle(DesignTokens.Colors.textTertiary)
        }
    }
}
