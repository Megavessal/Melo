// Melo/Editor/Core/CuttingRoomStore.swift
//
// The Cutting Room's one piece of state. Reached as `CuttingRoomStore.shared`,
// matching how the rest of Melo reaches its coordinators.
//
// Undo here is an array of `EditorDocument`s and an index into it. That is the
// entire mechanism, and it is why `EditorDocument` is a value type. There is no
// command pattern, no inverse-operation table, and nothing to keep in sync.

import Foundation
import SwiftUI
import os

@MainActor
final class CuttingRoomStore: ObservableObject {

    static let shared = CuttingRoomStore()

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

    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    /// The last thing that went wrong, as one sentence for the user. Cleared
    /// when the next operation starts.
    @Published private(set) var lastError: String?

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

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Melo",
        category: "CuttingRoomStore"
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
    /// **For `.extractedFromLink` and `.systemRecording`, this takes ownership
    /// of the file.** Those two land in the temporary directory, so the store
    /// moves them somewhere durable before anything reads the path — see
    /// `EditorSourceStore`. Hand the URL over and stop using it; the store's
    /// `document.source.url` is where the audio lives afterwards. Nothing is
    /// moved for `.file` or `.meloTheme`, which already have durable homes.
    func openSource(at url: URL, origin: EditorSource.Origin, displayName: String?) async {
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

            var opened = EditorDocument(source: source)
            if let session = EditorSession.load(for: resolved) {
                opened.moves = session.moves
                opened.analysis = session.analysis
                opened.destination = session.destinationID.flatMap { identifier in
                    DestinationCatalogue.all.first { $0.id == identifier }
                }
                logger.info("Restored a session with \(session.moves.count) moves")
            }

            // Drop the previous file's decoded samples before the next decode
            // rather than after it. Two hours of Float32 stereo is about 1.4 GB,
            // and holding the outgoing one while the incoming one is read is
            // 2.8 GB at the peak for no reason — the old document is already
            // gone from the screen by the time this line runs.
            if document?.source.url != resolved {
                await renderEngine.forgetCachedSource()
            }

            document = opened
            resetHistory(with: opened)
            selection = nil
            playhead = 0
            waveform = nil
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

    /// **The window controller must call this when the Cutting Room closes.**
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
        history = []
        historyIndex = -1
        refreshUndoFlags()
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

    /// Back to the file as it arrived. The measured analysis and the chosen
    /// destination survive: both describe the *source*, which has not changed,
    /// and re-measuring a long file to get back what we already know is the
    /// kind of thing that makes an editor feel slow.
    func revertToOriginal() {
        mutate { $0.moves.removeAll() }
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
        endCoalescing()
        document = history[historyIndex]
        refreshUndoFlags()
        scheduleQuiescentWork()
    }

    func redo() {
        guard historyIndex >= 0, historyIndex < history.count - 1 else { return }
        historyIndex += 1
        endCoalescing()
        document = history[historyIndex]
        refreshUndoFlags()
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
        if record { pushHistory(edited, coalescingOn: key) }
        scheduleQuiescentWork(rerender: rerender)
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
        refreshUndoFlags()
    }

    private func resetHistory(with document: EditorDocument) {
        history = [document]
        historyIndex = 0
        endCoalescing()
        refreshUndoFlags()
    }

    private func endCoalescing() {
        coalesceKey = nil
        coalesceDeadline = .distantPast
    }

    private func refreshUndoFlags() {
        canUndo = historyIndex > 0
        canRedo = historyIndex >= 0 && historyIndex < history.count - 1
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
                    self.clampTimeline(to: data.duration)
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

    /// A move that changes the length can strand the playhead or the selection
    /// past the end of the sound.
    private func clampTimeline(to duration: TimeInterval) {
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
    /// render actor. Every editor root view binds to `CuttingRoomStore.shared`,
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
