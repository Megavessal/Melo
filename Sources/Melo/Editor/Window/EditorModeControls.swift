// Melo/Editor/Window/EditorModeControls.swift
//
// The switch between Simple and Full, and the row Full adds under the
// transport.
//
// Both live here rather than beside the things they sit next to, because they
// are the two halves of one decision: the control that changes the mode and the
// largest thing the mode changes. Splitting them puts the tooltip that promises
// "a second row under the transport" in a different file from the second row.

import SwiftUI

/// Two segments, square edges, caption type. One control, always visible, and
/// nobody is ever asked to use it.
///
/// ## Why a segmented control and not a single toggling button
///
/// A button labelled "Full" is ambiguous in the way that matters: it can be
/// read as *you are in Full* or as *press for Full*, and a reader who guesses
/// wrong presses it to get back to Simple and gets Full. A button labelled
/// "Switch to Full" is unambiguous and is three times as wide as this whole
/// control, in a header that already carries a name, an origin line, a format
/// chip, a duration, a menu and Export.
///
/// Two segments say the current state and the available one at the same time,
/// in 92 points, which is what the density this pass is about actually buys.
///
/// *Rejected:* putting it in the source menu. It would be findable exactly once
/// — by somebody who already knew it existed — and the frame's requirement is
/// that Full is *one control away*, not one menu and one item away. It is in
/// the Settings Guide as well, which is the other half of findable.
@MainActor
struct EditorModeSwitch: View {

    @ObservedObject var store: EditorStore

    var body: some View {
        HStack(spacing: 0) {
            ForEach(EditorMode.allCases) { mode in
                segment(mode)
                if mode != EditorMode.allCases.last {
                    Rectangle()
                        .fill(DesignTokens.Colors.panelSeparator)
                        .frame(width: 1)
                        .accessibilityHidden(true)
                }
            }
        }
        .frame(height: Self.height)
        .overlay(
            Rectangle().strokeBorder(DesignTokens.Colors.panelSeparator, lineWidth: 1)
        )
        // Square. The frame's word is "no rounded floating cards", and a
        // capsule segmented control beside a squared-off pane is the one thing
        // in the header that would still look like the old window.
        .clipShape(Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("How much of the editor to show")
        .help(Self.help)
    }

    /// 22, under `minTouchTarget`. A known deviation, and a bounded one: the
    /// control is 92 points wide, so it is easy to hit by area, and the header
    /// row it sits in is 56 points tall with the segments centred in it. Making
    /// it 28 would make it the tallest thing in the header after the Export
    /// button, which is the wrong ranking for a control most people press once.
    static let height: CGFloat = 22

    static var help: String {
        "Simple keeps it to the essentials. Full adds \(EditorMode.additionsSentence)."
    }

    private func segment(_ mode: EditorMode) -> some View {
        let isOn = store.mode == mode
        return Button {
            // Through `setMode`, which is what a menu item and a key equivalent
            // would call. One route, so a scene that exercises the store
            // exercises the button's whole job except the press itself.
            withAnimation(DesignTokens.Animation.panel) {
                store.setMode(mode)
            }
        } label: {
            Text(mode.title)
                .font(DesignTokens.Typography.Scale.caption(isOn ? .semibold : .regular))
                .foregroundStyle(
                    isOn ? DesignTokens.Colors.textPrimary : DesignTokens.Colors.textTertiary
                )
                .frame(width: Self.segmentWidth, height: Self.height)
                .background(
                    Rectangle().fill(
                        isOn
                            ? DesignTokens.Colors.panelHeaderFillOpen
                            : DesignTokens.Colors.panelHeaderFill
                    )
                )
                .overlay(alignment: .bottom) {
                    // The accent, along the bottom of the chosen segment. Same
                    // idea as the open panel's leading stripe, turned ninety
                    // degrees to fit a control that is wider than it is tall —
                    // and the reason the fill difference does not have to carry
                    // the state on its own, which at 5% against 10% it could
                    // not.
                    Rectangle()
                        .fill(Color.accentColor)
                        .frame(height: 2)
                        .opacity(isOn ? 1 : 0)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(mode.title)
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
    }

    private static let segmentWidth: CGFloat = 45
}

/// What Full adds under the transport: the selected clip, and its numbers.
///
/// ## What this row costs, said plainly
///
/// It is 26 points, and they come out of the timeline pane's height. **That is
/// the one place the mode rule is not literally true** — "switching adds and
/// removes panels; it never moves the timeline or the waveform" holds exactly
/// for the time axis (zoom, window start, the x of every sample, the width of
/// the pane, which the scenes assert as numbers) and does not hold for the
/// pane's height, because a window is a fixed box and something has to give.
///
/// Two alternatives were written out and both are worse. **Reserving the row in
/// Simple** — drawing 26 points of nothing under every Simple user's transport
/// forever — buys a pixel-exact rule at the cost of the density this entire
/// pass is about. **Folding the row into the transport's existing 44 points**,
/// as a 28pt control band over a 16pt readout band, is the right answer and is
/// not available from here: it needs `EditorTransportBar.height` and that
/// file's layout, which this piece does not own. The patch is written out in
/// the run report so whoever does own it can take it.
///
/// So the honest statement is: everything the mode adds to the *pane* is a
/// panel, the track headers reserve their own additions so no lane ever
/// resizes, and this one strip moves the bottom edge of the timeline by 26
/// points.
@MainActor
struct EditorClipStrip: View {

    @ObservedObject var store: EditorStore

    /// 26. Two points under the transport's control height, because nothing on
    /// this row is a cold pointer target — the readouts are readouts and the
    /// two steppers are beside a number that is already being looked at.
    /// 16, not 26, and it is arithmetic rather than taste:
    /// `EditorTransportBar` drops from 44 to its 28pt control row in Full, and
    /// this takes the 16 back. The band under the timeline is 44 in both modes,
    /// so switching mode moves no lane and no waveform — the rule the whole
    /// feature rests on. Change one of these two numbers and you must change
    /// the other.
    static let height: CGFloat = 16

    private var clip: Clip? {
        guard let document = store.document else { return nil }
        // The *first* selected clip in document order, not "the selection".
        // With several selected there is no one gain to show, and showing the
        // first one's while editing all of them would be a number that means
        // something different from what it says.
        for track in document.tracks {
            for candidate in track.clips where store.selectedClipIDs.contains(candidate.id) {
                return candidate
            }
        }
        return nil
    }

    private var selectionCount: Int { store.selectedClipIDs.count }

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            if let clip {
                clipNumbers(clip)
            } else {
                Text("No clip selected")
                    .font(DesignTokens.Typography.Scale.caption())
                    .foregroundStyle(DesignTokens.Colors.textQuaternary)
            }

            Spacer(minLength: DesignTokens.Spacing.sm)

            if selectionCount > 1 {
                Text("\(selectionCount) clips selected")
                    .font(DesignTokens.Typography.Scale.caption())
                    .monospacedDigit()
                    .foregroundStyle(DesignTokens.Colors.textTertiary)
            }
        }
        .padding(.horizontal, DesignTokens.Spacing.lg)
        .frame(height: Self.height)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Selected clip")
    }

    /// The per-clip numbers, which exist nowhere else in the window.
    ///
    /// Gain is the one that is editable, because it is the one a person adjusts
    /// while listening. Start, length and the two fades are readouts: they are
    /// dragged on the clip itself, and a second way to set them from a strip at
    /// the bottom of the window is a second thing to keep in step with the
    /// drag for no gain the drag does not already give.
    private func clipNumbers(_ clip: Clip) -> some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            gainControl(clip)
            readout("Start", EditorFormat.timecode(clip.start))
            readout("Length", EditorFormat.timecode(clip.duration))
            readout("Fades", "\(EditorFormat.seconds(clip.fadeIn)) / \(EditorFormat.seconds(clip.fadeOut))")
        }
    }

    /// `EditorMode.Extra.clipGain`. A number and two steppers, half a decibel
    /// at a time — the increment a listener can actually hear on one clip
    /// against the rest of a mix, and small enough that holding the key is a
    /// usable ramp.
    private func gainControl(_ clip: Clip) -> some View {
        HStack(spacing: DesignTokens.Spacing.xxs) {
            Text("GAIN")
                .font(DesignTokens.Typography.Scale.caption2(.semibold))
                .foregroundStyle(DesignTokens.Colors.textTertiary)

            step(clip, by: -0.5, symbol: "minus")

            Text(EditorFormat.decibels(clip.gainDB))
                .font(DesignTokens.Typography.Scale.caption(.medium))
                .monospacedDigit()
                .foregroundStyle(
                    clip.gainDB == 0
                        ? DesignTokens.Colors.textSecondary
                        : DesignTokens.Colors.accentPrimary
                )
                .frame(width: 44)
                .accessibilityLabel("Clip level")
                .accessibilityValue(EditorFormat.decibels(clip.gainDB))

            step(clip, by: 0.5, symbol: "plus")
        }
    }

    private func step(_ clip: Clip, by delta: Double, symbol: String) -> some View {
        Button {
            store.setClipGain(clip.id, dB: clip.gainDB + delta)
        } label: {
            Image(systemName: symbol)
                .font(DesignTokens.Typography.Scale.caption2(.bold))
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.meloHover)
        .foregroundStyle(DesignTokens.Colors.interactiveDefault)
        .accessibilityLabel(delta < 0 ? "Quieter" : "Louder")
    }

    private func readout(_ title: String, _ value: String) -> some View {
        HStack(spacing: DesignTokens.Spacing.xxs) {
            Text(title.uppercased())
                .font(DesignTokens.Typography.Scale.caption2(.semibold))
                .foregroundStyle(DesignTokens.Colors.textTertiary)
            Text(value)
                .font(DesignTokens.Typography.Scale.caption(.medium))
                .monospacedDigit()
                .foregroundStyle(DesignTokens.Colors.textSecondary)
        }
        .lineLimit(1)
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
}
