// Melo/Editor/Views/Tracks/EditorTrackMetrics.swift
//
// The geometry the header column and the timeline lanes must agree on.
//
// **The lanes own lane height; this file owns the floor under it.**
//
// `EditorWaveformMetrics` / `EditorTimelineGeometry` in
// `Editor/Views/Waveform/` divide the pane between the tracks:
// `(lanes.height − gaps) / count`, clamped up to a minimum, with the ruler
// reserved above and the scroll strip reserved below. That is one formula and
// it is not reimplemented here. The header column reaches the identical numbers
// by handing the same three constants — ruler, scroll strip, gap — to a
// `VStack` of equally flexible rows and letting the layout system do the
// division, which is the one arithmetic that cannot drift from itself.
//
// The single number the two sides genuinely have to share is the floor, and it
// belongs on this side: what a lane can shrink to is decided by what a header
// needs, and a header cannot go under `Dimensions.minTouchTarget`.

import SwiftUI

/// What a track header needs, and therefore what a lane may not go below.
enum EditorTrackMetrics {

    // MARK: The rows of one header

    /// Name and the options menu. 22 rather than 28 because nothing on this row
    /// is a control the pointer has to acquire cold — the name is a
    /// double-click target the width of the column, and the menu button carries
    /// its own 22pt square inside a row that is already hoverable.
    static let nameRowHeight: CGFloat = 22

    /// Mute, solo, the fader and its readout. **Not a free choice.**
    /// `MuteButton` is built to `Dimensions.minTouchTarget`, so this row
    /// inherits 28 whatever else happens to it.
    static let levelRowHeight: CGFloat = DesignTokens.Dimensions.minTouchTarget

    /// Pan. `LiquidGlassSlider` draws itself at
    /// `Dimensions.sliderHitHeight`, which is 20.
    static let panRowHeight: CGFloat = DesignTokens.Dimensions.sliderHitHeight

    /// Between the three rows, and around them.
    static let rowSpacing: CGFloat = DesignTokens.Spacing.xs

    /// **The one number the lanes and the headers must both hold.**
    ///
    /// Derived rather than picked: 22 + 28 + 20 for the three rows, 4 twice
    /// between them, 4 twice around them — 86. A lane shorter than this is a
    /// lane whose header cannot be drawn, and a header that changes shape at a
    /// height the user reaches by adding a track (rather than by resizing
    /// anything) is a worse answer than lanes that stop shrinking.
    ///
    /// `EditorWaveformMetrics.minimumLaneHeight` has to equal this. It is
    /// currently 44, which is the height a *drawing* can survive and not the
    /// height a header can; 44 was written before there was a header to
    /// measure. **This is the one cross-directory change this piece needs.**
    ///
    /// What it costs, stated rather than discovered later: `n` tracks keep
    /// full-height lanes while the timeline pane has `92n + 26` points — 86
    /// each, 6 of gap between, 32 for the ruler and scroll strip — and the pane
    /// is the window less 130. So five tracks at the 640pt window the harness
    /// renders, three at the 520pt minimum. Past that both sides clip at the
    /// bottom until there is a shared vertical scroller.
    static var minimumLaneHeight: CGFloat {
        nameRowHeight + levelRowHeight + panRowHeight + rowSpacing * 4
    }

    // MARK: The column

    /// How wide the header column is.
    ///
    /// Narrow on purpose: this is enough to name a track and quiet it, not a
    /// mixer channel strip. At the 820pt minimum window, 320 of sidebar and 200
    /// of this leave about 297pt of waveform — thin, and the thinnest it ever
    /// gets, because the column is not drawn at all until there are two tracks.
    ///
    /// *Rejected:* 240pt with room for a wider fader. The fader is what suffers
    /// here — 68pt of travel over 36 dB — and it still loses: the waveform is
    /// the thing the user is looking at, and 40pt off the drawing to make a
    /// slider nicer is the wrong trade in a window whose whole point is the
    /// drawing.
    static let columnWidth: CGFloat = 200

    /// The blank band above the first header, and the blank band below the
    /// last one.
    ///
    /// Mirrored from the lanes rather than guessed: `EditorWaveformView` draws
    /// the ruler as the first band of the timeline pane and reserves the
    /// horizontal scroll strip as the last one, and the header column has to
    /// reserve exactly the same two or every lane sits at a different height
    /// from its header.
    ///
    /// **The bottom band must be reserved whether or not the scroll bar is
    /// drawn.** A strip that appears only when zoomed in changes the height
    /// available to the lanes, which changes every lane height, which shears
    /// the entire column against the entire timeline on a zoom. That is a
    /// property of the timeline pane, not of this file, and it is the one thing
    /// this column cannot compensate for.
    static var topBand: CGFloat { EditorWaveformMetrics.rulerHeight }
    static var bottomBand: CGFloat { EditorWaveformMetrics.scrollBarHeight }

    /// Between two headers, and between two lanes. The lanes' number, read
    /// rather than repeated.
    static var laneGap: CGFloat { EditorWaveformMetrics.laneGap }
}

/// Pan, as a string.
///
/// Its own type because two surfaces read it — the control and the header's
/// accessibility value — and a second spelling of "24% left" is the kind of
/// disagreement nobody notices until a VoiceOver user reports it.
enum EditorPanFormat {
    /// "C", "24L", "60R". Short, because it sits in a 30pt readout.
    static func short(_ pan: Double) -> String {
        let percent = Int((abs(pan) * 100).rounded())
        if percent == 0 { return "C" }
        return pan < 0 ? "\(percent)L" : "\(percent)R"
    }

    /// "Center", "24% left", "60% right". What VoiceOver says.
    static func spoken(_ pan: Double) -> String {
        let percent = Int((abs(pan) * 100).rounded())
        if percent == 0 { return "Center" }
        return pan < 0 ? "\(percent)% left" : "\(percent)% right"
    }
}
