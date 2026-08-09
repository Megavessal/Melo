// Melo/Editor/Views/Stack/MoveInspectorsTone.swift
import SwiftUI

// The three moves that change the colour of the sound.

// MARK: - Equalizer

/// The EQ row's inspector is a mount, not an equalizer. `EditorEQPanel` is the
/// equalizer — graphic at one depth, parametric at the other — and there is
/// exactly one of it in the app.
///
/// Alone among the inspectors this does **not** sit in a `MoveInspectorBody`.
/// The panel already draws its own recessed surfaces section by section, so the
/// wrapper would nest a recess inside a recess — and, more expensively, its
/// 8pt of horizontal padding would take the panel from the 280pt this pane
/// hands it down to 264pt, on a layout its author measured at 284pt with a
/// field in edit mode. The widest thing in the sidebar should get the sidebar's
/// full width.
@MainActor
struct EqualizerInspector: View {
    let bands: [AutoEQFilter]
    let preampDB: Double
    let settings: SettingsManager?
    let onChange: (MoveKind) -> Void

    var body: some View {
        EditorEQPanel(
            bands: bands,
            preampDB: preampDB,
            // Without this the panel is complete except for the one thing no
            // other audio editor does: a curve built here becoming a
            // `UserEQPreset` that applies to live apps.
            settings: settings
        ) { newBands, newPreamp in
            onChange(.equalizer(bands: newBands, preampDB: newPreamp))
        }
        .padding(.vertical, DesignTokens.Spacing.xxs)
    }
}

// MARK: - High pass

@MainActor
struct HighPassInspector: View {
    let frequency: Double
    let onChange: (MoveKind) -> Void

    var body: some View {
        MoveInspectorBody {
            MoveNumberRow(
                label: "Rolls off below",
                value: Binding(
                    get: { frequency },
                    set: { onChange(.highPass(frequency: $0)) }
                ),
                in: 20...500,
                step: 5,
                unit: "Hz",
                places: 0
            )

            Text("Takes out rumble, handling noise and room boom.")
                .font(DesignTokens.Typography.Scale.caption2())
                .foregroundStyle(DesignTokens.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Noise gate

@MainActor
struct NoiseGateInspector: View {
    let thresholdDB: Double
    let attackMS: Double
    let releaseMS: Double
    let onChange: (MoveKind) -> Void

    var body: some View {
        MoveInspectorBody {
            MoveNumberRow(
                label: "Opens above",
                value: Binding(
                    get: { thresholdDB },
                    set: { onChange(.noiseGate(thresholdDB: $0, attackMS: attackMS, releaseMS: releaseMS)) }
                ),
                in: -90...(-20),
                step: 1,
                unit: "dB",
                places: 0
            )

            MoveNumberRow(
                label: "Attack",
                value: Binding(
                    get: { attackMS },
                    set: { onChange(.noiseGate(thresholdDB: thresholdDB, attackMS: $0, releaseMS: releaseMS)) }
                ),
                in: 0.1...50,
                step: 0.1,
                unit: "ms"
            )

            MoveNumberRow(
                label: "Release",
                value: Binding(
                    get: { releaseMS },
                    set: { onChange(.noiseGate(thresholdDB: thresholdDB, attackMS: attackMS, releaseMS: $0)) }
                ),
                in: 10...1000,
                step: 5,
                unit: "ms",
                places: 0
            )
        }
    }
}
