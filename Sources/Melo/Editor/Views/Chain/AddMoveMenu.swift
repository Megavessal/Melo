// Melo/Editor/Views/Chain/AddMoveMenu.swift
import SwiftUI

/// How a move gets onto the Chain by hand.
///
/// Grouped Cut / Level / Tone / Shape — the four things a person is trying to do
/// to a sound — rather than in the order `MoveKind` happens to declare its
/// cases. The enum's order is an implementation detail and it is nobody's mental
/// model of an audio edit.
///
/// Every move added here arrives with **no rationale**. The sentence in a row is
/// what the analysis found about this file; a move the user chose has no such
/// finding behind it, and writing one to fill the space would be a machine
/// inventing a reason for a human's decision.
@MainActor
struct AddMoveMenu: View {
    @ObservedObject private var store: EditorStore

    init(store: EditorStore) {
        _store = ObservedObject(wrappedValue: store)
    }

    private var document: EditorDocument? { store.document }
    private var analysis: AnalysisReport? { document?.analysis }

    var body: some View {
        Menu {
            Section("Cut") {
                item(.trim(start: trimStart, end: trimEnd))
                item(.removeSilence(thresholdDB: -45, minimumLength: 0.5, leaveTail: 0.15))
                item(.speed(rate: 1.0))
                item(.reverse)
            }

            Section("Level") {
                item(.gain(dB: 0))
                // Normalising is arithmetic on a measurement. Without one there
                // is no honest number to put in the move, so the item is off
                // rather than seeded with a guess. The placeholder below exists
                // only so the disabled item still has a case to take its name
                // and glyph from; it can never be applied.
                item(
                    .normalize(
                        appliedGainDB: normalizeTarget - measuredLUFS,
                        measuredLUFS: measuredLUFS,
                        targetLUFS: normalizeTarget
                    ),
                    enabled: analysis != nil,
                    help: analysis == nil ? "Needs a measurement first." : nil
                )
                item(.limiter(ceilingDBTP: -1.0, releaseMS: 50))
                item(.fadeIn(length: 0.5, curve: .equalPower))
                item(.fadeOut(length: 1.0, curve: .equalPower))
            }

            Section("Tone") {
                // `EQSettings()` is Melo's ten-band graphic at flat, and
                // `autoEQFilters` is the bridge onto the parametric array. Flat
                // is not a guess about the file — it is the identity — and
                // starting from Melo's own band centres is what makes the
                // editor's EQ and the player's EQ the same instrument.
                item(.equalizer(bands: EQSettings().autoEQFilters, preampDB: 0))
                item(.highPass(frequency: 80))
                item(.noiseGate(thresholdDB: -50, attackMS: 5, releaseMS: 120))
            }

            Section("Shape") {
                item(.channels(.mono))
                item(
                    .fixDCOffset(measuredOffset: analysis?.dcOffset ?? 0),
                    enabled: analysis != nil,
                    help: analysis == nil ? "Needs a measurement first." : nil
                )
            }
        } label: {
            Image(systemName: "plus")
                .font(DesignTokens.Typography.Scale.footnote(.semibold))
                .foregroundStyle(DesignTokens.Colors.interactiveDefault)
                .frame(
                    width: DesignTokens.Dimensions.minTouchTarget,
                    height: DesignTokens.Dimensions.minTouchTarget
                )
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(document == nil)
        .help("Add a move")
        .accessibilityLabel("Add a move")
    }

    // MARK: - Items

    /// One menu item, built **from the move it creates**.
    ///
    /// The name and the glyph come off `MoveKind.title` and
    /// `MoveKind.symbolName` — the same two properties the Chain row reads — so
    /// the item and the row it produces cannot disagree. They previously did:
    /// this menu carried its own hardcoded table, ten of the fourteen glyphs
    /// had drifted from the row's, and Normalize here wore `speaker.wave.2`,
    /// which is *Gain's* symbol, so two entries in one list shared an icon.
    /// Titles had drifted too — "High pass" here against "High-pass" there.
    /// Passing the kind rather than restating its labels makes that class of
    /// divergence unrepresentable rather than merely fixed.
    @ViewBuilder
    private func item(
        _ kind: MoveKind,
        enabled: Bool = true,
        help: String? = nil
    ) -> some View {
        Button {
            store.apply(Move(id: UUID(), kind: kind, isEnabled: true, rationale: nil))
        } label: {
            Label(kind.title, systemImage: kind.symbolName)
        }
        .disabled(!enabled)
        // Only where there is something to say. An empty `help` string is a
        // tooltip that opens onto nothing.
        .modifier(OptionalHelp(text: help))
    }

    private struct OptionalHelp: ViewModifier {
        let text: String?

        func body(content: Content) -> some View {
            if let text {
                content.help(text)
            } else {
                content
            }
        }
    }

    // MARK: - Starting numbers

    /// A trim added while a range is selected takes that range. Adding one with
    /// nothing selected gives you the whole sound and two handles to move,
    /// which is the only other truthful starting point.
    private var trimStart: TimeInterval {
        store.selection?.lowerBound ?? 0
    }

    private var trimEnd: TimeInterval {
        store.selection?.upperBound ?? (document?.source.duration ?? 0)
    }

    /// Zero when nothing has been measured. Only ever reached by the disabled
    /// Normalize item, which exists to be named and not to be pressed.
    private var measuredLUFS: Double { analysis?.integratedLUFS ?? 0 }

    private var normalizeTarget: Double {
        document?.destination?.targetLUFS ?? -16
    }
}
