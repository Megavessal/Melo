// Melo/Editor/Views/Waveform/EditorWaveformStyle.swift
//
// Four ways to draw the same numbers, and the picker that chooses between them.
//
// Two decisions hold this file up.
//
// 1. **The preference is `@AppStorage`, not `SettingsManager.Settings`.**
//    `ExportSheet` already keeps `melo.editor.export.folder` and
//    `melo.editor.export.reveal` this way, so the editor has a precedent for its
//    own defaults. The alternative — a field on `AppSettings` — would mean
//    threading a `SettingsManager` from `EditorRootView` into a view that is
//    deliberately constructible from nothing but the store, which is the
//    property that lets the snapshot harness render it at all.
//
// 2. **The picker's thumbnails are drawn by the shipping renderer.** Each one is
//    an `EditorWaveformLanesCanvas` over a fixed set of columns, so a thumbnail
//    cannot drift from what the choice actually does. Hand-drawn thumbnails —
//    which is what `HUDStyleSegmentedControl` does, because a HUD is not a
//    drawing routine you can call — would be a second drawing of each style to
//    keep in step with the first.

import SwiftUI

// MARK: - The styles

/// How `EditorWaveformLanesCanvas` draws a lane.
///
/// Ordered as the picker shows them: the default first, then the one that is
/// most Melo's own, then the two conventional readings.
enum EditorWaveformStyle: String, CaseIterable, Identifiable, Sendable {

    /// Discrete vertical bars with a gap. The convention in Audacity, Logic's
    /// overview and every player that draws audio at all.
    case bars

    /// Chunky blocks on a square grid, the technique the app icon and the
    /// menu-bar mark are already drawn in.
    case pixel

    /// A filled symmetric envelope with the RMS core inside it. What Melo Edit
    /// shipped with in 3.1.0.
    case filled

    /// The peak outline, stroked, with nothing inside it.
    case line

    /// Bars. It reads as audio instantly and it is the one least likely to be
    /// anybody's least favourite; the other three are each somebody's taste.
    static let fallback: EditorWaveformStyle = .bars

    /// `melo.editor.` to match the two keys `ExportSheet` already writes.
    static let storageKey = "melo.editor.waveformStyle"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .bars: return "Bars"
        case .pixel: return "Pixel"
        case .filled: return "Filled"
        case .line: return "Line"
        }
    }
}

// MARK: - The picker

/// Four thumbnails, one selected. Follows `HUDStyleSegmentedControl` — the same
/// 4pt row, the same tinted selection wash and ring, the same `.meloHover`
/// button — because that control is already the answer to this question in
/// Settings and a second answer would be a second thing to keep consistent.
@MainActor
struct EditorWaveformStylePicker: View {

    @Binding var selection: EditorWaveformStyle

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            ForEach(EditorWaveformStyle.allCases) { style in
                EditorWaveformStyleOption(style: style, isSelected: selection == style) {
                    // `DesignTokens.Animation.quick` already collapses under
                    // Reduce Motion, so this does not read the environment the
                    // way the two older style pickers do.
                    withAnimation(DesignTokens.Animation.quick) {
                        selection = style
                    }
                }
            }
        }
    }
}

private struct EditorWaveformStyleOption: View {

    let style: EditorWaveformStyle
    let isSelected: Bool
    let onSelect: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    /// Broken into three computed views on purpose. As one expression the
    /// type-checker gave up on it — "unable to type-check this expression in
    /// reasonable time" — which is what a `Button` label holding a seven-argument
    /// initialiser, two shape backgrounds and a ternary `ShapeStyle` costs.
    var body: some View {
        Button(action: onSelect) {
            VStack(spacing: DesignTokens.Spacing.xxs) {
                thumbnail
                caption
            }
            .padding(DesignTokens.Spacing.xs)
            .frame(
                minWidth: DesignTokens.Dimensions.minTouchTarget,
                minHeight: DesignTokens.Dimensions.minTouchTarget
            )
            .contentShape(Rectangle())
            .background(selectionWash)
            .overlay(selectionRing)
        }
        .buttonStyle(.meloHover)
        .accessibilityLabel(style.label)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var tint: Color {
        isSelected ? DesignTokens.Colors.accentPrimary : DesignTokens.Colors.textSecondary
    }

    private var thumbnail: some View {
        let shape = DesignTokens.Dimensions.Shape.xs
        return EditorWaveformLanesCanvas(
            lanes: [EditorWaveformStylePicker.sampleColumns],
            window: 0...1,
            selection: nil,
            isBypassed: false,
            isDense: true,
            style: style,
            scheme: colorScheme
        )
        .frame(width: 54, height: 20)
        .background(shape.fill(Color.primary.opacity(0.08)))
        .clipShape(shape)
    }

    private var caption: some View {
        Text(style.label)
            .font(DesignTokens.Typography.Scale.caption2())
            .foregroundStyle(tint)
    }

    private var selectionWash: some View {
        DesignTokens.Dimensions.Shape.sm
            .fill(isSelected ? DesignTokens.Colors.accentPrimary.opacity(0.15) : Color.clear)
    }

    private var selectionRing: some View {
        DesignTokens.Dimensions.Shape.sm
            .stroke(isSelected ? DesignTokens.Colors.accentPrimary : Color.clear, lineWidth: 1.5)
    }
}

extension EditorWaveformStylePicker {

    /// A fixed bar of audio for the thumbnails: two hits, a decay off each, and
    /// a quiet stretch between them, so all four thumbnails are drawings of the
    /// same sound and differ only in how they draw it.
    ///
    /// Written out rather than sampled from the real waveform because a picker
    /// in Settings has no document open, and a thumbnail whose content depended
    /// on what happened to be loaded would move under the reader.
    static let sampleColumns: [EditorWaveformColumn] = (0..<72).map { index in
        let position = Double(index) / 71
        let hit = exp(-Double(index % 18) / 4.5)
        let body = 0.22 + 0.62 * hit * (position < 0.55 ? 1 : 0.55)
        let grain = 0.82 + 0.18 * cos(Double(index) * 2.399)
        let peak = min(body * grain, 0.98)
        return EditorWaveformColumn(
            minimum: Float(-peak * 0.86),
            maximum: Float(peak),
            rms: Float(peak * (0.34 + 0.28 * (1 - hit)))
        )
    }
}
