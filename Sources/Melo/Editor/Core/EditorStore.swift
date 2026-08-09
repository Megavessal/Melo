// Melo/Editor/Core/EditorStore.swift
//
// Melo Edit's one piece of state. Reached as `EditorStore.shared`,
// matching how the rest of Melo reaches its coordinators.
//
// Undo here is an array of `EditorDocument`s and an index into it. That is the
// entire mechanism, and it is why `EditorDocument` is a value type. There is no
// command pattern, no inverse-operation table, and nothing to keep in sync.

import Foundation
import SwiftUI
import os

@MainActor
final class EditorStore: ObservableObject {

    static let shared = EditorStore()

    // MARK: - Published state

    @Published private(set) var document: EditorDocument?
    @Published private(set) var waveform: WaveformData?
    @Published private(set) var jobs: [EditorJob] = []
    @Published var selection: ClosedRange<TimeInterval>?
    @Published var playhead: TimeInterval = 0
    /// Which move the stack has selected. The same class of state as
    /// `selection` and `playhead` above: ephemeral, absent from
    /// `EditorDocument`, not undone, describing the pane rather than the sound.
    /// It lives here rather than in the stack view because the window's ⌘⌫
    /// handler and the stack are different pieces that have to agree on it, and
    /// two objects that must agree is the defect class this project's anchor
    /// already records.
    @Published var selectedMoveID: Move.ID?

    /// Which clips the timeline has selected. The same class of state as
    /// `selectedMoveID`: ephemeral, absent from `EditorDocument`, not undone.
    /// Pruned by `mutate` whenever a clip stops existing, so no surface has to
    /// remember to do it and no two surfaces can disagree.
    @Published var selectedClipIDs: Set<Clip.ID> = []

    /// Which track the headers have selected. Where a paste with no explicit
    /// track lands, and what "add a move to this track" means.
    @Published var selectedTrackID: Track.ID?

    /// The last thing that went wrong, as one sentence for the user. Cleared
    /// when the next operation starts.
    @Published private(set) var lastError: String?

    /// The source most recently brought into the editor, whether by opening a
    /// file into an empty window or by laying one in as a new lane.
    ///
    /// **The window watches this to record a recent.** It used to watch
    /// `document.source.id`, which is the *first* source and does not change
    /// when a lane is added — so once opening started adding tracks, a file
    /// that arrived as a lane never reached the recents list, and a recording
    /// layered onto an open document is precisely the entry that exists nowhere
    /// else.
    ///
    /// A published signal rather than the store calling `EditorRecents`
    /// directly: `EditorRecents` is in the window layer and this is Core.
    /// `scripts/verify-editor-wiring.py` compiles Core without the UI, so the
    /// reverse dependency does not merely offend a diagram — it breaks the
    /// check that proves the store's expensive machinery is reached at all.
    @Published private(set) var lastAddedSource: EditorSource?

    /// The single render actor for the whole editor. Exposed rather than
    /// private so export and analysis use the same instance, and therefore the
    /// same decoded source, instead of decoding the file a second time.
    let renderEngine = RenderEngine()

    // MARK: - Tuning

    /// Twelve documents deep, and consecutive edits to the same move inside one
    /// second collapse into a single entry — the same cap and the same window
    /// as `ConsumerUndoManager` (`Coordination/ConsumerUndoManager.swift:12-13`),
    /// so Melo's two Undos behave identically even though they are deliberately
    /// separate stacks. They have to be separate: `ConsumerUndoManager` stores a
    /// `ConsumerScene` and structurally cannot hold an `EditorDocument`, and the
    /// popup's Undo button must not reach into a document the user is editing in
    /// another window.
    ///
    /// The coalescing is what makes twelve enough. Without it a single slider
    /// drag in the inspector fills the stack, because every tick calls
    /// `update(_:)` and every call is a new document.
    static let undoDepth = 12
    private static let coalescingWindow: TimeInterval = 1.0

    /// How long the document has to stay still before the waveform is re-rendered
    /// and the session sidecar is written. Long enough that a drag does not
    /// re-render per tick, short enough that letting go feels immediate.
    private static let quiescence: Duration = .milliseconds(180)

    /// Buckets in the stored waveform. Wide enough for a full-width waveform on
    /// a Retina display; the view scales this down, it does not ask for more.
    private static let waveformBuckets = 2_048

    // MARK: - Private state

    private var history: [EditorDocument] = []
    private var historyIndex = -1
    private var coalesceKey: UUID?
    private var coalesceDeadline: Date = .distantPast

    private var quiescentWork: Task<Void, Never>?
    private var waveformWork: Task<Void, Never>?

    /// Copied clips, with the track each came from expressed as an offset from
    /// the topmost track in the copy. Held here rather than on
    /// `NSPasteboard`: these are references into *this* document's source pool,
    /// and a clip pasted into another document would point at a source that
    /// does not exist there. Cross-document paste is not a thing this feature
    /// claims to do, and a pasteboard would imply it does.
    private var clipboard: [(clip: Clip, trackOffset: Int)] = []

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Melo",
        category: "EditorStore"
    )

    private init() {}

    // MARK: - Opening

    func open(_ url: URL) async {
        await openSource(at: url, origin: .file(originalURL: url), displayName: nil)
    }

    /// The bundled theme, opened for editing. The first thing there is to play
    /// with, and the one source that is always present.
    ///
    /// It opens the staged copy, never `Bundle.main`'s URL. The bundle is
    /// signed and must not be written into — and the sidecar is keyed on the
    /// source path, so a bundle path would put every saved remix behind a
    /// location that changes on the next install. The stack would vanish on
    /// update, which is the exact loss the sidecar exists to prevent.
    func openMeloTheme() async {
        do {
            let url = try MeloThemeRemix.preparedSourceURL()
            await openSource(at: url, origin: .meloTheme, displayName: "Melo Theme")
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Everything that arrives as a file: a chosen file, a link extraction's
    /// working copy, a finished recording, the bundled theme.
    ///
    /// **With a document already open this adds a track instead of replacing
    /// it.** Audio reaches the editor four ways — the file panel, drag and
    /// drop, link import and recording — through two entry points, and the rule
    /// lives here rather than at those call sites so the link sheet and the
    /// recorder need no code of their own and cannot drift apart.
    ///
    /// It reverses what "open" usually means, deliberately. The owner asked for
    /// "multiple audio tracks if wanted, layering audio", and layering is the
    /// feature; there is already a deliberate way to start fresh in "Close This
    /// Sound", which is what `close()` was given a caller for. Replacing
    /// silently would leave `addClip` and the second lane reachable only by a
    /// route nobody would guess — which is what shipped: `addTrack()` made a
    /// lane that could never receive audio.
    ///
    /// **The theme is the exception and still replaces.** It is not audio the
    /// user brought in; it arrives from "Remix the Melo theme", whose whole
    /// point is to edit the theme itself, and layering it under someone's
    /// podcast is not a thing anybody pressed that button for.
    ///
    /// **For `.extractedFromLink` and `.systemRecording`, this takes ownership
    /// of the file.** Those two land in the temporary directory, so the store
    /// moves them somewhere durable before anything reads the path — see
    /// `EditorSourceStore`. Hand the URL over and stop using it; the store's
    /// `document.source.url` is where the audio lives afterwards. Nothing is
    /// moved for `.file` or `.meloTheme`, which already have durable homes.
    func openSource(at url: URL, origin: EditorSource.Origin, displayName: String?) async {
        if document != nil, origin != .meloTheme {
            _ = await addSourceAsTrack(at: url, origin: origin, displayName: displayName)
            return
        }
        await replaceDocument(at: url, origin: origin, displayName: displayName)
    }

    /// Throws away whatever is open and puts this file in its place. Reached
    /// through `openSource` when nothing is open, and by the theme.
    private func replaceDocument(at url: URL,
                                 origin: EditorSource.Origin,
                                 displayName: String?) async {
        // Whatever is being replaced gets its sidecar now rather than 180 ms
        // from now. The debounced write is scheduled against the *store*, not
        // against a document, so an edit made just before this call would
        // otherwise land under the incoming file's key — the outgoing
        // document's last edit lost, silently, which is the failure this
        // feature spends the most effort avoiding.
        writeSession()
        lastError = nil
        let job = makeJob(stage: "Opening \(displayName ?? url.deletingPathExtension().lastPathComponent)")

        do {
            // Adoption happens first, and off the main actor with the probe,
            // because everything downstream keys on the path: the probe, the
            // session sidecar, and whatever the window lists as recent. A file
            // Melo made in the temporary directory gets a durable home here or
            // it does not get one at all.
            let (resolved, probed) = try await Task.detached(priority: .userInitiated) {
                let durable = EditorSourceStore.durableURL(
                    for: url,
                    origin: origin,
                    displayName: displayName
                )
                return (durable, try AudioFileIO.probe(durable))
            }.value

            var source = probed
            source.origin = origin
            if let displayName { source.displayName = displayName }

            guard source.duration <= AudioFileIO.maximumDuration else {
                throw AudioFileIO.Failure.tooLong(source.duration)
            }

            // One track, one clip covering the whole source. The window looks
            // exactly as it did before there were tracks; the second lane only
            // exists once the user asks for one.
            var opened = EditorDocument(source: source)
            if let session = EditorSession.load(for: resolved) {
                // Handles both shapes. A 3.1.x sidecar has no timeline in it,
                // and this leaves the one-track document above exactly as it
                // is with the saved moves on the master — which is what those
                // moves always meant.
                session.restore(into: &opened)
                logger.info(
                    """
                    Restored a session: \(session.moves.count) master moves, \
                    \(opened.tracks.count) track(s)
                    """
                )
            }

            // Drop the previous document's decoded samples before the next
            // decode rather than after it. Two hours of Float32 stereo is about
            // 1.4 GB, and holding the outgoing one while the incoming one is
            // read is 2.8 GB at the peak for no reason — the old document is
            // already gone from the screen by the time this line runs.
            //
            // **Every source, not the first one.** `RenderEngine.pool` holds one
            // decode per source URL in the document, and `forgetCachedSource()`
            // is the only thing that empties it. This used to compare
            // `document?.source.url`, which is the *first* source: open a file
            // whose URL matched the outgoing document's first source and the
            // whole rest of the pool — every other lane's decode — stayed
            // resident into a document that no longer refers to it, with nothing
            // left that would ever free it.
            //
            // The question is when to forget *everything*, not how to prune
            // cleverly. A prune down to the document's own sources was written
            // and is wrong: the waveform asks this same engine about one source
            // at a time through a synthetic single-source document, so a
            // document-keyed prune throws away every other decode the mix needs
            // each time a lane is zoomed. Measured by the render engine's
            // author — 0.012 s to re-render three sources without it, 0.094 s
            // with it — and the `prune-to-document` mutation is kept in the
            // suite to stop anyone re-adding it.
            //
            // So the pool is kept only when the outgoing document referred to
            // exactly the one file being opened, which is the reopen case the
            // cache is for. The pool is URL-keyed on purpose, so two sources
            // naming one file are one entry and a set is the right comparison.
            let outgoing = Set((document?.sources ?? []).map(\.url))
            if outgoing != [resolved] {
                await renderEngine.forgetCachedSource()
            }

            document = opened
            resetHistory(with: opened)
            selection = nil
            playhead = 0
            waveform = nil
            selectedClipIDs = []
            selectedMoveID = nil
            selectedTrackID = opened.tracks.first?.id
            clipboard = []
            lastAddedSource = source
            job.finish()
            retire(job)

            await refreshWaveform()
            // Measure after the waveform, never before: the waveform is what
            // the user is waiting to see, and it leaves the decoded source in
            // `RenderEngine`'s cache so the measurement costs the arithmetic
            // and not the decode.
            await measure()
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            job.fail(message)
            retire(job)
            lastError = message
            // Private: the sentence carries the file's name.
            logger.error("Open failed: \(message, privacy: .private)")
        }
    }

    /// **The window controller must call this when Melo Edit closes.**
    /// Nothing else frees `RenderEngine`'s decoded source, and the store is a
    /// singleton with no deinit to fall back on — a two-hour file left resident
    /// is about 1.4 GB held for the rest of the session.
    func close() {
        quiescentWork?.cancel()
        waveformWork?.cancel()
        // A measurement in flight needs no cancelling: it is awaited inside
        // `openSource`, and its source-identity guard drops the result rather
        // than writing it to a document that is no longer open. Dropping the
        // decoded source underneath it is safe too — `analyse` already holds
        // the block it was handed.
        writeSession()
        let engine = renderEngine
        Task { await engine.forgetCachedSource() }
        document = nil
        waveform = nil
        selection = nil
        playhead = 0
        selectedClipIDs = []
        selectedTrackID = nil
        selectedMoveID = nil
        // The clipboard holds source ids belonging to the document that just
        // closed. Keeping it would offer a paste that points at nothing.
        clipboard = []
        // So that reopening the same file after a close is a change the window
        // sees, rather than a value that never moved.
        lastAddedSource = nil
        history = []
        historyIndex = -1
    }

    // MARK: - Measurement

    /// Measures the source and puts the report on the document.
    ///
    /// **This is the call the whole novice path waits on.** "Fix it for me" is
    /// disabled until `document.analysis` is non-nil, "What I found" says
    /// "Still listening.", Normalize and Fix DC offset stay unavailable, and
    /// the export card's before/after has nothing to compare. Every frame any
    /// of us looked at showing a measurement came from `#if MELO_DEV` seeding;
    /// in a shipping build `analysis` was nil for the life of every document,
    /// because `setAnalysis` had no caller. `MoveProposer` had 45 executed
    /// assertions behind it and nothing observing the call — `CLAUDE.md:138`,
    /// again.
    ///
    /// Analysis describes the *source*, which no move changes, so it runs once
    /// per file and a restored sidecar satisfies it.
    func measure() async {
        guard let document, document.analysis == nil else { return }
        let sourceID = document.source.id

        // Not cancellable on purpose. The DSP measures ten minutes of stereo in
        // under a second, and a measurement the user can abort leaves the one
        // button the least-knowledgeable user ever presses disabled with no way
        // back to it.
        let job = makeJob(stage: "Measuring loudness", fraction: 0)
        let engine = renderEngine
        let sink = job.fractionSink()

        do {
            let report = try await engine.analyse(document, progress: sink)
            // The file may have been closed or replaced while this ran.
            guard self.document?.source.id == sourceID else {
                retire(job)
                return
            }
            setAnalysis(report)
            job.finish()
            retire(job)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            job.fail(message)
            retire(job)
            logger.error("Measurement failed: \(message, privacy: .private)")
        }
    }

    // MARK: - The stack

    func apply(_ move: Move) {
        mutate { $0.moves.append(move) }
    }

    func update(_ move: Move) {
        mutate(coalescingOn: move.id) { document in
            guard let index = document.moves.firstIndex(where: { $0.id == move.id }) else { return }
            document.moves[index] = move
        }
    }

    func remove(_ moveID: Move.ID) {
        mutate { $0.moves.removeAll { $0.id == moveID } }
    }

    /// `move(fromOffsets:toOffset:)` is SwiftUI's, not Foundation's — which is
    /// why this file imports SwiftUI. Worth the import rather than
    /// reimplementing: the offsets refer to pre-removal indices and so does
    /// `toOffset`, and hand-rolling that off-by-one is a silent reordering bug
    /// in a list the user is dragging.
    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        mutate { $0.moves.move(fromOffsets: source, toOffset: destination) }
    }

    func setEnabled(_ enabled: Bool, for moveID: Move.ID) {
        mutate { document in
            guard let index = document.moves.firstIndex(where: { $0.id == moveID }) else { return }
            document.moves[index].isEnabled = enabled
        }
    }

    /// Replaces the whole stack in one edit, so a destination's proposal is one
    /// undo step rather than one per move.
    func replaceMoves(_ moves: [Move]) {
        mutate { $0.moves = moves }
    }

    /// Empties every move stack — master, per-track and per-clip.
    ///
    /// The measured analysis and the chosen destination survive: both describe
    /// the *source*, which has not changed, and re-measuring a long file to get
    /// back what we already know is the kind of thing that makes an editor feel
    /// slow.
    ///
    /// **The timeline is left alone.** The shipped Guide's words for this
    /// control are "empties the stack and leaves the file exactly as it
    /// arrived", written when the stack was the only thing there was; clips,
    /// trims and fades are not stack entries and the button is not offered for
    /// a document that has only those. Clearing *only* the master while a track
    /// stack survived would be the worse reading — a control doing less than
    /// its label says is this project's recorded worst pattern.
    func revertToOriginal() {
        mutate { document in
            document.master.removeAll()
            for trackIndex in document.tracks.indices {
                document.tracks[trackIndex].moves.removeAll()
                for clipIndex in document.tracks[trackIndex].clips.indices {
                    document.tracks[trackIndex].clips[clipIndex].moves.removeAll()
                }
            }
        }
    }

    // MARK: - Tracks

    /// Adds an empty track below the others and selects it.
    ///
    /// The moment this is called for the first time the editor is a multitrack
    /// editor — nothing switches mode, a second lane simply appears under the
    /// one the user already understands.
    @discardableResult
    func addTrack() -> Track.ID {
        let track = Track(name: Track.defaultName(at: document?.tracks.count ?? 0))
        mutate { $0.tracks.append(track) }
        // Only if it actually landed. With no document open `mutate` does
        // nothing, and a selection naming a track that does not exist is the
        // state `pruneSelection` exists to prevent.
        if document?.tracks.contains(where: { $0.id == track.id }) == true {
            selectedTrackID = track.id
        }
        return track.id
    }

    /// Removes a track and everything on it.
    ///
    /// **Refuses to remove the last one.** A document with no tracks has no
    /// timeline to draw and no way back except undo, and "close the file" is
    /// the action that means that. Sources are left in the pool: undo has to be
    /// able to bring the clips back, and re-decoding is what the pool exists to
    /// avoid.
    func removeTrack(_ id: Track.ID) {
        guard (document?.tracks.count ?? 0) > 1 else { return }
        mutate { $0.tracks.removeAll { $0.id == id } }
    }

    /// Renames a track. An empty or whitespace-only name puts the default back
    /// rather than storing a blank header.
    func renameTrack(_ id: Track.ID, to name: String) {
        mutate { document in
            guard let index = document.tracks.firstIndex(where: { $0.id == id }) else { return }
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            document.tracks[index].name = trimmed.isEmpty ? Track.defaultName(at: index) : trimmed
        }
    }

    /// Coalesced on the track: a fader drag is one undo step, the same way an
    /// inspector slider drag already is.
    func setTrackGain(_ id: Track.ID, dB: Double) {
        mutate(coalescingOn: id) { document in
            guard let index = document.tracks.firstIndex(where: { $0.id == id }) else { return }
            document.tracks[index].gainDB = dB.clamped(to: Track.gainRange)
        }
    }

    func setTrackPan(_ id: Track.ID, _ pan: Double) {
        mutate(coalescingOn: id) { document in
            guard let index = document.tracks.firstIndex(where: { $0.id == id }) else { return }
            document.tracks[index].pan = pan.clamped(to: -1...1)
        }
    }

    func toggleMute(_ id: Track.ID) {
        mutate { document in
            guard let index = document.tracks.firstIndex(where: { $0.id == id }) else { return }
            document.tracks[index].isMuted.toggle()
        }
    }

    func toggleSolo(_ id: Track.ID) {
        mutate { document in
            guard let index = document.tracks.firstIndex(where: { $0.id == id }) else { return }
            document.tracks[index].isSoloed.toggle()
        }
    }

    /// Reorders the lanes. Drawing order only — it changes nothing about the
    /// sum, which is why it is still an undoable edit and not a view preference:
    /// the user will expect ⌘Z to put the lane back.
    func moveTracks(fromOffsets source: IndexSet, toOffset destination: Int) {
        mutate { $0.tracks.move(fromOffsets: source, toOffset: destination) }
    }

    /// Replaces one track's move stack in a single edit.
    func setTrackMoves(_ id: Track.ID, _ moves: [Move]) {
        mutate { document in
            guard let index = document.tracks.firstIndex(where: { $0.id == id }) else { return }
            document.tracks[index].moves = moves
        }
    }

    // MARK: - Clips

    @discardableResult
    func addClip(sourceID: EditorSource.ID, to track: Track.ID, at start: TimeInterval) -> Clip.ID {
        let clip = Clip(
            sourceID: sourceID,
            start: max(0, start),
            sourceIn: 0,
            sourceOut: document?.source(sourceID)?.duration ?? 0
        )
        mutate { document in
            guard let index = document.tracks.firstIndex(where: { $0.id == track }) else { return }
            document.tracks[index].clips.append(clip)
            Self.sortClips(&document.tracks[index])
        }
        return clip.id
    }

    /// Where one clip is going: a lane and a time.
    struct ClipMove: Equatable, Sendable {
        var id: Clip.ID
        var trackID: Track.ID
        var start: TimeInterval

        init(id: Clip.ID, trackID: Track.ID, start: TimeInterval) {
            self.id = id
            self.trackID = trackID
            self.start = start
        }
    }

    /// Moves a clip along the timeline and, if `toTrack` differs, onto another
    /// lane. Coalesced on the clip, so a drag is one undo step.
    func moveClip(_ id: Clip.ID, toTrack: Track.ID, start: TimeInterval) {
        moveClips([ClipMove(id: id, trackID: toTrack, start: start)])
    }

    /// **One gesture, one undo step.** Moves any number of clips through a
    /// single `mutate`, so dragging three clips takes one ⌘Z to put back rather
    /// than three.
    ///
    /// The same rule as a slider drag collapsing into one entry and a
    /// destination's proposal landing through `replaceMoves`: the unit of undo
    /// is what the user did, not how many objects it touched.
    ///
    /// Coalesced on the lowest id in the moved set, which is stable for a given
    /// selection and independent of the order they arrive in, so repeated calls
    /// during a live drag collapse together and a drag of a *different*
    /// selection does not join them.
    func moveClips(_ moves: [ClipMove]) {
        guard !moves.isEmpty else { return }
        let key = moves.map(\.id).min { $0.uuidString < $1.uuidString }

        mutate(coalescingOn: key) { document in
            let lanes = Set(document.tracks.map(\.id))
            var lifted: [(clip: Clip, target: Track.ID)] = []

            // Lift every clip out before putting any back. Two clips swapping
            // lanes would otherwise have the first one's insertion shift the
            // index the second was located at. A move naming a lane that does
            // not exist is skipped **before** the clip is lifted — a target
            // that cannot be resolved must leave the clip where it is, never
            // drop it on the floor.
            for move in moves where lanes.contains(move.trackID) {
                guard let (trackIndex, clipIndex) = Self.locate(move.id, in: document) else { continue }
                var clip = document.tracks[trackIndex].clips.remove(at: clipIndex)
                clip.start = max(0, move.start)
                lifted.append((clip, move.trackID))
            }

            for entry in lifted {
                guard let index = document.tracks.firstIndex(where: { $0.id == entry.target }) else { continue }
                document.tracks[index].clips.append(entry.clip)
            }
            for index in document.tracks.indices { Self.sortClips(&document.tracks[index]) }
        }
    }

    /// Moves the window into the source. `nil` leaves that edge alone.
    ///
    /// **Dragging the leading edge moves `start` with it**, by the same amount,
    /// so the audio under the pointer stays where it is on the timeline — which
    /// is what an edge drag means everywhere else and what makes the trim look
    /// reversible. Dragging it back out restores audio that was never discarded:
    /// nothing is cut here, the two numbers move.
    ///
    /// Both edges are clamped into the source and kept at least
    /// `Clip.minimumDuration` apart.
    func trimClip(_ id: Clip.ID, sourceIn: TimeInterval?, sourceOut: TimeInterval?) {
        mutate(coalescingOn: id) { document in
            guard let (trackIndex, clipIndex) = Self.locate(id, in: document) else { return }
            var clip = document.tracks[trackIndex].clips[clipIndex]
            let sourceDuration = document.source(clip.sourceID)?.duration ?? clip.sourceOut

            if let sourceIn {
                let upper = max(0, clip.sourceOut - Clip.minimumDuration)
                let resolved = sourceIn.clamped(to: 0...max(0, upper))
                clip.start = max(0, clip.start + (resolved - clip.sourceIn))
                clip.sourceIn = resolved
            }
            if let sourceOut {
                let lower = min(clip.sourceIn + Clip.minimumDuration, sourceDuration)
                clip.sourceOut = sourceOut.clamped(to: lower...max(lower, sourceDuration))
            }
            // A fade cannot be longer than what is left of the clip.
            clip.fadeIn = min(clip.fadeIn, clip.duration)
            clip.fadeOut = min(clip.fadeOut, clip.duration - min(clip.fadeIn, clip.duration))

            document.tracks[trackIndex].clips[clipIndex] = clip
            Self.sortClips(&document.tracks[trackIndex])
        }
    }

    /// Cuts a clip in two at a point on the timeline. Both halves share the one
    /// decoded source; nothing is copied and nothing is re-decoded.
    ///
    /// Returns the id of the right-hand half, or `nil` when the point is not
    /// strictly inside the clip — splitting at an edge would make a
    /// zero-length clip, which is a clip the user cannot see or grab.
    @discardableResult
    func splitClip(_ id: Clip.ID, at time: TimeInterval) -> Clip.ID? {
        guard let document, let clip = document.clip(id) else { return nil }
        let offset = time - clip.start
        guard offset > Clip.minimumDuration,
              offset < clip.duration - Clip.minimumDuration else { return nil }

        var right = clip
        right.id = UUID()
        right.start = clip.start + offset
        right.sourceIn = clip.sourceIn + offset
        right.fadeIn = 0
        right.fadeOut = min(clip.fadeOut, right.duration)

        mutate { document in
            guard let (trackIndex, clipIndex) = Self.locate(id, in: document) else { return }
            document.tracks[trackIndex].clips[clipIndex].sourceOut = clip.sourceIn + offset
            document.tracks[trackIndex].clips[clipIndex].fadeOut = 0
            document.tracks[trackIndex].clips[clipIndex].fadeIn =
                min(clip.fadeIn, offset)
            document.tracks[trackIndex].clips.insert(right, at: clipIndex + 1)
        }
        return right.id
    }

    /// Takes a clip off the timeline. **The source stays in the pool** — undo
    /// has to be able to put the clip back without decoding the file again.
    func removeClip(_ id: Clip.ID) {
        mutate { document in
            guard let (trackIndex, _) = Self.locate(id, in: document) else { return }
            document.tracks[trackIndex].clips.removeAll { $0.id == id }
        }
    }

    func removeSelectedClips() {
        let ids = selectedClipIDs
        guard !ids.isEmpty else { return }
        mutate { document in
            for index in document.tracks.indices {
                document.tracks[index].clips.removeAll { ids.contains($0.id) }
            }
        }
    }

    func setClipGain(_ id: Clip.ID, dB: Double) {
        mutate(coalescingOn: id) { document in
            guard let (trackIndex, clipIndex) = Self.locate(id, in: document) else { return }
            document.tracks[trackIndex].clips[clipIndex].gainDB = dB.clamped(to: -60...12)
        }
    }

    /// The clip's own fade handles. `nil` leaves that one alone. Neither fade
    /// can run past the clip, and the two together cannot overlap.
    func setClipFades(_ id: Clip.ID,
                      fadeIn: TimeInterval?,
                      fadeOut: TimeInterval?,
                      curve: FadeCurve?) {
        mutate(coalescingOn: id) { document in
            guard let (trackIndex, clipIndex) = Self.locate(id, in: document) else { return }
            var clip = document.tracks[trackIndex].clips[clipIndex]
            if let fadeIn {
                clip.fadeIn = fadeIn.clamped(to: 0...max(0, clip.duration - clip.fadeOut))
            }
            if let fadeOut {
                clip.fadeOut = fadeOut.clamped(to: 0...max(0, clip.duration - clip.fadeIn))
            }
            if let curve { clip.fadeCurve = curve }
            document.tracks[trackIndex].clips[clipIndex] = clip
        }
    }

    /// Replaces one clip's move stack in a single edit.
    func setClipMoves(_ id: Clip.ID, _ moves: [Move]) {
        mutate { document in
            guard let (trackIndex, clipIndex) = Self.locate(id, in: document) else { return }
            document.tracks[trackIndex].clips[clipIndex].moves = moves
        }
    }

    // MARK: - Copy and paste

    /// Copies clips, not samples. What lands on the clipboard is the window —
    /// ids, times and fades — and the paste points at the same decoded source.
    func copyClips(_ ids: [Clip.ID]) {
        guard let document else { return }
        var copied: [(clip: Clip, trackOffset: Int)] = []
        for (trackIndex, track) in document.tracks.enumerated() {
            for clip in track.clips where ids.contains(clip.id) {
                copied.append((clip, trackIndex))
            }
        }
        guard let topmost = copied.map(\.trackOffset).min() else { return }
        clipboard = copied
            .map { ($0.clip, $0.trackOffset - topmost) }
            .sorted { $0.clip.start < $1.clip.start }
    }

    var canPasteClips: Bool { !clipboard.isEmpty }

    /// Pastes at `time`, keeping the copied clips' spacing and their lane
    /// offsets. `track` is where the topmost copied clip lands; `nil` uses the
    /// selected track, then the first one. Offsets past the last existing track
    /// are clamped onto it — paste does not silently add lanes.
    ///
    /// New ids throughout, so pasting twice gives two clips and not one clip
    /// that two selections disagree about. The pasted clips become the
    /// selection, which is what makes a paste followed by a drag work.
    func pasteClips(at time: TimeInterval, track: Track.ID?) {
        guard let document, !clipboard.isEmpty, !document.tracks.isEmpty else { return }
        let anchorID = track ?? selectedTrackID ?? document.tracks[0].id
        let anchorIndex = document.tracks.firstIndex { $0.id == anchorID } ?? 0
        let earliest = clipboard.map(\.clip.start).min() ?? 0

        var pasted: [Clip.ID] = []
        mutate { document in
            for entry in clipboard {
                let index = min(anchorIndex + entry.trackOffset, document.tracks.count - 1)
                var clip = entry.clip
                clip.id = UUID()
                clip.start = max(0, time + (entry.clip.start - earliest))
                clip.moves = clip.moves.map { move in
                    var copy = move
                    copy.id = UUID()
                    return copy
                }
                document.tracks[index].clips.append(clip)
                pasted.append(clip.id)
            }
            for index in document.tracks.indices { Self.sortClips(&document.tracks[index]) }
        }
        if !pasted.isEmpty { selectedClipIDs = Set(pasted) }
    }

    // MARK: - Growing the document

    /// Brings another file in as a new track rather than replacing what is open.
    ///
    /// What every way of bringing in audio does once there is already a
    /// document — the owner's "layering audio" is this call. `openSource`
    /// routes to it, so no caller has to ask which state the editor is in.
    /// With nothing open it replaces instead, which for an empty editor is the
    /// same thing.
    ///
    /// Takes ownership of `url` on the same terms as `openSource`.
    @discardableResult
    func addSourceAsTrack(at url: URL,
                          origin: EditorSource.Origin,
                          displayName: String?) async -> Track.ID? {
        guard document != nil else {
            // `replaceDocument`, not `openSource` — `openSource` routes back
            // here when a document is open, and the two calling each other is a
            // loop rather than a delegation.
            await replaceDocument(at: url, origin: origin, displayName: displayName)
            return document?.tracks.first?.id
        }
        lastError = nil
        let job = makeJob(stage: "Adding \(displayName ?? url.deletingPathExtension().lastPathComponent)")
        do {
            // Adoption first and off the main actor, on the same terms as
            // `openSource`. `probe` reports the URL it read, so the source that
            // comes back already names the durable location.
            let probed = try await Task.detached(priority: .userInitiated) {
                try AudioFileIO.probe(
                    EditorSourceStore.durableURL(
                        for: url,
                        origin: origin,
                        displayName: displayName
                    )
                )
            }.value

            var source = probed
            source.origin = origin
            if let displayName { source.displayName = displayName }

            guard source.duration <= AudioFileIO.maximumDuration else {
                throw AudioFileIO.Failure.tooLong(source.duration)
            }

            // Named for the file, not "Track 3". The column exists to tell
            // lanes apart and the filename already does that.
            //
            // The clip lands at 0, not at the playhead. Layering means two
            // sounds against each other from the top, and a clip that appears
            // somewhere the user was not looking is worse than one they have to
            // drag.
            let track = Track(
                name: source.displayName,
                clips: [Clip(wholeOf: source)]
            )
            mutate { document in
                document.sources.append(source)
                document.tracks.append(track)
            }
            selectedTrackID = track.id
            lastAddedSource = source
            job.finish()
            retire(job)
            return track.id
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            job.fail(message)
            retire(job)
            lastError = message
            logger.error("Adding a track failed: \(message, privacy: .private)")
            return nil
        }
    }

    // MARK: - Clip and track bookkeeping

    /// Clips in start order, so the timeline can draw a lane without sorting in
    /// a `body`. Overlaps are allowed — two clips at the same instant layer,
    /// they do not fight.
    private static func sortClips(_ track: inout Track) {
        track.clips.sort { $0.start < $1.start }
    }

    private static func locate(_ id: Clip.ID, in document: EditorDocument) -> (Int, Int)? {
        for (trackIndex, track) in document.tracks.enumerated() {
            if let clipIndex = track.clips.firstIndex(where: { $0.id == id }) {
                return (trackIndex, clipIndex)
            }
        }
        return nil
    }

    // MARK: - Destination and analysis

    func setDestination(_ destination: Destination?) {
        mutate(record: false) { $0.destination = destination }
    }

    /// Not an undoable edit — measuring is something Melo did, not something the
    /// user did, and it does not change the sound.
    func setAnalysis(_ report: AnalysisReport?) {
        mutate(record: false, rerender: false) { $0.analysis = report }
    }

    // MARK: - Undo

    func undo() {
        guard historyIndex > 0 else { return }
        historyIndex -= 1
        applyHistory()
    }

    func redo() {
        guard historyIndex >= 0, historyIndex < history.count - 1 else { return }
        historyIndex += 1
        applyHistory()
    }

    private func applyHistory() {
        endCoalescing()
        let restored = history[historyIndex]
        document = restored
        pruneSelection(against: restored)
        clampTimeline()
        scheduleQuiescentWork()
    }

    // MARK: - Jobs

    /// Creates a job, publishes it, and hands it back. Anything long — export,
    /// extraction, recording, analysis — goes through here so one progress view
    /// shows all of it.
    func makeJob(stage: String,
                 detail: String? = nil,
                 fraction: Double? = nil,
                 isCancellable: Bool = false) -> EditorJob {
        let job = EditorJob(
            stage: stage,
            detail: detail,
            fraction: fraction,
            isCancellable: isCancellable
        )
        jobs.append(job)
        return job
    }

    /// Removes a finished job from the list. Call it after `finish()` or
    /// `fail(_:)`; a failure's sentence belongs in `lastError`, not in a row
    /// that stays on screen.
    func retire(_ job: EditorJob) {
        jobs.removeAll { $0 === job }
    }

    func clearError() {
        lastError = nil
    }

    // MARK: - Mutation

    /// Every edit goes through here: apply the change, notice whether anything
    /// actually moved, record it, and start the quiet-period clock.
    private func mutate(record: Bool = true,
                        rerender: Bool = true,
                        coalescingOn key: UUID? = nil,
                        _ body: (inout EditorDocument) -> Void) {
        guard var edited = document else { return }
        let before = edited
        body(&edited)
        guard edited != before else { return }

        document = edited
        pruneSelection(against: edited)
        // Against the edited document, not against the last render. Moving a
        // clip past the old end has to let the playhead follow it there now,
        // not in 180 ms.
        clampTimeline()
        if record { pushHistory(edited, coalescingOn: key) }
        scheduleQuiescentWork(rerender: rerender)
    }

    /// Drops selected ids that no longer name anything.
    ///
    /// Here rather than in each of remove-clip, remove-track, undo and redo,
    /// because a selection holding a dead id is the kind of state two surfaces
    /// end up disagreeing about — the timeline draws nothing, ⌘⌫ deletes
    /// nothing, and neither looks broken. Undo and redo go through
    /// `applyHistory`, which calls this too.
    private func pruneSelection(against document: EditorDocument) {
        let liveClips = Set(document.tracks.flatMap { $0.clips.map(\.id) })
        if !selectedClipIDs.isSubset(of: liveClips) {
            selectedClipIDs.formIntersection(liveClips)
        }
        if let track = selectedTrackID, !document.tracks.contains(where: { $0.id == track }) {
            selectedTrackID = nil
        }
    }

    private func pushHistory(_ document: EditorDocument, coalescingOn key: UUID?) {
        let now = Date()
        let canCoalesce = key != nil
            && key == coalesceKey
            && now < coalesceDeadline
            && historyIndex == history.count - 1
            && historyIndex >= 0

        if canCoalesce {
            // Keep the entry that was already there — undo should land on the
            // state before the drag started, not on its previous tick.
            history[historyIndex] = document
        } else {
            if historyIndex < history.count - 1 {
                history.removeSubrange((historyIndex + 1)...)
            }
            history.append(document)
            if history.count > Self.undoDepth {
                history.removeFirst(history.count - Self.undoDepth)
            }
            historyIndex = history.count - 1
        }

        coalesceKey = key
        coalesceDeadline = now.addingTimeInterval(Self.coalescingWindow)
    }

    private func resetHistory(with document: EditorDocument) {
        history = [document]
        historyIndex = 0
        endCoalescing()
    }

    private func endCoalescing() {
        coalesceKey = nil
        coalesceDeadline = .distantPast
    }

    // MARK: - Debounced re-render

    /// Restarts the quiet-period clock. When the document stops changing, the
    /// waveform is re-rendered and the session sidecar is written — once,
    /// rather than once per slider tick.
    private func scheduleQuiescentWork(rerender: Bool = true) {
        quiescentWork?.cancel()
        quiescentWork = Task { [weak self] in
            try? await Task.sleep(for: Self.quiescence)
            guard !Task.isCancelled, let self else { return }
            writeSession()
            if rerender { await refreshWaveform() }
        }
    }

    /// Renders the drawing data for the current document.
    ///
    /// Determinate: `RenderEngine.waveform` grew a progress closure after the
    /// contract was written, so the decode inside it reports all the way out to
    /// the strip and a long first open shows a bar that moves instead of a
    /// spinner that does not.
    private func refreshWaveform() async {
        #if MELO_DEV
        if snapshotPinned { return }
        #endif
        guard let document else {
            waveform = nil
            return
        }
        waveformWork?.cancel()
        let job = makeJob(stage: "Reading the sound", fraction: 0)
        let engine = renderEngine
        let buckets = Self.waveformBuckets
        let sink = job.fractionSink()

        let work = Task { [weak self] in
            do {
                let data = try await engine.waveform(
                    document,
                    range: nil,
                    bucketCount: buckets,
                    progress: sink
                )
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    // Explicit `self.` throughout: the unwrap happens in this
                    // inner closure but the capture is the outer `Task`'s weak
                    // one, so the implicit-self shorthand does not apply.
                    guard let self else { return }
                    self.waveform = data
                    self.clampTimeline()
                    job.finish()
                    self.retire(job)
                }
            } catch {
                guard !Task.isCancelled else { return }
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                await MainActor.run {
                    guard let self else { return }
                    job.fail(message)
                    self.retire(job)
                    self.lastError = message
                    self.logger.error("Waveform failed: \(message, privacy: .private)")
                }
            }
        }
        waveformWork = work
        await work.value
    }

    /// How far the playhead and a selection are allowed to reach.
    ///
    /// **Two authorities, whichever is longer, and both are needed.**
    ///
    /// `document.duration` is the end of the last clip. The timeline knows it
    /// the instant a clip moves and does not wait for a render, so it is the
    /// one that matters while the user is dragging: clamping to the render's
    /// length alone meant dragging a clip out to 4:00 and finding the playhead
    /// refuse to pass 3:10 until the re-render landed.
    ///
    /// The rendered length is still real and can legitimately *exceed* the
    /// clips. A master `speed(rate: 0.5)` doubles the output, and `trim`,
    /// `reverse` and `removeSilence` all move the length too — clamping to
    /// `document.duration` alone would stop the playhead halfway through audio
    /// that is genuinely there. That is the same defect wearing the other face.
    ///
    /// Taking the larger cannot truncate either one. The cost is that for the
    /// moment between an edit and its render the reach may be one edit stale in
    /// the generous direction — the playhead can sit briefly past the end, land
    /// in silence, and be pulled in by the next render. A playhead that goes
    /// somewhere empty for 180 ms is a great deal better than one that refuses
    /// to go where the user just put a clip.
    private var timelineReach: TimeInterval {
        max(document?.duration ?? 0, waveform?.duration ?? 0)
    }

    /// An edit that changes the length can strand the playhead or the selection
    /// past the end of the sound. Called on every mutation and on every
    /// restored history entry, not only after a render.
    private func clampTimeline() {
        let duration = timelineReach
        playhead = min(max(playhead, 0), duration)
        if let current = selection {
            let lower = min(max(current.lowerBound, 0), duration)
            let upper = min(max(current.upperBound, lower), duration)
            selection = lower < upper ? lower...upper : nil
        }
    }

    // MARK: - Session sidecar

    private func writeSession() {
        #if MELO_DEV
        if snapshotPinned { return }
        #endif
        guard let document else { return }
        EditorSession.save(document)
    }

    #if MELO_DEV
    /// A pinned fixture outranks everything. Without it the debounced
    /// re-render would reach `RenderEngine` for a file that does not exist and
    /// blank the frame — the same failure `AudioDeviceMonitor.refresh()` guards
    /// against at `Audio/Monitors/AudioDeviceMonitor.swift:145`.
    private var snapshotPinned = false

    /// Seeds the store for a snapshot scene, with no file, no decode and no
    /// render actor. Every editor root view binds to `EditorStore.shared`,
    /// so without this every editor frame is the empty state.
    func setForSnapshot(document: EditorDocument, waveform: WaveformData?) {
        snapshotPinned = true
        quiescentWork?.cancel()
        waveformWork?.cancel()
        self.document = document
        self.waveform = waveform
        resetHistory(with: document)
        playhead = 0
        selection = nil
        lastError = nil
        selectedClipIDs = []
        selectedTrackID = document.tracks.first?.id
    }

    /// Puts the store in the state a failed open leaves it in, so the banner
    /// that reads `lastError` can be rendered.
    ///
    /// It needs its own seam because `lastError` is `private(set)` and the only
    /// thing that writes it is an async open that has thrown — which a snapshot
    /// scene cannot cause without a file that fails in a specific way. The copy
    /// this puts on screen is what a user reads at the worst moment they will
    /// have with this feature, and until now no frame of it existed at any
    /// width.
    ///
    /// Deliberately does not pin: an error banner sits over whatever document
    /// is already there, and a scene that wants both calls `setForSnapshot`
    /// first.
    func setErrorForSnapshot(_ message: String?) {
        lastError = message
    }
    #endif
}

// `fileprivate` on purpose. A `Comparable.clamped(to:)` is the obvious spelling
// and four other builders are writing into this target right now; an internal
// one here would collide with an identical internal one there, and a duplicate
// extension method is a build failure that arrives all at once.
extension Comparable {
    fileprivate func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
