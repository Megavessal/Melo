// Melo/Editor/Views/Chain/MoveInspectorsLevel.swift
import SwiftUI

// The five moves that change how loud the sound is.

// MARK: - Gain

@MainActor
struct GainInspector: View {
    let dB: Double
    let onChange: (MoveKind) -> Void

    var body: some View {
        MoveInspectorBody {
            MoveNumberRow(
                label: "Gain",
                value: Binding(
                    get: { dB },
                    set: { onChange(.gain(dB: $0)) }
                ),
                in: -24...24,
                step: 0.1,
                unit: "dB",
                showsUnityMarker: true
            )
        }
    }
}

// MARK: - Normalize

@MainActor
struct NormalizeInspector: View {
    let appliedGainDB: Double
    let measuredLUFS: Double
    let targetLUFS: Double
    let onChange: (MoveKind) -> Void

    var body: some View {
        MoveInspectorBody {
            MoveFactRow(
                label: "Measured",
                value: "\(EditorFormat.number(measuredLUFS, places: 1)) LUFS"
            )

            MoveNumberRow(
                label: "Target",
                value: Binding(
                    get: { targetLUFS },
                    // Applied gain is the difference, not a third opinion about
                    // it. Letting it be typed independently is how a Chain ends
                    // up claiming -16 LUFS while applying the gain for -14.
                    set: {
                        onChange(.normalize(
                            appliedGainDB: $0 - measuredLUFS,
                            measuredLUFS: measuredLUFS,
                            targetLUFS: $0
                        ))
                    }
                ),
                in: -30...(-6),
                step: 0.5,
                unit: "LUFS"
            )

            // Reads exactly as the Chain row above reads it, because it is the
            // same formatter.
            MoveFactRow(
                label: "Applies",
                value: EditorFormat.decibels(appliedGainDB),
                note: "Target minus measured. Change the target and this follows."
            )
        }
    }
}

// MARK: - Limiter

@MainActor
struct LimiterInspector: View {
    let ceilingDBTP: Double
    let releaseMS: Double
    let onChange: (MoveKind) -> Void

    var body: some View {
        MoveInspectorBody {
            MoveNumberRow(
                label: "Ceiling",
                value: Binding(
                    get: { ceilingDBTP },
                    set: { onChange(.limiter(ceilingDBTP: $0, releaseMS: releaseMS)) }
                ),
                in: -6...0,
                step: 0.1,
                unit: "dBTP"
            )

            MoveNumberRow(
                label: "Release",
                value: Binding(
                    get: { releaseMS },
                    set: { onChange(.limiter(ceilingDBTP: ceilingDBTP, releaseMS: $0)) }
                ),
                in: 10...500,
                step: 5,
                unit: "ms",
                places: 0
            )
        }
    }
}

// MARK: - Fades

@MainActor
struct FadeInspector: View {
    let length: TimeInterval
    let curve: FadeCurve
    let duration: TimeInterval
    let isFadeIn: Bool
    let onChange: (MoveKind) -> Void

    /// A fade cannot be longer than the sound. Ten seconds otherwise, so a
    /// source that has not reported its length still gets a usable slider.
    private var ceiling: TimeInterval { max(min(duration, 30), length, 1) }

    private func kind(length: TimeInterval, curve: FadeCurve) -> MoveKind {
        isFadeIn ? .fadeIn(length: length, curve: curve) : .fadeOut(length: length, curve: curve)
    }

    var body: some View {
        MoveInspectorBody {
            MoveNumberRow(
                label: "Length",
                value: Binding(
                    get: { length },
                    set: { onChange(kind(length: $0, curve: curve)) }
                ),
                in: 0...ceiling,
                step: 0.05,
                unit: "s",
                places: 2
            )

            MoveChoiceRow(
                label: "Curve",
                selection: Binding(
                    get: { curve },
                    set: { onChange(kind(length: length, curve: $0)) }
                ),
                // `FadeCurve.title` is lowercase because the Chain row uses it
                // mid-sentence. A segment label starts a phrase of its own.
                options: FadeCurve.allCases.map { ($0, Self.sentenceCase($0.title)) }
            )
        }
    }

    /// "equal power" → "Equal power". Not `.capitalized`, which gives
    /// "Equal Power"; title case is not what macOS control labels use.
    private static func sentenceCase(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.uppercased() + text.dropFirst()
    }
}
