// Melo/Editor/DSP/MoveProcessors.swift
import AVFoundation
import Accelerate
import Foundation

/// One function per `MoveKind`. Each takes a block and returns the block the
/// move produces; nothing here reads the document or the stack, so a move can
/// be tested on a synthetic buffer with no file and no UI.
enum MoveProcessors {

    // MARK: - Level

    static func gain(_ block: PCMBlock, dB: Double) -> PCMBlock {
        guard abs(dB) > 1e-9, !block.samples.isEmpty else { return block }
        var output = block
        var scale = LoudnessEqualizerMath.dbToLinear(Float(dB))
        output.samples.withUnsafeMutableBufferPointer { samples in
            vDSP_vsmul(samples.baseAddress!, 1, &scale,
                       samples.baseAddress!, 1, vDSP_Length(samples.count))
        }
        return output
    }

    static func fixDCOffset(_ block: PCMBlock, offset: Double) -> PCMBlock {
        guard abs(offset) > 1e-9, !block.samples.isEmpty else { return block }
        var output = block
        var shift = Float(-offset)
        output.samples.withUnsafeMutableBufferPointer { samples in
            vDSP_vsadd(samples.baseAddress!, 1, &shift,
                       samples.baseAddress!, 1, vDSP_Length(samples.count))
        }
        return output
    }

    /// `length` seconds of fade at the head (`isFadeIn`) or the tail.
    ///
    /// Equal power is `sin(t·π/2)`, which holds constant power across a
    /// crossfade. Exponential is `t²`, the shape editors label exponential — a
    /// literal exponential never reaches zero, so it would need a floor picked
    /// out of the air and would still not silence the start of a fade-in.
    static func fade(_ block: PCMBlock,
                     length: TimeInterval,
                     curve: FadeCurve,
                     isFadeIn: Bool) -> PCMBlock {
        let frames = min(block.frameCount, Int((length * block.sampleRate).rounded()))
        guard frames > 1 else { return block }

        var output = block
        let channels = block.channelCount
        output.samples.withUnsafeMutableBufferPointer { samples in
            guard let base = samples.baseAddress else { return }
            for step in 0..<frames {
                let position = Double(step) / Double(frames - 1)
                let t = isFadeIn ? position : 1 - position
                let gain = Float(curveValue(t, curve: curve))
                let frame = isFadeIn ? step : block.frameCount - frames + step
                for channel in 0..<channels {
                    base[frame * channels + channel] *= gain
                }
            }
        }
        return output
    }

    private static func curveValue(_ t: Double, curve: FadeCurve) -> Double {
        switch curve {
        case .linear: return t
        case .equalPower: return sin(t * .pi / 2)
        case .exponential: return t * t
        }
    }

    // MARK: - Tone

    static func highPass(_ block: PCMBlock, frequency: Double) -> PCMBlock {
        guard frequency > 0, frequency < block.sampleRate / 2 else { return block }
        let coefficients = BiquadMath.highPassCoefficients(
            frequency: frequency, q: 1 / 2.0.squareRoot(), sampleRate: block.sampleRate)
        guard let chain = OfflineBiquadChain(coefficients: coefficients, sectionCount: 1) else {
            return block
        }
        var output = block
        chain.process(&output)
        return output
    }

    static func equalizer(_ block: PCMBlock,
                          bands: [AutoEQFilter],
                          preampDB: Double) -> PCMBlock {
        var output = preampDB.magnitude > 1e-9 ? gain(block, dB: preampDB) : block
        guard !bands.isEmpty else { return output }

        // `profileOptimizedRate` is the block's own rate: these bands were
        // authored against this file in the editor, not imported from an
        // AutoEQ profile measured at 48 kHz, so there is nothing to pre-warp.
        let coefficients = BiquadMath.coefficientsForAutoEQFilters(
            bands, sampleRate: block.sampleRate, profileOptimizedRate: block.sampleRate)
        guard let chain = OfflineBiquadChain(coefficients: coefficients,
                                             sectionCount: bands.count) else {
            return output
        }
        chain.process(&output)
        return output
    }

    /// Downward gate. The detector is linked across channels, so a gate never
    /// opens on one side of a stereo image and not the other.
    ///
    /// The 50 ms hold is not in the move's parameters and is not meant to be:
    /// without one, a gate chatters open and shut inside every syllable that
    /// crosses the threshold, and the fix for that is a hold, not a slower
    /// release the user has to discover.
    static func noiseGate(_ block: PCMBlock,
                          thresholdDB: Double,
                          attackMS: Double,
                          releaseMS: Double) -> PCMBlock {
        let frames = block.frameCount
        guard frames > 0 else { return block }

        let threshold = LoudnessEqualizerMath.dbToLinear(Float(thresholdDB))
        let stepMS = Float(1000.0 / block.sampleRate)
        let attack = LoudnessEqualizerMath.timeConstantCoefficient(
            timeMs: Float(max(attackMS, 0.1)), stepMs: stepMS)
        let release = LoudnessEqualizerMath.timeConstantCoefficient(
            timeMs: Float(max(releaseMS, 1)), stepMs: stepMS)
        // Detector follows peaks with a 10 ms decay so a waveform's own zero
        // crossings do not read as the signal going away.
        let detectorDecay = LoudnessEqualizerMath.timeConstantCoefficient(
            timeMs: 10, stepMs: stepMS)
        let holdFrames = Int(0.050 * block.sampleRate)
        // 3 dB of hysteresis: the gate shuts at a lower level than it opened.
        let closeThreshold = threshold * LoudnessEqualizerMath.dbToLinear(-3)

        var output = block
        let channels = block.channelCount
        var detector: Float = 0
        var gain: Float = 0
        var open = false
        var heldFor = 0

        output.samples.withUnsafeMutableBufferPointer { samples in
            guard let base = samples.baseAddress else { return }
            for frame in 0..<frames {
                var magnitude: Float = 0
                for channel in 0..<channels {
                    magnitude = max(magnitude, abs(base[frame * channels + channel]))
                }
                if magnitude > detector {
                    detector = magnitude
                } else {
                    detector += (magnitude - detector) * detectorDecay
                }

                if open {
                    if detector < closeThreshold {
                        heldFor += 1
                        if heldFor >= holdFrames { open = false }
                    } else {
                        heldFor = 0
                    }
                } else if detector > threshold {
                    open = true
                    heldFor = 0
                }

                let target: Float = open ? 1 : 0
                gain += (target - gain) * (target > gain ? attack : release)
                for channel in 0..<channels {
                    base[frame * channels + channel] *= gain
                }
            }
        }
        return output
    }

    // MARK: - Shape

    /// `.mono` produces a one-channel block, not a two-channel block carrying
    /// the same signal twice. The live path duplicates because it has to hand
    /// the device a stereo stream; an export has no such constraint and a mono
    /// file is half the size.
    static func channels(_ block: PCMBlock, mode: ChannelMode) -> PCMBlock {
        switch mode {
        case .keep:
            return block
        case .mono:
            guard block.channelCount != 1 else { return block }
            return PCMBlock(samples: block.monoSum(),
                            sampleRate: block.sampleRate,
                            channelCount: 1)
        case .stereo:
            guard block.channelCount != 2 else { return block }
            if block.channelCount == 1 {
                return PCMBlock.interleaving([block.samples, block.samples],
                                             sampleRate: block.sampleRate)
            }
            return PCMBlock.interleaving([block.channel(0), block.channel(1)],
                                         sampleRate: block.sampleRate)
        }
    }

    /// The last clamp on the render, always applied, never a move. Same call
    /// the live path makes at `ProcessTapController.swift:1955`.
    static func safetyClip(_ block: PCMBlock) -> PCMBlock {
        guard !block.samples.isEmpty else { return block }
        var output = block
        output.samples.withUnsafeMutableBufferPointer { samples in
            SoftLimiter.processBuffer(samples.baseAddress!, sampleCount: samples.count)
        }
        return output
    }

    // MARK: - Timeline

    static func trim(_ block: PCMBlock, start: TimeInterval, end: TimeInterval) -> PCMBlock {
        let lower = min(start, end)
        let upper = max(start, end)
        return block.slice(lower...upper)
    }

    static func reverse(_ block: PCMBlock) -> PCMBlock {
        guard block.frameCount > 1 else { return block }
        var output = block
        let channels = block.channelCount
        let frames = block.frameCount
        output.samples.withUnsafeMutableBufferPointer { samples in
            guard let base = samples.baseAddress else { return }
            for channel in 0..<channels {
                vDSP_vrvrs(base + channel, vDSP_Stride(channels), vDSP_Length(frames))
            }
        }
        return output
    }

    /// Shortens every run of near-silence at least `minimumLength` long to
    /// `leaveTail` seconds, keeping half of what is left at each end of the gap
    /// so both the decay of the previous sound and the breath before the next
    /// one survive. Each join dips through zero over 5 ms either side; both
    /// sides are already under the threshold, but the threshold is the user's
    /// and can be set high enough that a hard splice would tick.
    /// What a silence removal did, not just what it produced.
    ///
    /// The splice positions are returned rather than recomputed downstream: the
    /// waveform has to draw where the sound was cut, and a second silence
    /// detector on the drawing side that has to agree with this one is the
    /// defect class recorded at `CLAUDE.md:138`. This function already knows;
    /// it now says.
    struct SilenceRemoval: Sendable {
        var block: PCMBlock
        /// Splices this removal created, on `block`'s own timeline.
        var joins: [TimeInterval]
        /// Kept spans as `(first source frame, first output frame, length)`,
        /// which is what maps a time across the edit.
        var spans: [(source: Int, output: Int, length: Int)]

        /// A time on the input timeline, expressed on the output timeline.
        /// `nil` when it fell inside a run that was removed.
        func mapped(_ time: TimeInterval) -> TimeInterval? {
            guard !spans.isEmpty else { return time }
            let frame = Int((time * block.sampleRate).rounded())
            for span in spans where frame >= span.source && frame < span.source + span.length {
                return Double(span.output + frame - span.source) / block.sampleRate
            }
            return nil
        }
    }

    static func removeSilence(_ block: PCMBlock,
                              thresholdDB: Double,
                              minimumLength: TimeInterval,
                              leaveTail: TimeInterval) -> SilenceRemoval {
        let frames = block.frameCount
        let whole = SilenceRemoval(block: block, joins: [],
                                   spans: [(source: 0, output: 0, length: frames)])
        guard frames > 0 else { return whole }

        let window: TimeInterval = 0.005
        let map = SignalAnalysis.silences(block,
                                          thresholdDB: thresholdDB,
                                          minimumLength: minimumLength,
                                          window: window)
        var runs: [ClosedRange<TimeInterval>] = map.interior
        if map.leading >= minimumLength { runs.append(0...map.leading) }
        if map.trailing >= minimumLength {
            runs.append((block.duration - map.trailing)...block.duration)
        }
        guard !runs.isEmpty else { return whole }
        runs.sort { $0.lowerBound < $1.lowerBound }

        let channels = block.channelCount
        let keepFrames = max(0, Int((leaveTail * block.sampleRate).rounded()))
        var kept: [Float] = []
        kept.reserveCapacity(block.samples.count)
        var spans: [(source: Int, output: Int, length: Int)] = []
        var joins: [TimeInterval] = []

        var cursor = 0
        for run in runs {
            let start = block.frameIndex(at: run.lowerBound)
            let end = block.frameIndex(at: run.upperBound)
            guard end > start, end - start > keepFrames, start + keepFrames / 2 >= cursor else {
                continue
            }
            let head = keepFrames / 2
            let spanEnd = start + head
            let outputStart = kept.count / channels
            kept.append(contentsOf: block.samples[(cursor * channels)..<(spanEnd * channels)])
            spans.append((source: cursor, output: outputStart, length: spanEnd - cursor))
            joins.append(Double(kept.count / channels) / block.sampleRate)
            cursor = end - (keepFrames - head)
        }
        let finalStart = kept.count / channels
        kept.append(contentsOf: block.samples[(cursor * channels)...])
        spans.append((source: cursor, output: finalStart, length: frames - cursor))

        var output = PCMBlock(samples: kept,
                              sampleRate: block.sampleRate,
                              channelCount: channels)
        for join in joins { softenJoin(&output, atFrame: output.frameIndex(at: join)) }

        // A join at the very first or very last frame is not a splice the
        // picture should mark: the sound simply starts or stops there.
        let inside = joins.filter { $0 > 1e-9 && $0 < output.duration - 1e-9 }
        return SilenceRemoval(block: output, joins: inside, spans: spans)
    }

    private static func softenJoin(_ block: inout PCMBlock, atFrame frame: Int) {
        let span = max(1, Int(0.005 * block.sampleRate))
        let first = max(0, frame - span)
        let last = min(block.frameCount, frame + span)
        guard last > first else { return }
        let channels = block.channelCount
        block.samples.withUnsafeMutableBufferPointer { samples in
            guard let base = samples.baseAddress else { return }
            for index in first..<last {
                let distance = Double(abs(index - frame)) / Double(span)
                let gain = Float(distance)
                for channel in 0..<channels {
                    base[index * channels + channel] *= gain
                }
            }
        }
    }

    // MARK: - Speed

    /// Rate change with pitch preserved.
    ///
    /// `AVAudioUnitTimePitch` inside an `AVAudioEngine` in
    /// `enableManualRenderingMode(.offline,…)` is the route: it is the same
    /// time-stretcher the rest of the system uses, it is offline-safe, and the
    /// alternative — writing a phase vocoder — is a month of work to arrive
    /// somewhere worse. The unit's own latency is rendered and discarded so the
    /// result starts where the source did.
    static func speed(_ block: PCMBlock, rate: Double) throws -> PCMBlock {
        let clamped = min(max(rate, 0.5), 2.0)
        guard abs(clamped - 1) > 1e-6, block.frameCount > 0 else { return block }
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: block.sampleRate,
                                         channels: AVAudioChannelCount(block.channelCount),
                                         interleaved: false),
              let input = AVAudioPCMBuffer(pcmFormat: format,
                                           frameCapacity: AVAudioFrameCount(block.frameCount)),
              let channelData = input.floatChannelData else {
            return block
        }

        input.frameLength = AVAudioFrameCount(block.frameCount)
        for channel in 0..<block.channelCount {
            let samples = block.channel(channel)
            samples.withUnsafeBufferPointer { source in
                channelData[channel].update(from: source.baseAddress!, count: samples.count)
            }
        }

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let timePitch = AVAudioUnitTimePitch()
        timePitch.rate = Float(clamped)
        engine.attach(player)
        engine.attach(timePitch)
        engine.connect(player, to: timePitch, format: format)
        engine.connect(timePitch, to: engine.outputNode, format: format)

        let renderChunk: AVAudioFrameCount = 4096
        try engine.enableManualRenderingMode(.offline, format: format,
                                             maximumFrameCount: renderChunk)
        defer { engine.disableManualRenderingMode() }

        player.scheduleBuffer(input, at: nil, options: [], completionHandler: nil)
        try engine.start()
        player.play()
        defer { engine.stop() }

        let latencyFrames = Int((timePitch.auAudioUnit.latency * block.sampleRate).rounded())
        let expected = Int((Double(block.frameCount) / clamped).rounded())
        let total = expected + latencyFrames

        guard let scratch = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat,
                                             frameCapacity: renderChunk),
              let scratchData = scratch.floatChannelData else {
            return block
        }

        var collected = [[Float]](repeating: [], count: block.channelCount)
        for index in 0..<block.channelCount { collected[index].reserveCapacity(total) }

        while engine.manualRenderingSampleTime < AVAudioFramePosition(total) {
            try Task.checkCancellation()
            let remaining = total - Int(engine.manualRenderingSampleTime)
            let ask = AVAudioFrameCount(min(Int(renderChunk), remaining))
            let status = try engine.renderOffline(ask, to: scratch)
            guard status == .success, scratch.frameLength > 0 else { break }
            let produced = Int(scratch.frameLength)
            for channel in 0..<block.channelCount {
                collected[channel].append(
                    contentsOf: UnsafeBufferPointer(start: scratchData[channel], count: produced))
            }
        }

        for channel in 0..<block.channelCount {
            if collected[channel].count > latencyFrames {
                collected[channel].removeFirst(latencyFrames)
            }
            if collected[channel].count > expected {
                collected[channel].removeLast(collected[channel].count - expected)
            }
        }
        guard let produced = collected.first?.count, produced > 0 else { return block }
        return PCMBlock.interleaving(collected, sampleRate: block.sampleRate)
    }
}
