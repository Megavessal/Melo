// Melo/Editor/Views/Waveform/EditorPlayback.swift
//
// Playback of the *rendered* result, so what the user hears is what they will
// export.
//
// The engine graph follows `OnboardingVolumeDemo`
// (`Views/Onboarding/FirstRunOnboardingView.swift:19`), which is the closest
// thing in this project to what this needs: a private `AVAudioEngine`, one
// `AVAudioPlayerNode`, straight into the main mixer. What it deliberately does
// *not* copy is that class's `AVAudioUnitEQ`. The render engine has already
// applied every effect to the buffer handed over here, and a second EQ in the
// playback path would be a second place for Melo's sound to be decided.
//
// Three things make this more than "schedule a buffer and play it".
//
// 1. **Chunked scheduling.** The buffer is fed to the node 200 ms at a time,
//    kept 600 ms ahead. That is what makes a re-render land mid-playback
//    without a click and without losing position: the cursor is a *time*, not
//    an offset into a particular buffer object, so the next chunk simply comes
//    from the new render at the same sample position. It is also what lets a
//    selection loop without allocating a copy of the selection.
//
// 2. **The playhead comes off the audio clock.** `player.playerTime` gives the
//    frame the device is actually rendering; a 60 Hz task loop only *reads* it.
//    A timer that accumulates its own elapsed time drifts against the audio
//    within a minute, and on a loop that drift is audible as the playhead
//    arriving at the loop point early.
//
// 3. **Nothing happens until someone presses play.** `EditorPlayback.shared`
//    allocates no engine and opens no device; `AVAudioEngine` is created on the
//    first `play()`. Constructing the transport bar in a render harness must not
//    start an audio device, or no frame of this piece could ever be captured.

import AVFoundation
import SwiftUI

@MainActor
final class EditorPlayback: ObservableObject {

    static let shared = EditorPlayback()

    // MARK: - Published state

    @Published private(set) var isPlaying = false
    /// A render is in flight. The transport says so rather than looking dead.
    @Published private(set) var isPreparing = false
    /// Loop the selection, or the whole sound when there is no selection.
    @Published var loops = false
    /// Held bypass: the stack is off and the source is playing instead.
    @Published private(set) var isBypassed = false

    // MARK: - Tuning

    /// How much audio is handed to the node at a time. Small enough that a
    /// re-render or a loop wrap is never more than this far away; large enough
    /// that the 60 Hz top-up has an order of magnitude of slack.
    private static let chunkSeconds: TimeInterval = 0.2
    /// How far ahead the node is kept fed.
    private static let horizonSeconds: TimeInterval = 0.6
    /// A selection shorter than this is a mis-click, not a loop.
    private static let shortestLoop: TimeInterval = 0.02

    // MARK: - Audio

    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var wiredFormat: AVAudioFormat?

    /// The document as it will export.
    private var wet: AVAudioPCMBuffer?
    /// The same timeline with the tone and level moves taken out, for
    /// hold-to-bypass. Deliberately *not* the raw source: it keeps trim,
    /// silence removal, speed and reverse, so bypassing does not also change
    /// where you are in the sound. A/B is only honest if the two sides line up
    /// sample for sample.
    ///
    /// `nil` until somebody presses bypass — see `renderBypassIfWanted`.
    private var dry: AVAudioPCMBuffer?
    /// Whether this session has ever asked to hear the sound untouched. Once
    /// true it stays true, so every later render keeps `dry` current and only
    /// the very first press waits.
    private var wantsBypassBuffer = false
    private var isRenderingBypass = false

    private var activeBuffer: AVAudioPCMBuffer? {
        isBypassed ? (dry ?? wet) : wet
    }

    // MARK: - Schedule

    private struct Chunk {
        var playerStart: AVAudioFramePosition
        var frames: AVAudioFrameCount
        var timelineStart: TimeInterval
    }

    private var scheduled: [Chunk] = []
    private var nextPlayerFrame: AVAudioFramePosition = 0
    /// Where the next chunk starts, in timeline seconds.
    private var cursorTime: TimeInterval = 0
    private var segment: ClosedRange<TimeInterval> = 0...0

    // MARK: - Coordination

    private weak var store: CuttingRoomStore?
    private var renderedDocument: EditorDocument?
    private var renderWork: Task<Void, Never>?
    private var refreshWork: Task<Void, Never>?
    private var seekWork: Task<Void, Never>?
    private var bypassWork: Task<Void, Never>?
    private var ticker: Task<Void, Never>?
    /// The last value this object wrote to `store.playhead`, so a seek by the
    /// user can be told apart from this object's own 60 Hz writes.
    private var lastPublishedPlayhead: TimeInterval = -1

    private init() {}

    // MARK: - Wiring

    /// Called by the transport bar when it appears. Playback does not reach for
    /// `CuttingRoomStore.shared` itself so it can be pointed at a different
    /// store in a test without a singleton dance.
    func attach(_ store: CuttingRoomStore) {
        guard self.store !== store else { return }
        self.store = store
        reset()
    }

    /// A different sound entirely. Everything rendered is wrong now.
    ///
    /// `wantsBypassBuffer` deliberately survives: someone who uses bypass on one
    /// sound will use it on the next, and carrying the answer means only the
    /// first press of the session ever waits.
    func reset() {
        stop()
        wet = nil
        dry = nil
        renderedDocument = nil
        renderWork?.cancel()
        refreshWork?.cancel()
        seekWork?.cancel()
        bypassWork?.cancel()
        // Guarded. `attach` calls this from the transport's `onAppear`, which
        // SwiftUI delivers inside `NSHostingView.layout()`; on a fresh instance
        // every one of these is already false, so a first attach publishes
        // nothing at all rather than three times into a running display cycle.
        if isPreparing { isPreparing = false }
        if isBypassed { isBypassed = false }
    }

    /// The document changed. If nothing has ever been rendered, this does
    /// nothing — the render happens when someone presses play, not when they
    /// nudge a slider. If a render *does* exist, it is now stale and a fresh one
    /// is started quietly so the next press is instant and, if the sound is
    /// playing, so the swap happens under it.
    func noteDocumentChanged() {
        guard let store, let document = store.document else {
            reset()
            return
        }
        guard renderedDocument != nil, document != renderedDocument else { return }
        refreshWork?.cancel()
        refreshWork = Task { [weak self] in
            // Longer than the store's own 180 ms quiescence, so a drag settles
            // the waveform first and the two renders do not race each other for
            // the same actor.
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self else { return }
            await self.renderCurrentDocument()
        }
    }

    func noteSelectionChanged() {
        guard isPlaying else { return }
        let before = segment
        refreshSegment()
        guard segment != before else { return }
        scheduleReseek(to: nil)
    }

    /// Someone moved the playhead who was not this object.
    ///
    /// Debounced, and that is not politeness. A selection drag writes the
    /// playhead on every frame of the gesture — restarting the schedule sixty
    /// times a second would turn a drag over playing audio into a stutter, and
    /// the last write is the only one anybody meant.
    func notePlayheadChanged(_ value: TimeInterval) {
        guard isPlaying, abs(value - lastPublishedPlayhead) > 0.03 else { return }
        scheduleReseek(to: value)
    }

    private func scheduleReseek(to position: TimeInterval?) {
        seekWork?.cancel()
        seekWork = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(90))
            guard !Task.isCancelled, let self else { return }
            self.restart(at: position ?? self.store?.playhead)
        }
    }

    // MARK: - Transport

    func toggle() {
        if isPlaying { pause() } else { play() }
    }

    func play() {
        guard let store, let document = store.document else { return }
        if wet == nil || document != renderedDocument {
            renderWork?.cancel()
            isPreparing = true
            renderWork = Task { [weak self] in
                guard let self else { return }
                await self.renderCurrentDocument(showingProgress: true)
                guard !Task.isCancelled else { return }
                self.isPreparing = false
                if self.wet != nil { self.startPlayback() }
            }
            return
        }
        startPlayback()
    }

    func pause() {
        guard isPlaying else { return }
        let position = currentPosition() ?? store?.playhead ?? 0
        player?.stop()
        engine?.pause()
        clearSchedule()
        isPlaying = false
        stopTicker()
        publish(position)
    }

    func stop() {
        player?.stop()
        engine?.stop()
        clearSchedule()
        if isPlaying { isPlaying = false }
        stopTicker()
    }

    func jumpToStart() {
        publish(0)
        if isPlaying { restart(at: 0) }
    }

    /// Hold-to-bypass. The stack goes off, the sound keeps playing from the same
    /// place, and letting go puts it back. This is the only way someone can
    /// judge a change Melo proposed for them rather than taking it on faith.
    ///
    /// While playing this re-splices immediately rather than waiting for the
    /// scheduling horizon: 600 ms of latency between pressing and hearing is
    /// long enough to break the comparison the control exists for. The splice is
    /// at the same sample position in two renders of the same source, so it is
    /// phase-continuous — the only step is the processing itself, which is the
    /// thing being listened for.
    func setBypassed(_ bypassed: Bool) {
        guard isBypassed != bypassed else { return }
        isBypassed = bypassed
        Haptics.step()

        if bypassed && dry == nil {
            // The first press is what buys the second buffer. The control still
            // lights, so it is never silently inert; the sound changes when the
            // render lands, which `renderBypassIfWanted` handles even if the
            // press is still being held.
            wantsBypassBuffer = true
            // Only worth starting against a stack that has already been
            // rendered; otherwise the next `renderCurrentDocument` makes it.
            if let store, let document = renderedDocument {
                let engine = store.renderEngine
                bypassWork?.cancel()
                bypassWork = Task { [weak self] in
                    await self?.renderBypassIfWanted(document: document, engine: engine)
                }
            }
            return
        }
        guard isPlaying else { return }
        restart(at: nil)
    }

    // MARK: - Rendering

    /// `RenderEngine.render` hands back a `PCMBlock` — the `Sendable` struct, so
    /// it can leave the actor at all — and `makeBuffer()` copies it into the
    /// `AVAudioPCMBuffer` the player node needs.
    ///
    /// **That copy happens exactly once, here, and the buffer is what gets
    /// held.** Converting at the point of scheduling would be the same copy
    /// five times a second for the whole of playback, and the block would have
    /// to be kept resident alongside the buffer to do it. The block is a local
    /// and is released at the end of this scope, so the transient peak is one
    /// block plus one buffer rather than two of each.
    private func renderCurrentDocument(showingProgress: Bool = false) async {
        guard let store, let document = store.document else { return }
        let engine = store.renderEngine
        let job = showingProgress ? store.makeJob(stage: "Getting it ready to play", fraction: 0) : nil
        let sink: @Sendable (Double) -> Void
        if let job {
            sink = job.fractionSink()
        } else {
            sink = { _ in }
        }

        do {
            let block = try await engine.render(document, range: nil, progress: sink)
            guard let processed = block.makeBuffer() else {
                job?.fail("That render came back empty.")
                if let job { store.retire(job) }
                return
            }
            adopt(processed: processed, for: document)
            job?.finish()
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            job?.fail(message)
        }
        if let job { store.retire(job) }

        // Sequenced after the processed render rather than run alongside it, so
        // two blocks and two buffers are never resident at the same moment.
        await renderBypassIfWanted(document: document, engine: engine)
    }

    /// The unprocessed render, and only for someone who has actually pressed
    /// bypass.
    ///
    /// A second full-length buffer is not free: four minutes of 48 kHz stereo is
    /// about 92 MB, and the render actor is already holding the decoded source.
    /// Making one unconditionally would put three copies of every sound in
    /// memory for a control most sessions never touch, in a feature whose brief
    /// says lightweight. So the first press pays for it — the decode is cached
    /// in the actor and this render applies only the timeline moves, so what it
    /// pays is DSP, not I/O — and every render after that keeps it current, so
    /// the second press and all the rest are immediate.
    private func renderBypassIfWanted(document: EditorDocument, engine: RenderEngine) async {
        // `isRenderingBypass` rather than just `dry == nil`: a press and a
        // re-render can both arrive at this, and two concurrent full-length
        // renders is the one thing the memory argument above cannot afford.
        guard wantsBypassBuffer, dry == nil, !isRenderingBypass else { return }
        isRenderingBypass = true
        defer { isRenderingBypass = false }

        let block = try? await engine.render(Self.timelineOnly(document), range: nil, progress: { _ in })
        // Nothing to adopt if the stack moved on while this was rendering.
        guard let buffer = block?.makeBuffer(), document == renderedDocument else { return }
        dry = buffer
        // The press that asked for this may still be held. If it is, put it on
        // the sound now rather than waiting for the next one.
        if isBypassed && isPlaying { restart(at: nil) }
    }

    /// The document with everything that shapes the *sound* removed and
    /// everything that shapes the *timeline* kept.
    private static func timelineOnly(_ document: EditorDocument) -> EditorDocument {
        var copy = document
        copy.moves = document.moves.filter { move in
            switch move.kind {
            case .trim, .removeSilence, .speed, .reverse: return true
            case .gain, .normalize, .limiter, .fadeIn, .fadeOut,
                 .equalizer, .highPass, .noiseGate, .channels, .fixDCOffset: return false
            }
        }
        return copy
    }

    /// Takes a fresh render. If the sound is playing, nothing stops: the chunks
    /// already queued finish from the old buffer and the next one comes from
    /// this, at the same sample position.
    private func adopt(processed: AVAudioPCMBuffer, for document: EditorDocument) {
        let formatChanged = wiredFormat.map { !$0.isEqual(processed.format) } ?? false
        wet = processed
        // Whatever was rendered unprocessed described the old stack's timeline.
        // Dropped here and rebuilt by `renderBypassIfWanted`, so bypass can
        // never play a length that no longer matches the picture.
        dry = nil
        renderedDocument = document
        refreshSegment()
        if isPlaying && formatChanged {
            // A different sample rate cannot be spliced into a graph wired for
            // the old one; rebuild and pick up where we were.
            restart(at: nil)
        }
    }

    // MARK: - Engine

    private func ensureGraph(format: AVAudioFormat) -> AVAudioPlayerNode? {
        if let engine, let player, let wiredFormat, wiredFormat.isEqual(format) {
            if !engine.isRunning {
                do { try engine.start() } catch { return nil }
            }
            return player
        }

        engine?.stop()
        let newEngine = AVAudioEngine()
        let newPlayer = AVAudioPlayerNode()
        newEngine.attach(newPlayer)
        newEngine.connect(newPlayer, to: newEngine.mainMixerNode, format: format)
        newEngine.prepare()
        do {
            try newEngine.start()
        } catch {
            return nil
        }
        engine = newEngine
        player = newPlayer
        wiredFormat = format
        return newPlayer
    }

    private func startPlayback() {
        guard let source = activeBuffer, source.frameLength > 0 else { return }
        refreshSegment()
        guard segment.upperBound > segment.lowerBound else { return }

        var start = store?.playhead ?? 0
        if start < segment.lowerBound || start >= segment.upperBound - 0.001 {
            start = segment.lowerBound
        }

        guard let node = ensureGraph(format: source.format) else { return }
        node.stop()
        clearSchedule()
        cursorTime = start
        isPlaying = true
        topUp()
        // Queue first, then play: starting an empty node and racing the top-up
        // is how the first fifth of a second goes missing.
        node.play()
        publish(start)
        startTicker()
    }

    /// Re-splices the schedule.
    ///
    /// `position` is `nil` for a change that is not a seek — a bypass, a loop
    /// range — where the right place to resume is wherever the audio clock has
    /// actually reached. Pass a value for a seek, or the clock will overwrite
    /// the place the user just clicked.
    private func restart(at position: TimeInterval?) {
        guard isPlaying else { return }
        let target = position ?? currentPosition() ?? store?.playhead ?? 0
        publish(target)
        player?.stop()
        clearSchedule()
        startPlayback()
    }

    private func clearSchedule() {
        scheduled.removeAll(keepingCapacity: true)
        nextPlayerFrame = 0
        cursorTime = 0
    }

    private func refreshSegment() {
        guard let source = activeBuffer, source.format.sampleRate > 0 else {
            segment = 0...0
            return
        }
        let total = Double(source.frameLength) / source.format.sampleRate
        if loops,
           let selection = store?.selection,
           selection.upperBound - selection.lowerBound > Self.shortestLoop {
            let lower = min(max(selection.lowerBound, 0), total)
            let upper = min(max(selection.upperBound, lower), total)
            segment = upper > lower ? lower...upper : 0...total
        } else {
            segment = 0...total
        }
    }

    // MARK: - Scheduling

    private func topUp() {
        guard isPlaying, let node = player, let source = activeBuffer else { return }
        let rate = source.format.sampleRate
        guard rate > 0 else { return }
        let totalFrames = AVAudioFramePosition(source.frameLength)
        // An empty schedule means the node was just stopped and its player time
        // has been reset — but `lastRenderTime` can still be reporting the
        // frame the *previous* session reached. Reading it here would look like
        // an enormous backlog and queue sixteen chunks, which is three seconds
        // of latency before the next re-render or bypass could take effect.
        let now = scheduled.isEmpty ? 0 : currentPlayerFrame()

        var iterations = 0
        while Double(nextPlayerFrame - now) / rate < Self.horizonSeconds, iterations < 16 {
            iterations += 1

            if cursorTime >= segment.upperBound - 0.0005 {
                guard loops else { break }
                cursorTime = segment.lowerBound
            }

            let chunkEnd = min(cursorTime + Self.chunkSeconds, segment.upperBound)
            let startFrame = AVAudioFramePosition((cursorTime * rate).rounded())
            let endFrame = min(AVAudioFramePosition((chunkEnd * rate).rounded()), totalFrames)
            guard endFrame > startFrame else { break }

            let frames = AVAudioFrameCount(endFrame - startFrame)
            guard let chunk = Self.slice(source, from: startFrame, frames: frames) else { break }

            node.scheduleBuffer(chunk, at: nil, options: [], completionHandler: nil)
            scheduled.append(Chunk(playerStart: nextPlayerFrame, frames: frames, timelineStart: cursorTime))
            nextPlayerFrame += AVAudioFramePosition(frames)
            cursorTime = Double(endFrame) / rate
        }
    }

    /// A copy of `frames` frames starting at `startFrame`.
    ///
    /// Walks the audio buffer list rather than `floatChannelData`, so it is
    /// correct for interleaved and non-interleaved formats without asking which
    /// one this is: `mBytesPerFrame` is per-channel in one layout and
    /// per-frame-of-all-channels in the other, and in both it is exactly the
    /// stride this needs.
    private static func slice(
        _ source: AVAudioPCMBuffer,
        from startFrame: AVAudioFramePosition,
        frames: AVAudioFrameCount
    ) -> AVAudioPCMBuffer? {
        guard frames > 0, startFrame >= 0,
              startFrame + AVAudioFramePosition(frames) <= AVAudioFramePosition(source.frameLength),
              let output = AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: frames) else { return nil }

        output.frameLength = frames
        let bytesPerFrame = Int(source.format.streamDescription.pointee.mBytesPerFrame)
        guard bytesPerFrame > 0 else { return nil }

        let input = UnsafeMutableAudioBufferListPointer(source.mutableAudioBufferList)
        let target = UnsafeMutableAudioBufferListPointer(output.mutableAudioBufferList)
        let byteCount = Int(frames) * bytesPerFrame
        let offset = Int(startFrame) * bytesPerFrame

        for index in 0..<min(input.count, target.count) {
            guard let sourceData = input[index].mData, let targetData = target[index].mData else { continue }
            memcpy(targetData, sourceData.advanced(by: offset), byteCount)
            target[index].mDataByteSize = UInt32(byteCount)
        }
        return output
    }

    // MARK: - The clock

    private func currentPlayerFrame() -> AVAudioFramePosition {
        guard let node = player,
              let nodeTime = node.lastRenderTime,
              let playerTime = node.playerTime(forNodeTime: nodeTime) else { return 0 }
        return max(0, playerTime.sampleTime)
    }

    /// Where the sound actually is, from the audio clock, mapped back through
    /// the schedule so a loop wrap lands on the right side of the seam.
    private func currentPosition() -> TimeInterval? {
        guard let source = activeBuffer, source.format.sampleRate > 0 else { return nil }
        let rate = source.format.sampleRate
        let now = currentPlayerFrame()
        guard let chunk = scheduled.last(where: { $0.playerStart <= now }) else { return nil }
        let offset = Double(now - chunk.playerStart) / rate
        guard offset < Double(chunk.frames) / rate + 0.05 else { return nil }
        return chunk.timelineStart + offset
    }

    private func startTicker() {
        stopTicker()
        ticker = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(16))
                guard let self, self.isPlaying else { return }
                self.tick()
            }
        }
    }

    private func stopTicker() {
        ticker?.cancel()
        ticker = nil
    }

    private func tick() {
        guard isPlaying, activeBuffer != nil else { return }
        let now = currentPlayerFrame()

        // Retire chunks the device has finished with, keeping the one it is in.
        while scheduled.count > 1,
              let first = scheduled.first,
              first.playerStart + AVAudioFramePosition(first.frames) <= now {
            scheduled.removeFirst()
        }

        if let position = currentPosition() {
            publish(min(max(position, segment.lowerBound), segment.upperBound))
        } else if now >= nextPlayerFrame, !loops {
            // Everything queued has played and nothing more was due.
            finishedPlaying()
            return
        }
        topUp()
    }

    private func finishedPlaying() {
        let end = segment.upperBound
        stop()
        publish(end)
    }

    private func publish(_ time: TimeInterval) {
        lastPublishedPlayhead = time
        store?.playhead = time
    }
}
