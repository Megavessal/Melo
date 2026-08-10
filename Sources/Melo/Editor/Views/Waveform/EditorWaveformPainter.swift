// Melo/Editor/Views/Waveform/EditorWaveformPainter.swift
//
// The four ways Melo draws audio, and the colours they draw it in.
//
// This used to be four private methods on the lanes canvas, which was fine
// while there was one lane filling the pane. A clip has to draw the same four
// styles inside its own rectangle, several clips to a lane and several lanes to
// a pane — so the routines are a value you can point at a rect, and the canvas
// is one of its callers rather than its owner.
//
// **There is still exactly one implementation of each style.** The style
// picker's thumbnails, the timeline's clips and the bare lanes canvas all reach
// the same code. A second drawing of `.pixel` somewhere would be the first
// thing to go stale.

import AppKit
import SwiftUI

// MARK: - Palette

/// The waveform gets its own fixed colours, following the precedent
/// `DesignTokens.Colors` already sets for the VU meter: a readout of what the
/// audio *is* does not change hue with the user's accent. The accent is spent
/// on the selection chrome instead, where it means "you did this".
///
/// **Clips are not coloured per track.** Eight rotating hues is what a lot of
/// DAWs do and it is the opposite of what this app is: Melo's palette is
/// deliberate everywhere else, and a timeline that assigns a random colour to
/// track 5 has made a decision the user did not. Which lane a clip is on is
/// already unambiguous — it is the lane it is drawn on. Rejected: per-track hue
/// rotation, and a user-pickable clip colour, which is a preference in search
/// of a problem.
enum EditorWaveformPalette {

    /// The stripe and tab for a marker dropped with M.
    ///
    /// Green, and not the accent. The accent is already the playhead and the
    /// selected clip's ring, and a third thing in the same colour turns the
    /// accent into decoration rather than a signal. Green because it is the one
    /// hue the waveform's cool blues and the selection's warm amber both leave
    /// alone, so a marker is never mistaken for either.
    static let marker = DesignTokens.dynamicColor(
        name: "editorWaveformMarker",
        light: NSColor(srgbRed: 0.13, green: 0.55, blue: 0.34, alpha: 0.92),
        dark: NSColor(srgbRed: 0.36, green: 0.85, blue: 0.56, alpha: 0.90)
    )

    /// The number inside the tab. Near-black in both appearances, because the
    /// tab is a saturated green in both and white on it fails contrast in
    /// light mode.
    static let markerLabel = DesignTokens.dynamicColor(
        name: "editorWaveformMarkerLabel",
        light: NSColor.white.withAlphaComponent(0.98),
        dark: NSColor.black.withAlphaComponent(0.86)
    )

    static let ground = DesignTokens.dynamicColor(
        name: "editorWaveformGround",
        light: NSColor.black.withAlphaComponent(0.045),
        dark: NSColor.black.withAlphaComponent(0.30)
    )

    static let zeroLine = DesignTokens.dynamicColor(
        name: "editorWaveformZeroLine",
        light: NSColor.black.withAlphaComponent(0.16),
        dark: NSColor.white.withAlphaComponent(0.14)
    )

    /// Peak envelope — the quiet outer silhouette.
    static let peak = DesignTokens.dynamicColor(
        name: "editorWaveformPeak",
        light: NSColor(srgbRed: 0.34, green: 0.44, blue: 0.60, alpha: 0.42),
        dark: NSColor(srgbRed: 0.54, green: 0.70, blue: 0.94, alpha: 0.34)
    )

    /// RMS body — the dense core drawn inside the peak. Two weights rather than
    /// one silhouette is what makes a waveform read as a real one.
    static let body = DesignTokens.dynamicColor(
        name: "editorWaveformBody",
        light: NSColor(srgbRed: 0.15, green: 0.26, blue: 0.45, alpha: 0.94),
        dark: NSColor(srgbRed: 0.66, green: 0.83, blue: 1.00, alpha: 0.96)
    )

    /// Inside the time selection. Warm against the cool base so the selected
    /// span is unmistakable in a still frame — the accent alone would not be,
    /// because the harness window is never key and macOS desaturates its tint.
    ///
    /// **A selected *clip* does not use this.** There are two selections on
    /// this surface and they have to be told apart at a glance: a span of time
    /// goes warm, a selected clip gets an accent ring round its body. One
    /// signal for each, never both for one.
    static let peakSelected = DesignTokens.dynamicColor(
        name: "editorWaveformPeakSelected",
        light: NSColor(srgbRed: 0.76, green: 0.50, blue: 0.14, alpha: 0.46),
        dark: NSColor(srgbRed: 1.00, green: 0.79, blue: 0.42, alpha: 0.36)
    )

    static let bodySelected = DesignTokens.dynamicColor(
        name: "editorWaveformBodySelected",
        light: NSColor(srgbRed: 0.52, green: 0.30, blue: 0.02, alpha: 0.96),
        dark: NSColor(srgbRed: 1.00, green: 0.84, blue: 0.52, alpha: 0.98)
    )

    /// While the stack is held bypassed the clips go grey, so a still frame
    /// says which of the two things the user is hearing.
    static let peakBypassed = DesignTokens.dynamicColor(
        name: "editorWaveformPeakBypassed",
        light: NSColor.black.withAlphaComponent(0.18),
        dark: NSColor.white.withAlphaComponent(0.16)
    )

    static let bodyBypassed = DesignTokens.dynamicColor(
        name: "editorWaveformBodyBypassed",
        light: NSColor.black.withAlphaComponent(0.42),
        dark: NSColor.white.withAlphaComponent(0.46)
    )

    /// The compare lane's ink while the *edit* is what you are hearing.
    ///
    /// Cooler and quieter than `peak`/`body` rather than a second hue. Two
    /// waveforms in two colours read as two different sounds; two waveforms in
    /// two weights of the same colour read as the same sound twice, which is
    /// what they are. The reference is the quiet one because the thing being
    /// judged is above it.
    ///
    /// **The two inks swap when bypass is engaged** — see
    /// `EditorTimelineLanes.draw(_:into:laneRect:x:)`. Whichever picture you are
    /// listening to is the one drawn at full weight, and the other goes to
    /// `peakBypassed`/`bodyBypassed`. That inversion is the marker: it needs no
    /// badge, it is impossible to miss in a still frame, and it cannot get out
    /// of step with the sound because both sides read the same flag.
    static let comparePeak = DesignTokens.dynamicColor(
        name: "editorComparePeak",
        light: NSColor(srgbRed: 0.34, green: 0.44, blue: 0.60, alpha: 0.26),
        dark: NSColor(srgbRed: 0.54, green: 0.70, blue: 0.94, alpha: 0.22)
    )

    static let compareBody = DesignTokens.dynamicColor(
        name: "editorCompareBody",
        light: NSColor(srgbRed: 0.15, green: 0.26, blue: 0.45, alpha: 0.52),
        dark: NSColor(srgbRed: 0.66, green: 0.83, blue: 1.00, alpha: 0.54)
    )

    /// The strip's own ground, a shade recessed from the clip above it so the
    /// two readings are visibly two objects and not one tall waveform.
    static let compareGround = DesignTokens.dynamicColor(
        name: "editorCompareGround",
        light: NSColor.black.withAlphaComponent(0.05),
        dark: NSColor.black.withAlphaComponent(0.22)
    )

    /// "Original", and the marker that says it is the one playing.
    static let compareLabel = DesignTokens.dynamicColor(
        name: "editorCompareLabel",
        light: NSColor.black.withAlphaComponent(0.45),
        dark: NSColor.white.withAlphaComponent(0.48)
    )

    static let playhead = DesignTokens.dynamicColor(
        name: "editorWaveformPlayhead",
        light: NSColor.black.withAlphaComponent(0.84),
        dark: NSColor.white.withAlphaComponent(0.92)
    )

    static let cutFlag = DesignTokens.dynamicColor(
        name: "editorWaveformCutFlag",
        light: NSColor(srgbRed: 0.72, green: 0.22, blue: 0.16, alpha: 0.90),
        dark: NSColor(srgbRed: 1.00, green: 0.46, blue: 0.40, alpha: 0.88)
    )

    static let rulerTickMajor = DesignTokens.dynamicColor(
        name: "editorWaveformTickMajor",
        light: NSColor.black.withAlphaComponent(0.34),
        dark: NSColor.white.withAlphaComponent(0.30)
    )

    static let rulerTickMinor = DesignTokens.dynamicColor(
        name: "editorWaveformTickMinor",
        light: NSColor.black.withAlphaComponent(0.16),
        dark: NSColor.white.withAlphaComponent(0.14)
    )

    // MARK: Clips

    /// A clip's body. Barely there on purpose: at one track and one clip the
    /// body covers the whole lane, and the wash has to be quiet enough that the
    /// pane still looks like the single waveform it was.
    ///
    /// This is not the resting fill `CLAUDE.md` forbids. That rule is about
    /// rows inside the popup, where a fill breaks the material they are meant
    /// to blend with and `hoverSurface` is the interaction signal. A clip is a
    /// drawn object on an opaque ground that has to have an extent you can see
    /// — a clip with no body is not a clip.
    static let clipFill = DesignTokens.dynamicColor(
        name: "editorClipFill",
        light: NSColor.white.withAlphaComponent(0.34),
        dark: NSColor.white.withAlphaComponent(0.045)
    )

    /// The hairline round a clip. The same weight as the zero line, so a clip
    /// edge and a centre line read as the same kind of mark.
    static let clipBorder = DesignTokens.dynamicColor(
        name: "editorClipBorder",
        light: NSColor.black.withAlphaComponent(0.14),
        dark: NSColor.white.withAlphaComponent(0.12)
    )

    /// The name strip's wash, on hover only. Melo's own rule: flat at rest,
    /// `hoverSurface` is what says a thing is interactive. It is what tells the
    /// user the strip is the handle without a single pixel of chrome at rest.
    static let clipTitleHover = DesignTokens.dynamicColor(
        name: "editorClipTitleHover",
        light: NSColor.black.withAlphaComponent(0.07),
        dark: NSColor.white.withAlphaComponent(0.09)
    )

    /// The part of a clip a fade has turned down, drawn over the waveform as a
    /// wedge of the ground colour. The slope is in the waveform itself; this is
    /// what makes the slope legible over quiet audio, where a scaled-down
    /// waveform of nothing is still nothing.
    static let fadeShade = DesignTokens.dynamicColor(
        name: "editorClipFadeShade",
        light: NSColor.black.withAlphaComponent(0.07),
        dark: NSColor.black.withAlphaComponent(0.22)
    )
}

// MARK: - Columns

/// One vertical slice of the picture: the peak excursion and the RMS level over
/// the audio that lands under a single column of pixels.
struct EditorWaveformColumn: Equatable, Sendable {
    var minimum: Float
    var maximum: Float
    var rms: Float

    static let silent = EditorWaveformColumn(minimum: 0, maximum: 0, rms: 0)

    /// Everything scaled by one gain. What a clip's fade envelope and its own
    /// `gainDB` do to the drawing — the fade becomes a real slope in the
    /// waveform rather than a triangle laid over an unchanged one.
    func scaled(by gain: Double) -> EditorWaveformColumn {
        guard gain != 1 else { return self }
        let factor = Float(max(gain, 0))
        return EditorWaveformColumn(minimum: minimum * factor, maximum: maximum * factor, rms: rms * factor)
    }

    /// Several columns as one: the widest excursion any of them saw, and the
    /// root-mean-square of their squares — **not** the mean of their roots,
    /// which is wrong and looks it, because quiet passages inflate.
    ///
    /// Used along time (several pixels under one bar or one block) and across
    /// channels (two channels merged into one lane when the clip is too short
    /// to split). The rule is the same in both directions, so it is written
    /// once.
    static func merged<S: Sequence>(_ columns: S) -> EditorWaveformColumn where S.Element == EditorWaveformColumn {
        var minimum = Float.greatestFiniteMagnitude
        var maximum = -Float.greatestFiniteMagnitude
        var meanSquare = 0.0
        var count = 0
        for column in columns {
            minimum = min(minimum, column.minimum)
            maximum = max(maximum, column.maximum)
            meanSquare += Double(column.rms) * Double(column.rms)
            count += 1
        }
        guard count > 0 else { return .silent }
        return EditorWaveformColumn(
            minimum: minimum,
            maximum: maximum,
            rms: Float((meanSquare / Double(count)).squareRoot())
        )
    }
}

/// Turns whatever buckets are to hand into exactly the columns a rectangle has,
/// for exactly the span of time it covers.
///
/// The same function serves the sharp path and the fallback: a detail response
/// covers the visible window at the visible width and maps one-to-one, and a
/// whole-source overview maps many-to-one. Having one resampler means the
/// picture never disappears while a detail request is in flight — it only gets
/// sharper when the response lands.
enum EditorWaveformSampler {

    static func columns(
        buckets: [WaveformData.Bucket],
        lanes: Int,
        lane: Int,
        covering source: ClosedRange<TimeInterval>,
        window target: ClosedRange<TimeInterval>,
        count: Int
    ) -> [EditorWaveformColumn] {
        let laneCount = max(lanes, 1)
        let perLane = buckets.count / laneCount
        let sourceSpan = source.upperBound - source.lowerBound
        guard perLane > 0, count > 0, sourceSpan > 0 else { return [] }

        let targetSpan = target.upperBound - target.lowerBound
        guard targetSpan > 0 else { return [] }

        let bucketsPerSecond = Double(perLane) / sourceSpan
        var output = [EditorWaveformColumn](repeating: .silent, count: count)

        for index in 0..<count {
            let t0 = target.lowerBound + targetSpan * Double(index) / Double(count)
            let t1 = target.lowerBound + targetSpan * Double(index + 1) / Double(count)
            // Outside the buckets we were given: genuinely silent, not zero
            // data drawn as if measured.
            guard t1 > source.lowerBound, t0 < source.upperBound else { continue }

            var low = Int(((t0 - source.lowerBound) * bucketsPerSecond).rounded(.down))
            var high = Int(((t1 - source.lowerBound) * bucketsPerSecond).rounded(.up))
            low = min(max(low, 0), perLane - 1)
            high = min(max(high, low + 1), perLane)

            var minimum = Float.greatestFiniteMagnitude
            var maximum = -Float.greatestFiniteMagnitude
            var meanSquare = 0.0
            for bucketIndex in low..<high {
                let bucket = buckets[bucketIndex * laneCount + lane]
                minimum = min(minimum, bucket.minimum)
                maximum = max(maximum, bucket.maximum)
                meanSquare += Double(bucket.rms) * Double(bucket.rms)
            }
            let taken = high - low
            output[index] = EditorWaveformColumn(
                minimum: minimum,
                maximum: maximum,
                rms: Float((meanSquare / Double(taken)).squareRoot())
            )
        }
        return output
    }

    /// One lane per channel when the buckets divide evenly by it, one lane
    /// otherwise. The fallback is not defensive noise: a summed waveform is a
    /// true picture of the sound and two lanes of half a file is not, so an
    /// unexpected bucket count degrades to the honest drawing.
    static func laneCount(bucketCount: Int, channels: Int) -> Int {
        guard channels > 1, bucketCount >= channels * 2, bucketCount % channels == 0 else { return 1 }
        return channels
    }
}

// MARK: - The painter

/// Draws columns into a rectangle, in one of the four styles.
///
/// Held as a value and pointed at a rect, because a clip is a rect inside a
/// lane inside a pane and the same routine has to serve all three depths.
struct EditorWaveformPainter {

    let style: EditorWaveformStyle
    let isBypassed: Bool
    /// Drawing the compare lane's reference rather than the edit.
    ///
    /// A `var` with a default so the memberwise initialiser keeps its old
    /// shape: the style picker's four thumbnails, the bare lanes canvas and the
    /// clip painter all construct this by label, and a fourth required
    /// argument would have been three edits in two other files to say "no" in
    /// each of them.
    ///
    /// It is a third ink and not `isBypassed` reused. Bypassed means *this
    /// picture is not what you are hearing*; original means *this picture is
    /// the reference*. On the compare lane the two are independent and the
    /// caller sets both, which is what lets the pair invert when bypass is
    /// engaged.
    var isOriginal: Bool = false
    /// Whether there is at least one bucket behind every couple of columns.
    let isDense: Bool
    /// The span of time the columns cover, so a time selection can be resolved
    /// per column without the painter knowing what a viewport is.
    let covering: ClosedRange<TimeInterval>
    let selection: ClosedRange<TimeInterval>?

    // MARK: The one rule every style obeys
    //
    // **The RMS core is only ever drawn when `isDense`.** Below that there are
    // fewer buckets than columns — either genuinely past sample resolution, or
    // a detail render that has not landed yet — and one bucket repeated across
    // forty columns paints as a solid slab of constant level. That slab is the
    // most confident-looking thing on the screen and it is not a measurement of
    // anything: it is one number stretched. The peak extent is true at every
    // scale, because a bucket really does assert that the signal ranged between
    // those two values over the span it covers, however many columns that span
    // is drawn across. So the envelope survives the zoom and the core does not.
    //
    // `.line` never draws a core at all, which is why it is the only style that
    // looks the same coarse as it does dense.

    private var drawsCore: Bool { isDense }

    func drawZeroLine(_ context: inout GraphicsContext, rect: CGRect) {
        context.fill(
            Path(CGRect(x: rect.minX, y: rect.midY - 0.5, width: rect.width, height: 1)),
            with: .color(EditorWaveformPalette.zeroLine)
        )
    }

    func draw(_ context: inout GraphicsContext, rect: CGRect, columns: [EditorWaveformColumn]) {
        guard rect.width > 0.5, rect.height > 2 else { return }
        drawZeroLine(&context, rect: rect)
        guard !columns.isEmpty else { return }

        switch style {
        case .bars: drawBars(&context, rect: rect, columns: columns)
        case .pixel: drawPixel(&context, rect: rect, columns: columns)
        case .filled: drawFilled(&context, rect: rect, columns: columns)
        case .line: drawLine(&context, rect: rect, columns: columns)
        }
    }

    // MARK: Filled

    /// What Melo Edit shipped with: the peak envelope as a filled silhouette,
    /// the RMS core filled inside it, and — when the data is coarser than the
    /// pixels — a line through the bucket midpoints in place of the core.
    private func drawFilled(_ context: inout GraphicsContext, rect: CGRect, columns: [EditorWaveformColumn]) {
        let geometry = LaneGeometry(rect: rect)
        let columnWidth = rect.width / CGFloat(columns.count)

        var peakOutside = Path()
        var peakInside = Path()
        var bodyOutside = Path()
        var bodyInside = Path()
        var linePath = Path()
        var lineStarted = false

        for (index, column) in columns.enumerated() {
            let x = rect.minX + CGFloat(index) * columnWidth
            let selected = isSelected(from: index, to: index + 1, of: columns.count)

            // A hairline for silence: nothing at all reads as missing data
            // rather than as quiet.
            let peakRect = CGRect(
                x: x,
                y: geometry.y(column.maximum),
                width: columnWidth,
                height: max(geometry.y(column.minimum) - geometry.y(column.maximum), 1)
            )
            if selected { peakInside.addRect(peakRect) } else { peakOutside.addRect(peakRect) }

            if drawsCore {
                let rms = geometry.length(column.rms)
                let bodyRect = CGRect(
                    x: x,
                    y: geometry.midY - rms,
                    width: columnWidth,
                    height: max(rms * 2, 1)
                )
                if selected { bodyInside.addRect(bodyRect) } else { bodyOutside.addRect(bodyRect) }
            } else {
                let value = (column.maximum + column.minimum) / 2
                let point = CGPoint(x: x + columnWidth / 2, y: geometry.y(value))
                if lineStarted {
                    linePath.addLine(to: point)
                } else {
                    linePath.move(to: point)
                    lineStarted = true
                }
            }
        }

        context.fill(peakOutside, with: .color(peakColor(selected: false)))
        context.fill(peakInside, with: .color(peakColor(selected: true)))
        if lineStarted {
            context.stroke(linePath, with: .color(bodyColor(selected: false)), lineWidth: 1.25)
        }
        context.fill(bodyOutside, with: .color(bodyColor(selected: false)))
        context.fill(bodyInside, with: .color(bodyColor(selected: true)))
    }

    // MARK: Bars

    /// Discrete bars on a fixed pitch, each one the peak extent of the audio
    /// under it, with the RMS core as a second bar inside.
    ///
    /// The columns are *not* resampled to the bar pitch upstream. Sampling stays
    /// at one column per physical pixel and the bars aggregate what lands under
    /// them, so a transient two pixels wide still raises the bar it falls in
    /// rather than being missed by a coarser sample grid.
    private func drawBars(_ context: inout GraphicsContext, rect: CGRect, columns: [EditorWaveformColumn]) {
        let geometry = LaneGeometry(rect: rect)
        let columnWidth = rect.width / CGFloat(columns.count)
        let pitch = EditorWaveformMetrics.barWidth + EditorWaveformMetrics.barGap
        let perBar = max(1, Int((pitch / columnWidth).rounded()))

        var peakOutside = Path()
        var peakInside = Path()
        var bodyOutside = Path()
        var bodyInside = Path()

        var start = 0
        while start < columns.count {
            let end = min(start + perBar, columns.count)
            let column = EditorWaveformColumn.merged(columns[start..<end])
            let selected = isSelected(from: start, to: end, of: columns.count)
            let x = rect.minX + CGFloat(start) * columnWidth
            // The gap comes out of the right of every bar, including the last,
            // so the pitch is constant and the bars do not shuffle by a
            // half-pixel as the window scrolls.
            let width = max(CGFloat(end - start) * columnWidth - EditorWaveformMetrics.barGap, 1)

            let top = geometry.y(column.maximum)
            let bar = CGRect(x: x, y: top, width: width, height: max(geometry.y(column.minimum) - top, 1))
            if selected { peakInside.addRect(bar) } else { peakOutside.addRect(bar) }

            if drawsCore {
                let rms = geometry.length(column.rms)
                let core = CGRect(x: x, y: geometry.midY - rms, width: width, height: max(rms * 2, 1))
                if selected { bodyInside.addRect(core) } else { bodyOutside.addRect(core) }
            }
            start = end
        }

        context.fill(peakOutside, with: .color(peakColor(selected: false)))
        context.fill(peakInside, with: .color(peakColor(selected: true)))
        context.fill(bodyOutside, with: .color(bodyColor(selected: false)))
        context.fill(bodyInside, with: .color(bodyColor(selected: true)))
    }

    // MARK: Pixel

    /// Blocks on a square grid, the technique the app icon is drawn in.
    ///
    /// The grid is derived from the lane rather than fixed in absolute points:
    /// a whole number of rows has to fit between the centre line and full scale
    /// or a peak of 1.0 would stop short of the top by up to one block, and the
    /// cell is squared off that row height so the blocks are blocks.
    ///
    /// Peak blocks and core blocks are drawn in disjoint row ranges rather than
    /// stacked. Both palette colours carry alpha, and overlapping them would
    /// make the core a third colour that is in no palette.
    private func drawPixel(_ context: inout GraphicsContext, rect: CGRect, columns: [EditorWaveformColumn]) {
        let geometry = LaneGeometry(rect: rect)
        let rows = max(2, Int((geometry.half / EditorWaveformMetrics.pixelCell).rounded()))
        let cell = geometry.half / CGFloat(rows)
        let gridColumns = max(1, Int((rect.width / cell).rounded()))
        let cellWidth = rect.width / CGFloat(gridColumns)
        let inset = min(EditorWaveformMetrics.pixelInset, min(cellWidth, cell) / 4)

        var peakOutside = Path()
        var peakInside = Path()
        var bodyOutside = Path()
        var bodyInside = Path()

        for gridIndex in 0..<gridColumns {
            let low = columns.count * gridIndex / gridColumns
            let high = max(low + 1, columns.count * (gridIndex + 1) / gridColumns)
            guard low < columns.count else { break }
            let column = EditorWaveformColumn.merged(columns[low..<min(high, columns.count)])
            let selected = isSelected(from: low, to: min(high, columns.count), of: columns.count)
            let x = rect.minX + CGFloat(gridIndex) * cellWidth + inset
            let width = max(cellWidth - inset * 2, 0.5)

            let up = Self.blocks(column.maximum, rows: rows)
            let down = Self.blocks(-column.minimum, rows: rows)
            // The core can never poke out of the envelope it is inside.
            let core = drawsCore ? min(Self.blocks(column.rms, rows: rows), min(up, down)) : 0

            func block(_ row: Int, above: Bool) -> CGRect {
                let y = above
                    ? geometry.midY - CGFloat(row + 1) * cell
                    : geometry.midY + CGFloat(row) * cell
                return CGRect(x: x, y: y + inset, width: width, height: max(cell - inset * 2, 0.5))
            }

            for row in core..<up {
                let blockRect = block(row, above: true)
                if selected { peakInside.addRect(blockRect) } else { peakOutside.addRect(blockRect) }
            }
            for row in core..<down {
                let blockRect = block(row, above: false)
                if selected { peakInside.addRect(blockRect) } else { peakOutside.addRect(blockRect) }
            }
            for row in 0..<core {
                let above = block(row, above: true)
                let below = block(row, above: false)
                if selected {
                    bodyInside.addRect(above)
                    bodyInside.addRect(below)
                } else {
                    bodyOutside.addRect(above)
                    bodyOutside.addRect(below)
                }
            }
        }

        context.fill(peakOutside, with: .color(peakColor(selected: false)))
        context.fill(peakInside, with: .color(peakColor(selected: true)))
        context.fill(bodyOutside, with: .color(bodyColor(selected: false)))
        context.fill(bodyInside, with: .color(bodyColor(selected: true)))
    }

    /// How many whole blocks a level of `0...1` reaches, floored at one for
    /// anything audible. Rounding alone would draw quiet audio as nothing at
    /// all, which on a grid this coarse is indistinguishable from silence.
    private static func blocks(_ level: Float, rows: Int) -> Int {
        guard level > 0 else { return 0 }
        return max(1, min(rows, Int((Double(min(level, 1)) * Double(rows)).rounded())))
    }

    // MARK: Line

    /// The peak outline, stroked, with nothing inside it.
    ///
    /// Two polylines rather than one closed shape, because the top and the
    /// bottom of a real waveform are not mirror images and drawing one from the
    /// other would be inventing half the picture.
    private func drawLine(_ context: inout GraphicsContext, rect: CGRect, columns: [EditorWaveformColumn]) {
        let geometry = LaneGeometry(rect: rect)
        let columnWidth = rect.width / CGFloat(columns.count)

        var top = SplitPolyline()
        var bottom = SplitPolyline()

        for (index, column) in columns.enumerated() {
            let x = rect.minX + (CGFloat(index) + 0.5) * columnWidth
            let selected = isSelected(from: index, to: index + 1, of: columns.count)
            top.add(CGPoint(x: x, y: geometry.y(column.maximum)), selected: selected)
            bottom.add(CGPoint(x: x, y: geometry.y(column.minimum)), selected: selected)
        }

        for polyline in [top, bottom] {
            context.stroke(polyline.outside, with: .color(bodyColor(selected: false)), lineWidth: 1)
            context.stroke(polyline.inside, with: .color(bodyColor(selected: true)), lineWidth: 1)
        }
    }

    // MARK: Shared

    /// Where the centre line is and how far full scale is from it, so four draw
    /// routines cannot disagree about it.
    private struct LaneGeometry {
        let midY: CGFloat
        let half: CGFloat

        init(rect: CGRect) {
            midY = rect.midY
            half = max(rect.height / 2 - 1, 1)
        }

        /// The y of a signed sample value, clamped to the lane.
        func y(_ value: Float) -> CGFloat {
            midY - CGFloat(min(max(value, -1), 1)) * half
        }

        /// How far an unsigned level reaches from the centre line.
        func length(_ value: Float) -> CGFloat {
            CGFloat(min(max(value, 0), 1)) * half
        }
    }

    /// Whether the midpoint of the columns in `start..<end` falls in the time
    /// selection. The midpoint rather than either edge, so a bar straddling a
    /// selection boundary belongs to whichever side most of it is on.
    private func isSelected(from start: Int, to end: Int, of count: Int) -> Bool {
        guard let selection, count > 0 else { return false }
        let span = covering.upperBound - covering.lowerBound
        let centre = covering.lowerBound + span * ((Double(start) + Double(end)) / 2 / Double(count))
        return selection.contains(centre)
    }

    /// A polyline that changes colour partway along, kept as two paths.
    ///
    /// The point at which the run changes is added to *both* paths. Without
    /// that the stroke would have a one-column hole at every selection edge,
    /// which at a 1pt line width reads as a rendering defect rather than as a
    /// boundary.
    private struct SplitPolyline {
        var outside = Path()
        var inside = Path()
        private var started = false
        private var wasSelected = false

        mutating func add(_ point: CGPoint, selected: Bool) {
            guard started else {
                if selected { inside.move(to: point) } else { outside.move(to: point) }
                started = true
                wasSelected = selected
                return
            }
            if wasSelected { inside.addLine(to: point) } else { outside.addLine(to: point) }
            if selected != wasSelected {
                if selected { inside.move(to: point) } else { outside.move(to: point) }
                wasSelected = selected
            }
        }
    }

    // Bypassed outranks original, and original outranks the time selection.
    //
    // Bypassed first because it answers "is this what I am hearing", which is
    // the question the user has in their hand while a key is held down.
    // Original before selected because the compare strip is a reference and a
    // reference that goes warm inside a time selection would compete with the
    // edit above it for the same signal — the selection is already drawn across
    // both, by the chrome, in one unbroken band.
    private func peakColor(selected: Bool) -> Color {
        if isBypassed { return EditorWaveformPalette.peakBypassed }
        if isOriginal { return EditorWaveformPalette.comparePeak }
        return selected ? EditorWaveformPalette.peakSelected : EditorWaveformPalette.peak
    }

    private func bodyColor(selected: Bool) -> Color {
        if isBypassed { return EditorWaveformPalette.bodyBypassed }
        if isOriginal { return EditorWaveformPalette.compareBody }
        return selected ? EditorWaveformPalette.bodySelected : EditorWaveformPalette.body
    }
}

// MARK: - The bare lanes canvas

/// Columns drawn across a rectangle with nothing else in it — one lane per
/// channel, no clips, no chrome.
///
/// Kept because `EditorWaveformStylePicker` draws its four thumbnails with it,
/// and a picker that hand-drew four little waveforms would be a second
/// implementation of every style and the first thing to go stale. The timeline
/// itself no longer uses this: its clips paint through `EditorWaveformPainter`
/// directly, into their own rects.
///
/// `Equatable` and used through `.equatable()` so a playhead moving at sixty
/// hertz does not rebuild two thousand rectangles it did not change.
struct EditorWaveformLanesCanvas: View, Equatable {

    let lanes: [[EditorWaveformColumn]]
    let window: ClosedRange<TimeInterval>
    let selection: ClosedRange<TimeInterval>?
    let isBypassed: Bool
    let isDense: Bool
    let style: EditorWaveformStyle
    /// Not read directly — the palette is dynamic — but a colour scheme change
    /// has to invalidate the cached drawing, and equality is what decides that.
    let scheme: ColorScheme

    // `nonisolated` because SwiftUI's `View` carries `@MainActor` onto this
    // type, and `Equatable.==` is a nonisolated requirement. Every stored
    // property here is an immutable `Sendable` value, so reading them off the
    // main actor is sound.
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.isBypassed == rhs.isBypassed
            && lhs.isDense == rhs.isDense
            && lhs.style == rhs.style
            && lhs.scheme == rhs.scheme
            && lhs.selection == rhs.selection
            && lhs.window == rhs.window
            && lhs.lanes == rhs.lanes
    }

    var body: some View {
        Canvas(opaque: false) { context, size in
            draw(&context, size: size)
        }
    }

    private func draw(_ context: inout GraphicsContext, size: CGSize) {
        guard size.width > 1, size.height > 1 else { return }
        let painter = EditorWaveformPainter(
            style: style,
            isBypassed: isBypassed,
            isDense: isDense,
            covering: window,
            selection: selection
        )
        guard !lanes.isEmpty else {
            painter.drawZeroLine(&context, rect: CGRect(origin: .zero, size: size))
            return
        }

        let count = lanes.count
        let gap = count > 1 ? EditorWaveformMetrics.laneGap : 0
        let laneHeight = (size.height - gap * CGFloat(count - 1)) / CGFloat(count)
        guard laneHeight > 2 else { return }

        for (index, columns) in lanes.enumerated() {
            painter.draw(
                &context,
                rect: CGRect(
                    x: 0,
                    y: CGFloat(index) * (laneHeight + gap),
                    width: size.width,
                    height: laneHeight
                ),
                columns: columns
            )
        }
    }
}
