// Melo/Editor/Views/Waveform/EditorClipWaveforms.swift
//
// The drawing data for clips, which is **per source, not per mix**.
//
// This is the decision that makes a clip an object rather than a window onto a
// rendered result, and it is worth stating plainly because it changes what the
// picture means.
//
// A clip is a window (`sourceIn`…`sourceOut`) onto a decoded file. Drawing it
// from that file's own waveform is what makes a trim *look* like what it is:
// drag the leading edge in and the picture inside the clip does not squash, it
// reveals less of the same audio; drag it back out and the audio comes back,
// because it was never thrown away. A clip drawn from a rendered mix cannot do
// that — the mix has one timeline, the lanes have many, and after a trim the
// mix is a different length than the thing you are drawing.
//
// **What this costs, named.** The move stacks no longer tint the picture. A
// normalize on the master used to visibly lift the waveform, and it will not
// any more. That is the same trade every DAW makes and it is forced here: the
// mix is one signal and there are several lanes, so there is no honest way to
// draw a per-track picture of it. What the clip *does* draw honestly is what
// belongs to the clip — its own gain and its own two fades, which are scaled
// into the columns so the fade is a real slope in the audio and not a wedge
// laid over it.
//
// Three sources of buckets, in order, so the picture never disappears:
//
//  1. **Detail** — one source, one window, at the width on screen. Only ever
//     requested for the source that occupies most of the visible pane, and
//     only when the overview is coarser than the pixels.
//  2. **Overview** — the whole of a source at 2048 buckets, fetched once per
//     source and kept. This is what a clip draws with almost all the time.
//  3. **The store's mix overview**, resolved by the view, not here. See
//     `EditorWaveformView.columns(for:)`.

import Foundation
import SwiftUI

@MainActor
final class EditorClipWaveforms: ObservableObject {

    /// A singleton for the same reason `EditorStore` and `EditorTimeline` are:
    /// there is one Melo Edit window.
    ///
    /// It was a `@StateObject` on the view until the harness probe caught what
    /// that costs — a scene has no way to reach a view's `@StateObject`, so
    /// `setForSnapshot` was unreachable and every multitrack frame would have
    /// fallen back to drawing the mix in every lane. Which is exactly the
    /// defect a multitrack frame exists to catch, so it would have shipped
    /// looking correct.
    static let shared = EditorClipWaveforms()

    private init() {}

    /// One source's whole waveform. `covering` is `0...data.duration` — the
    /// render's own idea of how long the file is, which is the number the
    /// buckets were actually laid out against.
    struct Overview: Equatable {
        var data: WaveformData
        var covering: ClosedRange<TimeInterval>
    }

    /// A sharp window into one source, in that source's own time.
    struct Detail: Equatable {
        var sourceID: UUID
        var range: ClosedRange<TimeInterval>
        /// Columns *requested*. `buckets.count / requested` is the channel
        /// count the engine actually returned, which is how stereo lanes are
        /// discovered without a second field on `WaveformData`.
        var requested: Int
        var data: WaveformData
    }

    /// What one clip needs drawn this pass.
    struct Need {
        var sourceID: UUID
        /// The part of the source that is on screen, in source time.
        var range: ClosedRange<TimeInterval>
        /// How many columns that span is being drawn across.
        var columns: Int
    }

    /// One on-screen clip whose chain the compare lane needs a picture of.
    ///
    /// Carries the source rather than its id: the render is of a synthetic
    /// one-source document, and looking the source back up on the far side of
    /// an `await` is a lookup into a document that may have moved on.
    struct ProcessedNeed {
        var clipID: Clip.ID
        var source: EditorSource
        /// Already through `EditorChain.effectiveChain`, so it holds only
        /// enabled moves that do not shape time. That filter is what guarantees
        /// the render comes back the same length as the source, which is what
        /// lets the strip be drawn against the clip's own span of the ruler.
        var moves: [Move]
    }

    /// One clip's audio after its chain, for the compare lane.
    ///
    /// **Keyed by clip, not by source**, because the chain is per clip: two
    /// clips cut from one file can carry different stacks, and one entry per
    /// source would have drawn one of them through the other's moves. The cost
    /// is that two clips with identical chains render twice. Measured against
    /// the alternative — keying by a per-clip fingerprint of the chain — that
    /// alternative loses on the hot path, not on the render: `stamp` is one
    /// reflected pass over the document per drawing frame, and per clip it
    /// would be one per clip per frame at sixty frames a second.
    struct Processed: Equatable {
        var data: WaveformData
        var covering: ClosedRange<TimeInterval>
    }

    @Published private(set) var overviews: [UUID: Overview] = [:]
    @Published private(set) var detail: Detail?
    @Published private(set) var processed: [Clip.ID: Processed] = [:]

    /// The document chain every entry in `processed` was rendered against.
    ///
    /// One string for the whole map rather than one per entry. When the user
    /// changes any move, this stops matching and **every** processed picture is
    /// stale at once — which is the truth: the master stack is in every clip's
    /// effective chain, so a master edit really does invalidate all of them, and
    /// a per-entry stamp would spend a comparison per clip per frame to
    /// discover the same thing.
    private var processedChain: String?

    /// Buckets in a source overview. The same number the store asks for, for
    /// the same reason: wide enough for a full-width waveform on a Retina
    /// display, and the detail path is what covers anything deeper.
    private static let overviewBuckets = 2_048

    /// Within a factor of ~1.35 either way. Tighter than this re-renders on
    /// every pinch frame; looser and a deep zoom stays visibly blocky.
    private static let densityTolerance = 0.3

    private var overviewWork: Task<Void, Never>?
    private var overviewQueue: [UUID] = []
    private var processedWork: Task<Void, Never>?
    private var processedQueue: [ProcessedNeed] = []
    private var detailWork: Task<Void, Never>?
    private var detailInFlight: (sourceID: UUID, range: ClosedRange<TimeInterval>, requested: Int)?

    /// Snapshot fixtures have no file behind them, so `RenderEngine` throws on
    /// every call. Two failures for a source and this stops asking for it —
    /// otherwise a pinned frame would spin the actor forever.
    private var failures: [UUID: Int] = [:]

    #if MELO_DEV
    /// A harness has seeded the overviews by hand. Nothing is requested, and a
    /// source with no seeded overview simply has none — the view falls back to
    /// the store's picture, which is what every pre-multitrack scene already
    /// renders with.
    private var isSeeded = false
    #endif

    // MARK: - Reading

    /// The best buckets available for a span of one source, and the span they
    /// actually cover. `nil` when nothing has arrived yet.
    func buckets(
        for sourceID: UUID,
        covering range: ClosedRange<TimeInterval>,
        columns: Int
    ) -> (data: WaveformData, covering: ClosedRange<TimeInterval>)? {
        if let detail, detail.sourceID == sourceID, Self.covers(detail.range, range) {
            return (detail.data, detail.range)
        }
        if let overview = overviews[sourceID] {
            return (overview.data, overview.covering)
        }
        return nil
    }

    /// The chain-processed picture of one clip's source, if there is a current
    /// one.
    ///
    /// `nil` covers three different situations and the caller has to keep them
    /// apart: the lane is off so nothing was asked for, the render has not
    /// landed, or the document changed and what is held describes an older
    /// chain. All three mean *draw the raw picture in both places and say so* —
    /// never *draw two identical waveforms and call it a comparison*.
    func processedBuckets(
        for clipID: Clip.ID,
        chain: String
    ) -> (data: WaveformData, covering: ClosedRange<TimeInterval>)? {
        guard processedChain == chain, let entry = processed[clipID] else { return nil }
        return (entry.data, entry.covering)
    }

    /// Whether what is on hand for this span has at least one bucket behind
    /// every couple of columns. The painter suppresses the RMS core below this,
    /// because one bucket stretched across forty columns paints as a solid slab
    /// of constant level that is not a measurement of anything.
    func isDense(sourceID: UUID, covering range: ClosedRange<TimeInterval>, columns: Int, channels: Int) -> Bool {
        let span = range.upperBound - range.lowerBound
        guard span > 0, columns > 0 else { return true }
        guard let (data, covering) = buckets(for: sourceID, covering: range, columns: columns) else { return false }
        let lanes = max(EditorWaveformSampler.laneCount(bucketCount: data.buckets.count, channels: channels), 1)
        let perLane = Double(data.buckets.count / lanes)
        let coveringSpan = covering.upperBound - covering.lowerBound
        guard coveringSpan > 0 else { return false }
        return perLane * span / coveringSpan >= Double(columns) * 0.6
    }

    // MARK: - Asking

    /// Makes sure every source on screen has an overview, and gives the sharp
    /// picture to the one that most of the pane is showing.
    ///
    /// **One detail request at a time, for one source.** `RenderEngine` caches
    /// exactly one decoded file, so alternating detail requests between two
    /// sources would re-decode on every frame — the fan-spinner this feature
    /// exists not to be. The source with the most columns on screen is the one
    /// the user is looking closest at; everything else draws from its overview,
    /// which is already good to about a bucket a pixel at normal zooms.
    func request(document: EditorDocument, engine: RenderEngine, needs: [Need]) {
        #if MELO_DEV
        if isSeeded { return }
        #endif
        guard !needs.isEmpty else { return }

        for need in needs where overviews[need.sourceID] == nil {
            guard (failures[need.sourceID] ?? 0) < 2 else { continue }
            guard !overviewQueue.contains(need.sourceID) else { continue }
            overviewQueue.append(need.sourceID)
        }
        drainOverviews(document: document, engine: engine)

        // Merge the needs per source: two clips cut from the same file that are
        // both on screen want one request spanning both.
        var merged: [UUID: Need] = [:]
        for need in needs {
            if let existing = merged[need.sourceID] {
                let lower = min(existing.range.lowerBound, need.range.lowerBound)
                let upper = max(existing.range.upperBound, need.range.upperBound)
                merged[need.sourceID] = Need(
                    sourceID: need.sourceID,
                    range: lower...upper,
                    columns: existing.columns + need.columns
                )
            } else {
                merged[need.sourceID] = need
            }
        }

        guard let widest = merged.values.max(by: { $0.columns < $1.columns }) else { return }
        guard (failures[widest.sourceID] ?? 0) < 2 else { return }
        guard needsDetail(widest, channels: document.source(widest.sourceID)?.channelCount ?? 1) else { return }
        requestDetail(widest, document: document, engine: engine)
    }

    /// Everything the compare lane needs for the clips on screen, and nothing
    /// for anything else.
    ///
    /// **Called only while the lane is on**, which is the whole cost argument:
    /// with it off this is never reached, no second render is started, and the
    /// timeline behaves exactly as it did before the lane existed. That is what
    /// makes "it can be turned off" a real answer to the expense rather than a
    /// setting that hides a feature you are still paying for.
    ///
    /// A clip whose effective chain is **empty is skipped rather than
    /// rendered**. There is nothing for the render to do — the answer would be
    /// the raw overview, bucket for bucket — and the drawing side already falls
    /// back to that. It also happens to be the default document's state, so the
    /// common case costs nothing at all.
    ///
    /// Serial, one clip at a time, for the reason `drainOverviews` is: the
    /// transient peak is one decoded block plus one processed copy, whatever
    /// the project holds. Draw order, so the lane being looked at fills first.
    func requestProcessed(
        document: EditorDocument,
        engine: RenderEngine,
        chain: String,
        needs: [ProcessedNeed]
    ) {
        #if MELO_DEV
        if isSeeded { return }
        #endif
        if processedChain != chain {
            // The stack moved. Everything held describes an edit nobody is
            // making any more, and drawing it under a clip would be a
            // comparison against the wrong thing — worse than no comparison.
            processedChain = chain
            processedWork?.cancel()
            processedWork = nil
            processedQueue = []
            if !processed.isEmpty { processed = [:] }
        }
        for need in needs where !need.moves.isEmpty {
            guard processed[need.clipID] == nil else { continue }
            guard (failures[need.source.id] ?? 0) < 2 else { continue }
            guard !processedQueue.contains(where: { $0.clipID == need.clipID }) else { continue }
            processedQueue.append(need)
        }
        drainProcessed(engine: engine, chain: chain)
    }

    /// Drops everything. Called when the document closes or the sources change
    /// under us.
    func invalidate() {
        overviewWork?.cancel()
        overviewWork = nil
        overviewQueue = []
        detailWork?.cancel()
        detailWork = nil
        detailInFlight = nil
        processedWork?.cancel()
        processedWork = nil
        processedQueue = []
        processedChain = nil
        failures = [:]
        // Guarded: these are the published properties, and this is reached from
        // callbacks that fire on every resize.
        if !overviews.isEmpty { overviews = [:] }
        if detail != nil { detail = nil }
        if !processed.isEmpty { processed = [:] }
    }

    /// Forgets one source, so re-importing a file that changed on disk redraws.
    func invalidate(sourceID: UUID) {
        overviews[sourceID] = nil
        failures[sourceID] = nil
        if detail?.sourceID == sourceID { detail = nil }
        // The whole processed map, not the entries for this source: the map is
        // keyed by clip and nothing here knows which clips point at it, and a
        // compare strip left drawing a file that changed under it is precisely
        // the "convincingly drawn wrong audio" failure the seeding note on
        // `setForSnapshot` records. Re-rendering a few strips is cheap; being
        // quietly wrong is not.
        if !processed.isEmpty { processed = [:] }
        processedChain = nil
    }

    // MARK: - Private

    private func needsDetail(_ need: Need, channels: Int) -> Bool {
        guard need.columns > 0 else { return false }
        let want = (need.range.upperBound - need.range.lowerBound) / Double(need.columns)
        guard want > 0 else { return false }
        guard let (data, covering) = buckets(for: need.sourceID, covering: need.range, columns: need.columns) else {
            return true
        }
        let lanes = max(EditorWaveformSampler.laneCount(bucketCount: data.buckets.count, channels: channels), 1)
        let perLane = Double(data.buckets.count / lanes)
        let coveringSpan = covering.upperBound - covering.lowerBound
        guard perLane > 0, coveringSpan > 0 else { return true }
        let have = coveringSpan / perLane
        return abs(log(have / want)) > Self.densityTolerance
    }

    private func requestDetail(_ need: Need, document: EditorDocument, engine: RenderEngine) {
        guard let source = document.source(need.sourceID) else { return }

        // Half a window of margin either side, so a small scroll is free.
        let span = need.range.upperBound - need.range.lowerBound
        let margin = span * 0.25
        let lower = max(0, need.range.lowerBound - margin)
        let upper = min(max(source.duration, span), need.range.upperBound + margin)
        guard upper > lower else { return }
        let padded = lower...upper
        let requested = min(4096, Int((Double(need.columns) * (upper - lower) / span).rounded()))
        guard requested > 0 else { return }

        if let detailInFlight,
           detailInFlight.sourceID == need.sourceID,
           detailInFlight.range == padded,
           detailInFlight.requested == requested { return }
        detailInFlight = (need.sourceID, padded, requested)

        // The synthetic document is one source with an empty stack, so source
        // time and output time are the same thing and `range` means what it
        // says. It is not a second render path: it is the same `RenderEngine`
        // asked about one file with nothing applied to it.
        let isolated = EditorDocument(source: source)
        let sourceID = need.sourceID

        detailWork?.cancel()
        detailWork = Task { [weak self] in
            // One display frame of quiet. A pinch that is still moving replaces
            // this task before the engine is ever reached.
            try? await Task.sleep(for: .milliseconds(45))
            guard !Task.isCancelled else { return }
            do {
                let data = try await engine.waveform(isolated, range: padded, bucketCount: requested)
                guard !Task.isCancelled, let self else { return }
                self.detail = Detail(sourceID: sourceID, range: padded, requested: requested, data: data)
                self.failures[sourceID] = 0
                self.detailInFlight = nil
            } catch {
                guard !Task.isCancelled, let self else { return }
                self.failures[sourceID, default: 0] += 1
                self.detailInFlight = nil
            }
        }
    }

    /// Fetches queued overviews one at a time.
    ///
    /// **Still serial, for a different reason than it was.** The original one
    /// was cache eviction — the engine held exactly one decoded file, so two
    /// requests in flight for different sources would thrash it. That is no
    /// longer true: the pool now keeps one entry per source URL, so a split
    /// costs no extra decode and concurrent requests would not evict each
    /// other. What still binds is memory: two hours of Float32 stereo is about
    /// 1.4 GB, and the peak while N sources decode at once is N of those. Serial
    /// holds the transient to one decode regardless of how many files the
    /// project has, and the queue is drained in draw order anyway, so the lane
    /// the user is looking at fills first.
    private func drainOverviews(document: EditorDocument, engine: RenderEngine) {
        guard overviewWork == nil, !overviewQueue.isEmpty else { return }
        let buckets = Self.overviewBuckets

        overviewWork = Task { [weak self] in
            while true {
                guard let self, !Task.isCancelled else { return }
                guard !self.overviewQueue.isEmpty else { break }
                let sourceID = self.overviewQueue.removeFirst()
                guard self.overviews[sourceID] == nil,
                      let source = document.source(sourceID) else { continue }
                do {
                    let data = try await engine.waveform(
                        EditorDocument(source: source),
                        range: nil,
                        bucketCount: buckets
                    )
                    guard !Task.isCancelled else { return }
                    self.overviews[sourceID] = Overview(
                        data: data,
                        covering: 0...max(data.duration, 0.001)
                    )
                    self.failures[sourceID] = 0
                } catch {
                    guard !Task.isCancelled else { return }
                    self.failures[sourceID, default: 0] += 1
                }
            }
            self?.overviewWork = nil
        }
    }

    /// Renders queued compare pictures one at a time.
    ///
    /// The chain is captured and re-checked on the far side of the `await`. A
    /// user who edits a move while a strip is rendering must not get the old
    /// answer written into the new map — it would look exactly like a working
    /// comparison and be a comparison against the previous edit.
    private func drainProcessed(engine: RenderEngine, chain: String) {
        guard processedWork == nil, !processedQueue.isEmpty else { return }

        processedWork = Task { [weak self] in
            while true {
                guard let self, !Task.isCancelled else { return }
                guard self.processedChain == chain else { break }
                guard !self.processedQueue.isEmpty else { break }
                let need = self.processedQueue.removeFirst()
                guard self.processed[need.clipID] == nil else { continue }
                do {
                    let data = try await engine.waveform(
                        EditorChain.isolated(need.source, through: need.moves),
                        range: nil,
                        bucketCount: Self.overviewBuckets
                    )
                    guard !Task.isCancelled, self.processedChain == chain else { return }
                    self.processed[need.clipID] = Processed(
                        data: data,
                        covering: 0...max(data.duration, 0.001)
                    )
                    self.failures[need.source.id] = 0
                } catch {
                    guard !Task.isCancelled else { return }
                    self.failures[need.source.id, default: 0] += 1
                }
            }
            self?.processedWork = nil
        }
    }

    /// Whether `have` contains `want`, with a hair of slack for the floating
    /// point that got both of them here.
    private static func covers(_ have: ClosedRange<TimeInterval>, _ want: ClosedRange<TimeInterval>) -> Bool {
        have.lowerBound <= want.lowerBound + 0.0001 && have.upperBound >= want.upperBound - 0.0001
    }

    #if MELO_DEV
    /// Hands the harness's fixtures straight in, and stops this object asking
    /// `RenderEngine` for anything at all.
    ///
    /// A multitrack scene has to seed one waveform per source or every lane
    /// draws the same picture, and two lanes that are identical when their
    /// sources are not is precisely the defect a multitrack frame exists to
    /// catch. Without a seed the view falls back to the store's overview, which
    /// is what every single-clip scene written before clips existed renders
    /// with — so those keep working untouched.
    func setForSnapshot(_ seeded: [UUID: WaveformData]) {
        invalidate()
        isSeeded = true
        overviews = seeded.mapValues { Overview(data: $0, covering: 0...max($0.duration, 0.001)) }
    }

    /// Hands the harness a compare-lane fixture, since it cannot render one.
    ///
    /// **The processed side of a compare frame cannot be real here and the
    /// scene has to say so.** There is no file behind a snapshot source, so
    /// `RenderEngine` throws on every call and the only picture the strip could
    /// ever hold is a seeded one. What that costs is stated where it is spent,
    /// in the scene's note: the frames prove the *lane* — that it appears, that
    /// it takes its space from the clip and not from the header alignment, that
    /// the two inks invert under bypass, that two different pictures are drawn
    /// over one span — and they prove nothing about whether the real chain
    /// changes the real waveform. That claim is
    /// `scripts/verify-compare-bypass.py`'s, which renders both sides through
    /// the shipping engine and compares samples.
    ///
    /// `chain` is whatever stamp the scene will hand the view; the two only
    /// have to match each other, because a seeded map is never re-rendered.
    func setProcessedForSnapshot(_ seeded: [Clip.ID: WaveformData], chain: String) {
        isSeeded = true
        processedChain = chain
        processed = seeded.mapValues {
            Processed(data: $0, covering: 0...max($0.duration, 0.001))
        }
    }

    /// This object outlives every scene, which is the sticky global-state trap
    /// `MeloEasterEggClock` is documented for at `MeloVisualTheme.swift:476`.
    /// Call it from the shared `prepare` wrapper in `SnapshotScenes.swift`, next
    /// to `EditorTimeline.shared.resetForSnapshot()`.
    func resetForSnapshot() {
        invalidate()
        isSeeded = false
    }
    #endif
}
