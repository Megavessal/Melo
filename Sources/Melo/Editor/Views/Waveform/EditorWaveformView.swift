// Melo/Editor/Views/Waveform/EditorWaveformView.swift
//
// The timeline. The thing the user looks at for the whole session.
//
// Four decisions hold this file up.
//
// 1. **It draws in a SwiftUI `Canvas`, not an `NSView`.** `SnapshotHarness`
//    cannot draw `NSViewRepresentable` content on the `.imageRenderer` path
//    (`Utilities/SnapshotHarness.swift:165-172`), which is the path this
//    project's anchor tells critics to judge from. A Metal or CALayer timeline
//    would be blank in every frame anyone ever looked at.
//
// 2. **One viewport, one coordinate space.** The ruler, every lane and the
//    chrome are laid out in the *pane's* coordinates and all read the same
//    `EditorTimeline`. The lanes canvas is full-pane and offsets itself with
//    `EditorTimelineGeometry.lanesRect`, rather than being a child view with a
//    coordinate space of its own — so drawing and hit-testing call literally
//    the same function with literally the same size, and a lane that drifts out
//    of alignment with the ruler is not a bug that can be written here.
//
// 3. **Clips draw from their source, not from the mix.** See
//    `EditorClipWaveforms` for what that buys and what it costs.
//
// 4. **Clip edits are previewed locally and committed on mouse-up.** One undo
//    entry per gesture, and no debounced re-render per tick of a drag. The
//    preview clamps through `EditorClipEdit`, which is executed and asserted,
//    so the picture under the pointer is the picture the store commits.

import AppKit
import SwiftUI

// MARK: - Viewport

/// What part of the timeline is on screen, shared between the ruler, the lanes
/// and the transport's zoom control because they are siblings in the window and
/// none of them owns the others.
///
/// A singleton for the same reason `EditorStore` is: there is one Melo Edit
/// window, and `EditorWindowController.shared` is the only thing that opens it.
///
/// The arithmetic lives in `EditorTimelineViewport`, which is a value with no
/// SwiftUI in it and is asserted on its own. This class is the observable
/// wrapper: it decides *when* to notify and *whether follow is on*, and nothing
/// else.
@MainActor
final class EditorTimeline: ObservableObject {

    static let shared = EditorTimeline()

    // MARK: - State
    //
    // `viewport` is **not** `@Published`, and that is the load-bearing decision
    // in this file. Two separate defects came from its being so:
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
    // timeline are in different subtrees — and those all arrive from gestures,
    // buttons and the key monitor, never from layout. So user changes bump
    // `revision` and adoption stays silent.
    //
    // **Do not make `viewport` published, and do not write any published
    // property from anything on the geometry path.** It reaches the shipped app.

    /// Bumped by user-driven changes only, so `@ObservedObject` observers redraw.
    /// Never bumped by `adopt`.
    @Published private(set) var revision: Int = 0

    private(set) var viewport = EditorTimelineViewport()

    /// Where the pointer is, 0…1 across the surface. Anchors scroll-zoom and pinch.
    var pointerFraction: Double = 0.5

    /// Set while the user is dragging, so playback's follow does not yank the
    /// view out from under them.
    var isUserAdjusting = false

    /// Whether the view pages to keep the playhead in frame.
    ///
    /// **Off the moment the user scrolls or drags; back on at the next play
    /// from a control.** A view that fights the user's scroll is worse than one
    /// that never follows. Zooming does *not* turn it off — the frame's words
    /// are "scrolls or drags", and a zoom anchored on the playhead keeps the
    /// playhead in frame by construction, so there is nothing to fight.
    private(set) var isFollowing = true

    private var adoptedSourceID: UUID?
    private var appliedSeed: Seed?

    private init() {}

    // MARK: Forwarded

    var start: TimeInterval { viewport.start }
    var visible: TimeInterval { viewport.visible }
    var duration: TimeInterval { viewport.duration }
    var sampleRate: Double { viewport.sampleRate }
    var width: CGFloat { viewport.width }
    var end: TimeInterval { viewport.end }
    var window: ClosedRange<TimeInterval> { viewport.window }
    var secondsPerPoint: Double { viewport.secondsPerPoint }
    var isFitToWindow: Bool { viewport.isFitToWindow }
    var minimumVisible: TimeInterval { viewport.minimumVisible }

    func time(atX x: CGFloat, width surfaceWidth: CGFloat) -> TimeInterval {
        viewport.time(atX: x, width: surfaceWidth)
    }

    func x(for time: TimeInterval, width surfaceWidth: CGFloat) -> CGFloat {
        viewport.x(for: time, width: surfaceWidth)
    }

    func clampToSound(_ time: TimeInterval) -> TimeInterval {
        viewport.clampToSound(time)
    }

    // MARK: Adoption

    /// An opening position, for a render harness that has no user to set one.
    struct Seed: Equatable {
        /// 0 fits the whole project, 1 is sample-adjacent. Logarithmic.
        var zoomFraction: Double?
        /// Left edge in seconds. Wins over `centreOn`.
        var windowStart: TimeInterval?
        /// A moment to put in the middle — used to frame a seeded selection
        /// handle or a seeded clip without anyone having to work out the window
        /// by hand.
        var centreOn: TimeInterval?
    }

    /// Points the timeline at a project and returns the window to draw.
    ///
    /// **Called from `body`, and it publishes nothing.** Both of those are
    /// deliberate. Called from `body`, the frame that needs the window is the
    /// frame that gets it, with no turn of latency for anyone to photograph.
    /// Publishing nothing, it is safe from anywhere SwiftUI might dispatch it,
    /// including inside a layout pass.
    ///
    /// Idempotent, so every view that draws the timeline can call it and
    /// whichever renders first wins. A different first source starts fitted;
    /// the same one keeps the zoom the user set, because adding a track or
    /// nudging a gain slider must not throw away where they were looking.
    @discardableResult
    func adopt(
        sourceID: UUID?,
        duration newDuration: TimeInterval,
        sampleRate rate: Double,
        width surfaceWidth: CGFloat,
        seed: Seed? = nil
    ) -> ClosedRange<TimeInterval> {
        viewport.width = max(surfaceWidth, 1)

        let resolvedRate = rate > 0 ? rate : 48_000
        let resolved = max(newDuration, 0.001)
        let isNewSound = sourceID != adoptedSourceID

        if isNewSound || resolved != viewport.duration || resolvedRate != viewport.sampleRate {
            let wasFitted = viewport.isFitToWindow
            viewport.sampleRate = resolvedRate
            viewport.duration = resolved
            adoptedSourceID = sourceID
            if isNewSound || wasFitted {
                viewport.fitAll()
            } else {
                viewport.clamp()
            }
        }

        // Keyed on the seed's value, not on a "have I run" flag: successive
        // scenes in one process reuse this singleton, and a one-shot flag would
        // let the first seeded frame apply and silently ignore the rest.
        if seed != appliedSeed {
            appliedSeed = seed
            if let seed { apply(seed) }
        }

        return viewport.window
    }

    private func apply(_ seed: Seed) {
        if let fraction = seed.zoomFraction {
            viewport.setZoomFraction(fraction, anchorFraction: 0.5)
        }
        if let windowStart = seed.windowStart {
            viewport.setStart(windowStart)
        } else if let centre = seed.centreOn {
            viewport.setStart(centre - viewport.visible / 2)
        }
    }

    // MARK: User-driven changes
    //
    // Everything below notifies. Every one of them arrives from a gesture, a
    // button or the key monitor.

    func fitAll() {
        // Not `endFollowing`: at fit-to-window there is nothing to follow, and
        // zooming back in afterwards should still follow.
        if viewport.fitAll() { notifyChange() }
    }

    func setVisible(_ target: TimeInterval, anchorFraction: Double) {
        if viewport.setVisible(target, anchorFraction: anchorFraction) { notifyChange() }
    }

    func zoom(by factor: Double, anchorFraction: Double) {
        if viewport.zoom(by: factor, anchorFraction: anchorFraction) { notifyChange() }
    }

    func setZoomFraction(_ fraction: Double, anchorFraction: Double) {
        if viewport.setZoomFraction(fraction, anchorFraction: anchorFraction) { notifyChange() }
    }

    var zoomFraction: Double {
        get { viewport.zoomFraction }
        set { setZoomFraction(newValue, anchorFraction: 0.5) }
    }

    /// The user scrolling. Turns follow off — this is the whole of that rule's
    /// enforcement, and it is why paging goes through `reveal` and not here.
    func scroll(byPoints points: CGFloat) {
        guard !viewport.isFitToWindow else { return }
        scroll(toStart: viewport.start + Double(points) * viewport.secondsPerPoint)
    }

    func scroll(toStart newStart: TimeInterval) {
        endFollowing()
        if viewport.setStart(newStart) { notifyChange() }
    }

    // MARK: Follow

    /// Turned on by `EditorPlayback` when playback starts from a control.
    func beginFollowing() {
        isFollowing = true
    }

    func endFollowing() {
        isFollowing = false
    }

    /// Pages the window when the playhead walks off the visible span. Silent
    /// when following is off, when the user is dragging, and when the whole
    /// project is already on screen.
    func reveal(_ time: TimeInterval) {
        guard isFollowing, !isUserAdjusting else { return }
        if viewport.page(toReveal: time) { notifyChange() }
    }

    /// A selection the user cannot see is not a selection.
    ///
    /// When something other than a drag puts one off screen — a proposal, an
    /// undo, a move's range — the view goes to it. Only when it misses the
    /// window entirely: a select-all while zoomed in already contains what is on
    /// screen, and jumping then would throw away the place they were looking at
    /// for nothing. Does not touch follow: this is about the selection, not
    /// about who is driving the scroll.
    func reveal(range: ClosedRange<TimeInterval>) {
        guard !isUserAdjusting else { return }
        if viewport.reveal(range: range) { notifyChange() }
    }

    private func notifyChange() {
        revision &+= 1
    }

    #if MELO_DEV
    /// Forgets the project and the seed, so a render scene starts from a known
    /// window instead of the one the previous scene left.
    ///
    /// This object outlives every scene, which is the sticky global-state trap
    /// `MeloEasterEggClock` is documented for at `MeloVisualTheme.swift:476`.
    /// Call it from the shared `prepare` wrapper in `SnapshotScenes.swift`, next
    /// to `applyAppearance(scheme)`, exactly as that one is.
    func resetForSnapshot() {
        adoptedSourceID = nil
        appliedSeed = nil
        pointerFraction = 0.5
        isUserAdjusting = false
        isFollowing = true
        viewport = EditorTimelineViewport()
    }
    #endif
}

// MARK: - Cuts

/// What the enabled duration-changing **master** moves did to the length,
/// expressed in the timeline the view actually draws.
///
/// **Named limitation, not an oversight.** `removeSilence` re-detects its gaps
/// inside the render (`DSP/MoveProcessors.swift:241-276`) and does not report
/// where they were, and the timeline drawn here is clip time, in which those
/// gaps do not exist at all. Recomputing them here would be a second silence
/// detector that has to agree with the first — the exact defect class
/// `CLAUDE.md:138` records. So this shows what is exactly knowable: what a
/// master trim took off each end, and how much shorter the master stack made
/// the mix overall.
///
/// A clip's own trim is not in here and must not be: it has an edge you can see
/// and grab, which is a better flag than a label.
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
        let enabled = document.master.filter(\.isEnabled)
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

// MARK: - A clip edit in progress

/// What a drag is doing to the document before it is committed.
///
/// Public to the module because `SnapshotScenes` seeds one: a drag is the state
/// the render harness structurally cannot reach — it photographs states, not
/// gestures — so the only way a mid-drag frame exists is for a scene to hand
/// the view one of these.
enum EditorTimelineClipEdit: Equatable {
    /// Several clips moving together, along the timeline and between lanes.
    case move(ids: Set<UUID>, by: TimeInterval, lanes: Int)
    /// The leading edge, expressed as the clip's new `sourceIn`.
    case trimStart(id: UUID, sourceIn: TimeInterval)
    /// The trailing edge, expressed as the clip's new `sourceOut`.
    case trimEnd(id: UUID, sourceOut: TimeInterval)
    case fadeIn(id: UUID, seconds: TimeInterval)
    case fadeOut(id: UUID, seconds: TimeInterval)

    /// The clips this edit touches, for the drawing to mark as live.
    var ids: Set<UUID> {
        switch self {
        case let .move(ids, _, _): return ids
        case let .trimStart(id, _), let .trimEnd(id, _), let .fadeIn(id, _), let .fadeOut(id, _): return [id]
        }
    }
}

// MARK: - The view

/// The ruler, the lanes, the clips, the selection, the playhead and the zoom.
///
/// Constructible from nothing but the store: no audio device, no window and no
/// engine are touched by drawing it, which is what lets the harness render it
/// at all. Playback lives behind `EditorPlayback`, which the transport owns.
@MainActor
struct EditorWaveformView: View {

    @ObservedObject private var store: EditorStore
    @ObservedObject private var timeline = EditorTimeline.shared
    @ObservedObject private var playback = EditorPlayback.shared
    @ObservedObject private var clipWaveforms = EditorClipWaveforms.shared

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale

    /// How the clips are drawn. Read straight from defaults rather than from
    /// `SettingsManager`, so this view stays constructible from nothing but the
    /// store — see `EditorWaveformStyle` for why that property matters.
    @AppStorage(EditorWaveformStyle.storageKey) private var storedStyle = EditorWaveformStyle.fallback

    @State private var drag: DragState?
    @State private var edit: EditorTimelineClipEdit?
    @State private var lastClick: ClickRecord?
    @State private var hover: EditorTimelineHit?
    /// Which time-selection handle the pointer is on. The two selection handles
    /// float above the clips and are hit-tested separately, so a selection you
    /// can see is a selection you can grab even when a clip is under it.
    @State private var selectionEdgeUnderPointer: SelectionEdge?
    @State private var scrollMonitor: Any?
    @State private var magnifyBase: CGFloat = 1
    @State private var edgeDetents = DetentTracker(values: [], tolerance: 0)

    /// Set only by the `#if MELO_DEV` initialiser; applied once on appear.
    private var seededZoom: Double?
    private var seededWindowStart: TimeInterval?
    private var seededHoveredEdge: SelectionEdge?
    private var seededStyle: EditorWaveformStyle?
    private var seededHover: EditorTimelineHit?
    private var seededEdit: EditorTimelineClipEdit?

    init(store: EditorStore) {
        _store = ObservedObject(wrappedValue: store)
        seededZoom = nil
        seededWindowStart = nil
        seededHoveredEdge = nil
        seededStyle = nil
        seededHover = nil
        seededEdit = nil
    }

    // MARK: Body

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let plan = plan(for: size)

            ZStack(alignment: .top) {
                EditorTimelineLanes(
                    lanes: plan.lanes,
                    window: plan.window,
                    selection: store.selection,
                    isBypassed: playback.isBypassed,
                    style: seededStyle ?? storedStyle,
                    scheme: colorScheme
                )
                .equatable()
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                EditorTimeRuler(timeline: timeline)
                    .frame(height: EditorWaveformMetrics.rulerHeight)
                    .frame(maxHeight: .infinity, alignment: .top)

                if !timeline.isFitToWindow {
                    EditorWaveformScrollBar(timeline: timeline)
                        .frame(height: EditorWaveformMetrics.scrollBarHeight)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                }

                EditorTimelineChrome(
                    window: plan.window,
                    laneCount: plan.laneCount,
                    selection: store.selection,
                    playhead: store.playhead,
                    // The seeded edge stands in for a pointer the harness has
                    // no way to put on the handle.
                    hoveredEdge: selectionEdgeUnderPointer ?? seededHoveredEdge,
                    draggingEdge: draggingSelectionEdge,
                    cuts: EditorCutMap.summary(for: store.document, outputDuration: timeline.duration),
                    hasSound: store.document != nil
                )
                .allowsHitTesting(false)
            }
            // No inset and no rounded corners: `EditorRootView` gives this
            // pane the full width between two dividers on purpose, and a
            // drawing of the whole project that stops short of the edge is a
            // drawing of most of it.
            .background(EditorWaveformPalette.ground)
            .contentShape(Rectangle())
            .gesture(dragGesture(size: size, plan: plan))
            .simultaneousGesture(magnifyGesture)
            .onContinuousHover(coordinateSpace: .local) { phase in
                handleHover(phase, size: size, plan: plan)
            }
            .onHover { hovering in
                if hovering { installScrollMonitor() } else { removeScrollMonitor() }
            }
            .contextMenu { clipMenu }
            .onAppear { requestDetail(plan) }
            .onDisappear { removeScrollMonitor() }
            // Nothing on the geometry path touches the timeline any more —
            // `adopt` in `body` already recorded the width. All this does is ask
            // for sharper buckets, and even that waits until the layout pass has
            // unwound.
            .onChange(of: size.width) { _, _ in
                afterLayout { requestDetail(plan) }
            }
            .onChange(of: documentStamp) { _, _ in requestDetail(plan) }
            .onChange(of: plan.window) { _, _ in requestDetail(plan) }
            .onChange(of: store.selection) { _, selection in
                if let selection { timeline.reveal(range: selection) }
            }
            .onChange(of: store.playhead) { _, value in timeline.reveal(value) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Timeline")
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

    // MARK: - The plan
    //
    // Everything the frame needs, worked out once. Hit-testing and drawing read
    // the *same* `frames` and the *same* `size`, which is the property that
    // makes a click land on the clip it looks like it landed on.

    private struct Plan {
        var window: ClosedRange<TimeInterval>
        var laneCount: Int
        var trackIDs: [UUID]
        var frames: [EditorClipFrame]
        var lanes: [[EditorTimelineClipDrawing]]
        var needs: [EditorClipWaveforms.Need]
    }

    private func plan(for size: CGSize) -> Plan {
        guard let document = store.document, !document.tracks.isEmpty else {
            let window = timeline.adopt(
                sourceID: nil,
                duration: 0,
                sampleRate: 48_000,
                width: size.width,
                seed: viewportSeed
            )
            return Plan(window: window, laneCount: 0, trackIDs: [], frames: [], lanes: [], needs: [])
        }

        let resolved = resolvedClips(in: document)
        // The end of the last clip, *including a drag in progress* — a clip
        // dragged past the old end extends the ruler on the same frame rather
        // than one commit later.
        let duration = max(resolved.map(\.clip.end).max() ?? 0, 0.001)

        let window = timeline.adopt(
            sourceID: document.sources.first?.id,
            duration: duration,
            sampleRate: document.source.sampleRate,
            width: size.width,
            seed: viewportSeed
        )

        let laneCount = document.tracks.count
        let lanesRect = EditorTimelineGeometry.lanesRect(in: size)
        let showsNames = resolved.count > 1 || laneCount > 1
        let liveIDs = edit?.ids ?? []

        var frames: [EditorClipFrame] = []
        var lanes = [[EditorTimelineClipDrawing]](repeating: [], count: laneCount)
        var needs: [EditorClipWaveforms.Need] = []

        for entry in resolved {
            let clip = entry.clip
            guard entry.trackIndex >= 0, entry.trackIndex < laneCount else { continue }
            frames.append(
                EditorClipFrame(
                    id: clip.id,
                    trackIndex: entry.trackIndex,
                    start: clip.start,
                    end: clip.end,
                    fadeIn: clip.fadeIn,
                    fadeOut: clip.fadeOut
                )
            )

            // Only the part on screen is ever sampled or drawn. Asking for the
            // whole file at full resolution and clipping is how a "lightweight"
            // editor becomes a fan-spinner.
            let lower = max(clip.start, window.lowerBound)
            let upper = min(clip.end, window.upperBound)
            guard upper > lower else { continue }

            let laneRect = EditorTimelineGeometry.laneRect(
                index: entry.trackIndex, count: laneCount, in: lanesRect
            )
            let widthOnScreen = timeline.x(for: upper, width: size.width)
                - timeline.x(for: lower, width: size.width)
            let count = columnCount(for: widthOnScreen)
            guard count > 0, laneRect.height > 4 else { continue }

            let sourceRange = clip.sourceTime(atTimelineTime: lower)...clip.sourceTime(atTimelineTime: upper)
            needs.append(
                EditorClipWaveforms.Need(sourceID: clip.sourceID, range: sourceRange, columns: count)
            )

            let channels = channelColumns(
                for: clip,
                document: document,
                sourceRange: sourceRange,
                timelineRange: lower...upper,
                count: count,
                splittable: laneRect.height - EditorWaveformMetrics.clipTitleHeight
                    >= EditorWaveformMetrics.channelSplitMinimumHeight
            )

            lanes[entry.trackIndex].append(
                EditorTimelineClipDrawing(
                    id: clip.id,
                    name: document.source(clip.sourceID)?.displayName ?? "Clip",
                    showsName: showsNames,
                    start: clip.start,
                    end: clip.end,
                    fadeIn: clip.fadeIn,
                    fadeOut: clip.fadeOut,
                    fadeShape: Self.shape(of: clip.fadeCurve),
                    isSelected: store.selectedClipIDs.contains(clip.id),
                    isHovered: hoveredClipID == clip.id,
                    isLive: liveIDs.contains(clip.id),
                    visible: lower...upper,
                    channels: channels.columns,
                    isDense: channels.isDense
                )
            )
        }

        return Plan(
            window: window,
            laneCount: laneCount,
            trackIDs: document.tracks.map(\.id),
            frames: frames,
            lanes: lanes,
            needs: needs
        )
    }

    /// The document's clips with any drag in progress applied.
    ///
    /// **The one place a preview is turned into numbers.** Every clamp goes
    /// through `EditorClipEdit`, whose rules are executed and asserted against
    /// the same numbers `EditorStore` uses on commit — so the clip does not jump
    /// when the mouse comes up.
    private func resolvedClips(in document: EditorDocument) -> [(clip: Clip, trackIndex: Int)] {
        var output: [(clip: Clip, trackIndex: Int)] = []
        let trackCount = document.tracks.count

        // A group move is limited by its earliest clip, so a multi-clip drag
        // keeps its spacing instead of collapsing the leftmost one against zero.
        var groupDelta: TimeInterval = 0
        var laneDelta = 0
        if case let .move(ids, by, lanes) = edit {
            let touched = document.tracks.enumerated().flatMap { index, track in
                track.clips.filter { ids.contains($0.id) }.map { (clip: $0, index: index) }
            }
            let earliest = touched.map(\.clip.start).min() ?? 0
            groupDelta = EditorClipEdit.clampedGroupDelta(by, earliestStart: earliest)
            let lowest = touched.map(\.index).min() ?? 0
            let highest = touched.map(\.index).max() ?? 0
            laneDelta = min(max(lanes, -lowest), max(trackCount - 1 - highest, 0))
        }

        for (index, track) in document.tracks.enumerated() {
            for clip in track.clips {
                var resolvedClip = clip
                var resolvedIndex = index
                let sourceDuration = document.source(clip.sourceID)?.duration ?? clip.sourceOut

                switch edit {
                case let .move(ids, _, _) where ids.contains(clip.id):
                    resolvedClip.start = EditorClipEdit.moved(start: clip.start, by: groupDelta)
                    resolvedIndex = min(max(index + laneDelta, 0), max(trackCount - 1, 0))
                case let .trimStart(id, sourceIn) where id == clip.id:
                    let trimmed = EditorClipEdit.trimmedStart(
                        sourceIn: clip.sourceIn,
                        sourceOut: clip.sourceOut,
                        start: clip.start,
                        to: sourceIn
                    )
                    resolvedClip.sourceIn = trimmed.sourceIn
                    resolvedClip.start = trimmed.start
                case let .trimEnd(id, sourceOut) where id == clip.id:
                    resolvedClip.sourceOut = EditorClipEdit.trimmedEnd(
                        sourceIn: clip.sourceIn, to: sourceOut, sourceDuration: sourceDuration
                    )
                case let .fadeIn(id, seconds) where id == clip.id:
                    resolvedClip.fadeIn = EditorClipEdit.fade(
                        seconds, otherFade: clip.fadeOut, clipDuration: clip.duration
                    )
                case let .fadeOut(id, seconds) where id == clip.id:
                    resolvedClip.fadeOut = EditorClipEdit.fade(
                        seconds, otherFade: clip.fadeIn, clipDuration: clip.duration
                    )
                default:
                    break
                }

                // A trim can shorten the clip under a fade that was already
                // there. Same rule the store applies on commit.
                resolvedClip.fadeIn = min(resolvedClip.fadeIn, resolvedClip.duration)
                resolvedClip.fadeOut = min(resolvedClip.fadeOut, resolvedClip.duration - resolvedClip.fadeIn)
                output.append((resolvedClip, resolvedIndex))
            }
        }
        return output
    }

    private static func shape(of curve: FadeCurve) -> EditorClipEdit.FadeShape {
        switch curve {
        case .linear: return .linear
        case .equalPower: return .equalPower
        case .exponential: return .exponential
        }
    }

    // MARK: - Columns

    /// One column per physical pixel, capped. Beyond a few thousand the extra
    /// columns are drawing rectangles narrower than the screen can show.
    private func columnCount(for width: CGFloat) -> Int {
        min(4096, max(0, Int((width * displayScale).rounded())))
    }

    /// The clip's own audio, through its window, scaled by its envelope.
    ///
    /// Three places the buckets can come from, in order — see
    /// `EditorClipWaveforms`. The third is the store's rendered mix, which is
    /// only an exact picture of a clip when the project is the default one
    /// (one source, one track, one clip starting at zero and covering all of
    /// it). It is the fallback that keeps a picture up while the real data is
    /// in flight, and it is the only data a render scene has unless a scene
    /// seeds `EditorClipWaveforms` — which is exactly why every frame written
    /// before clips existed still renders.
    private func channelColumns(
        for clip: Clip,
        document: EditorDocument,
        sourceRange: ClosedRange<TimeInterval>,
        timelineRange: ClosedRange<TimeInterval>,
        count: Int,
        splittable: Bool
    ) -> (columns: [[EditorWaveformColumn]], isDense: Bool) {
        let channels = max(1, document.source(clip.sourceID)?.channelCount ?? 1)

        var raw: [[EditorWaveformColumn]] = []
        var isDense = false

        if let (data, covering) = clipWaveforms.buckets(
            for: clip.sourceID, covering: sourceRange, columns: count
        ), !data.buckets.isEmpty {
            let lanes = EditorWaveformSampler.laneCount(bucketCount: data.buckets.count, channels: channels)
            raw = (0..<lanes).map { lane in
                EditorWaveformSampler.columns(
                    buckets: data.buckets,
                    lanes: lanes, lane: lane,
                    covering: covering, window: sourceRange, count: count
                )
            }
            isDense = clipWaveforms.isDense(
                sourceID: clip.sourceID, covering: sourceRange, columns: count, channels: channels
            )
        } else if let overview = store.waveform, !overview.buckets.isEmpty, overview.duration > 0 {
            let lanes = EditorWaveformSampler.laneCount(bucketCount: overview.buckets.count, channels: channels)
            raw = (0..<lanes).map { lane in
                EditorWaveformSampler.columns(
                    buckets: overview.buckets,
                    lanes: lanes, lane: lane,
                    covering: 0...overview.duration,
                    window: timelineRange, count: count
                )
            }
            let perLane = Double(overview.buckets.count / max(lanes, 1))
            let span = timelineRange.upperBound - timelineRange.lowerBound
            isDense = perLane * span / overview.duration >= Double(count) * 0.6
        }

        guard !raw.isEmpty else { return ([], false) }
        if !splittable, raw.count > 1 {
            // Too short to split honestly: one lane carrying the widest
            // excursion either channel saw. A 15pt stripe per channel is not a
            // drawing of two channels.
            raw = [(0..<count).map { index in
                EditorWaveformColumn.merged(raw.map { $0[index] })
            }]
        }

        // The clip's own gain and its two fades, multiplied into the picture.
        // This is what makes a fade a *real slope in the audio* rather than a
        // wedge laid over an unchanged waveform, and what makes a clip you
        // turned down look turned down.
        let gain = pow(10.0, clip.gainDB / 20)
        let clipDuration = clip.duration
        let span = timelineRange.upperBound - timelineRange.lowerBound
        let needsEnvelope = clip.fadeIn > 0 || clip.fadeOut > 0 || gain != 1
        guard needsEnvelope, span > 0 else { return (raw, isDense) }

        let scaled = raw.map { lane in
            lane.enumerated().map { index, column -> EditorWaveformColumn in
                let time = timelineRange.lowerBound + span * (Double(index) + 0.5) / Double(count)
                let envelope = EditorClipEdit.envelopeGain(
                    at: time - clip.start,
                    clipDuration: clipDuration,
                    fadeIn: clip.fadeIn,
                    fadeOut: clip.fadeOut,
                    curve: Self.shape(of: clip.fadeCurve)
                )
                return column.scaled(by: gain * envelope)
            }
        }
        return (scaled, isDense)
    }

    /// Cheap identity for "the project changed". Comparing the whole document on
    /// every body evaluation is not free, and the sources plus the clip count
    /// plus the length is enough to catch anything that needs new buckets.
    private var documentStamp: String {
        guard let document = store.document else { return "-" }
        let sources = document.sources.map(\.id.uuidString).joined(separator: ",")
        let clips = document.tracks.reduce(0) { $0 + $1.clips.count }
        return "\(sources)|\(document.tracks.count)|\(clips)|\(Int(document.duration * 1000))"
    }

    /// Runs `work` on the next main-actor turn, once the layout pass that
    /// delivered the callback has unwound.
    ///
    /// Only detail requests use this, and only from the geometry path. It is
    /// the right tool for work whose result nobody is photographing — an
    /// asynchronous render request that is already debounced by 45 ms. It was
    /// the wrong tool for adopting the sound, because a turn of latency in the
    /// window being drawn is a turn of latency the first frame shows.
    private func afterLayout(_ work: @escaping @MainActor () -> Void) {
        Task { @MainActor in work() }
    }

    private func requestDetail(_ plan: Plan) {
        guard let document = store.document else {
            clipWaveforms.invalidate()
            return
        }
        clipWaveforms.request(document: document, engine: store.renderEngine, needs: plan.needs)
    }

    /// An opening window for a render scene. Always `nil` outside `MELO_DEV`.
    private var viewportSeed: EditorTimeline.Seed? {
        guard seededZoom != nil || seededWindowStart != nil
                || seededHoveredEdge != nil || seededHover != nil || seededEdit != nil else {
            return nil
        }
        // Asking for a grabbed handle is asking to see the handle: without this,
        // a seeded window that misses the seeded selection renders a zoomed
        // frame with no chrome in it at all.
        var centreOn: TimeInterval?
        if seededWindowStart == nil {
            if let edge = seededHoveredEdge, let selection = store.selection {
                centreOn = edge == .lower ? selection.lowerBound : selection.upperBound
            } else if let id = seededHoverClipID ?? seededEdit?.ids.first,
                      let clip = store.document?.clip(id) {
                centreOn = (clip.start + clip.end) / 2
            }
        }
        return EditorTimeline.Seed(
            zoomFraction: seededZoom,
            windowStart: seededWindowStart,
            centreOn: centreOn
        )
    }

    private var accessibilityValue: String {
        guard let document = store.document else { return "No sound loaded" }
        var parts = [
            "Playhead at \(EditorFormat.spokenTime(store.playhead)) of \(EditorFormat.spokenTime(timeline.duration))"
        ]
        if document.isMultitrack {
            let clips = document.tracks.reduce(0) { $0 + $1.clips.count }
            parts.append("\(document.tracks.count) tracks, \(clips) clips")
        }
        if let selection = store.selection {
            parts.append(
                "Selection \(EditorFormat.spokenTime(selection.lowerBound)) to "
                    + "\(EditorFormat.spokenTime(selection.upperBound))"
            )
        }
        if !store.selectedClipIDs.isEmpty {
            let count = store.selectedClipIDs.count
            parts.append("\(count) clip\(count == 1 ? "" : "s") selected")
        }
        if !timeline.isFitToWindow {
            parts.append("Showing \(EditorFormat.spokenTime(timeline.visible))")
        }
        return parts.joined(separator: ". ")
    }

    // MARK: - Selection edges

    enum SelectionEdge: Equatable { case lower, upper }

    private struct ClickRecord: Equatable {
        var at: Date
        var x: CGFloat
    }

    /// Live drag state. The `kind` decides what the pointer's movement means;
    /// nothing branches on a mode, because there is no mode.
    private struct DragState {
        enum Kind: Equatable {
            /// A span of time — the gesture the whole move stack is aimed with.
            case timeSelection(anchor: TimeInterval, edge: SelectionEdge?)
            /// The ruler. Moves the playhead and nothing else.
            case scrub
            /// `grabbed` is the clip actually under the pointer. Its two edges
            /// are what snap; the pointer does not. Snapping the pointer looks
            /// identical in a screenshot and is wrong in the hand — the clip
            /// then lands wherever the grab offset happened to put it, so
            /// butting two clips together is luck rather than a detent.
            case moveClips(ids: Set<UUID>, grabbed: UUID, grabTime: TimeInterval, grabLane: Int)
            case trimStart(id: UUID)
            case trimEnd(id: UUID)
            case fadeIn(id: UUID)
            case fadeOut(id: UUID)
        }
        var kind: Kind
        var isActive: Bool
    }

    private var hoveredClipID: UUID? {
        if case let .clip(id, _) = hover { return id }
        return seededHoverClipID
    }

    private var seededHoverClipID: UUID? {
        if case let .clip(id, _) = seededHover { return id }
        return nil
    }

    private var draggingSelectionEdge: SelectionEdge? {
        if case let .timeSelection(_, edge) = drag?.kind, drag?.isActive == true { return edge }
        return nil
    }

    // MARK: - Gestures

    private func dragGesture(size: CGSize, plan: Plan) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                guard store.document != nil else { return }
                var state = drag ?? beginDrag(at: value.startLocation, size: size, plan: plan)
                if !state.isActive,
                   abs(value.translation.width) > EditorWaveformMetrics.dragThreshold
                    || abs(value.translation.height) > EditorWaveformMetrics.dragThreshold {
                    state.isActive = true
                    timeline.isUserAdjusting = true
                    timeline.endFollowing()
                    if case let .timeSelection(anchor, _) = state.kind {
                        edgeDetents = DetentTracker(
                            values: snapLandmarks(excluding: anchor, plan: plan),
                            tolerance: timeline.secondsPerPoint * Double(EditorWaveformMetrics.snapPoints)
                        )
                    }
                }
                if state.isActive {
                    state = update(state, at: value.location, size: size, plan: plan)
                    autoScroll(pointerX: value.location.x, width: size.width)
                }
                drag = state
            }
            .onEnded { value in
                let finished = drag
                defer {
                    drag = nil
                    edit = nil
                    timeline.isUserAdjusting = false
                }
                guard store.document != nil, let finished else { return }
                if finished.isActive {
                    commit(finished, plan: plan)
                } else {
                    click(finished, at: value.location, size: size, plan: plan)
                }
            }
    }

    private func beginDrag(at point: CGPoint, size: CGSize, plan: Plan) -> DragState {
        let time = timeline.clampToSound(timeline.time(atX: point.x, width: size.width))

        if point.y < EditorWaveformMetrics.rulerHeight {
            return DragState(kind: .scrub, isActive: false)
        }

        // The time-selection handles float above everything, so a selection you
        // can see is a selection you can grab even when a clip is under it.
        if let edge = selectionEdge(nearX: point.x, width: size.width), let selection = store.selection {
            let anchor = edge == .lower ? selection.upperBound : selection.lowerBound
            return DragState(kind: .timeSelection(anchor: anchor, edge: edge), isActive: false)
        }

        let hit = EditorTimelineGeometry.hitTest(
            point, frames: plan.frames, laneCount: plan.laneCount, in: size, viewport: timeline.viewport
        )

        switch hit {
        case let .clip(id, .move):
            var ids = store.selectedClipIDs
            if !ids.contains(id) { ids = [id] }
            let lane = plan.frames.first { $0.id == id }?.trackIndex ?? 0
            return DragState(
                kind: .moveClips(ids: ids, grabbed: id, grabTime: time, grabLane: lane),
                isActive: false
            )
        case let .clip(id, .trimStart):
            return DragState(kind: .trimStart(id: id), isActive: false)
        case let .clip(id, .trimEnd):
            return DragState(kind: .trimEnd(id: id), isActive: false)
        case let .clip(id, .fadeIn):
            return DragState(kind: .fadeIn(id: id), isActive: false)
        case let .clip(id, .fadeOut):
            return DragState(kind: .fadeOut(id: id), isActive: false)
        default:
            break
        }

        // Anywhere else — a clip's body included — is a span of time, which is
        // what a drag across the waveform has always meant and what every move
        // in the stack is aimed with.
        let shift = NSEvent.modifierFlags.contains(.shift)
        if shift, let selection = store.selection {
            // Extend from whichever end is further away, which is what the rest
            // of macOS does with a shift-click.
            let anchor = abs(time - selection.lowerBound) > abs(time - selection.upperBound)
                ? selection.lowerBound
                : selection.upperBound
            return DragState(kind: .timeSelection(anchor: anchor, edge: nil), isActive: false)
        }
        if shift {
            return DragState(kind: .timeSelection(anchor: store.playhead, edge: nil), isActive: false)
        }
        return DragState(kind: .timeSelection(anchor: time, edge: nil), isActive: false)
    }

    private func update(_ state: DragState, at point: CGPoint, size: CGSize, plan: Plan) -> DragState {
        var state = state
        let raw = timeline.time(atX: point.x, width: size.width)
        let time = timeline.clampToSound(raw)

        switch state.kind {
        case .scrub:
            store.playhead = time

        case let .timeSelection(anchor, _):
            let moving = snapped(time, plan: plan)
            if edgeDetents.crossed(moving) { Haptics.detent() }
            let lower = min(anchor, moving)
            let upper = max(anchor, moving)
            store.selection = upper > lower ? lower...upper : nil
            store.playhead = lower
            state.kind = .timeSelection(anchor: anchor, edge: moving <= anchor ? .lower : .upper)

        case let .moveClips(ids, grabbed, grabTime, grabLane):
            let lanesRect = EditorTimelineGeometry.lanesRect(in: size)
            let lane = EditorTimelineGeometry.nearestLaneIndex(
                atY: point.y, count: max(plan.laneCount, 1), in: lanesRect
            )
            // The clip's *stored* edges, not `plan.frames` — those already
            // carry the preview, so snapping against them would chase itself.
            let clip = store.document?.clip(grabbed)
            let delta = snappedDelta(
                raw - grabTime,
                edges: clip.map { [$0.start, $0.end] } ?? [],
                plan: plan
            )
            edit = .move(ids: ids, by: delta, lanes: lane - grabLane)

        case let .trimStart(id):
            guard let clip = store.document?.clip(id) else { break }
            edit = .trimStart(id: id, sourceIn: clip.sourceIn + (snapped(raw, plan: plan) - clip.start))

        case let .trimEnd(id):
            guard let clip = store.document?.clip(id) else { break }
            edit = .trimEnd(id: id, sourceOut: clip.sourceIn + (snapped(raw, plan: plan) - clip.start))

        case let .fadeIn(id):
            guard let clip = store.document?.clip(id) else { break }
            edit = .fadeIn(id: id, seconds: raw - clip.start)

        case let .fadeOut(id):
            guard let clip = store.document?.clip(id) else { break }
            edit = .fadeOut(id: id, seconds: clip.end - raw)
        }
        return state
    }

    /// Writes the drag to the store. One call per gesture wherever the store
    /// offers one.
    private func commit(_ state: DragState, plan: Plan) {
        switch state.kind {
        case .scrub:
            break

        case .timeSelection:
            // A drag that ended up shorter than two points is a click that
            // wobbled, not a selection.
            if let selection = store.selection,
               selection.upperBound - selection.lowerBound < timeline.secondsPerPoint * 2 {
                store.selection = nil
            } else {
                Haptics.commit()
            }

        case .moveClips:
            guard let document = store.document, let edit else { break }
            // One batch through one `mutate`, so a three-clip drag is one ⌘Z.
            store.moveClips(
                resolvedClips(in: document).compactMap { entry in
                    guard edit.ids.contains(entry.clip.id),
                          entry.trackIndex < plan.trackIDs.count else { return nil }
                    return EditorStore.ClipMove(
                        id: entry.clip.id,
                        trackID: plan.trackIDs[entry.trackIndex],
                        start: entry.clip.start
                    )
                }
            )
            Haptics.commit()

        case let .trimStart(id):
            guard case let .trimStart(_, sourceIn) = edit else { break }
            store.trimClip(id, sourceIn: sourceIn, sourceOut: nil)
            Haptics.commit()

        case let .trimEnd(id):
            guard case let .trimEnd(_, sourceOut) = edit else { break }
            store.trimClip(id, sourceIn: nil, sourceOut: sourceOut)
            Haptics.commit()

        case let .fadeIn(id):
            guard case let .fadeIn(_, seconds) = edit else { break }
            store.setClipFades(id, fadeIn: max(0, seconds), fadeOut: nil, curve: nil)
            Haptics.commit()

        case let .fadeOut(id):
            guard case let .fadeOut(_, seconds) = edit else { break }
            store.setClipFades(id, fadeIn: nil, fadeOut: max(0, seconds), curve: nil)
            Haptics.commit()
        }
    }

    /// A press that never became a drag.
    ///
    /// **The name strip is the clip; the body is the audio.** Clicking a clip's
    /// strip selects the clip. Clicking its body — or empty lane — moves the
    /// playhead and clears the clip selection, exactly as clicking the waveform
    /// did before clips existed. That is the whole of the model, and it is why
    /// one track with one clip behaves identically to the pane it replaced.
    private func click(_ state: DragState, at point: CGPoint, size: CGSize, plan: Plan) {
        let time = timeline.clampToSound(timeline.time(atX: point.x, width: size.width))

        if case .scrub = state.kind {
            store.playhead = time
            return
        }

        if isSecondClick(atX: point.x) {
            store.selection = 0...timeline.duration
            store.playhead = 0
            lastClick = nil
            Haptics.commit()
            return
        }
        lastClick = ClickRecord(at: Date(), x: point.x)

        let hit = EditorTimelineGeometry.hitTest(
            point, frames: plan.frames, laneCount: plan.laneCount, in: size, viewport: timeline.viewport
        )
        if case let .lane(index) = hit, index < plan.trackIDs.count {
            store.selectedTrackID = plan.trackIDs[index]
        }
        if case let .clip(id, part) = hit {
            if let lane = plan.frames.first(where: { $0.id == id })?.trackIndex,
               lane < plan.trackIDs.count {
                store.selectedTrackID = plan.trackIDs[lane]
            }
            if part == .move {
                let additive = NSEvent.modifierFlags.contains(.shift)
                    || NSEvent.modifierFlags.contains(.command)
                if additive {
                    if store.selectedClipIDs.contains(id) {
                        store.selectedClipIDs.remove(id)
                    } else {
                        store.selectedClipIDs.insert(id)
                    }
                } else {
                    store.selectedClipIDs = [id]
                }
                return
            }
        }

        store.selectedClipIDs = []
        store.selection = nil
        store.playhead = time
    }

    /// The landmarks a dragged edge snaps to: the ends of the project, the
    /// playhead, and every clip boundary. Nothing else — snapping to a grid the
    /// user cannot see is how an edge stops landing where they let go, and a
    /// clip boundary is a line they can see.
    private func snapLandmarks(excluding anchor: TimeInterval, plan: Plan) -> [Double] {
        var values: [Double] = [0, timeline.duration]
        if abs(store.playhead - anchor) > 0.0001 { values.append(store.playhead) }
        for frame in plan.frames {
            values.append(frame.start)
            values.append(frame.end)
        }
        return values
    }

    private func snapped(_ time: TimeInterval, plan: Plan) -> TimeInterval {
        let tolerance = timeline.secondsPerPoint * Double(EditorWaveformMetrics.snapPoints)
        var landmarks: [Double] = [0, timeline.duration, store.playhead]
        // A clip does not snap to itself.
        let moving = edit?.ids ?? []
        for frame in plan.frames where !moving.contains(frame.id) {
            landmarks.append(frame.start)
            landmarks.append(frame.end)
        }
        var best: (value: Double, distance: Double)?
        for landmark in landmarks {
            let distance = abs(time - landmark)
            guard distance <= tolerance else { continue }
            if best == nil || distance < best!.distance { best = (landmark, distance) }
        }
        return best?.value ?? time
    }

    /// A move drag's delta, adjusted so that whichever of the dragged clip's
    /// two edges comes closest to a landmark lands exactly on it.
    ///
    /// Both edges are offered, and the nearer wins: dragging a clip up against
    /// the one before it should butt its head to that clip's tail, and dragging
    /// it back should butt its tail to the next clip's head. Offering only the
    /// head makes half the gestures miss.
    private func snappedDelta(_ delta: TimeInterval, edges: [TimeInterval], plan: Plan) -> TimeInterval {
        guard !edges.isEmpty else { return delta }
        var best: (delta: TimeInterval, distance: TimeInterval)?
        for edge in edges {
            let target = snapped(edge + delta, plan: plan)
            let distance = abs(target - (edge + delta))
            if best == nil || distance < best!.distance { best = (target - edge, distance) }
        }
        return best?.delta ?? delta
    }

    private func isSecondClick(atX x: CGFloat) -> Bool {
        guard let lastClick else { return false }
        return Date().timeIntervalSince(lastClick.at) <= NSEvent.doubleClickInterval
            && abs(lastClick.x - x) <= 4
    }

    /// Keeps the window moving when a drag runs off the edge. Tied to pointer
    /// movement rather than a timer on purpose: a timer that scrolls while the
    /// pointer is parked overshoots every time.
    private func autoScroll(pointerX: CGFloat, width: CGFloat) {
        guard !timeline.isFitToWindow else { return }
        if pointerX < 16 {
            timeline.scroll(byPoints: max(-24, pointerX - 16))
        } else if pointerX > width - 16 {
            timeline.scroll(byPoints: min(24, pointerX - (width - 16)))
        }
    }

    // MARK: - Pointer

    private func handleHover(_ phase: HoverPhase, size: CGSize, plan: Plan) {
        switch phase {
        case let .active(location):
            timeline.pointerFraction = Double(location.x / max(size.width, 1))
            let edge = selectionEdge(nearX: location.x, width: size.width)
            if edge != selectionEdgeUnderPointer { selectionEdgeUnderPointer = edge }
            let hit = edge == nil
                ? EditorTimelineGeometry.hitTest(
                    location, frames: plan.frames, laneCount: plan.laneCount,
                    in: size, viewport: timeline.viewport
                )
                : nil
            if hit != hover { hover = hit }
            Self.cursor(for: hit, selectionEdge: edge).set()
        case .ended:
            if hover != nil { hover = nil }
            if selectionEdgeUnderPointer != nil { selectionEdgeUnderPointer = nil }
            NSCursor.arrow.set()
        }
    }

    private static func cursor(for hit: EditorTimelineHit?, selectionEdge: SelectionEdge?) -> NSCursor {
        if selectionEdge != nil { return .resizeLeftRight }
        guard case let .clip(_, part) = hit else { return .arrow }
        switch part {
        // `NSCursor.columnResize` is macOS 15; `resizeLeftRight` is the one
        // that has always been there and reads identically.
        case .trimStart, .trimEnd, .fadeIn, .fadeOut: return .resizeLeftRight
        case .move: return .openHand
        case .body: return .arrow
        }
    }

    private func selectionEdge(nearX x: CGFloat, width: CGFloat) -> SelectionEdge? {
        guard let selection = store.selection else { return nil }
        let grab = EditorWaveformMetrics.handleGrab
        if abs(x - timeline.x(for: selection.lowerBound, width: width)) <= grab { return .lower }
        if abs(x - timeline.x(for: selection.upperBound, width: width)) <= grab { return .upper }
        return nil
    }

    // MARK: - The clip menu
    //
    // Right-click, built against whatever the pointer is over — which is where
    // the click happened, because the pointer had to be there to click. Split,
    // copy, paste and delete are here rather than as buttons because the pane
    // has to stay calm at rest: a toolbar of clip verbs above one track and one
    // clip is exactly the chrome the simple case must not grow.
    //
    // The same four verbs want keyboard shortcuts, which live in
    // `Editor/Window/EditorCommands.swift` and are not this file's to write.
    // Reported.

    @ViewBuilder
    private var clipMenu: some View {
        if let id = hoveredClipID, let document = store.document, document.clip(id) != nil {
            let targets = store.selectedClipIDs.contains(id) ? Array(store.selectedClipIDs) : [id]
            Button("Split at Playhead") {
                for target in targets { store.splitClip(target, at: store.playhead) }
            }
            .disabled(!canSplit(targets))

            Button(targets.count > 1 ? "Copy \(targets.count) Clips" : "Copy") {
                store.copyClips(targets)
            }
            Button("Paste") {
                store.pasteClips(at: store.playhead, track: store.selectedTrackID)
            }
            .disabled(!store.canPasteClips)

            Divider()

            Button(targets.count > 1 ? "Delete \(targets.count) Clips" : "Delete", role: .destructive) {
                for target in targets { store.removeClip(target) }
            }
        } else if store.document != nil {
            Button("Paste") {
                store.pasteClips(at: store.playhead, track: store.selectedTrackID)
            }
            .disabled(!store.canPasteClips)
        }
    }

    private func canSplit(_ ids: [UUID]) -> Bool {
        guard let document = store.document else { return false }
        return ids.contains { id in
            guard let clip = document.clip(id) else { return false }
            let offset = store.playhead - clip.start
            return offset > Clip.minimumDuration && offset < clip.duration - Clip.minimumDuration
        }
    }

    // MARK: - Zoom

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
    /// `ScrollWheelStepModifier`: a representable inside the timeline would be
    /// a hole in every captured frame.
    ///
    /// Plain scroll pans and Option- or Command-scroll zooms, which is the
    /// macOS convention and the opposite of what a web canvas does.
    /// `zoomFraction` is the value stepped, so a swipe covers the same fraction
    /// of the zoom range wherever it starts.
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
                // vertical one, and on a timeline vertical wheel means "along".
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
        if hover != nil { hover = nil }
        if selectionEdgeUnderPointer != nil { selectionEdgeUnderPointer = nil }
        NSCursor.arrow.set()
    }
}

// MARK: - Scroll bar

/// Where the window sits in the whole project. Only drawn when zoomed in: at
/// fit-to-window it would be a full-width bar saying nothing. **Its ten points
/// are reserved either way** — see `EditorWaveformMetrics.scrollBarHeight`.
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
    /// zoomed view, a grabbed handle, a hovered clip and a drag in progress.
    ///
    /// `EditorStore.setForSnapshot` covers the document and the mix waveform,
    /// `EditorClipWaveforms.setForSnapshot` covers per-source pictures for a
    /// multitrack scene, and a scene sets `selection`, `playhead`,
    /// `selectedClipIDs` and `selectedTrackID` on the store directly — those are
    /// published properties, not this view's `@State`.
    ///
    /// Declared in an extension, and behind `#if MELO_DEV`, so the real
    /// `init(store:)` is the only one a release build has at all.
    ///
    /// - Parameters:
    ///   - zoom: 0 fits the whole project, 1 is sample-adjacent. Logarithmic.
    ///   - windowStart: Left edge in seconds, applied after `zoom`. Left `nil`,
    ///     the window centres itself on whatever else was seeded.
    ///   - hoveredEdge: Draws a time-selection handle in its grabbed state.
    ///   - style: Overrides the stored preference for this view only. A scene
    ///     that wrote the preference instead would change what every later
    ///     scene rendered, and the harness renders them in one process.
    ///   - hoveredClip: Draws a clip in its hovered state — which is the only
    ///     state that shows the name strip's wash, and therefore the only frame
    ///     in which the move handle is visible at all.
    ///   - edit: A drag in progress, drawn exactly as the pointer would have it
    ///     mid-gesture. The harness cannot produce a gesture, so this is the
    ///     only way a mid-drag frame exists.
    init(
        store: EditorStore,
        zoom: Double? = nil,
        windowStart: TimeInterval? = nil,
        hoveredEdge: SelectionEdge? = nil,
        style: EditorWaveformStyle? = nil,
        hoveredClip: Clip.ID? = nil,
        hoveredPart: EditorClipPart = .move,
        edit: EditorTimelineClipEdit? = nil
    ) {
        _store = ObservedObject(wrappedValue: store)
        seededZoom = zoom
        seededWindowStart = windowStart
        seededHoveredEdge = hoveredEdge
        seededStyle = style
        seededHover = hoveredClip.map { .clip(id: $0, part: hoveredPart) }
        seededEdit = edit
        _edit = State(initialValue: edit)
        _hover = State(initialValue: hoveredClip.map { .clip(id: $0, part: hoveredPart) })
    }
}
#endif
