// Melo/Editor/Views/Waveform/EditorTimelineLanes.swift
//
// The lanes, the clips in them, and the chrome over the top.
//
// Both canvases here are laid out in the **pane's** coordinate space and offset
// themselves with `EditorTimelineGeometry`, rather than being child views with
// coordinate spaces of their own. That is the whole reason a lane cannot drift
// out of alignment with the ruler: drawing and hit-testing call the same
// function with the same size, so there is no second answer for either of them
// to be wrong about.
//
// They are split in two for the reason they always were: the playhead moves at
// sixty hertz and the clips do not. `EditorTimelineLanes` is `Equatable` and
// used through `.equatable()`, so a moving playhead rebuilds four shapes in the
// chrome instead of two thousand rectangles in the lanes.

import AppKit
import SwiftUI

// MARK: - One clip, ready to draw

/// A clip reduced to what the canvas needs. Built by `EditorWaveformView.plan`
/// from the document **and any drag in progress**, which is why the canvas
/// never reads the document: what is on screen mid-drag is not what is stored.
struct EditorTimelineClipDrawing: Equatable {
    var id: UUID
    /// The source's display name. Melo does not name clips separately — a clip
    /// is a window onto a file, and the file's name is the true answer.
    var name: String
    /// Whether the name is drawn at all. **False for the default project**: one
    /// track, one clip, and the window header already says what the file is.
    /// Drawing it twice is chrome the simple case must not grow.
    var showsName: Bool
    var start: TimeInterval
    var end: TimeInterval
    var fadeIn: TimeInterval
    var fadeOut: TimeInterval
    var fadeShape: EditorClipEdit.FadeShape
    var isSelected: Bool
    var isHovered: Bool
    /// Being dragged, trimmed or faded right now.
    var isLive: Bool
    /// The part of the clip inside the window — the only part sampled or drawn.
    var visible: ClosedRange<TimeInterval>
    /// One entry per channel lane, already scaled by the clip's gain and fades.
    var channels: [[EditorWaveformColumn]]
    var isDense: Bool
}

// MARK: - The lanes

struct EditorTimelineLanes: View, Equatable {

    let lanes: [[EditorTimelineClipDrawing]]
    let window: ClosedRange<TimeInterval>
    let selection: ClosedRange<TimeInterval>?
    let isBypassed: Bool
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
        let lanesRect = EditorTimelineGeometry.lanesRect(in: size)
        guard lanesRect.height > 4 else { return }

        let span = window.upperBound - window.lowerBound
        guard span > 0 else { return }
        func x(_ time: TimeInterval) -> CGFloat {
            CGFloat((time - window.lowerBound) / span) * size.width
        }

        guard !lanes.isEmpty else {
            // Nothing open. One centre line, which is what an empty pane has
            // always shown.
            context.fill(
                Path(CGRect(x: 0, y: lanesRect.midY - 0.5, width: size.width, height: 1)),
                with: .color(EditorWaveformPalette.zeroLine)
            )
            return
        }

        for (index, clips) in lanes.enumerated() {
            let laneRect = EditorTimelineGeometry.laneRect(
                index: index, count: lanes.count, in: lanesRect
            )
            guard laneRect.minY < size.height else { break }

            // The lane's own centre line, under everything. With one track this
            // is exactly the line the bare waveform drew; with three, three
            // lines is what says there are three lanes — no wash, no border, no
            // chrome the simple case did not already have.
            context.fill(
                Path(CGRect(x: 0, y: laneRect.midY - 0.5, width: size.width, height: 1)),
                with: .color(EditorWaveformPalette.zeroLine)
            )

            for clip in clips {
                draw(clip, into: &context, laneRect: laneRect, x: x)
            }
        }
    }

    // MARK: One clip

    private func draw(
        _ clip: EditorTimelineClipDrawing,
        into context: inout GraphicsContext,
        laneRect: CGRect,
        x: (TimeInterval) -> CGFloat
    ) {
        let startX = x(clip.start)
        let endX = x(clip.end)
        guard endX - startX > 0.5 else { return }

        let body = CGRect(x: startX, y: laneRect.minY, width: endX - startX, height: laneRect.height)
        let shape = Path(
            roundedRect: body.insetBy(dx: 0.5, dy: 0.5),
            cornerRadius: EditorWaveformMetrics.clipCorner,
            style: .continuous
        )

        context.fill(shape, with: .color(EditorWaveformPalette.clipFill))
        if clip.isSelected || clip.isLive {
            context.fill(shape, with: .color(Color.accentColor.opacity(0.10)))
        }

        // Everything inside is clipped to the body, so a fade slope, a name and
        // a waveform all stop at the clip's own corners.
        context.drawLayer { inner in
            inner.clip(to: shape)
            drawTitle(clip, into: &inner, body: body)
            drawWaveform(clip, into: &inner, body: body, x: x)
            drawFades(clip, into: &inner, body: body, x: x)
        }

        context.stroke(shape, with: .color(EditorWaveformPalette.clipBorder), lineWidth: 1)
        if clip.isSelected || clip.isLive {
            context.stroke(shape, with: .color(Color.accentColor.opacity(clip.isLive ? 1 : 0.85)), lineWidth: 1.5)
        }
        drawFadeHandles(clip, into: &context, body: body, x: x)
    }

    /// The name strip. **Flat at rest and washed on hover** — Melo's own rule
    /// everywhere else, and here it is also the discovery mechanism: the wash
    /// is what tells the user this strip is the thing that drags the clip,
    /// without a single pixel of chrome when nobody is pointing at it.
    private func drawTitle(
        _ clip: EditorTimelineClipDrawing,
        into context: inout GraphicsContext,
        body: CGRect
    ) {
        let strip = CGRect(
            x: body.minX, y: body.minY,
            width: body.width, height: EditorWaveformMetrics.clipTitleHeight
        )
        if clip.isHovered || clip.isLive {
            context.fill(Path(strip), with: .color(EditorWaveformPalette.clipTitleHover))
        }
        guard clip.showsName, body.width >= EditorWaveformMetrics.clipNameMinimumWidth else { return }
        let text = context.resolve(
            Text(clip.name)
                .font(DesignTokens.Typography.Scale.caption2(.medium))
                .foregroundStyle(DesignTokens.Colors.textTertiary)
        )
        context.draw(
            text,
            at: CGPoint(x: strip.minX + DesignTokens.Spacing.xs2, y: strip.midY),
            anchor: .leading
        )
    }

    private func drawWaveform(
        _ clip: EditorTimelineClipDrawing,
        into context: inout GraphicsContext,
        body: CGRect,
        x: (TimeInterval) -> CGFloat
    ) {
        guard !clip.channels.isEmpty else { return }
        let area = waveArea(body)
        guard area.height > 4 else { return }

        let lowerX = x(clip.visible.lowerBound)
        let upperX = x(clip.visible.upperBound)
        guard upperX - lowerX > 0.5 else { return }

        let painter = EditorWaveformPainter(
            style: style,
            isBypassed: isBypassed,
            isDense: clip.isDense,
            covering: clip.visible,
            selection: selection
        )

        let count = clip.channels.count
        let gap = count > 1 ? EditorWaveformMetrics.channelGap : 0
        let height = (area.height - gap * CGFloat(count - 1)) / CGFloat(count)
        guard height > 2 else { return }

        for (index, columns) in clip.channels.enumerated() {
            painter.draw(
                &context,
                rect: CGRect(
                    x: lowerX,
                    y: area.minY + CGFloat(index) * (height + gap),
                    width: upperX - lowerX,
                    height: height
                ),
                columns: columns
            )
        }
    }

    /// The waveform's part of the clip: everything under the name strip.
    ///
    /// Reserved whether or not a name is drawn, because the strip is the move
    /// handle either way and a handle that sits on top of the waveform is a
    /// handle you cannot tell from the audio.
    private func waveArea(_ body: CGRect) -> CGRect {
        CGRect(
            x: body.minX,
            y: body.minY + EditorWaveformMetrics.clipTitleHeight,
            width: body.width,
            height: max(body.height - EditorWaveformMetrics.clipTitleHeight, 0)
        )
    }

    // MARK: Fades

    /// The fade, twice over.
    ///
    /// **The slope is already in the audio** — the columns were scaled by the
    /// envelope before they got here, so the waveform itself ramps. This draws
    /// the envelope line over the top of it and shades what the fade took away,
    /// because a scaled-down drawing of quiet audio is still quiet audio and
    /// the user has to be able to see the shape they are dragging.
    private func drawFades(
        _ clip: EditorTimelineClipDrawing,
        into context: inout GraphicsContext,
        body: CGRect,
        x: (TimeInterval) -> CGFloat
    ) {
        let area = waveArea(body)
        guard area.height > 6 else { return }
        let top = area.minY
        let mid = area.midY

        /// The envelope's y for a gain: full at the top of the waveform area,
        /// silent at the centre line.
        func y(_ gain: Double) -> CGFloat {
            mid - CGFloat(min(max(gain, 0), 1)) * (mid - top)
        }

        if clip.fadeIn > 0 {
            var curve = Path()
            curve.move(to: CGPoint(x: x(clip.start), y: y(0)))
            for step in 1...24 {
                let position = Double(step) / 24
                let time = clip.start + clip.fadeIn * position
                curve.addLine(
                    to: CGPoint(
                        x: x(time),
                        y: y(EditorClipEdit.fadeGain(position: position, curve: clip.fadeShape))
                    )
                )
            }
            shade(curve, into: &context, body: body, top: top)
            context.stroke(curve, with: .color(fadeInk(clip)), lineWidth: 1.25)
        }

        if clip.fadeOut > 0 {
            var curve = Path()
            curve.move(to: CGPoint(x: x(clip.end), y: y(0)))
            for step in 1...24 {
                let position = Double(step) / 24
                let time = clip.end - clip.fadeOut * position
                curve.addLine(
                    to: CGPoint(
                        x: x(time),
                        y: y(EditorClipEdit.fadeGain(position: position, curve: clip.fadeShape))
                    )
                )
            }
            shade(curve, into: &context, body: body, top: top)
            context.stroke(curve, with: .color(fadeInk(clip)), lineWidth: 1.25)
        }
    }

    /// Fills the wedge between an envelope curve and the top of the waveform —
    /// the part of the signal the fade removed.
    private func shade(
        _ curve: Path,
        into context: inout GraphicsContext,
        body: CGRect,
        top: CGFloat
    ) {
        guard let first = curve.currentPoint else { return }
        var wedge = curve
        wedge.addLine(to: CGPoint(x: first.x, y: top))
        wedge.closeSubpath()
        context.fill(wedge, with: .color(EditorWaveformPalette.fadeShade))
    }

    private func fadeInk(_ clip: EditorTimelineClipDrawing) -> Color {
        Color.accentColor.opacity(clip.isHovered || clip.isSelected || clip.isLive ? 0.95 : 0.6)
    }

    /// The two grab points, in the name strip above the slope they control.
    ///
    /// Drawn when there is a fade to see, and when the pointer is on the clip —
    /// which is the moment the user might want one. A clip with no fades sitting
    /// untouched shows nothing, which is the calm the simple case needs.
    private func drawFadeHandles(
        _ clip: EditorTimelineClipDrawing,
        into context: inout GraphicsContext,
        body: CGRect,
        x: (TimeInterval) -> CGFloat
    ) {
        let visible = clip.isHovered || clip.isSelected || clip.isLive
        let size = EditorWaveformMetrics.fadeHandleSize
        let centreY = body.minY + EditorWaveformMetrics.fadeHandleZone / 2

        func handle(at pointX: CGFloat) {
            guard pointX >= body.minX - size, pointX <= body.maxX + size else { return }
            let rect = CGRect(x: pointX - size / 2, y: centreY - size / 2, width: size, height: size)
            context.fill(Path(ellipseIn: rect), with: .color(Color.accentColor))
            context.stroke(Path(ellipseIn: rect), with: .color(Color.white.opacity(0.75)), lineWidth: 1)
        }

        if clip.fadeIn > 0 || visible { handle(at: x(clip.start + clip.fadeIn)) }
        if clip.fadeOut > 0 || visible { handle(at: x(clip.end - clip.fadeOut)) }
    }
}

// MARK: - Chrome

/// The time selection, its handles, the playhead and the cut flags. Everything
/// that moves while the sound plays, kept out of the lanes canvas so it can
/// redraw cheaply.
struct EditorTimelineChrome: View {

    let window: ClosedRange<TimeInterval>
    let laneCount: Int
    let selection: ClosedRange<TimeInterval>?
    let playhead: TimeInterval
    let hoveredEdge: EditorWaveformView.SelectionEdge?
    let draggingEdge: EditorWaveformView.SelectionEdge?
    let cuts: EditorCutMap.Summary
    let hasSound: Bool

    var body: some View {
        Canvas(opaque: false) { context, size in
            guard hasSound, size.width > 1 else { return }
            let span = window.upperBound - window.lowerBound
            guard span > 0 else { return }
            let lanes = EditorTimelineGeometry.lanesRect(in: size)

            func x(_ time: TimeInterval) -> CGFloat {
                CGFloat((time - window.lowerBound) / span) * size.width
            }

            if let selection {
                drawSelection(
                    &context, size: size, lanes: lanes,
                    from: x(selection.lowerBound), to: x(selection.upperBound)
                )
            }
            drawCutFlags(&context, size: size, lanes: lanes)
            drawPlayhead(&context, lanes: lanes, at: x(playhead))
        }
    }

    /// The selected span, drawn from the top of the ruler to the bottom of the
    /// lanes. Over the ruler as well because that is where a span is *read* —
    /// the numbers that say how long it is are up there.
    private func drawSelection(
        _ context: inout GraphicsContext,
        size: CGSize,
        lanes: CGRect,
        from lowerX: CGFloat,
        to upperX: CGFloat
    ) {
        let clampedLower = max(lowerX, -2)
        let clampedUpper = min(upperX, size.width + 2)
        guard clampedUpper > clampedLower else { return }

        context.fill(
            Path(CGRect(x: clampedLower, y: 0, width: clampedUpper - clampedLower, height: lanes.maxY)),
            with: .color(Color.accentColor.opacity(0.12))
        )
        for edgeX in [lowerX, upperX] where edgeX >= -1 && edgeX <= size.width + 1 {
            context.fill(
                Path(CGRect(x: edgeX - 0.5, y: 0, width: 1, height: lanes.maxY)),
                with: .color(Color.accentColor.opacity(0.85))
            )
        }
        drawHandle(&context, size: size, lanes: lanes, at: lowerX, edge: .lower)
        drawHandle(&context, size: size, lanes: lanes, at: upperX, edge: .upper)
    }

    private func drawHandle(
        _ context: inout GraphicsContext,
        size: CGSize,
        lanes: CGRect,
        at edgeX: CGFloat,
        edge: EditorWaveformView.SelectionEdge
    ) {
        guard edgeX >= -EditorWaveformMetrics.handleWidth,
              edgeX <= size.width + EditorWaveformMetrics.handleWidth else { return }
        let active = hoveredEdge == edge || draggingEdge == edge
        let width = EditorWaveformMetrics.handleWidth
        let height = EditorWaveformMetrics.handleHeight * (active ? 1.15 : 1)
        let rect = CGRect(
            x: edgeX - width / 2,
            y: lanes.midY - height / 2,
            width: width,
            height: height
        )
        context.fill(
            Path(roundedRect: rect, cornerRadius: width / 2, style: .continuous),
            with: .color(Color.accentColor.opacity(active ? 1 : 0.85))
        )
        // Two grip lines, so the handle reads as something to grab rather than
        // as a coloured tick.
        for offset in [-1.25, 1.25] as [CGFloat] {
            context.fill(
                Path(CGRect(x: edgeX + offset - 0.5, y: rect.midY - 5, width: 1, height: 10)),
                with: .color(Color.white.opacity(0.8))
            )
        }
    }

    /// The playhead runs the full height of the ruler and the lanes, with its
    /// cap sitting in the ruler — which is also where you grab it to scrub.
    private func drawPlayhead(_ context: inout GraphicsContext, lanes: CGRect, at playheadX: CGFloat) {
        guard playheadX >= -1, playheadX <= lanes.maxX + 1 else { return }
        context.fill(
            Path(CGRect(x: playheadX - 0.5, y: 0, width: 1, height: lanes.maxY)),
            with: .color(EditorWaveformPalette.playhead)
        )
        var cap = Path()
        cap.move(to: CGPoint(x: playheadX - 5, y: 0))
        cap.addLine(to: CGPoint(x: playheadX + 5, y: 0))
        cap.addLine(to: CGPoint(x: playheadX, y: 7))
        cap.closeSubpath()
        context.fill(cap, with: .color(EditorWaveformPalette.playhead))
    }

    /// What the **master** stack took off, drawn at the ends where it was
    /// taken, along the bottom of the lanes. It used to sit under the ruler,
    /// which is now where a clip's name is.
    private func drawCutFlags(_ context: inout GraphicsContext, size: CGSize, lanes: CGRect) {
        guard !cuts.isEmpty else { return }
        let y = lanes.maxY - 4

        if let head = cuts.headRemoved {
            draw(&context, label: "✂ " + EditorFormat.seconds(head),
                 at: CGPoint(x: 4, y: y), anchor: .bottomLeading)
        }
        if let tail = cuts.tailRemoved {
            draw(&context, label: EditorFormat.seconds(tail) + " ✂",
                 at: CGPoint(x: size.width - 4, y: y), anchor: .bottomTrailing)
        }
        if let shortened = cuts.shortenedBy, cuts.headRemoved == nil, cuts.tailRemoved == nil {
            draw(&context, label: EditorFormat.seconds(shortened) + " shorter",
                 at: CGPoint(x: 4, y: y), anchor: .bottomLeading)
        }
    }

    private func draw(_ context: inout GraphicsContext, label: String, at point: CGPoint, anchor: UnitPoint) {
        let text = context.resolve(
            Text(label)
                .font(DesignTokens.Typography.Scale.caption2(.semibold).monospacedDigit())
                .foregroundStyle(EditorWaveformPalette.cutFlag)
        )
        context.draw(text, at: point, anchor: anchor)
    }
}
