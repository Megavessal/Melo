// Melo/Editor/Views/Waveform/EditorTimelineViewport.swift
//
// The timeline's arithmetic, with nothing in it that can draw.
//
// **This file imports Foundation and CoreGraphics and nothing else, on
// purpose.** Every rule that decides where a moment lands on screen, where a
// lane sits, what the pointer is over, and what a drag does to a clip's numbers
// lives here as a pure function over values. That makes the whole of it
// compilable and assertable with `xcrun swiftc` without SwiftUI, AppKit, a
// window or a decoded file — which is the only kind of proof this piece can
// offer, since the render harness photographs states and not gestures.
//
// The view in `EditorWaveformView.swift` owns the observable object, the
// gestures and the drawing. It holds one of these and forwards to it. Anything
// in here that needed `@Published`, `GraphicsContext` or `NSEvent` would be in
// the wrong file.

import CoreGraphics
import Foundation

// MARK: - Metrics

/// Every fixed dimension the timeline draws or grabs by.
///
/// **The track-header column reads `laneRect` from here.** The headers and the
/// lanes are drawn by two different views in two different panes, and a lane
/// that can disagree with its header about where it starts is the defect that
/// makes a timeline feel amateur. There is one function that answers it.
enum EditorWaveformMetrics {

    static let rulerHeight: CGFloat = 22

    /// **Reserved whether or not the scroll bar is drawn.** It used to appear
    /// only when zoomed in, which meant every lane changed height the moment
    /// the user zoomed — invisible when the lanes were the only thing in the
    /// pane, and a visible shear against a header column that did not move.
    /// Ten points of empty strip at fit-to-window costs nothing and removes the
    /// whole class.
    static let scrollBarHeight: CGFloat = 10

    /// Half-width of a selection handle's grab zone. 9pt either side of the
    /// edge is an 18pt target for a 6pt-wide grip — real to hit, quiet to look
    /// at. `Dimensions.minTouchTarget` is the floor for a control the pointer
    /// has to acquire cold; a handle sits on a line the user is already aiming
    /// at, and 28pt of grab either side of a selection edge would swallow short
    /// selections whole. The same number is the clip's trim grab.
    static let handleGrab: CGFloat = 9
    static let handleWidth: CGFloat = 6
    static let handleHeight: CGFloat = 26

    /// How far the pointer travels before a click becomes a drag.
    static let dragThreshold: CGFloat = 3

    /// Between two track lanes.
    static let laneGap: CGFloat = 6

    /// A lane never goes below this, even if that means the lanes together
    /// overflow the pane.
    ///
    /// **Owned by the header column, not by the lanes, and read from there.**
    /// This side used to hold 44, which is the height a *drawing* survives; the
    /// binding constraint turned out to be the height a *header* survives —
    /// `MuteButton` is built to `Dimensions.minTouchTarget` and cannot shrink —
    /// and that is 86. A lane and its header that stop shrinking at different
    /// heights shear apart, so there is one number and it lives where the
    /// requirement is. `EditorTrackMetrics` reads `rulerHeight`, `laneGap` and
    /// `scrollBarHeight` back from here; the floor is the one that goes the
    /// other way.
    ///
    /// **The pane does not scroll vertically**, and neither does the header
    /// column — the two builders arrived at that separately. So `n` tracks keep
    /// full-height lanes while the pane has `92n + 26` points: five tracks at
    /// the 640pt window the harness renders, three at the 520pt minimum, and
    /// past that both sides clip at the bottom together. That is the trade, and
    /// it is the right one for now: a scroll offset the lanes and the headers
    /// both have to agree about is a shared contract nobody has written, and
    /// `ImageRenderer` cannot draw `ScrollView` content at all
    /// (`CLAUDE.md`), so the first version of it would be invisible to every
    /// frame anyone looked at.
    static var minimumLaneHeight: CGFloat { EditorTrackMetrics.minimumLaneHeight }

    /// How close a dragged edge has to come to a landmark before it snaps.
    static let snapPoints: CGFloat = 4

    // MARK: Clips

    /// The clip body's corner. `Dimensions.Shape.xs`'s radius, spelled as a
    /// number because a `Canvas` draws paths and not shapes.
    static let clipCorner: CGFloat = 4

    /// The band across the top of a clip that drags it. **This is why a clip
    /// has a name strip**: dragging the body has to keep meaning "select a
    /// range of time", because that is what it means today and what every move
    /// in the stack is aimed with. Giving the move gesture the title strip is
    /// what Ableton does and it is the only placement that costs the existing
    /// gesture nothing.
    static let clipTitleHeight: CGFloat = 14

    /// Below this on-screen width the clip's name is not drawn — a truncated
    /// name in 30 points of space is a smear, not a label.
    static let clipNameMinimumWidth: CGFloat = 56

    /// A clip narrower than this is all move target and has no trim zones. Two
    /// 9pt grabs and a body do not fit in 20 points, and the clip you cannot
    /// grab is worse than the clip you cannot trim without zooming in.
    static let clipMinimumGrabWidth: CGFloat = 22

    /// The vertical band at a clip's top corners where the fade handles live.
    /// Below it, the same x is the trim edge. Vertical position is what
    /// separates two handles that start life at the same point.
    static let fadeHandleZone: CGFloat = 12
    static let fadeHandleSize: CGFloat = 7

    /// A clip body shorter than this draws its channels merged into one lane.
    /// Two 24pt sub-lanes and the gap between them is the floor at which a
    /// stereo split is still a drawing of two channels rather than two stripes.
    static let channelSplitMinimumHeight: CGFloat = 54
    static let channelGap: CGFloat = 3

    /// `.bars`: 2pt of ink and 1pt of air. Below about 2pt a bar stops reading
    /// as an object and becomes a texture, which is the filled style with extra
    /// steps; above about 4pt the picture starts throwing away detail the
    /// buckets actually have.
    static let barWidth: CGFloat = 2
    static let barGap: CGFloat = 1

    /// `.pixel`: the edge of one block, before it is rounded so a whole number
    /// of them fills half a lane exactly. Five points at Melo's window sizes is
    /// roughly fourteen blocks from the centre line to the top — the same order
    /// as the 18×9 and 20×11 grids the app icon and the menu-bar mark are drawn
    /// on, which is what makes this read as the same drawing technique rather
    /// than as a coarse bar chart.
    static let pixelCell: CGFloat = 5
    /// The air around each block. Half a point at a five-point cell is a tenth
    /// of the grid: enough that the blocks are countable, little enough that a
    /// solid passage still reads as solid.
    static let pixelInset: CGFloat = 0.5
}

// MARK: - The viewport

/// What part of the timeline is on screen.
///
/// **One of these is shared by the ruler and every lane.** They are not three
/// views that each keep a scroll offset and try to stay in step; they are one
/// number read three times in the same layout pass.
struct EditorTimelineViewport: Equatable, Sendable {

    /// Left edge of the visible window, in seconds of timeline time.
    var start: TimeInterval = 0
    /// Width of the visible window, in seconds. Equal to `duration` when the
    /// whole project is on screen.
    var visible: TimeInterval = 1
    /// End of the last clip. The model's own definition of length — it does not
    /// wait for a render, which is what lets a clip dragged past the old end
    /// extend the ruler on the same frame.
    var duration: TimeInterval = 1
    var sampleRate: Double = 48_000
    var width: CGFloat = 600

    // MARK: Derived

    var end: TimeInterval { start + visible }
    var window: ClosedRange<TimeInterval> { start...(start + visible) }
    var secondsPerPoint: Double { visible / max(Double(width), 1) }
    var isFitToWindow: Bool { visible >= duration - 0.0005 }

    /// The deepest zoom: two milliseconds, or sixty-four sample frames,
    /// whichever is longer.
    ///
    /// **The two-millisecond floor is the one that binds**, at every sample
    /// rate Melo will meet — 64 frames is 1.3 ms at 48 kHz and 0.67 ms at
    /// 96 kHz, so the `max` picks 0.002 either way. Which is fine and is the
    /// point: two milliseconds is 96 sample frames across a 660pt pane, about
    /// seven points per sample, and that is sample-adjacent by any definition.
    /// The 64-frame term only takes over below about 32 kHz.
    ///
    /// Measured rather than reasoned: an earlier version of this comment
    /// claimed sixty-four frames across the surface, which the arithmetic never
    /// produced.
    var minimumVisible: TimeInterval {
        min(duration, max(0.002, 64 / max(sampleRate, 1)))
    }

    // MARK: Mapping

    func time(atX x: CGFloat, width surfaceWidth: CGFloat) -> TimeInterval {
        start + Double(x / max(surfaceWidth, 1)) * visible
    }

    func x(for time: TimeInterval, width surfaceWidth: CGFloat) -> CGFloat {
        CGFloat((time - start) / max(visible, .leastNormalMagnitude)) * surfaceWidth
    }

    func time(atX x: CGFloat) -> TimeInterval { time(atX: x, width: width) }
    func x(for time: TimeInterval) -> CGFloat { x(for: time, width: width) }

    func clampToSound(_ time: TimeInterval) -> TimeInterval {
        min(max(time, 0), duration)
    }

    // MARK: Zoom

    /// Logarithmic, because linear zoom spends 90% of a slider's travel on the
    /// first 10% of the useful range.
    var zoomFraction: Double {
        let span = log(duration / minimumVisible)
        guard span > 0, span.isFinite else { return 0 }
        return min(max(log(duration / max(visible, minimumVisible)) / span, 0), 1)
    }

    /// Zooms so `anchorFraction` of the surface keeps the moment that is under
    /// it. Getting this wrong is the single most common way a timeline feels
    /// amateur, so it is the only way this value changes `visible`.
    @discardableResult
    mutating func setVisible(_ target: TimeInterval, anchorFraction: Double) -> Bool {
        let anchor = min(max(anchorFraction, 0), 1)
        let anchorTime = start + anchor * visible
        let resolved = min(max(target, minimumVisible), duration)
        var changed = assign(start: anchorTime - anchor * resolved, visible: resolved)
        changed = clamp() || changed
        return changed
    }

    @discardableResult
    mutating func zoom(by factor: Double, anchorFraction: Double) -> Bool {
        guard factor > 0, factor.isFinite else { return false }
        return setVisible(visible / factor, anchorFraction: anchorFraction)
    }

    @discardableResult
    mutating func setZoomFraction(_ fraction: Double, anchorFraction: Double) -> Bool {
        let span = log(duration / minimumVisible)
        guard span > 0, span.isFinite else { return false }
        return setVisible(
            duration / exp(min(max(fraction, 0), 1) * span),
            anchorFraction: anchorFraction
        )
    }

    @discardableResult
    mutating func fitAll() -> Bool {
        assign(start: 0, visible: duration)
    }

    // MARK: Scroll

    @discardableResult
    mutating func setStart(_ newStart: TimeInterval) -> Bool {
        assign(start: min(max(newStart, 0), max(duration - visible, 0)), visible: visible)
    }

    // MARK: Follow

    /// Where the playhead has to reach before the view pages forward.
    static let followLead: Double = 0.85
    /// Where the playhead lands after a page: a tenth in from the left, so
    /// there is a little of what just played still visible behind it.
    static let followLanding: Double = 0.1

    /// Pages the window when the playhead walks out of it.
    ///
    /// **A page, not a slide.** Re-centring on every frame makes the audio move
    /// continuously under a fixed playhead, which is genuinely unpleasant to
    /// watch and destroys the one thing a waveform is for — a stable picture
    /// you can point at. So the window stays still while the playhead crosses
    /// it, and jumps once when it reaches 85%. Silent when the whole project is
    /// already on screen, because there is nowhere to page to.
    ///
    /// The caller decides whether following is on at all; this only decides
    /// where the window goes when it is.
    @discardableResult
    mutating func page(toReveal time: TimeInterval) -> Bool {
        guard !isFitToWindow else { return false }
        guard time < start || time > start + visible * Self.followLead else { return false }
        return setStart(time - visible * Self.followLanding)
    }

    /// Brings a range into view when it misses the window entirely. A range
    /// that already overlaps what is on screen is left alone — jumping then
    /// would throw away the place the user was looking at for nothing.
    @discardableResult
    mutating func reveal(range: ClosedRange<TimeInterval>) -> Bool {
        guard !isFitToWindow else { return false }
        guard range.upperBound < start || range.lowerBound > start + visible else { return false }
        return setStart(range.lowerBound - visible * Self.followLanding)
    }

    // MARK: Bounds

    @discardableResult
    mutating func clamp() -> Bool {
        let boundedVisible = min(max(visible, minimumVisible), duration)
        let boundedStart = min(max(start, 0), max(duration - boundedVisible, 0))
        return assign(start: boundedStart, visible: boundedVisible)
    }

    /// The only place `start` and `visible` are written. Reports whether
    /// anything actually moved, so a mutator that changed nothing notifies
    /// nobody.
    @discardableResult
    private mutating func assign(start newStart: TimeInterval, visible newVisible: TimeInterval) -> Bool {
        var changed = false
        if visible != newVisible { visible = newVisible; changed = true }
        if start != newStart { start = newStart; changed = true }
        return changed
    }
}

// MARK: - Lane layout

/// One clip, reduced to the numbers the timeline needs to place it and hit-test
/// it. Built from the document every pass — including any drag the user has in
/// progress, which is why the hit-testing and the drawing cannot read the
/// document directly and both read this.
struct EditorClipFrame: Equatable, Identifiable, Sendable {
    var id: UUID
    /// Index of the lane it is on, top to bottom.
    var trackIndex: Int
    var start: TimeInterval
    var end: TimeInterval
    var fadeIn: TimeInterval
    var fadeOut: TimeInterval

    var duration: TimeInterval { max(0, end - start) }
}

/// Which part of a clip the pointer is over. Each one is a different drag.
enum EditorClipPart: Equatable, Sendable {
    /// The name strip across the top. Drags the clip, along the timeline and
    /// between lanes.
    case move
    /// Anywhere else inside. Selects the clip, and drags a range of time
    /// exactly as the bare waveform did before clips existed.
    case body
    case trimStart
    case trimEnd
    case fadeIn
    case fadeOut
}

enum EditorTimelineHit: Equatable, Sendable {
    case clip(id: UUID, part: EditorClipPart)
    /// Empty space on a lane.
    case lane(index: Int)
    /// The ruler, where a drag scrubs.
    case ruler
    case outside
}

/// Where the lanes are, and what is under the pointer.
///
/// Pure and static. The header column in the other pane calls `laneRect` for
/// exactly the same reason the lanes canvas does.
enum EditorTimelineGeometry {

    /// The lanes area: the pane less the ruler above and the scroll strip
    /// below. Both are reserved unconditionally.
    static func lanesRect(in size: CGSize) -> CGRect {
        let top = EditorWaveformMetrics.rulerHeight
        let bottom = EditorWaveformMetrics.scrollBarHeight
        return CGRect(
            x: 0,
            y: top,
            width: size.width,
            height: max(size.height - top - bottom, 0)
        )
    }

    static func laneHeight(count: Int, in lanes: CGRect) -> CGFloat {
        let tracks = max(count, 1)
        let gaps = EditorWaveformMetrics.laneGap * CGFloat(tracks - 1)
        return max(
            EditorWaveformMetrics.minimumLaneHeight,
            (lanes.height - gaps) / CGFloat(tracks)
        )
    }

    static func laneRect(index: Int, count: Int, in lanes: CGRect) -> CGRect {
        let height = laneHeight(count: count, in: lanes)
        return CGRect(
            x: lanes.minX,
            y: lanes.minY + CGFloat(index) * (height + EditorWaveformMetrics.laneGap),
            width: lanes.width,
            height: height
        )
    }

    /// Which lane a y falls on, or `nil` for the gap between two of them and
    /// for anything past the last one. The gap is deliberately not owned by
    /// either neighbour: a drag that lands a clip on the lane above because the
    /// pointer was two points high is worse than one that does nothing.
    static func laneIndex(atY y: CGFloat, count: Int, in lanes: CGRect) -> Int? {
        guard count > 0, y >= lanes.minY else { return nil }
        let height = laneHeight(count: count, in: lanes)
        let pitch = height + EditorWaveformMetrics.laneGap
        let index = Int((y - lanes.minY) / pitch)
        guard index >= 0, index < count else { return nil }
        let offset = y - lanes.minY - CGFloat(index) * pitch
        return offset <= height ? index : nil
    }

    /// The nearest lane to a y, with no dead zone. What a clip drag uses: the
    /// pointer in a gap has to mean *something*, and the nearest lane is the
    /// only answer that does not drop the drag.
    static func nearestLaneIndex(atY y: CGFloat, count: Int, in lanes: CGRect) -> Int {
        guard count > 1 else { return 0 }
        let height = laneHeight(count: count, in: lanes)
        let pitch = height + EditorWaveformMetrics.laneGap
        let raw = Int(((y - lanes.minY) / pitch).rounded(.down))
        return min(max(raw, 0), count - 1)
    }

    /// What the pointer is over.
    ///
    /// Clips are tested last-to-first, so an overlapping clip drawn on top is
    /// the one you grab. Within a clip the order is fade handle, then trim
    /// edge, then title strip, then body — from the smallest and most specific
    /// target to the largest.
    static func hitTest(
        _ point: CGPoint,
        frames: [EditorClipFrame],
        laneCount: Int,
        in size: CGSize,
        viewport: EditorTimelineViewport
    ) -> EditorTimelineHit {
        if point.y < EditorWaveformMetrics.rulerHeight { return .ruler }
        let lanes = lanesRect(in: size)
        guard let lane = laneIndex(atY: point.y, count: laneCount, in: lanes) else { return .outside }
        let rect = laneRect(index: lane, count: laneCount, in: lanes)

        for frame in frames.reversed() where frame.trackIndex == lane {
            let startX = viewport.x(for: frame.start, width: size.width)
            let endX = viewport.x(for: frame.end, width: size.width)
            let grab = EditorWaveformMetrics.handleGrab
            guard point.x >= startX - grab, point.x <= endX + grab else { continue }

            let inTopBand = point.y <= rect.minY + EditorWaveformMetrics.fadeHandleZone
            if inTopBand {
                let fadeInX = viewport.x(for: frame.start + frame.fadeIn, width: size.width)
                if abs(point.x - fadeInX) <= grab { return .clip(id: frame.id, part: .fadeIn) }
                let fadeOutX = viewport.x(for: frame.end - frame.fadeOut, width: size.width)
                if abs(point.x - fadeOutX) <= grab { return .clip(id: frame.id, part: .fadeOut) }
            }

            // Too narrow to hold three targets: it is all move, so it can at
            // least be picked up and dropped somewhere it can be worked on.
            if endX - startX < EditorWaveformMetrics.clipMinimumGrabWidth {
                return .clip(id: frame.id, part: .move)
            }

            if abs(point.x - startX) <= grab { return .clip(id: frame.id, part: .trimStart) }
            if abs(point.x - endX) <= grab { return .clip(id: frame.id, part: .trimEnd) }
            guard point.x >= startX, point.x <= endX else { continue }

            if point.y <= rect.minY + EditorWaveformMetrics.clipTitleHeight {
                return .clip(id: frame.id, part: .move)
            }
            return .clip(id: frame.id, part: .body)
        }
        return .lane(index: lane)
    }
}

// MARK: - Clip edits

/// What a clip drag does to a clip's four numbers.
///
/// **These exist so the picture under the pointer is the picture the store will
/// commit.** A clip drag is previewed locally and written once on mouse-up —
/// one undo entry for a drag that moves eight clips, and no debounced re-render
/// per tick. That only works if the preview clamps the way the store clamps, so
/// the rules are written here as pure functions, executed in
/// `scripts/…/timeline-assertions` against the numbers
/// `EditorStore.moveClip`, `trimClip` and `setClipFades` use.
///
/// The store re-clamps on commit and the store wins. If these two ever
/// disagree, the visible symptom is a clip that jumps by a hair on release —
/// which is a defect, not a safety net.
enum EditorClipEdit {

    /// A millisecond, matching `Clip.minimumDuration`. Spelled again rather
    /// than imported because this file deliberately knows nothing about the
    /// document model.
    static let minimumDuration: TimeInterval = 0.001

    /// Moving a clip along the timeline. The only clamp is the head of the
    /// timeline: there is no end to run off.
    static func moved(start: TimeInterval, by delta: TimeInterval) -> TimeInterval {
        max(0, start + delta)
    }

    /// The largest leftward move a set of clips can make together without any
    /// one of them going negative — so a multi-clip drag keeps its spacing
    /// instead of collapsing the leftmost clip against zero.
    static func clampedGroupDelta(_ delta: TimeInterval, earliestStart: TimeInterval) -> TimeInterval {
        max(delta, -earliestStart)
    }

    /// Dragging the leading edge. **`start` moves with `sourceIn` by the same
    /// amount**, so the audio under the pointer stays where it is on the
    /// timeline. That is what an edge drag means everywhere else, and it is
    /// what makes the trim look reversible — because it is: nothing is cut,
    /// two numbers move, and dragging back out restores audio that was never
    /// thrown away.
    static func trimmedStart(
        sourceIn: TimeInterval,
        sourceOut: TimeInterval,
        start: TimeInterval,
        to target: TimeInterval
    ) -> (sourceIn: TimeInterval, start: TimeInterval) {
        let upper = max(0, sourceOut - minimumDuration)
        let resolved = min(max(target, 0), max(0, upper))
        return (resolved, max(0, start + (resolved - sourceIn)))
    }

    /// Dragging the trailing edge. `start` does not move; the window grows or
    /// shrinks at its far end, bounded by the source.
    static func trimmedEnd(
        sourceIn: TimeInterval,
        to target: TimeInterval,
        sourceDuration: TimeInterval
    ) -> TimeInterval {
        let lower = min(sourceIn + minimumDuration, sourceDuration)
        return min(max(target, lower), max(lower, sourceDuration))
    }

    /// A fade handle. Neither fade can run past the clip and the two together
    /// cannot overlap.
    static func fade(_ target: TimeInterval, otherFade: TimeInterval, clipDuration: TimeInterval) -> TimeInterval {
        min(max(target, 0), max(0, clipDuration - otherFade))
    }

    /// What a fade multiplies the signal by, `position` running 0…1 across the
    /// fade. The three curves are the three `FadeCurve` cases, spelled here as
    /// a number because this is what the drawing needs — the clip's waveform is
    /// scaled by it, so the fade is a real slope in the picture and not a
    /// triangle laid over one.
    ///
    /// `equalPower` is `sin(π/2 · p)`, which is −3 dB at the midpoint and the
    /// reason a crossfade made of two of them holds level. Linear is −6 dB
    /// there and audibly dips.
    static func fadeGain(position: Double, curve: FadeShape) -> Double {
        let clamped = min(max(position, 0), 1)
        switch curve {
        case .linear: return clamped
        case .equalPower: return sin(clamped * .pi / 2)
        case .exponential: return clamped * clamped
        }
    }

    /// The three shapes, mirroring `FadeCurve` without depending on it. The
    /// view converts; this file stays free of the document model so it can be
    /// compiled and asserted on its own.
    enum FadeShape: Equatable, Sendable { case linear, equalPower, exponential }

    /// The gain a clip's own envelope applies at a point inside it: both fades
    /// and nothing else. Used to scale the drawn columns, which is what makes
    /// dragging a fade handle change the waveform rather than draw a wedge over
    /// it.
    static func envelopeGain(
        at offset: TimeInterval,
        clipDuration: TimeInterval,
        fadeIn: TimeInterval,
        fadeOut: TimeInterval,
        curve: FadeShape
    ) -> Double {
        var gain = 1.0
        if fadeIn > 0, offset < fadeIn {
            gain *= fadeGain(position: offset / fadeIn, curve: curve)
        }
        if fadeOut > 0, offset > clipDuration - fadeOut {
            gain *= fadeGain(position: (clipDuration - offset) / fadeOut, curve: curve)
        }
        return min(max(gain, 0), 1)
    }
}
