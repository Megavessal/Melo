// Melo/Editor/Views/Waveform/EditorWaveformView.swift
//
// The thing the user looks at for the whole session.
//
// Three decisions hold this file up.
//
// 1. **It draws in a SwiftUI `Canvas`, not an `NSView`.** `SnapshotHarness`
//    cannot draw `NSViewRepresentable` content on the `.imageRenderer` path
//    (`Utilities/SnapshotHarness.swift:165-172`), which is the path this
//    project's anchor tells critics to judge from. A Metal or CALayer waveform
//    would be blank in every frame anyone ever looked at.
//
// 2. **The timeline is output time — what the render engine produces, and what
//    export will write.** `CuttingRoomStore.refreshWaveform` renders the whole
//    document and `clampTimeline(to:)` clamps the playhead and the selection to
//    *that* duration, so a view drawing source time would disagree with the
//    store about where the end of the sound is the moment a trim was applied.
//    The cost is named at `EditorCutMap`: an interior splice from
//    `removeSilence` has no position in output time that this view can compute.
//
// 3. **Only the visible range is ever requested.** `EditorWaveformDetail` asks
//    `RenderEngine.waveform` for the window on screen at the width on screen;
//    the store's 2048-bucket overview is the fallback that keeps a picture up
//    while that is in flight. Asking for the whole file at full resolution and
//    clipping is how a "lightweight" editor becomes a fan-spinner.

import AppKit
import SwiftUI

// MARK: - Viewport

/// What part of the sound is on screen, shared between the waveform and the
/// transport's zoom control because they are siblings in the window and neither
/// owns the other.
///
/// A singleton for the same reason `CuttingRoomStore` is: there is one Cutting
/// Room window, and `CuttingRoomWindowController.shared` is the only thing that
/// opens it.
@MainActor
final class EditorTimeline: ObservableObject {

    static let shared = EditorTimeline()

    // MARK: - State
    //
    // `start` and `visible` are **not** `@Published`, and that is the load-bearing
    // decision in this file. Two separate defects came from their being so:
    //
    //  * A published write from a `GeometryProxy` `onChange` — which SwiftUI
    //    dispatches inside `NSHostingView.layout()` — re-entered AppKit's
    //    constraint system mid display cycle and killed the app on a SIGTRAP.
    //  * Deferring that write off the layout pass fixed the crash and bought a
    //    new bug: the window adopted the sound one main-actor turn late, so the
    //    first frame of a 4:10 file was a one-second window of it. The render
    //    harness photographed exactly that, and a user opening a file would have
    //    seen the same flash.
    //
    // Both go away if adopting a sound does not need to notify anybody. It does
    // not: the view that adopts is the view that is already rendering, and it
    // reads the result straight back out of `adopt`. Only a change the *user*
    // makes has to reach a sibling — the transport's zoom slider and the
    // waveform are in different subtrees — and those all arrive from gestures,
    // buttons and the key monitor, never from layout. So user changes bump
    // `revision` and adoption stays silent.

    /// Bumped by user-driven changes only, so `@ObservedObject` observers redraw.
    /// Never bumped by `adopt`.
    @Published private(set) var revision: Int = 0

    /// Left edge of the visible window, in seconds of output time.
    private(set) var start: TimeInterval = 0
    /// Width of the visible window, in seconds. Equal to `duration` when the
    /// whole sound is on screen.
    private(set) var visible: TimeInterval = 1

    private(set) var duration: TimeInterval = 1
    private(set) var sampleRate: Double = 48_000
    private(set) var width: CGFloat = 600

    /// Where the pointer is, 0…1 across the surface. Anchors scroll-zoom and pinch.
    var pointerFraction: Double = 0.5
    /// Set while the user is dragging, so playback's follow-the-playhead does
    /// not yank the view out from under them.
    var isUserAdjusting = false

    private var adoptedSourceID: UUID?
    private var appliedSeed: Seed?

    private init() {}

    // MARK: Derived

    var end: TimeInterval { start + visible }
    var window: ClosedRange<TimeInterval> { start...(start + visible) }
    var secondsPerPoint: Double { visible / max(Double(width), 1) }
    var isFitToWindow: Bool { visible >= duration - 0.0005 }

    /// The deepest zoom. Sixty-four sample frames across the whole surface is
    /// sample-adjacent by any definition — at 48 kHz on a 700pt view that is
    /// about eleven points per sample.
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

    func clampToSound(_ time: TimeInterval) -> TimeInterval {
        min(max(time, 0), duration)
    }

    // MARK: Adoption

    /// An opening position, for a render harness that has no user to set one.
    struct Seed: Equatable {
        /// 0 fits the whole sound, 1 is sample-adjacent. Logarithmic.
        var zoomFraction: Double?
        /// Left edge in seconds. Wins over `centreOn`.
        var windowStart: TimeInterval?
        /// A moment to put in the middle — used to frame a seeded selection
        /// handle without anyone having to work out the window by hand.
        var centreOn: TimeInterval?
    }

    /// Points the timeline at a sound and returns the window to draw.
    ///
    /// **Called from `body`, and it publishes nothing.** Both of those are
    /// deliberate. Called from `body`, the frame that needs the window is the
    /// frame that gets it, with no turn of latency for anyone to photograph.
    /// Publishing nothing, it is safe from anywhere SwiftUI might dispatch it,
    /// including inside a layout pass.
    ///
    /// Idempotent, so every view that draws the timeline can call it and
    /// whichever renders first wins. A different source starts fitted; the same
    /// source keeps the zoom the user set, because a gain slider that re-renders
    /// the waveform must not also throw away where they were looking.
    @discardableResult
    func adopt(
        sourceID: UUID?,
        duration newDuration: TimeInterval,
        sampleRate rate: Double,
        width surfaceWidth: CGFloat,
        seed: Seed? = nil
    ) -> ClosedRange<TimeInterval> {
        width = max(surfaceWidth, 1)

        let resolvedRate = rate > 0 ? rate : 48_000
        let resolved = max(newDuration, 0.001)
        let isNewSound = sourceID != adoptedSourceID

        if isNewSound || resolved != duration || resolvedRate != sampleRate {
            let wasFitted = isFitToWindow
            sampleRate = resolvedRate
            duration = resolved
            adoptedSourceID = sourceID
            if isNewSound || wasFitted {
                assign(start: 0, visible: duration)
            } else {
                clampWindow()
            }
        }

        // Keyed on the seed's value, not on a "have I run" flag: successive
        // scenes in one process reuse this singleton, and a one-shot flag would
        // let the first seeded frame apply and silently ignore the rest.
        if seed != appliedSeed {
            appliedSeed = seed
            if let seed { apply(seed) }
        }

        return window
    }

    private func apply(_ seed: Seed) {
        if let fraction = seed.zoomFraction {
            setWindow(zoomFraction: fraction, anchorFraction: 0.5)
        }
        if let windowStart = seed.windowStart {
            setWindow(start: windowStart)
        } else if let centre = seed.centreOn {
            setWindow(start: centre - visible / 2)
        }
    }

    // MARK: User-driven changes
    //
    // Everything below notifies. Every one of them arrives from a gesture, a
    // button or the key monitor.

    func fitAll() {
        if assign(start: 0, visible: duration) { notifyChange() }
    }

    /// Zooms so `anchorFraction` of the surface keeps the moment that is under
    /// it. Getting this wrong is the single most common way a waveform view
    /// feels amateur, so it is the only way this class changes `visible`.
    func setVisible(_ target: TimeInterval, anchorFraction: Double) {
        if setWindow(visible: target, anchorFraction: anchorFraction) { notifyChange() }
    }

    func zoom(by factor: Double, anchorFraction: Double) {
        guard factor > 0, factor.isFinite else { return }
        setVisible(visible / factor, anchorFraction: anchorFraction)
    }

    func setZoomFraction(_ fraction: Double, anchorFraction: Double) {
        if setWindow(zoomFraction: fraction, anchorFraction: anchorFraction) { notifyChange() }
    }

    func scroll(byPoints points: CGFloat) {
        guard !isFitToWindow else { return }
        scroll(toStart: start + Double(points) * secondsPerPoint)
    }

    func scroll(toStart newStart: TimeInterval) {
        if setWindow(start: newStart) { notifyChange() }
    }

    /// Pages the window when the playhead walks off the right edge. Silent when
    /// the whole sound is already on screen, and silent while the user is
    /// dragging.
    func reveal(_ time: TimeInterval) {
        guard !isFitToWindow, !isUserAdjusting else { return }
        if time < start || time > start + visible * 0.98 {
            scroll(toStart: time - visible * 0.1)
        }
    }

    /// Logarithmic, because linear zoom spends 90% of a slider's travel on the
    /// first 10% of the useful range.
    var zoomFraction: Double {
        get {
            let span = log(duration / minimumVisible)
            guard span > 0, span.isFinite else { return 0 }
            return min(max(log(duration / max(visible, minimumVisible)) / span, 0), 1)
        }
        set { setZoomFraction(newValue, anchorFraction: 0.5) }
    }

    // MARK: The window, without notifying

    @discardableResult
    private func setWindow(visible target: TimeInterval, anchorFraction: Double) -> Bool {
        let anchor = min(max(anchorFraction, 0), 1)
        let anchorTime = start + anchor * visible
        let resolved = min(max(target, minimumVisible), duration)
        var changed = assign(start: anchorTime - anchor * resolved, visible: resolved)
        changed = clampWindow() || changed
        return changed
    }

    @discardableResult
    private func setWindow(zoomFraction fraction: Double, anchorFraction: Double) -> Bool {
        let span = log(duration / minimumVisible)
        guard span > 0, span.isFinite else { return false }
        return setWindow(
            visible: duration / exp(min(max(fraction, 0), 1) * span),
            anchorFraction: anchorFraction
        )
    }

    @discardableResult
    private func setWindow(start newStart: TimeInterval) -> Bool {
        assign(start: min(max(newStart, 0), max(duration - visible, 0)), visible: visible)
    }

    @discardableResult
    private func clampWindow() -> Bool {
        let boundedVisible = min(max(visible, minimumVisible), duration)
        let boundedStart = min(max(start, 0), max(duration - boundedVisible, 0))
        return assign(start: boundedStart, visible: boundedVisible)
    }

    /// The only place `start` and `visible` are written. Reports whether
    /// anything actually moved, so a mutator that changed nothing notifies
    /// nobody.
    @discardableResult
    private func assign(start newStart: TimeInterval, visible newVisible: TimeInterval) -> Bool {
        var changed = false
        if visible != newVisible { visible = newVisible; changed = true }
        if start != newStart { start = newStart; changed = true }
        return changed
    }

    private func notifyChange() {
        revision &+= 1
    }

    #if MELO_DEV
    /// Forgets the sound and the seed, so a render scene starts from a known
    /// window instead of the one the previous scene left.
    ///
    /// This object outlives every scene, which is the sticky global-state trap
    /// `MeloEasterEggClock` is documented for at `MeloVisualTheme.swift:476`.
    /// Call it from the shared `prepare` wrapper in `SnapshotScenes.swift`, next
    /// to `applyAppearance(scheme)`, exactly as that one is.
    func resetForSnapshot() {
        adoptedSourceID = nil
        appliedSeed = nil
        duration = 1
        sampleRate = 48_000
        width = 600
        pointerFraction = 0.5
        isUserAdjusting = false
        assign(start: 0, visible: 1)
    }
    #endif
}

// MARK: - Palette

/// The waveform gets its own fixed colours, following the precedent
/// `DesignTokens.Colors` already sets for the VU meter: a readout of what the
/// audio *is* does not change hue with the user's accent. The accent is spent
/// on the selection chrome instead, where it means "you did this".
enum EditorWaveformPalette {

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

    /// Inside the selection. Warm against the cool base so the selected span is
    /// unmistakable in a still frame — the accent alone would not be, because
    /// the harness window is never key and macOS desaturates its tint.
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

    /// While the stack is held bypassed, the picture is still the processed
    /// render but the sound is not — so the picture says so by going grey.
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
}

// MARK: - Metrics

enum EditorWaveformMetrics {
    static let rulerHeight: CGFloat = 22
    static let scrollBarHeight: CGFloat = 10
    /// Half-width of a selection handle's grab zone. 9pt either side of the
    /// edge is an 18pt target for a 6pt-wide grip — real to hit, quiet to look
    /// at. `Dimensions.minTouchTarget` is the floor for a control the pointer
    /// has to acquire cold; a handle sits on a line the user is already aiming
    /// at, and 28pt of grab either side of a selection edge would swallow short
    /// selections whole.
    static let handleGrab: CGFloat = 9
    static let handleWidth: CGFloat = 6
    static let handleHeight: CGFloat = 26
    /// How far the pointer travels before a click becomes a drag.
    static let dragThreshold: CGFloat = 3
    static let laneGap: CGFloat = 6
    /// How close a dragged edge has to come to a landmark before it snaps.
    static let snapPoints: CGFloat = 4
}

// MARK: - Columns

/// One vertical slice of the picture: the peak excursion and the RMS level over
/// the audio that lands under a single column of pixels.
struct EditorWaveformColumn: Equatable {
    var minimum: Float
    var maximum: Float
    var rms: Float

    static let silent = EditorWaveformColumn(minimum: 0, maximum: 0, rms: 0)
}

/// Turns whatever buckets are to hand into exactly the columns the surface has,
/// for exactly the window on screen.
///
/// The same function serves the sharp path and the fallback: a detail response
/// covers the visible window at the visible width and maps one-to-one, and the
/// store's whole-file overview maps many-to-one. Having one resampler means the
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
                // Root-mean-square of the squares, not the mean of the roots.
                // The second one is wrong and looks it: quiet passages inflate.
                rms: Float((meanSquare / Double(taken)).squareRoot())
            )
        }
        return output
    }
}

// MARK: - Detail

/// Asks the render engine for the window on screen, at the width on screen.
///
/// Debounced and coalesced: a zoom drag emits a viewport per frame and the
/// engine is an actor holding one decoded source, so firing every frame would
/// queue sixty renders behind each other. The last request wins.
@MainActor
final class EditorWaveformDetail: ObservableObject {

    struct Slice: Equatable {
        var range: ClosedRange<TimeInterval>
        /// Columns *requested*. `buckets.count / requested` is the channel
        /// count the engine actually returned, which is how stereo lanes are
        /// discovered without a second field on `WaveformData`.
        var requested: Int
        var data: WaveformData
    }

    @Published private(set) var slice: Slice?

    private var work: Task<Void, Never>?
    private var inFlight: (range: ClosedRange<TimeInterval>, requested: Int)?
    /// Snapshot fixtures have no file behind them, so `RenderEngine` throws on
    /// every call. Two failures and this stops asking until the document
    /// changes — otherwise a pinned frame would spin the actor forever.
    private var consecutiveFailures = 0
    private var lastDocument: EditorDocument?

    func invalidate() {
        work?.cancel()
        work = nil
        inFlight = nil
        consecutiveFailures = 0
        // Guarded: `slice` is the only `@Published` property here, and this is
        // reached from callbacks that fire on every resize.
        if slice != nil { slice = nil }
    }

    /// True when `slice` already covers `window` at roughly the right density,
    /// so a small scroll or a nudge of the zoom reuses what is on screen.
    func covers(_ window: ClosedRange<TimeInterval>, columns: Int) -> Bool {
        guard let slice, columns > 0 else { return false }
        guard slice.range.lowerBound <= window.lowerBound + 0.0001,
              slice.range.upperBound >= window.upperBound - 0.0001 else { return false }
        let have = (slice.range.upperBound - slice.range.lowerBound) / Double(slice.requested)
        let want = (window.upperBound - window.lowerBound) / Double(columns)
        guard have > 0, want > 0 else { return false }
        // Within a factor of ~1.35 either way. Tighter than this re-renders on
        // every pinch frame; looser and a deep zoom stays visibly blocky.
        return abs(log(have / want)) < 0.3
    }

    func request(document: EditorDocument, engine: RenderEngine, window: ClosedRange<TimeInterval>, columns: Int) {
        if document != lastDocument {
            lastDocument = document
            consecutiveFailures = 0
        }
        guard consecutiveFailures < 2, columns > 0 else { return }

        // Ask for half a window of margin either side so a small scroll is free.
        let margin = (window.upperBound - window.lowerBound) * 0.25
        let lower = max(0, window.lowerBound - margin)
        let upper = window.upperBound + margin
        guard upper > lower else { return }
        let padded = lower...upper
        let requested = min(4096, Int((Double(columns) * (upper - lower) / (window.upperBound - window.lowerBound)).rounded()))
        guard requested > 0 else { return }

        if let inFlight, inFlight.range == padded, inFlight.requested == requested { return }
        inFlight = (padded, requested)

        work?.cancel()
        work = Task { [weak self] in
            // One display frame of quiet. A pinch that is still moving replaces
            // this task before the engine is ever reached.
            try? await Task.sleep(for: .milliseconds(45))
            guard !Task.isCancelled else { return }
            do {
                let data = try await engine.waveform(document, range: padded, bucketCount: requested)
                guard !Task.isCancelled, let self else { return }
                self.slice = Slice(range: padded, requested: requested, data: data)
                self.consecutiveFailures = 0
                self.inFlight = nil
            } catch {
                guard !Task.isCancelled, let self else { return }
                self.consecutiveFailures += 1
                self.inFlight = nil
            }
        }
    }
}

// MARK: - Cuts

/// What the enabled duration-changing moves did to the length, expressed in the
/// timeline the view actually draws.
///
/// **Named limitation, not an oversight.** `removeSilence` re-detects its gaps
/// inside the render (`DSP/MoveProcessors.swift:241-276`) and does not report
/// where they were, and the timeline drawn here is output time, in which those
/// gaps have collapsed to points. Recomputing them here would be a second
/// silence detector that has to agree with the first — the exact defect class
/// `CLAUDE.md:138` records. So this shows what is exactly knowable: what a trim
/// took off each end, and how much shorter the stack made the sound overall.
enum EditorCutMap {

    struct Summary: Equatable {
        /// Seconds the enabled trims removed from the head, or nil.
        var headRemoved: TimeInterval?
        /// Seconds the enabled trims removed from the tail, or nil.
        var tailRemoved: TimeInterval?
        /// Total shortening across the whole stack, when it is a cut rather
        /// than a speed change.
        var shortenedBy: TimeInterval?

        var isEmpty: Bool { headRemoved == nil && tailRemoved == nil && shortenedBy == nil }
    }

    static func summary(for document: EditorDocument?, outputDuration: TimeInterval) -> Summary {
        guard let document else { return Summary() }
        let enabled = document.moves.filter(\.isEnabled)
        var head: TimeInterval?
        var tail: TimeInterval?
        var changesSpeed = false

        for move in enabled {
            switch move.kind {
            case let .trim(start, end):
                let lower = min(start, end)
                let upper = max(start, end)
                if lower > 0.001 { head = (head ?? 0) + lower }
                let removedTail = document.source.duration - upper
                if removedTail > 0.001 { tail = (tail ?? 0) + removedTail }
            case .speed:
                changesSpeed = true
            default:
                break
            }
        }

        let delta = document.source.duration - outputDuration
        let shortened = (!changesSpeed && delta > 0.05 && outputDuration > 0) ? delta : nil
        return Summary(headRemoved: head, tailRemoved: tail, shortenedBy: shortened)
    }
}

// MARK: - The view

/// The waveform, the ruler above it, the selection, the playhead and the zoom.
///
/// Constructible from nothing but the store: no audio device, no window and no
/// engine are touched by drawing it, which is what lets the harness render it
/// at all. Playback lives behind `EditorPlayback`, which the transport owns.
@MainActor
struct EditorWaveformView: View {

    @ObservedObject private var store: CuttingRoomStore
    @ObservedObject private var timeline = EditorTimeline.shared
    @ObservedObject private var playback = EditorPlayback.shared
    @StateObject private var detail = EditorWaveformDetail()

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale

    @State private var drag: DragState?
    @State private var lastClick: ClickRecord?
    @State private var hoveredEdge: SelectionEdge?
    @State private var scrollMonitor: Any?
    @State private var magnifyBase: CGFloat = 1
    @State private var edgeDetents = DetentTracker(values: [], tolerance: 0)
    /// Set only by the `#if MELO_DEV` initialiser; applied once on appear.
    private var seededZoom: Double?
    private var seededWindowStart: TimeInterval?
    private var seededHoveredEdge: SelectionEdge?

    init(store: CuttingRoomStore) {
        _store = ObservedObject(wrappedValue: store)
        seededZoom = nil
        seededWindowStart = nil
        seededHoveredEdge = nil
    }

    // MARK: Body

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let columns = columnCount(for: size.width)
            // Adopted here, in `body`, rather than from `onAppear` or a geometry
            // `onChange`. It publishes nothing, so it is safe from inside a
            // layout pass, and it happens in the pass that draws — which is the
            // difference between a correct first frame and a one-second window
            // of a four-minute song. See `EditorTimeline.adopt`.
            let window = timeline.adopt(
                sourceID: store.document?.source.id,
                duration: store.waveform?.duration ?? store.document?.source.duration ?? 0,
                sampleRate: store.document?.source.sampleRate ?? 48_000,
                width: size.width,
                seed: viewportSeed
            )
            let lanes = laneColumns(window: window, count: columns)

            VStack(spacing: 0) {
                EditorTimeRuler(timeline: timeline)
                    .frame(height: EditorWaveformMetrics.rulerHeight)

                EditorWaveformLanesCanvas(
                    lanes: lanes,
                    window: window,
                    selection: store.selection,
                    isBypassed: playback.isBypassed,
                    isDense: isDense(window: window, count: columns),
                    scheme: colorScheme
                )
                .equatable()
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                if !timeline.isFitToWindow {
                    EditorWaveformScrollBar(timeline: timeline)
                        .frame(height: EditorWaveformMetrics.scrollBarHeight)
                }
            }
            .background(EditorWaveformPalette.ground)
            .overlay {
                EditorWaveformChrome(
                    window: window,
                    selection: store.selection,
                    playhead: store.playhead,
                    // The seeded edge stands in for a pointer the harness has
                    // no way to put on the handle.
                    hoveredEdge: hoveredEdge ?? seededHoveredEdge,
                    draggingEdge: drag?.edge,
                    cuts: EditorCutMap.summary(for: store.document, outputDuration: timeline.duration),
                    hasSound: store.waveform != nil
                )
                .allowsHitTesting(false)
            }
            // No inset and no rounded corners: `CuttingRoomRootView` gives this
            // pane the full width between two dividers on purpose, and a
            // drawing of the whole sound that stops short of the edge is a
            // drawing of most of it.
            .contentShape(Rectangle())
            .gesture(dragGesture(width: size.width))
            .simultaneousGesture(magnifyGesture)
            .onContinuousHover(coordinateSpace: .local) { phase in
                handleHover(phase, width: size.width)
            }
            .onHover { hovering in
                if hovering { installScrollMonitor() } else { removeScrollMonitor() }
            }
            .onAppear { requestDetail(width: size.width) }
            .onDisappear { removeScrollMonitor() }
            // Nothing on the geometry path touches the timeline any more —
            // `adopt` in `body` already recorded the width. All this does is ask
            // for sharper buckets, and even that waits until the layout pass has
            // unwound.
            .onChange(of: size.width) { _, width in
                afterLayout { requestDetail(width: width) }
            }
            .onChange(of: documentStamp) { _, _ in requestDetail(width: size.width) }
            .onChange(of: window) { _, _ in requestDetail(width: size.width) }
            .onChange(of: store.selection) { _, selection in reveal(selection) }
            .onChange(of: store.playhead) { _, value in timeline.reveal(value) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Waveform")
        .accessibilityValue(accessibilityValue)
        .accessibilityHint("Drag to select. Double-click to select everything.")
        .accessibilityAdjustableAction { direction in
            let step = timeline.visible / 20
            switch direction {
            case .increment: store.playhead = timeline.clampToSound(store.playhead + step)
            case .decrement: store.playhead = timeline.clampToSound(store.playhead - step)
            @unknown default: break
            }
            timeline.reveal(store.playhead)
        }
    }

    // MARK: Data

    /// One column per physical pixel, capped. Beyond a few thousand the extra
    /// columns are drawing rectangles narrower than the screen can show.
    private func columnCount(for width: CGFloat) -> Int {
        min(4096, max(1, Int((width * displayScale).rounded())))
    }

    /// Cheap identity for "the sound changed". Comparing two 2048-bucket arrays
    /// on every body evaluation is not free, and the length plus the ends plus
    /// the source is enough to catch a re-render.
    private var documentStamp: String {
        let source = store.document?.source.id.uuidString ?? "-"
        let moves = store.document?.moves.count ?? 0
        let buckets = store.waveform?.buckets.count ?? 0
        let duration = store.waveform?.duration ?? 0
        let tail = store.waveform?.buckets.last?.rms ?? 0
        return "\(source)|\(moves)|\(buckets)|\(Int(duration * 1000))|\(Int(tail * 10_000))"
    }

    /// Detail if it covers the window, the store's overview if not, nothing if
    /// there is no sound. Never blank while a request is in flight.
    private func laneColumns(window: ClosedRange<TimeInterval>, count: Int) -> [[EditorWaveformColumn]] {
        let channels = max(1, store.document?.source.channelCount ?? 1)

        if let slice = detail.slice, detail.covers(window, columns: count) {
            // `RenderEngine.waveform` emits `bucketCount * channelCount`
            // buckets interleaved, so dividing by what was asked for gives the
            // channel count back without `WaveformData` needing a field for it.
            let lanes = min(max(slice.data.buckets.count / max(slice.requested, 1), 1), channels)
            return (0..<lanes).map { lane in
                EditorWaveformSampler.columns(
                    buckets: slice.data.buckets,
                    lanes: lanes,
                    lane: lane,
                    covering: slice.range,
                    window: window,
                    count: count
                )
            }
        }

        guard let overview = store.waveform, !overview.buckets.isEmpty else { return [] }
        // The overview arrives from the same engine under the same interleaving
        // rule, but nothing here knows the bucket count the store asked for — so
        // the channel count is the divisor. It has to resolve to the *same*
        // number of lanes the detail path will, or the picture would jump from
        // one lane to two the instant a detail request landed.
        let overviewLanes = Self.laneCount(bucketCount: overview.buckets.count, channels: channels)
        return (0..<overviewLanes).map { lane in
            EditorWaveformSampler.columns(
                buckets: overview.buckets,
                lanes: overviewLanes,
                lane: lane,
                covering: 0...max(overview.duration, 0.001),
                window: window,
                count: count
            )
        }
    }

    /// One lane per channel when the buckets divide evenly by it, one lane
    /// otherwise. The fallback is not defensive noise: a summed waveform is a
    /// true picture of the sound and two lanes of half a file is not, so an
    /// unexpected bucket count degrades to the honest drawing.
    private static func laneCount(bucketCount: Int, channels: Int) -> Int {
        guard channels > 1, bucketCount >= channels * 2, bucketCount % channels == 0 else { return 1 }
        return channels
    }

    /// Whether there is at least one bucket behind every couple of columns. Below
    /// that the bars are the same value repeated and a joined line is the honest
    /// picture — which is also what every editor shows at sample zoom.
    private func isDense(window: ClosedRange<TimeInterval>, count: Int) -> Bool {
        let span = window.upperBound - window.lowerBound
        guard span > 0, count > 0 else { return true }
        let available: Double
        if let slice = detail.slice, detail.covers(window, columns: count) {
            let lanes = max(slice.data.buckets.count / max(slice.requested, 1), 1)
            let perLane = Double(slice.data.buckets.count / lanes)
            let sliceSpan = slice.range.upperBound - slice.range.lowerBound
            available = sliceSpan > 0 ? perLane * span / sliceSpan : 0
        } else if let overview = store.waveform, overview.duration > 0 {
            let lanes = Self.laneCount(
                bucketCount: overview.buckets.count,
                channels: max(1, store.document?.source.channelCount ?? 1)
            )
            available = Double(overview.buckets.count / lanes) * span / overview.duration
        } else {
            available = 0
        }
        return available >= Double(count) * 0.6
    }

    /// Runs `work` on the next main-actor turn, once the layout pass that
    /// delivered the callback has unwound.
    ///
    /// Only detail requests use this now, and only from the geometry path. It is
    /// the right tool for work whose result nobody is photographing — an
    /// asynchronous render request that is already debounced by 45 ms. It was
    /// the wrong tool for adopting the sound, because a turn of latency in the
    /// window being drawn is a turn of latency the first frame shows.
    private func afterLayout(_ work: @escaping @MainActor () -> Void) {
        Task { @MainActor in work() }
    }

    /// An opening window for a render scene. Always `nil` outside `MELO_DEV`.
    private var viewportSeed: EditorTimeline.Seed? {
        guard seededZoom != nil || seededWindowStart != nil || seededHoveredEdge != nil else {
            return nil
        }
        // Asking for a grabbed handle is asking to see the handle: without this,
        // a seeded window that misses the seeded selection renders a zoomed
        // frame with no selection chrome in it at all.
        var centreOn: TimeInterval?
        if seededWindowStart == nil, let edge = seededHoveredEdge, let selection = store.selection {
            centreOn = edge == .lower ? selection.lowerBound : selection.upperBound
        }
        return EditorTimeline.Seed(
            zoomFraction: seededZoom,
            windowStart: seededWindowStart,
            centreOn: centreOn
        )
    }

    /// A selection the user cannot see is not a selection.
    ///
    /// When something other than a drag puts one off screen — a proposal, an
    /// undo, a move's range — the view goes to it. Only when it misses the
    /// window entirely: a select-all while zoomed in already contains what is on
    /// screen, and jumping then would throw away the place they were looking at
    /// for nothing.
    private func reveal(_ selection: ClosedRange<TimeInterval>?) {
        guard let selection, !timeline.isUserAdjusting, !timeline.isFitToWindow else { return }
        let window = timeline.window
        guard selection.upperBound < window.lowerBound || selection.lowerBound > window.upperBound else {
            return
        }
        timeline.scroll(toStart: selection.lowerBound - timeline.visible * 0.1)
    }

    private func requestDetail(width: CGFloat) {
        guard let document = store.document else {
            detail.invalidate()
            return
        }
        let count = columnCount(for: width)
        let window = timeline.window
        guard !detail.covers(window, columns: count) else { return }
        detail.request(document: document, engine: store.renderEngine, window: window, columns: count)
    }

    private var accessibilityValue: String {
        guard store.waveform != nil else { return "No sound loaded" }
        var parts = ["Playhead at \(EditorFormat.spokenTime(store.playhead)) of \(EditorFormat.spokenTime(timeline.duration))"]
        if let selection = store.selection {
            parts.append("Selection \(EditorFormat.spokenTime(selection.lowerBound)) to \(EditorFormat.spokenTime(selection.upperBound))")
        }
        if !timeline.isFitToWindow {
            parts.append("Showing \(EditorFormat.spokenTime(timeline.visible))")
        }
        return parts.joined(separator: ". ")
    }

    // MARK: Selection

    enum SelectionEdge: Equatable { case lower, upper }

    private struct DragState: Equatable {
        /// The end of the selection that stays put.
        var anchor: TimeInterval
        var startX: CGFloat
        var isActive: Bool
        /// Which handle is being dragged, when the drag started on one.
        var edge: SelectionEdge?
    }

    private struct ClickRecord: Equatable {
        var at: Date
        var x: CGFloat
    }

    private func dragGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                guard store.waveform != nil else { return }
                var state = drag ?? beginDrag(atX: value.startLocation.x, width: width)
                if !state.isActive, abs(value.translation.width) > EditorWaveformMetrics.dragThreshold {
                    state.isActive = true
                    timeline.isUserAdjusting = true
                    edgeDetents = DetentTracker(
                        values: snapLandmarks(excluding: state.anchor),
                        tolerance: timeline.secondsPerPoint * Double(EditorWaveformMetrics.snapPoints)
                    )
                }
                if state.isActive {
                    let raw = timeline.clampToSound(timeline.time(atX: value.location.x, width: width))
                    let moving = snapped(raw)
                    if edgeDetents.crossed(moving) { Haptics.detent() }
                    let lower = min(state.anchor, moving)
                    let upper = max(state.anchor, moving)
                    if upper > lower {
                        store.selection = lower...upper
                    } else {
                        store.selection = nil
                    }
                    store.playhead = lower
                    state.edge = moving <= state.anchor ? .lower : .upper
                    autoScroll(pointerX: value.location.x, width: width)
                }
                drag = state
            }
            .onEnded { value in
                defer {
                    drag = nil
                    timeline.isUserAdjusting = false
                }
                guard store.waveform != nil, let state = drag else { return }
                if state.isActive {
                    // A drag that ended up shorter than two points is a click
                    // that wobbled, not a selection.
                    if let selection = store.selection,
                       selection.upperBound - selection.lowerBound < timeline.secondsPerPoint * 2 {
                        store.selection = nil
                    } else {
                        Haptics.commit()
                    }
                    return
                }
                let x = value.location.x
                if isSecondClick(atX: x) {
                    store.selection = 0...timeline.duration
                    store.playhead = 0
                    lastClick = nil
                    Haptics.commit()
                } else {
                    lastClick = ClickRecord(at: Date(), x: x)
                    store.selection = nil
                    store.playhead = timeline.clampToSound(timeline.time(atX: x, width: width))
                }
            }
    }

    private func beginDrag(atX x: CGFloat, width: CGFloat) -> DragState {
        let time = timeline.clampToSound(timeline.time(atX: x, width: width))
        let shift = NSEvent.modifierFlags.contains(.shift)

        if let selection = store.selection {
            let lowerX = timeline.x(for: selection.lowerBound, width: width)
            let upperX = timeline.x(for: selection.upperBound, width: width)
            if abs(x - lowerX) <= EditorWaveformMetrics.handleGrab {
                return DragState(anchor: selection.upperBound, startX: x, isActive: false, edge: .lower)
            }
            if abs(x - upperX) <= EditorWaveformMetrics.handleGrab {
                return DragState(anchor: selection.lowerBound, startX: x, isActive: false, edge: .upper)
            }
            if shift {
                // Extend from whichever end is further away, which is what the
                // rest of macOS does with a shift-click.
                let anchor = abs(time - selection.lowerBound) > abs(time - selection.upperBound)
                    ? selection.lowerBound
                    : selection.upperBound
                return DragState(anchor: anchor, startX: x, isActive: false, edge: nil)
            }
        } else if shift {
            return DragState(anchor: store.playhead, startX: x, isActive: false, edge: nil)
        }
        return DragState(anchor: time, startX: x, isActive: false, edge: nil)
    }

    /// The landmarks a dragged edge snaps to: the ends of the sound and the
    /// playhead. Nothing else — snapping to a grid the user cannot see is how a
    /// selection stops landing where they let go.
    private func snapLandmarks(excluding anchor: TimeInterval) -> [Double] {
        var values: [Double] = [0, timeline.duration]
        if abs(store.playhead - anchor) > 0.0001 { values.append(store.playhead) }
        return values
    }

    private func snapped(_ time: TimeInterval) -> TimeInterval {
        let tolerance = timeline.secondsPerPoint * Double(EditorWaveformMetrics.snapPoints)
        for landmark in [0, timeline.duration, store.playhead] where abs(time - landmark) <= tolerance {
            return landmark
        }
        return time
    }

    private func isSecondClick(atX x: CGFloat) -> Bool {
        guard let lastClick else { return false }
        return Date().timeIntervalSince(lastClick.at) <= NSEvent.doubleClickInterval
            && abs(lastClick.x - x) <= 4
    }

    /// Keeps the window moving when a selection drag runs off the edge. Tied to
    /// pointer movement rather than a timer on purpose: a timer that scrolls
    /// while the pointer is parked overshoots every time.
    private func autoScroll(pointerX: CGFloat, width: CGFloat) {
        guard !timeline.isFitToWindow else { return }
        if pointerX < 16 {
            timeline.scroll(byPoints: max(-24, pointerX - 16))
        } else if pointerX > width - 16 {
            timeline.scroll(byPoints: min(24, pointerX - (width - 16)))
        }
    }

    // MARK: Pointer

    private func handleHover(_ phase: HoverPhase, width: CGFloat) {
        switch phase {
        case let .active(location):
            timeline.pointerFraction = Double(location.x / max(width, 1))
            let edge = edge(nearX: location.x, width: width)
            if edge != hoveredEdge {
                hoveredEdge = edge
                // `NSCursor.columnResize` is macOS 15; `resizeLeftRight` is the
                // one that has always been there and reads identically.
                (edge == nil ? NSCursor.arrow : NSCursor.resizeLeftRight).set()
            }
        case .ended:
            if hoveredEdge != nil {
                hoveredEdge = nil
                NSCursor.arrow.set()
            }
        }
    }

    private func edge(nearX x: CGFloat, width: CGFloat) -> SelectionEdge? {
        guard let selection = store.selection else { return nil }
        if abs(x - timeline.x(for: selection.lowerBound, width: width)) <= EditorWaveformMetrics.handleGrab { return .lower }
        if abs(x - timeline.x(for: selection.upperBound, width: width)) <= EditorWaveformMetrics.handleGrab { return .upper }
        return nil
    }

    // MARK: Zoom

    private var magnifyGesture: some Gesture {
        MagnifyGesture(minimumScaleDelta: 0.01)
            .onChanged { value in
                let delta = value.magnification / max(magnifyBase, 0.0001)
                magnifyBase = value.magnification
                timeline.zoom(by: Double(delta), anchorFraction: timeline.pointerFraction)
            }
            .onEnded { _ in magnifyBase = 1 }
    }

    /// A local monitor rather than an `NSViewRepresentable`, following
    /// `ScrollWheelStepModifier`: a representable inside the waveform would be
    /// a hole in every captured frame.
    ///
    /// Plain scroll pans and Option- or Command-scroll zooms, which is the
    /// macOS convention and the opposite of what a web canvas does. `zoomFraction`
    /// is the value stepped, so a swipe covers the same fraction of the zoom
    /// range wherever it starts.
    private func installScrollMonitor() {
        guard scrollMonitor == nil else { return }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            let zooming = event.modifierFlags.contains(.option) || event.modifierFlags.contains(.command)
            if zooming {
                var fraction = timeline.zoomFraction
                ScrollWheelStep.apply(
                    deltaY: event.scrollingDeltaY,
                    hasPreciseDeltas: event.hasPreciseScrollingDeltas,
                    isDirectionInverted: event.isDirectionInvertedFromDevice,
                    isMomentumTail: event.momentumPhase != [],
                    value: &fraction,
                    // A 250pt swipe crosses the whole zoom range.
                    sensitivity: 1.0 / 250.0,
                    in: 0...1
                )
                timeline.setZoomFraction(fraction, anchorFraction: timeline.pointerFraction)
            } else {
                guard !timeline.isFitToWindow else { return nil }
                // Trackpads send the horizontal component; wheels only send the
                // vertical one, and on a waveform vertical wheel means "along".
                let horizontal = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
                let delta = horizontal ? event.scrollingDeltaX : event.scrollingDeltaY
                var start = timeline.start
                ScrollWheelStep.apply(
                    deltaY: -delta,
                    hasPreciseDeltas: event.hasPreciseScrollingDeltas,
                    isDirectionInverted: event.isDirectionInvertedFromDevice,
                    isMomentumTail: event.momentumPhase != [],
                    value: &start,
                    sensitivity: timeline.secondsPerPoint,
                    in: 0...max(timeline.duration - timeline.visible, 0)
                )
                timeline.scroll(toStart: start)
            }
            return nil
        }
    }

    private func removeScrollMonitor() {
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        scrollMonitor = nil
        if hoveredEdge != nil {
            hoveredEdge = nil
            NSCursor.arrow.set()
        }
    }
}

// MARK: - Lanes

/// The waveform itself. `Equatable` and used through `.equatable()` so a
/// playhead moving at sixty hertz does not rebuild two thousand rectangles it
/// did not change — the chrome above redraws instead, and it is four shapes.
private struct EditorWaveformLanesCanvas: View, Equatable {

    let lanes: [[EditorWaveformColumn]]
    let window: ClosedRange<TimeInterval>
    let selection: ClosedRange<TimeInterval>?
    let isBypassed: Bool
    let isDense: Bool
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
        guard !lanes.isEmpty else {
            drawZeroLine(&context, rect: CGRect(origin: .zero, size: size))
            return
        }

        let count = lanes.count
        let gap = count > 1 ? EditorWaveformMetrics.laneGap : 0
        let laneHeight = (size.height - gap * CGFloat(count - 1)) / CGFloat(count)
        guard laneHeight > 2 else { return }

        for (index, columns) in lanes.enumerated() {
            let rect = CGRect(
                x: 0,
                y: CGFloat(index) * (laneHeight + gap),
                width: size.width,
                height: laneHeight
            )
            drawLane(&context, rect: rect, columns: columns)
        }
    }

    private func drawZeroLine(_ context: inout GraphicsContext, rect: CGRect) {
        context.fill(
            Path(CGRect(x: rect.minX, y: rect.midY - 0.5, width: rect.width, height: 1)),
            with: .color(EditorWaveformPalette.zeroLine)
        )
    }

    private func drawLane(_ context: inout GraphicsContext, rect: CGRect, columns: [EditorWaveformColumn]) {
        drawZeroLine(&context, rect: rect)
        guard !columns.isEmpty else { return }

        let half = max(rect.height / 2 - 1, 1)
        let midY = rect.midY
        let columnWidth = rect.width / CGFloat(columns.count)
        let span = window.upperBound - window.lowerBound

        var peakOutside = Path()
        var peakInside = Path()
        var bodyOutside = Path()
        var bodyInside = Path()
        var linePath = Path()
        var lineStarted = false

        for (index, column) in columns.enumerated() {
            let x = rect.minX + CGFloat(index) * columnWidth
            let centre = window.lowerBound + span * (Double(index) + 0.5) / Double(columns.count)
            let selected = selection.map { $0.contains(centre) } ?? false

            // The peak envelope is true at every scale: a bucket really does
            // assert that the signal ranged between these two values over the
            // span it covers, however many columns that span is drawn across.
            let top = midY - CGFloat(min(max(column.maximum, 0), 1)) * half
            let bottom = midY - CGFloat(min(max(column.minimum, -1), 0)) * half
            // A hairline for silence: nothing at all reads as missing data
            // rather than as quiet.
            let peakRect = CGRect(x: x, y: top, width: columnWidth, height: max(bottom - top, 1))
            if selected { peakInside.addRect(peakRect) } else { peakOutside.addRect(peakRect) }

            if isDense {
                let rms = CGFloat(min(max(column.rms, 0), 1)) * half
                let bodyRect = CGRect(x: x, y: midY - rms, width: columnWidth, height: max(rms * 2, 1))
                if selected { bodyInside.addRect(bodyRect) } else { bodyOutside.addRect(bodyRect) }
            } else {
                // Fewer buckets than columns — either genuinely past sample
                // resolution, or a detail render that has not landed yet.
                //
                // **The RMS core is deliberately not drawn here.** One bucket
                // repeated across forty columns paints as a solid slab of
                // constant level, which is the most confident-looking thing on
                // screen and is not a measurement of anything: it is one number
                // stretched. The envelope plus a line through the bucket
                // midpoints says what is actually known and no more.
                let value = CGFloat(min(max((column.maximum + column.minimum) / 2, -1), 1))
                let point = CGPoint(x: x + columnWidth / 2, y: midY - value * half)
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

    private func peakColor(selected: Bool) -> Color {
        if isBypassed { return EditorWaveformPalette.peakBypassed }
        return selected ? EditorWaveformPalette.peakSelected : EditorWaveformPalette.peak
    }

    private func bodyColor(selected: Bool) -> Color {
        if isBypassed { return EditorWaveformPalette.bodyBypassed }
        return selected ? EditorWaveformPalette.bodySelected : EditorWaveformPalette.body
    }
}

// MARK: - Chrome

/// Selection, handles, playhead and the cut flags. Everything that moves while
/// the sound plays, kept out of the lanes canvas so it can redraw cheaply.
private struct EditorWaveformChrome: View {

    let window: ClosedRange<TimeInterval>
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

            func x(_ time: TimeInterval) -> CGFloat {
                CGFloat((time - window.lowerBound) / span) * size.width
            }

            if let selection {
                drawSelection(&context, size: size, from: x(selection.lowerBound), to: x(selection.upperBound))
            }
            drawCutFlags(&context, size: size)
            drawPlayhead(&context, size: size, at: x(playhead))
        }
    }

    private func drawSelection(_ context: inout GraphicsContext, size: CGSize, from lowerX: CGFloat, to upperX: CGFloat) {
        let clampedLower = max(lowerX, -2)
        let clampedUpper = min(upperX, size.width + 2)
        guard clampedUpper > clampedLower else { return }

        context.fill(
            Path(CGRect(x: clampedLower, y: 0, width: clampedUpper - clampedLower, height: size.height)),
            with: .color(Color.accentColor.opacity(0.12))
        )
        for edgeX in [lowerX, upperX] where edgeX >= -1 && edgeX <= size.width + 1 {
            context.fill(
                Path(CGRect(x: edgeX - 0.5, y: 0, width: 1, height: size.height)),
                with: .color(Color.accentColor.opacity(0.85))
            )
        }
        drawHandle(&context, size: size, at: lowerX, edge: .lower)
        drawHandle(&context, size: size, at: upperX, edge: .upper)
    }

    private func drawHandle(_ context: inout GraphicsContext, size: CGSize, at edgeX: CGFloat, edge: EditorWaveformView.SelectionEdge) {
        guard edgeX >= -EditorWaveformMetrics.handleWidth, edgeX <= size.width + EditorWaveformMetrics.handleWidth else { return }
        let active = hoveredEdge == edge || draggingEdge == edge
        let width = EditorWaveformMetrics.handleWidth
        let height = EditorWaveformMetrics.handleHeight * (active ? 1.15 : 1)
        let rect = CGRect(
            x: edgeX - width / 2,
            y: (size.height - height) / 2,
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

    private func drawPlayhead(_ context: inout GraphicsContext, size: CGSize, at playheadX: CGFloat) {
        guard playheadX >= -1, playheadX <= size.width + 1 else { return }
        context.fill(
            Path(CGRect(x: playheadX - 0.5, y: 0, width: 1, height: size.height)),
            with: .color(EditorWaveformPalette.playhead)
        )
        var cap = Path()
        cap.move(to: CGPoint(x: playheadX - 5, y: 0))
        cap.addLine(to: CGPoint(x: playheadX + 5, y: 0))
        cap.addLine(to: CGPoint(x: playheadX, y: 7))
        cap.closeSubpath()
        context.fill(cap, with: .color(EditorWaveformPalette.playhead))
    }

    /// What the stack took off, drawn at the ends where it was taken. A trim is
    /// exact and says so; anything the view cannot place exactly is not drawn.
    private func drawCutFlags(_ context: inout GraphicsContext, size: CGSize) {
        guard !cuts.isEmpty else { return }
        let y = EditorWaveformMetrics.rulerHeight + 4

        if let head = cuts.headRemoved {
            draw(&context, label: "✂ " + EditorFormat.seconds(head), at: CGPoint(x: 4, y: y), anchor: .topLeading)
        }
        if let tail = cuts.tailRemoved {
            draw(&context, label: EditorFormat.seconds(tail) + " ✂", at: CGPoint(x: size.width - 4, y: y), anchor: .topTrailing)
        }
        if let shortened = cuts.shortenedBy, cuts.headRemoved == nil, cuts.tailRemoved == nil {
            draw(&context, label: EditorFormat.seconds(shortened) + " shorter", at: CGPoint(x: 4, y: y), anchor: .topLeading)
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

// MARK: - Scroll bar

/// Where the window sits in the whole sound. Only present when zoomed in: at
/// fit-to-window it would be a full-width bar saying nothing.
private struct EditorWaveformScrollBar: View {

    @ObservedObject var timeline: EditorTimeline

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let fraction = timeline.visible / max(timeline.duration, 0.0001)
            let thumbWidth = max(24, width * CGFloat(min(fraction, 1)))
            let travel = max(width - thumbWidth, 0)
            let scrollable = max(timeline.duration - timeline.visible, 0.0001)
            let progress = min(max(timeline.start / scrollable, 0), 1)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.07))
                    .frame(height: 3)
                Capsule()
                    .fill(Color.primary.opacity(0.28))
                    .frame(width: thumbWidth, height: 3)
                    .offset(x: travel * CGFloat(progress))
            }
            .frame(height: proxy.size.height)
        }
        .padding(.horizontal, DesignTokens.Spacing.xs)
        .accessibilityHidden(true)
    }
}

// MARK: - Snapshot seeding

#if MELO_DEV
extension EditorWaveformView {
    /// Seeds the state the store does not hold, so the harness can render a
    /// zoomed view and a grabbed handle. `CuttingRoomStore.setForSnapshot`
    /// covers the document and the waveform, and a scene sets `selection` and
    /// `playhead` on the store directly — those are published properties, not
    /// this view's `@State`.
    ///
    /// Declared in an extension, and behind `#if MELO_DEV`, so the real
    /// `init(store:)` is the only one a release build has at all. Inside the
    /// harness both are reachable, which is the point — `SnapshotScenes` uses
    /// each.
    ///
    /// - Parameters:
    ///   - zoom: 0 fits the whole sound, 1 is sample-adjacent. Logarithmic.
    ///   - windowStart: Left edge in seconds, applied after `zoom`.
    ///   - hoveredEdge: Draws a selection handle in its grabbed state, which is
    ///     otherwise reachable only by putting a pointer on it.
    init(
        store: CuttingRoomStore,
        zoom: Double? = nil,
        windowStart: TimeInterval? = nil,
        hoveredEdge: SelectionEdge? = nil
    ) {
        _store = ObservedObject(wrappedValue: store)
        seededZoom = zoom
        seededWindowStart = windowStart
        seededHoveredEdge = hoveredEdge
    }
}
#endif
