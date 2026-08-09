// Melo/Editor/DSP/SignalAnalysis.swift
import Accelerate
import Foundation

/// The measurements the report is made of, minus loudness and true peak, which
/// have files of their own.
enum SignalAnalysis {

    /// Where a run of near-silence sits on the timeline.
    struct SilenceMap: Sendable, Equatable {
        var leading: TimeInterval
        var trailing: TimeInterval
        var interior: [ClosedRange<TimeInterval>]
    }

    /// The window the silence and noise-floor scans step through. 10 ms is fine
    /// enough that a trim lands inside a syllable's decay and coarse enough that
    /// a two-hour file is 720 000 windows rather than tens of millions.
    static let scanWindow: TimeInterval = 0.010

    // MARK: - Level

    static func peakDBFS(_ block: PCMBlock) -> Double {
        guard !block.samples.isEmpty else { return -.infinity }
        var peak: Float = 0
        vDSP_maxmgv(block.samples, 1, &peak, vDSP_Length(block.samples.count))
        return 20 * log10(Double(max(peak, 1e-12)))
    }

    /// Samples sitting at or beyond digital full scale. The threshold is just
    /// below 1.0 so that material decoded from 16-bit, whose full scale is
    /// 32767/32768 = 0.99997, is counted rather than missed by a hair.
    static func clippedSampleCount(_ block: PCMBlock) -> Int {
        var count = 0
        for sample in block.samples where abs(sample) >= 0.9999 { count += 1 }
        return count
    }

    /// The largest per-channel mean. A stereo file with +0.01 on the left and
    /// −0.01 on the right has a DC problem that a whole-file mean would report
    /// as zero.
    static func dcOffset(_ block: PCMBlock) -> Double {
        var worst = 0.0
        for index in 0..<block.channelCount {
            let samples = block.channel(index)
            guard !samples.isEmpty else { continue }
            var mean: Float = 0
            vDSP_meanv(samples, 1, &mean, vDSP_Length(samples.count))
            if abs(Double(mean)) > abs(worst) { worst = Double(mean) }
        }
        return worst
    }

    /// Tenth percentile of the windowed RMS. The tenth rather than the minimum
    /// because the minimum of any real recording is one digitally silent window
    /// at the head of the file, which measures the encoder, not the room.
    static func noiseFloorDBFS(_ block: PCMBlock) -> Double {
        let levels = windowLevelsDBFS(block)
        guard !levels.isEmpty else { return -.infinity }
        let sorted = levels.sorted()
        let index = min(sorted.count - 1, Int(Double(sorted.count) * 0.1))
        return sorted[index]
    }

    /// True when the channels carry the same signal. The test is on the side
    /// component, because two channels can differ in level by 20 dB and still
    /// be one mono source panned, whereas a side component 40 dB down is one
    /// signal plus dither.
    static func isEffectivelyMono(_ block: PCMBlock) -> Bool {
        guard block.channelCount >= 2, block.frameCount > 0 else { return true }
        let left = block.channel(0)
        let right = block.channel(1)
        var side = [Float](repeating: 0, count: left.count)
        vDSP.subtract(left, right, result: &side)
        var mid = [Float](repeating: 0, count: left.count)
        vDSP.add(left, right, result: &mid)

        var sideRMS: Float = 0
        var midRMS: Float = 0
        vDSP_rmsqv(side, 1, &sideRMS, vDSP_Length(side.count))
        vDSP_rmsqv(mid, 1, &midRMS, vDSP_Length(mid.count))
        guard midRMS > 1e-9 else { return true }
        return 20 * log10(sideRMS / midRMS) < -40
    }

    // MARK: - Silence

    /// Runs whose windowed RMS stays under `thresholdDB`. A run touching frame
    /// zero is leading, a run touching the last frame is trailing, and the rest
    /// are interior if they last at least `minimumLength`.
    static func silences(_ block: PCMBlock,
                         thresholdDB: Double,
                         minimumLength: TimeInterval,
                         window: TimeInterval = scanWindow) -> SilenceMap {
        let levels = windowLevelsDBFS(block, window: window)
        guard !levels.isEmpty else {
            return SilenceMap(leading: 0, trailing: 0, interior: [])
        }

        var leading: TimeInterval = 0
        var trailing: TimeInterval = 0
        var interior: [ClosedRange<TimeInterval>] = []

        var runStart: Int? = nil
        for index in 0...levels.count {
            let quiet = index < levels.count && levels[index] <= thresholdDB
            if quiet {
                if runStart == nil { runStart = index }
                continue
            }
            guard let start = runStart else { continue }
            let end = index
            let startTime = Double(start) * window
            let endTime = min(Double(end) * window, block.duration)
            if start == 0 {
                leading = endTime
            } else if end == levels.count {
                trailing = block.duration - startTime
            } else if endTime - startTime >= minimumLength {
                interior.append(startTime...endTime)
            }
            runStart = nil
        }

        return SilenceMap(leading: leading, trailing: trailing, interior: interior)
    }

    /// The threshold the *report* uses, as opposed to the one the user sets on
    /// a `removeSilence` move. It sits 6 dB over the measured noise floor so a
    /// hissy field recording is not reported as having no silence at all and a
    /// clean studio track is not reported as silent between every word, and it
    /// is clamped so neither extreme can run away.
    static func reportingSilenceThresholdDB(noiseFloorDBFS: Double) -> Double {
        min(max(noiseFloorDBFS + 6, -70), -35)
    }

    /// Windowed RMS in dBFS, one entry per `window` seconds, energy summed over
    /// every channel.
    static func windowLevelsDBFS(_ block: PCMBlock,
                                 window: TimeInterval = scanWindow) -> [Double] {
        let frames = block.frameCount
        let windowFrames = max(1, Int((window * block.sampleRate).rounded()))
        guard frames >= windowFrames else { return [] }

        let count = frames / windowFrames
        let stride = windowFrames * block.channelCount
        var levels = [Double](repeating: 0, count: count)
        block.samples.withUnsafeBufferPointer { samples in
            guard let base = samples.baseAddress else { return }
            for index in 0..<count {
                var rms: Float = 0
                vDSP_rmsqv(base + index * stride, 1, &rms, vDSP_Length(stride))
                levels[index] = 20 * log10(Double(max(rms, 1e-12)))
            }
        }
        return levels
    }

    // MARK: - Spectral tilt

    /// Slope of the average spectrum in dB per octave, fitted over third-octave
    /// bands from 100 Hz to 10 kHz. Negative means the top is rolling off.
    ///
    /// Two decisions here. The spectrum is averaged over up to 64 windows
    /// spread evenly through the file rather than over every window: 64 × 8192
    /// samples is a stable average of a whole programme, and FFT-ing all of a
    /// two-hour file to produce one number is work nobody asked for. And the
    /// fit is over third-octave bands rather than raw bins, because bins are
    /// linearly spaced — a straight regression on them is dominated by the top
    /// octave, which holds half of them.
    static func spectralTiltDBPerOctave(_ block: PCMBlock) -> Double {
        let mono = block.monoSum()
        var size = 8192
        while size > mono.count { size /= 2 }
        guard size >= 1024 else { return 0 }

        let log2n = vDSP_Length(log2(Double(size)))
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return 0 }
        defer { vDSP_destroy_fftsetup(setup) }

        let half = size / 2
        var window = [Float](repeating: 0, count: size)
        vDSP_hann_window(&window, vDSP_Length(size), Int32(vDSP_HANN_NORM))

        let available = mono.count / size
        let windowCount = min(64, max(1, available))
        let step = max(1, available / windowCount)

        var spectrum = [Double](repeating: 0, count: half)
        var real = [Float](repeating: 0, count: half)
        var imaginary = [Float](repeating: 0, count: half)
        var windowed = [Float](repeating: 0, count: size)
        var magnitudes = [Float](repeating: 0, count: half)
        var used = 0

        for index in Swift.stride(from: 0, to: available, by: step) {
            if used >= windowCount { break }
            let start = index * size
            vDSP_vmul(Array(mono[start..<(start + size)]), 1, window, 1, &windowed, 1, vDSP_Length(size))
            real.withUnsafeMutableBufferPointer { realPtr in
                imaginary.withUnsafeMutableBufferPointer { imagPtr in
                    var split = DSPSplitComplex(realp: realPtr.baseAddress!,
                                                imagp: imagPtr.baseAddress!)
                    windowed.withUnsafeBufferPointer { source in
                        source.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                            vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
                        }
                    }
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                    vDSP_zvmags(&split, 1, &magnitudes, 1, vDSP_Length(half))
                }
            }
            for bin in 0..<half { spectrum[bin] += Double(magnitudes[bin]) }
            used += 1
        }
        guard used > 0 else { return 0 }

        // Third-octave bands, averaged per bin so bands of different widths are
        // comparable, then a least-squares line through (log2 f, dB).
        let binWidth = block.sampleRate / Double(size)
        let topFrequency = min(10_000.0, block.sampleRate * 0.45)
        guard topFrequency > 200 else { return 0 }

        var sumX = 0.0, sumY = 0.0, sumXY = 0.0, sumXX = 0.0, points = 0.0
        var centre = 100.0
        let ratio = pow(2.0, 1.0 / 3.0)
        while centre <= topFrequency {
            let lower = centre / pow(2.0, 1.0 / 6.0)
            let upper = centre * pow(2.0, 1.0 / 6.0)
            let firstBin = max(1, Int(lower / binWidth))
            let lastBin = min(half - 1, Int(upper / binWidth))
            centre *= ratio
            guard lastBin >= firstBin else { continue }

            var energy = 0.0
            for bin in firstBin...lastBin { energy += spectrum[bin] }
            energy /= Double(lastBin - firstBin + 1)
            guard energy > 0 else { continue }

            let x = log2(centre / ratio)
            let y = 10 * log10(energy)
            sumX += x; sumY += y; sumXY += x * y; sumXX += x * x; points += 1
        }

        guard points >= 4 else { return 0 }
        let denominator = points * sumXX - sumX * sumX
        guard abs(denominator) > 1e-12 else { return 0 }
        return (points * sumXY - sumX * sumY) / denominator
    }
}
