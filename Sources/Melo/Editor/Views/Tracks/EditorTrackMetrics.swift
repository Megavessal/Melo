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
    ///
    /// **Full mode only** — `EditorMode.Extra.trackPan`. The height is still
    /// counted into `minimumLaneHeight` in both modes; see the note there.
    static let panRowHeight: CGFloat = DesignTokens.Dimensions.sliderHitHeight

    /// The level bar. 6pt, and it is a bar rather than a row: it sits directly
    /// under the name with 1pt of air, inside the name row's own band, so a
    /// meter costs the header six points and not a fourth row of controls.
    static let meterBarHeight: CGFloat = 6

    /// The decibel ladder under the bar. Full mode only —
    /// `EditorMode.Extra.meterScale`. 10 is `caption2`'s cap height plus the
    /// 2pt tick; anything less clips the numerals' descender-free digits, which
    /// looks like a rendering fault rather than a tight layout.
    static let meterScaleHeight: CGFloat = 10

    /// Between the rows, and around them.
    ///
    /// **2, down from 4.** The VEGAS pass is density: four rows at 4pt spent 20
    /// points of a lane that can be as short as 86 on air between controls that
    /// are already separated by being different shapes. Measured against the
    /// alternative of cutting a row instead — there is no row to cut, the name,
    /// the meter, the fader and the pan are each the answer to a different
    /// question — so the air goes and the controls stay.
    static let rowSpacing: CGFloat = DesignTokens.Spacing.xxs

    /// The colour band down the leading edge of a header.
    ///
    /// 3, not the 2 the panel headers use for their open stripe. That one marks
    /// a binary state on a strip the eye is already reading; this one has to be
    /// identifiable *as a colour* at a glance across a column of six, and 2
    /// points of a mid-tone hue on a dark ground reads as a slightly lighter
    /// edge rather than as blue.
    static let stripeWidth: CGFloat = 3

    /// **The one number the lanes and the headers must both hold, and it does
    /// not move when the mode does.**
    ///
    /// Derived rather than picked, and it mirrors the stack in
    /// `TrackHeaderRow.content` line for line: four children — the name row
    /// (22), the meter block (6 + 1 + 10 = 17), the fader row (28) and pan (20)
    /// — three gaps of 2 between them and 2 of padding at each end. 97.
    ///
    /// ## Why the Full arrangement is the floor in both modes
    ///
    /// The rule that governs the whole mode feature is that **switching adds
    /// and removes panels and never moves the timeline or the waveform**. Two
    /// of Full's additions live inside a track header — pan and the meter's
    /// decibel ladder, 30 points between them — so a floor computed from
    /// whichever mode is current would be 98 in Full and 68 in Simple. That
    /// number is what stops lanes shrinking, so at four or more tracks in a
    /// normal window it *binds*, and switching modes would resize every lane
    /// and redraw every waveform at a new height. The person would press a
    /// control labelled "show me more" and watch the thing they were looking at
    /// jump.
    ///
    /// So the floor is Full's, always. What it costs is honest and small:
    /// Simple reserves 30 points per lane it does not draw into, which is
    /// visible only past the point where the floor binds at all — four tracks
    /// in a 640pt window — and what it buys is that a mode switch cannot move a
    /// single pixel of the timeline. Measured the other way round in the scenes:
    /// `cutting-room-mode-full` and `cutting-room-mode-simple` are rendered at
    /// the same size with the same document, and the lane geometry assertion
    /// reads the live timeline rather than trusting this comment.
    ///
    /// `EditorWaveformMetrics.minimumLaneHeight` no longer has to be *kept*
    /// equal to this — it forwards to it
    /// (`EditorTimelineViewport.swift:80`), so raising the number here raises
    /// the lanes' floor in the same edit and the two cannot drift. The comment
    /// this replaces asked for that change; it has since been made.
    ///
    /// One stale sentence is left behind by it, in a file this piece does not
    /// own: `EditorTimelineViewport.swift:139` still reads "`minimumLaneHeight`
    /// is 86" while arguing that the compare lane's 44pt threshold cannot bite.
    /// The argument survives — 97 is further above 44 than 86 was — but the
    /// number is now wrong and is named in the run report.
    ///
    /// What it costs, stated rather than discovered later: `n` tracks keep
    /// full-height lanes while the timeline pane has `103n + 26` points — 97
    /// each, 6 of gap between, 32 for the ruler and scroll strip — and the pane
    /// is the window less 130. So four tracks at the 640pt window the harness
    /// renders (down from five), three at the 520pt minimum. Past that both
    /// sides clip at the bottom until there is a shared vertical scroller.
    static var minimumLaneHeight: CGFloat {
        nameRowHeight
            + meterBlockHeight
            + levelRowHeight
            + panRowHeight
            + rowSpacing * 5
    }

    /// The bar, the point of air under it, and the ladder. Reserved in both
    /// modes even though Simple draws only the bar — see the note above.
    static var meterBlockHeight: CGFloat {
        meterBarHeight + meterScaleGap + meterScaleHeight
    }

    /// Between the meter bar and its ladder. One point, because the ladder's
    /// ticks grow *out of* the bar and any more air makes them read as a
    /// separate row of marks.
    static let meterScaleGap: CGFloat = 1

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
