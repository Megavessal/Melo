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
/// The stack is walked in the order the user put it in. The chain the contract
/// names — gain → EQ → noise gate → normalize → limiter → channel mode → safety
/// clip, mirroring `ProcessTapController.swift:1700-1956` — is the order the
/// proposer builds the stack in, so a document nobody has reordered renders
/// through exactly the live path's chain. The safety clip is not a move and is
/// not in the stack: it is applied last, always.
actor RenderEngine {

    /// Decoded source, kept between calls. Analysis, the waveform and every
    /// preview render all start from the same decode, and decoding is the
    /// slowest thing here by a wide margin. One entry: the editor holds one
    /// sound, so a second entry would only ever be the file the user just left.
    private var cachedSourceURL: URL?
    private var cachedSource: PCMBlock?

    init() {}

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
    /// empty stack measures the source, and a stack that already carries a
    /// high-pass measures the file with the high-pass in. The alternative,
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
        /// there is nothing left to recover it from.
        var joins: [TimeInterval]
    }

    private func renderBlock(_ document: EditorDocument,
                             progress: @Sendable (Double) -> Void) throws -> Rendered {
        let decodeShare = 0.35
        var result = Rendered(
            block: try source(for: document.source.url) { fraction in
                progress(fraction * decodeShare)
            },
            joins: [])

        let moves = document.moves.filter(\.isEnabled)
        for (index, move) in moves.enumerated() {
            try Task.checkCancellation()
            result = try apply(move.kind, to: result)
            progress(decodeShare + (1 - decodeShare) * Double(index + 1) / Double(moves.count + 1))
        }

        result.block = MoveProcessors.safetyClip(result.block)
        progress(1)
        return result
    }

    private func source(for url: URL,
                        progress: @Sendable (Double) -> Void) throws -> PCMBlock {
        if cachedSourceURL == url, let cachedSource {
            progress(1)
            return cachedSource
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
        cachedSourceURL = url
        cachedSource = decoded
        return decoded
    }

    /// Drops the decoded source. The store calls this when the document closes;
    /// two hours of Float32 stereo is about 1.4 GB and nothing else will free it.
    func forgetCachedSource() {
        cachedSourceURL = nil
        cachedSource = nil
    }

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

        var errorDescription: String? {
            switch self {
            case .emptyRender:
                return "That stack leaves nothing to play."
            }
        }
    }
}
