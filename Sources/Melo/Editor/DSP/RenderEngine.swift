// Melo/Editor/DSP/RenderEngine.swift
import AVFoundation
import Accelerate
import Foundation

/// Renders a document, draws a document, and measures a document.
///
/// There is one render. `range` is a slice taken from its output, never a
/// second, cleverer path that trims the source first and hopes to agree with
/// the full render — `speed`, `removeSilence` and `reverse` all move the
/// timeline, so a range in output time cannot be turned into a range in source
/// time without re-deriving the whole stack, and two render paths that must
/// agree is the defect class this project records at `CLAUDE.md:138`.
///
/// **The walk, outermost last.** Per track: every clip is cut out of its
/// source's decoded samples by `sourceIn`/`sourceOut`, put through its own
/// moves, then its fades and its gain, then added into the track's buffer at
/// its `start`. Clips that overlap sum, because layering is the feature. Then
/// the track's own moves, then its gain and its pan. The audible tracks are
/// summed — `EditorDocument.audibleTrackIDs` decides which, so solo and the
/// track headers cannot disagree about what solo means — and the master moves
/// run on the sum.
///
/// The stack at each level is walked in the order the user put it in. The chain
/// the contract names — gain → EQ → noise gate → normalize → limiter → channel
/// mode → safety clip, mirroring `ProcessTapController.swift:1700-1956` — is the
/// order the proposer builds the master stack in, so a document nobody has
/// reordered renders through exactly the live path's chain. The safety clip is
/// not a move and is not in the stack: it is applied last, always.
actor RenderEngine {

    /// The decoded source pool: one decode per **file**, not per clip.
    ///
    /// Keyed by url rather than by `EditorSource.ID` because the decode is a
    /// function of the file and nothing else — so two clips cut from one source
    /// share it (the thing a split must not cost), and so do two sources that
    /// happen to name the same file. Keying by id would have made a split
    /// cheap and left the second case paying twice for the same bytes.
    ///
    /// *Rejected:* the single-entry cache this replaced. It was right when the
    /// editor held one sound; with a pool it turns every render of a two-source
    /// timeline into two full decodes, alternating, forever — the worst
    /// possible shape, and silent apart from the wait.
    private var pool: [URL: PCMBlock] = [:]

    /// The same audio in the mix's own format. A source at another sample rate
    /// or channel count is conformed once and kept, because resampling two
    /// hours of stereo on every keystroke is not a thing that can be repeated.
    /// A source that already matches is stored unchanged, which under
    /// copy-on-write costs one more reference to the same buffer and no bytes.
    private var conformed: [URL: PCMBlock] = [:]
    private var conformedFormat: MixFormat?

    init() {}

    /// What the mix is summed in. Every clip is conformed to it before it is
    /// laid, because adding 44.1 kHz samples into a 48 kHz buffer is not a
    /// wrong number, it is a wrong speed.
    struct MixFormat: Equatable, Sendable {
        var sampleRate: Double
        var channelCount: Int
    }

    // MARK: - Render

    /// Returns the canonical block rather than an `AVAudioPCMBuffer`.
    /// `AVAudioPCMBuffer` is a non-`Sendable` class and cannot leave an actor;
    /// `PCMBlock` is the `Sendable` struct the whole DSP layer already speaks,
    /// and `makeBuffer()` turns it into one on the caller's own side.
    func render(_ document: EditorDocument,
                range: ClosedRange<TimeInterval>?,
                progress: @Sendable (Double) -> Void) async throws -> PCMBlock {
        let block = try renderBlock(document, progress: progress).block.slice(range)
        guard !block.samples.isEmpty else { throw Failure.emptyRender }
        return block
    }

    // MARK: - Waveform

    /// `bucketCount * channelCount` buckets, interleaved by channel within each
    /// time bucket — `buckets[bucket * channelCount + channel]`, which is what
    /// `EditorWaveformSampler.columns(buckets:lanes:lane:…)` indexes. A stereo
    /// file has to be drawable as two lanes, and summing the channels into one
    /// bucket here is a decision the drawing side cannot undo.
    func waveform(_ document: EditorDocument,
                  range: ClosedRange<TimeInterval>?,
                  bucketCount: Int,
                  progress: (@Sendable (Double) -> Void)? = nil) async throws -> WaveformData {
        // The first waveform of a long file pays for the decode, and the decode
        // is the slowest thing in the feature. Reporting it out is the
        // difference between a progress bar and a spinner.
        let rendered = try renderBlock(document, progress: { progress?($0 * 0.9) })
        let block = rendered.block.slice(range)
        let joins = Self.joins(rendered.joins, within: range, duration: block.duration)
        let buckets = max(1, bucketCount)
        let frames = block.frameCount
        guard frames > 0 else {
            return WaveformData(buckets: [], duration: 0, joins: [])
        }

        let channels = block.channelCount
        var result = [WaveformData.Bucket](
            repeating: WaveformData.Bucket(minimum: 0, maximum: 0, rms: 0),
            count: buckets * channels)

        try block.samples.withUnsafeBufferPointer { samples in
            guard let base = samples.baseAddress else { return }
            for index in 0..<buckets {
                if index % 512 == 0 {
                    try Task.checkCancellation()
                    progress?(0.9 + 0.1 * Double(index) / Double(buckets))
                }
                let first = frames * index / buckets
                let last = min(max(first + 1, frames * (index + 1) / buckets), frames)
                let count = vDSP_Length(last - first)
                guard count > 0 else { continue }
                for channel in 0..<channels {
                    let start = first * channels + channel
                    var minimum: Float = 0
                    var maximum: Float = 0
                    var rms: Float = 0
                    vDSP_minv(base + start, vDSP_Stride(channels), &minimum, count)
                    vDSP_maxv(base + start, vDSP_Stride(channels), &maximum, count)
                    vDSP_rmsqv(base + start, vDSP_Stride(channels), &rms, count)
                    result[index * channels + channel] =
                        WaveformData.Bucket(minimum: minimum, maximum: maximum, rms: rms)
                }
            }
        }

        progress?(1)
        return WaveformData(buckets: result, duration: block.duration, joins: joins)
    }

    /// Splice positions expressed on the sliced timeline, dropping any that the
    /// slice left outside the window.
    private nonisolated static func joins(_ joins: [TimeInterval],
                                          within range: ClosedRange<TimeInterval>?,
                                          duration: TimeInterval) -> [TimeInterval] {
        guard let range else { return joins }
        return joins.compactMap { join in
            let shifted = join - range.lowerBound
            return shifted > 0 && shifted < duration ? shifted : nil
        }
    }

    // MARK: - Analysis

    /// Measures what the document currently sounds like, stack included — an
    /// empty stack measures the mix, and a stack that already carries a
    /// high-pass measures the mix with the high-pass in. The alternative,
    /// always measuring the raw source, would have the report describe audio
    /// the user is no longer listening to.
    func analyse(_ document: EditorDocument,
                 progress: (@Sendable (Double) -> Void)? = nil) async throws -> AnalysisReport {
        let rendered = try renderBlock(document, progress: { progress?($0 * 0.4) })
        return try Self.report(for: rendered.block) { progress?(0.4 + 0.6 * $0) }
    }

    /// The report for a block that is already in memory. Separate from
    /// `analyse` so a caller holding a block does not decode a second time, and
    /// so it can run on a synthetic buffer with no document, no file, no actor
    /// and no UI — which is what makes every number in the report testable.
    nonisolated static func report(
        for block: PCMBlock,
        progress: (@Sendable (Double) -> Void)? = nil
    ) throws -> AnalysisReport {
        // Loudness is the long pole: it filters every sample of every channel.
        let loudness = try LoudnessMeter.measure(block) { progress?($0 * 0.7) }
        try Task.checkCancellation()
        let truePeak = try TruePeakMeter.truePeakDBTP(block) { progress?(0.7 + $0 * 0.2) }
        try Task.checkCancellation()
        progress?(0.9)

        let noiseFloor = SignalAnalysis.noiseFloorDBFS(block)
        let silences = SignalAnalysis.silences(
            block,
            thresholdDB: SignalAnalysis.reportingSilenceThresholdDB(noiseFloorDBFS: noiseFloor),
            minimumLength: 0.5)
        progress?(1)

        return AnalysisReport(
            integratedLUFS: loudness.integratedLUFS,
            truePeakDBTP: truePeak,
            loudnessRangeLU: loudness.loudnessRangeLU,
            peakDBFS: SignalAnalysis.peakDBFS(block),
            noiseFloorDBFS: noiseFloor,
            dcOffset: SignalAnalysis.dcOffset(block),
            clippedSampleCount: SignalAnalysis.clippedSampleCount(block),
            spectralTiltDBPerOctave: SignalAnalysis.spectralTiltDBPerOctave(block),
            leadingSilence: silences.leading,
            trailingSilence: silences.trailing,
            interiorSilences: silences.interior,
            isEffectivelyMono: SignalAnalysis.isEffectivelyMono(block),
            measuredAt: Date())
    }

    // MARK: - The one render

    /// A render and the splices it made, which is more than the samples say.
    struct Rendered: Sendable {
        var block: PCMBlock
        /// Where `removeSilence` spliced the sound, in the final output's own
        /// timeline — carried through every later trim, reverse and speed
        /// change rather than recovered afterwards, because after a reverse
        /// there is nothing left to recover it from. A splice a clip's own
        /// stack made is carried up to the timeline by its clip's position.
        var joins: [TimeInterval]
    }

    private func renderBlock(_ document: EditorDocument,
                             progress: @Sendable (Double) -> Void) throws -> Rendered {
        let decodeShare = 0.35
        let mixShare = 0.40

        // The sources the timeline actually names, in the pool's own order so
        // that which one sets the mix format does not depend on which track
        // happens to be first. A pool entry no clip points at is **not**
        // decoded: the model keeps a source after its last clip goes so undo
        // can bring the clip back, and paying a decode for audio nobody can
        // hear would make every delete cost what an open costs.
        var referenced = Set<EditorSource.ID>()
        for track in document.tracks {
            for clip in track.clips where clip.duration > 0 { referenced.insert(clip.sourceID) }
        }
        let needed = document.sources.filter { referenced.contains($0.id) }

        var decoded: [EditorSource.ID: PCMBlock] = [:]
        let decodes = max(needed.count, 1)
        for (index, source) in needed.enumerated() {
            try Task.checkCancellation()
            let base = decodeShare * Double(index) / Double(decodes)
            let slice = decodeShare / Double(decodes)
            decoded[source.id] = try self.source(for: source.url) { fraction in
                progress(base + fraction * slice)
            }
        }
        progress(decodeShare)

        let format = Self.mixFormat(document, decoded: decoded, needed: needed)
        if conformedFormat != format {
            conformed.removeAll()
            conformedFormat = format
        }
        var blocks: [EditorSource.ID: PCMBlock] = [:]
        for source in needed {
            guard let raw = decoded[source.id] else { continue }
            if let ready = conformed[source.url] {
                blocks[source.id] = ready
                continue
            }
            try Task.checkCancellation()
            let ready = try Self.conform(raw, to: format)
            conformed[source.url] = ready
            blocks[source.id] = ready
        }

        // Solo resolved in one place. Asking `audibleTrackIDs` rather than
        // re-deriving it is what stops the render and the track headers from
        // ever describing different sound.
        let audible = document.audibleTrackIDs
        let tracks = document.tracks.filter { audible.contains($0.id) }
        var lanes: [Rendered] = []
        lanes.reserveCapacity(tracks.count)
        for (index, track) in tracks.enumerated() {
            try Task.checkCancellation()
            lanes.append(try lay(track, blocks: blocks, format: format))
            progress(decodeShare + mixShare * Double(index + 1) / Double(max(tracks.count, 1)))
        }

        var result = Self.sum(lanes, format: format)
        let masterShare = 1 - decodeShare - mixShare
        let moves = document.master.filter(\.isEnabled)
        for (index, move) in moves.enumerated() {
            try Task.checkCancellation()
            result = try apply(move.kind, to: result)
            progress(decodeShare + mixShare
                     + masterShare * Double(index + 1) / Double(moves.count + 1))
        }

        result.block = MoveProcessors.safetyClip(result.block)
        progress(1)
        return result
    }

    // MARK: - One track

    /// A track's clips, laid at their start times and summed, then put through
    /// the track's own stack, gain and pan.
    private nonisolated func lay(_ track: Track,
                                 blocks: [EditorSource.ID: PCMBlock],
                                 format: MixFormat) throws -> Rendered {
        let rate = format.sampleRate
        let channels = format.channelCount
        var pieces: [(offset: Int, block: PCMBlock)] = []
        var joins: [TimeInterval] = []
        var frames = 0

        for clip in track.clips {
            try Task.checkCancellation()
            guard let source = blocks[clip.sourceID], source.frameCount > 0 else { continue }

            // **Where a clip lands is a source frame plus one integer offset**,
            // and that is what makes a split free.
            //
            // Rounding `start` and `sourceIn` to frames independently would let
            // the two halves of a split disagree by one frame — the second
            // half's `start` and `sourceIn` both moved by the same amount, but
            // `round(a + d) - round(a)` is not `round(b + d) - round(b)` unless
            // `a` and `b` share a fractional frame. Deriving the offset from
            // `start - sourceIn` instead means the two halves compute the *same*
            // offset, so the second half begins at exactly the frame the first
            // one ended on, by construction rather than by luck.
            let delta = Int(((clip.start - clip.sourceIn) * rate).rounded())
            var first = max(0, Int((clip.sourceIn * rate).rounded()))
            let last = min(source.frameCount, Int((clip.sourceOut * rate).rounded()))
            var offset = delta + first
            if offset < 0 {
                first -= offset
                offset = 0
            }
            guard last > first else { continue }

            let window = PCMBlock(
                samples: Array(source.samples[(first * source.channelCount)..<(last * source.channelCount)]),
                sampleRate: rate,
                channelCount: source.channelCount)

            var piece = Rendered(block: window, joins: [])
            for move in clip.moves where move.isEnabled {
                piece = try apply(move.kind, to: piece)
            }
            // A clip move may have folded the piece to mono. It has to come
            // back to the mix's shape before anything is added to anything.
            var block = Self.matchChannels(piece.block, to: channels)
            if clip.fadeIn > 0 {
                block = MoveProcessors.fade(block, length: clip.fadeIn,
                                            curve: clip.fadeCurve, isFadeIn: true)
            }
            if clip.fadeOut > 0 {
                block = MoveProcessors.fade(block, length: clip.fadeOut,
                                            curve: clip.fadeCurve, isFadeIn: false)
            }
            block = MoveProcessors.gain(block, dB: clip.gainDB)
            guard block.frameCount > 0 else { continue }

            let at = Double(offset) / rate
            joins.append(contentsOf: piece.joins.map { $0 + at })
            frames = max(frames, offset + block.frameCount)
            pieces.append((offset: offset, block: block))
        }

        guard frames > 0 else {
            return Rendered(block: PCMBlock(samples: [], sampleRate: rate, channelCount: channels),
                            joins: [])
        }

        // Added, not written: two clips that overlap are meant to be heard at
        // once, and a later clip overwriting an earlier one is what layering
        // is not.
        var mix = [Float](repeating: 0, count: frames * channels)
        for piece in pieces {
            let start = piece.offset * channels
            let count = piece.block.samples.count
            guard count > 0 else { continue }
            mix.withUnsafeMutableBufferPointer { destination in
                piece.block.samples.withUnsafeBufferPointer { source in
                    guard let base = destination.baseAddress,
                          let incoming = source.baseAddress else { return }
                    vDSP_vadd(base + start, 1, incoming, 1, base + start, 1, vDSP_Length(count))
                }
            }
        }

        var result = Rendered(
            block: PCMBlock(samples: mix, sampleRate: rate, channelCount: channels),
            joins: joins.sorted())
        for move in track.moves where move.isEnabled {
            try Task.checkCancellation()
            result = try apply(move.kind, to: result)
        }
        result.block = MoveProcessors.gain(result.block, dB: track.gainDB)
        result.block = Self.pan(result.block, position: track.pan)
        return result
    }

    /// Balance, not a constant-power sweep: centre is unity on both sides and
    /// hard over is silence on the far side, with nothing added anywhere.
    ///
    /// *Rejected:* the sine/cosine law. Normalised to unity at the centre it
    /// adds 3 dB to a hard-panned track, which can push a mix that was already
    /// sitting on its ceiling through it; normalised to unity at the extremes
    /// it takes 3 dB off every track in every existing document the moment this
    /// code ships, which is a silent level change nobody asked for.
    private nonisolated static func pan(_ block: PCMBlock, position: Double) -> PCMBlock {
        guard abs(position) > 1e-9, block.channelCount >= 2, !block.samples.isEmpty else {
            return block
        }
        let clamped = min(max(position, -1), 1)
        var left = Float(min(1, 1 - clamped))
        var right = Float(min(1, 1 + clamped))
        var output = block
        let stride = vDSP_Stride(block.channelCount)
        let frames = vDSP_Length(block.frameCount)
        output.samples.withUnsafeMutableBufferPointer { samples in
            guard let base = samples.baseAddress else { return }
            vDSP_vsmul(base, stride, &left, base, stride, frames)
            vDSP_vsmul(base + 1, stride, &right, base + 1, stride, frames)
        }
        return output
    }

    /// The audible tracks, added. Zero-padded to the longest, because a track
    /// stack that shortens one lane must not shorten the record.
    private nonisolated static func sum(_ lanes: [Rendered], format: MixFormat) -> Rendered {
        let channels = format.channelCount
        let blocks = lanes.map { matchChannels($0.block, to: channels) }
        let frames = blocks.map(\.frameCount).max() ?? 0
        guard frames > 0 else {
            return Rendered(
                block: PCMBlock(samples: [], sampleRate: format.sampleRate, channelCount: channels),
                joins: [])
        }
        if blocks.count == 1 {
            return Rendered(block: blocks[0], joins: lanes[0].joins)
        }

        var mix = [Float](repeating: 0, count: frames * channels)
        var joins: [TimeInterval] = []
        for (index, block) in blocks.enumerated() {
            joins.append(contentsOf: lanes[index].joins)
            let count = block.samples.count
            guard count > 0 else { continue }
            mix.withUnsafeMutableBufferPointer { destination in
                block.samples.withUnsafeBufferPointer { source in
                    guard let base = destination.baseAddress,
                          let incoming = source.baseAddress else { return }
                    vDSP_vadd(base, 1, incoming, 1, base, 1, vDSP_Length(count))
                }
            }
        }
        return Rendered(
            block: PCMBlock(samples: mix, sampleRate: format.sampleRate, channelCount: channels),
            joins: joins.sorted())
    }

    // MARK: - The mix's format

    /// The first source the timeline names sets the rate and the channel count,
    /// so a document with one file renders in that file's own format exactly as
    /// it always did.
    ///
    /// Read from the *pool*, not from the mute states: a muted track must not
    /// change the shape of the render, or muting the only stereo track would
    /// hand the player a mono buffer mid-session.
    private nonisolated static func mixFormat(_ document: EditorDocument,
                                              decoded: [EditorSource.ID: PCMBlock],
                                              needed: [EditorSource]) -> MixFormat {
        let leader = needed.first.flatMap { decoded[$0.id] }
        var rate = leader?.sampleRate ?? document.sources.first?.sampleRate ?? 48_000
        if !(rate > 0) { rate = 48_000 }
        var channels = max(1, leader?.channelCount ?? document.sources.first?.channelCount ?? 2)
        // A pan on a one-channel mix has nowhere to put the sound. The control
        // exists, so the mix widens to meet it rather than going quietly inert.
        if channels < 2, document.tracks.contains(where: { abs($0.pan) > 1e-9 }) {
            channels = 2
        }
        return MixFormat(sampleRate: rate, channelCount: channels)
    }

    private nonisolated static func conform(_ block: PCMBlock,
                                            to format: MixFormat) throws -> PCMBlock {
        // Channels first: folding to mono before resampling is half the work of
        // resampling and then folding, and the result is the same.
        var output = matchChannels(block, to: format.channelCount)
        if abs(output.sampleRate - format.sampleRate) > 0.5 {
            output = try resample(output, to: format.sampleRate)
        }
        return output
    }

    private nonisolated static func matchChannels(_ block: PCMBlock, to count: Int) -> PCMBlock {
        guard block.channelCount != count, block.channelCount > 0, count > 0 else { return block }
        if count == 1 { return MoveProcessors.channels(block, mode: .mono) }
        if count == 2 { return MoveProcessors.channels(block, mode: .stereo) }
        let lanes = (0..<count).map { block.channel(min($0, block.channelCount - 1)) }
        return PCMBlock.interleaving(lanes, sampleRate: block.sampleRate)
    }

    /// Sample-rate conversion through `AVAudioConverter`, the same converter
    /// `AudioFileIO.writeConverted` exports through, so a 44.1 kHz clip on a
    /// 48 kHz timeline arrives the same way whether it is played or written.
    private nonisolated static func resample(_ block: PCMBlock, to rate: Double) throws -> PCMBlock {
        guard block.frameCount > 0, block.sampleRate > 0, rate > 0 else { return block }
        guard let inputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                              sampleRate: block.sampleRate,
                                              channels: AVAudioChannelCount(block.channelCount),
                                              interleaved: true),
              let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                               sampleRate: rate,
                                               channels: AVAudioChannelCount(block.channelCount),
                                               interleaved: true),
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw Failure.mixedRates(block.sampleRate, rate)
        }
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue

        let chunk = 8192
        let channels = block.channelCount
        // The converter drives its input block synchronously on this thread, so
        // one box and no locking — the same shape `AudioFileIO` uses.
        let cursor = FrameCursor()
        let input: AVAudioConverterInputBlock = { _, status in
            let consumed = cursor.frames
            guard consumed < block.frameCount else {
                status.pointee = .endOfStream
                return nil
            }
            let count = min(chunk, block.frameCount - consumed)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: inputFormat,
                                                frameCapacity: AVAudioFrameCount(count)),
                  let destination = buffer.floatChannelData?[0] else {
                status.pointee = .endOfStream
                return nil
            }
            buffer.frameLength = AVAudioFrameCount(count)
            block.samples.withUnsafeBufferPointer { source in
                destination.update(from: source.baseAddress! + consumed * channels,
                                   count: count * channels)
            }
            cursor.frames = consumed + count
            status.pointee = .haveData
            return buffer
        }

        let ratio = rate / block.sampleRate
        let capacity = AVAudioFrameCount(Double(chunk) * ratio) + 8192
        var output: [Float] = []
        output.reserveCapacity(Int(Double(block.frameCount) * ratio) * channels + channels * chunk)

        while true {
            try Task.checkCancellation()
            guard let buffer = AVAudioPCMBuffer(pcmFormat: outputFormat,
                                                frameCapacity: capacity) else {
                throw Failure.mixedRates(block.sampleRate, rate)
            }
            var conversionError: NSError?
            let status = converter.convert(to: buffer,
                                           error: &conversionError,
                                           withInputFrom: input)
            if status == .error { throw Failure.mixedRates(block.sampleRate, rate) }
            let produced = Int(buffer.frameLength)
            if produced > 0, let samples = buffer.floatChannelData?[0] {
                output.append(contentsOf: UnsafeBufferPointer(start: samples,
                                                              count: produced * channels))
            }
            if status == .endOfStream { break }
            if status == .inputRanDry && produced == 0 { break }
        }
        return PCMBlock(samples: output, sampleRate: rate, channelCount: channels)
    }

    /// Single-threaded read cursor for the converter's input block. Unchecked
    /// because the converter drives the block synchronously from the calling
    /// thread — there is no second writer.
    private final class FrameCursor: @unchecked Sendable {
        var frames = 0
    }

    // MARK: - The pool

    private func source(for url: URL,
                        progress: @Sendable (Double) -> Void) throws -> PCMBlock {
        if let cached = pool[url] {
            progress(1)
            return cached
        }
        // `AudioFileIO.ProgressSink` returns the verdict as well as taking the
        // number: `false` aborts at the next chunk boundary. Answering with the
        // task's own cancellation makes a two-hour decode stop when the window
        // closes, rather than at the first `checkCancellation` after it.
        //
        // The contract's `progress` is non-escaping and the sink is escaping.
        // `decode` is synchronous and does not outlive this call, which is
        // exactly what `withoutActuallyEscaping` is for.
        let decoded = try withoutActuallyEscaping(progress) { sink in
            try AudioFileIO.decode(url, progress: { fraction in
                sink(fraction)
                return !Task.isCancelled
            })
        }
        pool[url] = decoded
        return decoded
    }

    /// Drops every decoded source. The store calls this when the document
    /// closes; two hours of Float32 stereo is about 1.4 GB per source and
    /// nothing else will free it.
    ///
    /// **This is the only thing that empties the pool, and it has to be.**
    /// Pruning to the document's own sources at the end of each render looks
    /// tidier and is wrong: `EditorClipWaveforms` asks this same engine about
    /// one source at a time, through a synthetic `EditorDocument(source:)`
    /// holding just that one, so a prune keyed on the document being rendered
    /// would throw away every other decode the mix needs each time the user
    /// zooms a lane. The bound is the set of files the user has open, which is
    /// the smallest set a multitrack render can be made from.
    func forgetCachedSource() {
        pool.removeAll()
        conformed.removeAll()
        conformedFormat = nil
    }

    // MARK: - One move

    private nonisolated func apply(_ kind: MoveKind, to rendered: Rendered) throws -> Rendered {
        let block = rendered.block
        let joins = rendered.joins

        // The four moves that move the timeline have to move the marks with it.
        switch kind {
        case .trim(let start, let end):
            let lower = min(start, end)
            let trimmed = MoveProcessors.trim(block, start: start, end: end)
            return Rendered(block: trimmed, joins: joins.compactMap {
                let shifted = $0 - lower
                return shifted > 0 && shifted < trimmed.duration ? shifted : nil
            })
        case .removeSilence(let thresholdDB, let minimumLength, let leaveTail):
            let removal = MoveProcessors.removeSilence(block,
                                                       thresholdDB: thresholdDB,
                                                       minimumLength: minimumLength,
                                                       leaveTail: leaveTail)
            return Rendered(block: removal.block,
                            joins: (joins.compactMap(removal.mapped) + removal.joins).sorted())
        case .reverse:
            let reversed = MoveProcessors.reverse(block)
            return Rendered(block: reversed,
                            joins: joins.map { reversed.duration - $0 }.sorted())
        case .speed(let rate):
            let stretched = try MoveProcessors.speed(block, rate: rate)
            let scale = block.duration > 0 ? stretched.duration / block.duration : 1
            return Rendered(block: stretched, joins: joins.map { $0 * scale })
        default:
            return Rendered(block: try applyLevel(kind, to: block), joins: joins)
        }
    }

    /// Everything that leaves the timeline alone.
    private nonisolated func applyLevel(_ kind: MoveKind, to block: PCMBlock) throws -> PCMBlock {
        switch kind {
        case .trim, .removeSilence, .reverse, .speed:
            return block                                   // handled in `apply`

        case .gain(let dB):
            return MoveProcessors.gain(block, dB: dB)
        case .normalize(let appliedGainDB, _, _):
            // The move carries the gain it resolved to, so a range render and a
            // full render cannot measure two different loudnesses and disagree.
            return MoveProcessors.gain(block, dB: appliedGainDB)
        case .limiter(let ceilingDBTP, let releaseMS):
            var limited = block
            try LookaheadLimiter.apply(&limited,
                                       ceilingDBTP: ceilingDBTP,
                                       releaseMS: releaseMS)
            return limited
        case .fadeIn(let length, let curve):
            return MoveProcessors.fade(block, length: length, curve: curve, isFadeIn: true)
        case .fadeOut(let length, let curve):
            return MoveProcessors.fade(block, length: length, curve: curve, isFadeIn: false)

        case .equalizer(let bands, let preampDB):
            return MoveProcessors.equalizer(block, bands: bands, preampDB: preampDB)
        case .highPass(let frequency):
            return MoveProcessors.highPass(block, frequency: frequency)
        case .noiseGate(let thresholdDB, let attackMS, let releaseMS):
            return MoveProcessors.noiseGate(block,
                                            thresholdDB: thresholdDB,
                                            attackMS: attackMS,
                                            releaseMS: releaseMS)

        case .channels(let mode):
            return MoveProcessors.channels(block, mode: mode)
        case .fixDCOffset(let measuredOffset):
            return MoveProcessors.fixDCOffset(block, offset: measuredOffset)
        }
    }

    enum Failure: LocalizedError {
        case emptyRender
        case mixedRates(Double, Double)

        var errorDescription: String? {
            switch self {
            case .emptyRender:
                return "That Chain leaves nothing to play."
            case .mixedRates:
                return "Those files record at rates Melo couldn't line up."
            }
        }
    }
}
