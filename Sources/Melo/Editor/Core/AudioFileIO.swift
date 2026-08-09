// Melo/Editor/Core/AudioFileIO.swift
//
// Decode, probe, encode. The whole of audio file I/O for the Cutting Room —
// nothing in Melo read or wrote an audio file before this except the onboarding
// theme, so there is nothing here to reuse and nothing here to duplicate.
//
// `decode` and `probe` are synchronous and throwing, and everything here is
// meant to be called off the main thread — `RenderEngine` and the export job
// own the threading. `encode` is async, because MP3 and Opus go out through a
// child process and there is no honest way to await one from a sync function.

import AVFoundation
import Accelerate
import Foundation
import UniformTypeIdentifiers
import os

enum AudioFileIO {

    /// Two hours. Interleaved Float32 is about 690 MB an hour at 48 kHz stereo,
    /// so this is roughly a 1.4 GB ceiling on one decoded source. Past it
    /// `decode` throws `Failure.tooLong` — it never truncates, and it never
    /// quietly allocates eight gigabytes.
    static let maximumDuration: TimeInterval = 2 * 60 * 60

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Melo",
        category: "AudioFileIO"
    )

    /// Frames per read/write pass. 64k frames is ~1.4 s at 48 kHz: small enough
    /// that progress moves visibly on a long file, large enough that the
    /// per-chunk overhead disappears. It is also the interruption granularity —
    /// see `ProgressSink`.
    private static let chunkFrames = 65_536

    /// Progress *and* the stop button, in one closure.
    ///
    /// Returning `false` means abort, and the operation throws
    /// `CancellationError` at the next chunk boundary. This used to return
    /// `Void`, which made both `decode` and `encode` uninterruptible: the UI
    /// said "Stopping" the instant it was pressed and then the work ran to
    /// completion anyway, so on a long file the control was telling the truth
    /// about intent and a lie about effect.
    ///
    /// A `Bool` rather than `Task.isCancelled` inside the loop because the
    /// caller's notion of "stop" is not always task cancellation — a job the
    /// user cancelled, a superseded render, a closed window — and one sink that
    /// carries both the number and the verdict keeps that decision at the
    /// caller where it belongs.
    typealias ProgressSink = @Sendable (Double) -> Bool

    /// Reports `fraction` and honours a refusal.
    @inline(__always)
    private static func report(_ sink: ProgressSink?, _ fraction: Double) throws {
        if sink?(fraction) == false { throw CancellationError() }
    }

    // MARK: - Failures

    enum Failure: LocalizedError, Equatable {
        case unreadable(URL)
        case noAudioTrack(URL)
        case tooLong(TimeInterval)
        case encodeFailed(String)
        case toolMissing(ExternalTool)

        var errorDescription: String? {
            switch self {
            case let .unreadable(url):
                "Melo couldn't read \(url.lastPathComponent)."
            case let .noAudioTrack(url):
                "\(url.lastPathComponent) has no audio in it."
            case let .tooLong(duration):
                "That file is \(EditorFormat.timecode(duration)) long, and the Cutting Room works up to two hours."
            case let .encodeFailed(reason):
                "Melo couldn't finish writing the file. \(reason)"
            case let .toolMissing(tool):
                "That format needs \(tool.executableName), which isn't on this Mac."
            }
        }

        var recoverySuggestion: String? {
            switch self {
            case .unreadable:
                "The file may be damaged, or in a format macOS doesn't decode."
            case .noAudioTrack:
                "Pick a file with an audio track."
            case .tooLong:
                "Trim it down first, or open a shorter piece of it."
            case .encodeFailed:
                nil
            case let .toolMissing(tool):
                tool.installHint
            }
        }
    }

    // MARK: - Importable types

    /// What the open panel offers. `.audio` and `.movie` are the broad nets;
    /// the named types are there so the panel's format list reads like a list
    /// of formats rather than "Audio".
    static var importableTypes: [UTType] {
        var types: [UTType] = [
            .audio, .mp3, .wav, .aiff, .mpeg4Audio,
            .movie, .mpeg4Movie, .quickTimeMovie
        ]
        for identifier in ["org.xiph.flac", "org.xiph.opus", "public.ogg", "com.apple.m4v-video"] {
            if let type = UTType(identifier) { types.append(type) }
        }
        return types
    }

    // MARK: - Decode

    /// Decodes anything AVFoundation can open into the canonical interleaved
    /// Float32 block.
    ///
    /// Two paths, and which one runs is decided by *asking* rather than by
    /// guessing from the extension: `AVAudioFile(forReading:)` is tried first
    /// and used when it opens the file, and `AVAssetReader` handles everything
    /// else — `.mp4`, `.mov`, `.m4v`, and any other container where the audio
    /// has to be pulled out of a track. An extension allowlist would be wrong
    /// in both directions, because `AVAudioFile` opens more than the obvious
    /// list and fails on some files that look like it should not.
    static func decode(_ url: URL, progress: ProgressSink? = nil) throws -> PCMBlock {
        if let file = try? AVAudioFile(forReading: url) {
            return try decodeAudioFile(file, url: url, progress: progress)
        }
        return try decodeAssetTrack(url, progress: progress)
    }

    private static func decodeAudioFile(
        _ file: AVAudioFile,
        url: URL,
        progress: ProgressSink?
    ) throws -> PCMBlock {
        // `processingFormat` is deinterleaved Float32 at the file's own rate.
        // The interleave below is the single place sample order can go wrong
        // for this path, and a mistake there is silent.
        let format = file.processingFormat
        let channels = Int(format.channelCount)
        let sampleRate = format.sampleRate
        let totalFrames = Int(file.length)

        guard channels > 0, sampleRate > 0, totalFrames > 0 else {
            throw Failure.unreadable(url)
        }

        let duration = Double(totalFrames) / sampleRate
        guard duration <= maximumDuration else { throw Failure.tooLong(duration) }

        guard let scratch = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(chunkFrames)
        ) else { throw Failure.unreadable(url) }

        var samples = [Float](repeating: 0, count: totalFrames * channels)
        var decoded = 0
        try report(progress, 0)

        while decoded < totalFrames {
            let wanted = min(chunkFrames, totalFrames - decoded)
            do {
                try file.read(into: scratch, frameCount: AVAudioFrameCount(wanted))
            } catch {
                logger.error("Decode failed at frame \(decoded): \(error.localizedDescription)")
                throw Failure.unreadable(url)
            }
            let got = Int(scratch.frameLength)
            if got == 0 { break }

            samples.withUnsafeMutableBufferPointer { output in
                interleave(
                    scratch,
                    into: output.baseAddress! + decoded * channels,
                    frames: got,
                    channels: channels
                )
            }
            decoded += got
            try report(progress, Double(decoded) / Double(totalFrames))
        }

        // A file can report more frames than it hands over. Shrink rather than
        // leave a tail of zeroes that every measurement would then read.
        if decoded < totalFrames {
            samples.removeLast((totalFrames - decoded) * channels)
        }
        try report(progress, 1)

        return PCMBlock(samples: samples, sampleRate: sampleRate, channelCount: channels)
    }

    private static func decodeAssetTrack(
        _ url: URL,
        progress: ProgressSink?
    ) throws -> PCMBlock {
        let asset = AVURLAsset(url: url)
        // Synchronous accessors, deprecated since macOS 13 in favour of the
        // async `load(_:)` family. `AudioFileIO` is synchronous throughout, and
        // bridging async to sync with a semaphore on the cooperative pool is a
        // worse trade than a deprecation warning.
        let audioTracks = asset.tracks(withMediaType: .audio)
        guard let track = audioTracks.first else {
            throw asset.tracks.isEmpty ? Failure.unreadable(url) : Failure.noAudioTrack(url)
        }

        let assetDuration = CMTimeGetSeconds(asset.duration)
        if assetDuration.isFinite, assetDuration > maximumDuration {
            throw Failure.tooLong(assetDuration)
        }

        guard let reader = try? AVAssetReader(asset: asset) else {
            throw Failure.unreadable(url)
        }
        // Ask the reader for exactly the canonical format, so there is no
        // second interleaving step for this path.
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw Failure.unreadable(url) }
        reader.add(output)
        guard reader.startReading() else { throw Failure.unreadable(url) }
        defer { if reader.status == .reading { reader.cancelReading() } }

        var samples: [Float] = []
        var sampleRate: Double = 0
        var channels = 0
        try report(progress, 0)

        while let sampleBuffer = output.copyNextSampleBuffer() {
            if channels == 0 {
                guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
                      let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
                      asbd.mChannelsPerFrame > 0, asbd.mSampleRate > 0
                else { continue }
                sampleRate = asbd.mSampleRate
                channels = Int(asbd.mChannelsPerFrame)
                if assetDuration.isFinite, assetDuration > 0 {
                    samples.reserveCapacity(Int(assetDuration * sampleRate) * channels)
                }
            }

            if let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) {
                let byteCount = CMBlockBufferGetDataLength(blockBuffer)
                let floatCount = byteCount / MemoryLayout<Float>.size
                if floatCount > 0 {
                    let start = samples.count
                    samples.append(contentsOf: repeatElement(0, count: floatCount))
                    let status = samples.withUnsafeMutableBufferPointer { buffer in
                        CMBlockBufferCopyDataBytes(
                            blockBuffer,
                            atOffset: 0,
                            dataLength: floatCount * MemoryLayout<Float>.size,
                            destination: buffer.baseAddress! + start
                        )
                    }
                    guard status == kCMBlockBufferNoErr else { throw Failure.unreadable(url) }
                }
            }

            // A container can lie about its duration, or not carry one. The
            // budget is enforced against what has actually arrived, so a stream
            // that runs long is refused instead of filling memory.
            let framesSoFar = Double(samples.count / max(channels, 1))
            if sampleRate > 0, framesSoFar / sampleRate > maximumDuration {
                throw Failure.tooLong(framesSoFar / sampleRate)
            }

            if progress != nil, assetDuration.isFinite, assetDuration > 0 {
                let played = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
                // Throws out of the loop; `defer` above cancels the reader.
                try report(progress, min(max(played / assetDuration, 0), 1))
            }
        }

        guard reader.status == .completed else { throw Failure.unreadable(url) }
        guard channels > 0, sampleRate > 0, !samples.isEmpty else {
            throw Failure.noAudioTrack(url)
        }
        // Drop a partial trailing frame rather than shifting every channel.
        let remainder = samples.count % channels
        if remainder != 0 { samples.removeLast(remainder) }

        try report(progress, 1)
        return PCMBlock(samples: samples, sampleRate: sampleRate, channelCount: channels)
    }

    // MARK: - Probe

    /// Duration, rate, channels and a human format line, without decoding.
    /// Does not enforce the length budget: the caller wants to be able to tell
    /// the user *how* long the file is before refusing it.
    static func probe(_ url: URL) throws -> EditorSource {
        let displayName = url.deletingPathExtension().lastPathComponent

        if let file = try? AVAudioFile(forReading: url) {
            let format = file.fileFormat
            let asbd = format.streamDescription.pointee
            let sampleRate = format.sampleRate
            let channels = Int(format.channelCount)
            guard sampleRate > 0, channels > 0 else { throw Failure.unreadable(url) }
            let duration = Double(file.length) / sampleRate

            return EditorSource(
                url: url,
                displayName: displayName,
                origin: .file(originalURL: url),
                duration: duration,
                sampleRate: sampleRate,
                channelCount: channels,
                formatDescription: formatLine(
                    formatID: asbd.mFormatID,
                    bitsPerChannel: Int(asbd.mBitsPerChannel),
                    bitRateKbps: estimatedBitRateKbps(of: url, duration: duration),
                    sampleRate: sampleRate,
                    channels: channels,
                    fallbackName: url.pathExtension
                )
            )
        }

        let asset = AVURLAsset(url: url)
        let audioTracks = asset.tracks(withMediaType: .audio)
        guard let track = audioTracks.first else {
            throw asset.tracks.isEmpty ? Failure.unreadable(url) : Failure.noAudioTrack(url)
        }
        // `formatDescriptions` is imported as `[Any]` but is documented to hold
        // `CMFormatDescription`s. The conditional form is a compile *error* for
        // a CoreFoundation type — "will always succeed" — so the forced cast is
        // the language's own remedy here, not a shortcut past a real check.
        guard let rawDescription = track.formatDescriptions.first,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(
                  rawDescription as! CMFormatDescription
              )?.pointee
        else { throw Failure.unreadable(url) }

        let sampleRate = asbd.mSampleRate
        let channels = Int(asbd.mChannelsPerFrame)
        guard sampleRate > 0, channels > 0 else { throw Failure.unreadable(url) }
        let duration = CMTimeGetSeconds(asset.duration)
        // `estimatedDataRate` is bits per second for this track alone, which is
        // a better number than dividing the whole container by its length.
        let trackBitRate = track.estimatedDataRate > 0 ? Int((track.estimatedDataRate / 1000).rounded()) : nil

        return EditorSource(
            url: url,
            displayName: displayName,
            origin: .file(originalURL: url),
            duration: duration.isFinite ? duration : 0,
            sampleRate: sampleRate,
            channelCount: channels,
            formatDescription: formatLine(
                formatID: asbd.mFormatID,
                bitsPerChannel: Int(asbd.mBitsPerChannel),
                bitRateKbps: trackBitRate,
                sampleRate: sampleRate,
                channels: channels,
                fallbackName: url.pathExtension
            )
        )
    }

    // MARK: - Encode

    /// Writes the block to `settings.destinationURL`.
    ///
    /// Native formats go through `AVAudioFile(forWriting:settings:)`. MP3 and
    /// Opus have no encoder on macOS, so they go through `ffmpeg` when the user
    /// has one, and throw `Failure.toolMissing` only when they genuinely do not.
    ///
    /// `runner` and `locate` are injected the way `LinkExtractor` injects them,
    /// so the external path can be driven end to end by a scripted stand-in on
    /// a machine with no `ffmpeg` — which is every machine this was built on.
    ///
    /// Async because the external path awaits a child process. The native path
    /// does no awaiting and behaves exactly as it did.
    static func encode(
        _ block: PCMBlock,
        settings: ExportSettings,
        runner: any ToolProcessRunning = SystemToolProcessRunner(),
        locate: @escaping @Sendable (ExternalTool) -> URL? = { ExternalToolLocator.locate($0) },
        progress: ProgressSink? = nil
    ) async throws {
        guard !block.isEmpty, block.channelCount > 0, block.sampleRate > 0 else {
            throw Failure.encodeFailed("There is nothing to write.")
        }

        if let tool = settings.format.requiresExternalTool {
            guard let executable = locate(tool) else { throw Failure.toolMissing(tool) }
            try await encodeThroughFFmpeg(
                block,
                settings: settings,
                executable: executable,
                runner: runner,
                progress: progress
            )
            return
        }
        try encodeNatively(block, settings: settings, progress: progress)
    }

    /// Everything macOS can write on its own.
    static func encodeNatively(
        _ block: PCMBlock,
        settings: ExportSettings,
        progress: ProgressSink? = nil
    ) throws {
        let targetRate = settings.sampleRate ?? block.sampleRate
        let targetChannels = settings.channels.resolvedChannelCount(from: block.channelCount)

        let file: AVAudioFile
        do {
            file = try AVAudioFile(
                forWriting: settings.destinationURL,
                settings: writerSettings(
                    format: settings.format,
                    sampleRate: targetRate,
                    channels: targetChannels,
                    bitRateKbps: settings.bitRateKbps
                )
            )
        } catch {
            throw Failure.encodeFailed(error.localizedDescription)
        }

        let writeFormat = file.processingFormat
        try report(progress, 0)

        if targetRate == block.sampleRate && targetChannels == block.channelCount {
            try writeDirect(block, to: file, format: writeFormat, progress: progress)
        } else {
            try writeConverted(block, to: file, format: writeFormat, progress: progress)
        }
        try report(progress, 1)
    }

    // MARK: - MP3 and Opus, through ffmpeg

    /// Share of the progress bar spent staging the intermediate WAV. Writing
    /// uncompressed samples to disk is far quicker than encoding them, so most
    /// of the bar belongs to ffmpeg.
    private static let stagingShare = 0.2

    /// Encodes via `ffmpeg`, by writing a lossless intermediate and transcoding
    /// it.
    ///
    /// **Why a file and not a pipe.** `ToolProcessRunning` binds the child's
    /// stdin to `/dev/null`, deliberately — it is the abstraction that made the
    /// yt-dlp path provable without the binary, and widening it to carry a
    /// gigabyte of PCM would change a proved component to save one temporary
    /// file. So the block is written as a 32-bit float WAV through the native
    /// path that already exists and is already correct, and ffmpeg is handed a
    /// filename. The cost is honest: roughly the size of the audio again, in
    /// the temporary directory, for the length of the encode, removed on every
    /// exit including a throw.
    ///
    /// The staged WAV already carries the target sample rate and channel count,
    /// so ffmpeg is only ever asked to change the codec — there is no second
    /// resampler in the chain and no way for the two to disagree.
    private static func encodeThroughFFmpeg(
        _ block: PCMBlock,
        settings: ExportSettings,
        executable: URL,
        runner: any ToolProcessRunning,
        progress: ProgressSink?
    ) async throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeloEncode-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let staged = scratch.appendingPathComponent("staged.wav")
        var stagingSettings = settings
        stagingSettings.format = .wav
        stagingSettings.destinationURL = staged
        try encodeNatively(block, settings: stagingSettings) { fraction in
            progress?(fraction * stagingShare) ?? true
        }

        let duration = block.duration
        let run = ExternalRun()
        let onLine: @Sendable (ToolOutputLine) -> Void = { line in
            guard case let .standardOutput(text) = line,
                  let microseconds = ffmpegProgressMicroseconds(text),
                  duration > 0 else { return }
            let encoded = Double(microseconds) / 1_000_000
            let fraction = stagingShare
                + (1 - stagingShare) * min(max(encoded / duration, 0), 1)
            if progress?(fraction) == false { run.cancel() }
        }

        let result: ToolProcessResult
        do {
            result = try await withTaskCancellationHandler {
                let task = Task {
                    try await runner.run(
                        executable: executable,
                        arguments: ffmpegArguments(input: staged, settings: settings),
                        workingDirectory: nil,
                        onLine: onLine
                    )
                }
                run.adopt(task)
                return try await task.value
            } onCancel: {
                run.cancel()
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Failure.encodeFailed(error.localizedDescription)
        }

        // A tool killed by a signal can still report exit code 0, which is what
        // `wasKilledBySignal` exists for. Check our own intent first: a stop the
        // user asked for is a cancellation, not a failed export.
        if run.wasCancelled { throw CancellationError() }
        guard result.didSucceed else {
            throw Failure.encodeFailed(ffmpegMessage(from: result))
        }
        try report(progress, 1)
    }

    /// The command line, built as an array and never as a shell string.
    /// Internal so it can be asserted on without running anything.
    static func ffmpegArguments(input: URL, settings: ExportSettings) -> [String] {
        var arguments = [
            "-hide_banner",
            "-nostdin",
            "-y",
            // Diagnostics on stderr, machine-readable progress on stdout, which
            // is the split `ToolOutputLine` already preserves.
            "-loglevel", "error",
            "-progress", "pipe:1",
            "-i", input.path
        ]
        switch settings.format {
        case .mp3:
            // 320 kbps: MP3 is what people mean by "save it as a different
            // format", and the top of the format is the least surprising place
            // to land when they did not ask for a number.
            arguments += ["-c:a", "libmp3lame", "-b:a", "\(settings.bitRateKbps ?? 320)k"]
        case .opus:
            // 160 kbps stereo is past transparent for Opus; going higher costs
            // bytes and buys nothing anyone can hear.
            arguments += ["-c:a", "libopus", "-b:a", "\(settings.bitRateKbps ?? 160)k"]
        case .wav, .aiff, .caf, .m4aAAC, .m4aALAC, .flac:
            break
        }
        arguments.append(settings.destinationURL.path)
        return arguments
    }

    /// Microseconds encoded so far, from one `-progress` line.
    ///
    /// ffmpeg emits `key=value` lines, and **both** `out_time_us` and
    /// `out_time_ms` carry microseconds — the `_ms` name is a long-standing
    /// misnomer in ffmpeg itself, not a units bug here. Either is accepted so
    /// the parse does not depend on which build the user installed. A value of
    /// `N/A` appears before the first frame and is correctly ignored.
    static func ffmpegProgressMicroseconds(_ line: String) -> Int64? {
        guard let separator = line.firstIndex(of: "=") else { return nil }
        let key = line[line.startIndex..<separator]
        guard key == "out_time_us" || key == "out_time_ms" else { return nil }
        let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
        guard let microseconds = Int64(value), microseconds >= 0 else { return nil }
        return microseconds
    }

    /// ffmpeg's own last word, so the sheet says what actually went wrong
    /// instead of "the export failed".
    static func ffmpegMessage(from result: ToolProcessResult) -> String {
        let lastLine = result.standardError
            .split(separator: "\n", omittingEmptySubsequences: true)
            .last?
            .trimmingCharacters(in: .whitespaces)
        if let lastLine, !lastLine.isEmpty { return lastLine }
        return "ffmpeg stopped with code \(result.exitCode)."
    }

    /// Holds the child task so `onLine` can stop it. A refusal that arrives
    /// before the task is adopted still lands, which matters because ffmpeg can
    /// emit its first progress line very early.
    private final class ExternalRun: @unchecked Sendable {
        private let lock = NSLock()
        private var task: Task<ToolProcessResult, Error>?
        private var cancelled = false

        func adopt(_ task: Task<ToolProcessResult, Error>) {
            lock.lock()
            self.task = task
            let already = cancelled
            lock.unlock()
            if already { task.cancel() }
        }

        func cancel() {
            lock.lock()
            cancelled = true
            let running = task
            lock.unlock()
            running?.cancel()
        }

        var wasCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }
    }

    /// Same rate, same channel count: deinterleave straight into the writer's
    /// buffers. No converter, so nothing can resample a file that did not ask
    /// to be resampled.
    private static func writeDirect(
        _ block: PCMBlock,
        to file: AVAudioFile,
        format: AVAudioFormat,
        progress: ProgressSink?
    ) throws {
        let channels = block.channelCount
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(chunkFrames)
        ) else { throw Failure.encodeFailed("Couldn't allocate a write buffer.") }

        var written = 0
        while written < block.frameCount {
            let count = min(chunkFrames, block.frameCount - written)
            buffer.frameLength = AVAudioFrameCount(count)
            block.samples.withUnsafeBufferPointer { source in
                deinterleave(
                    source.baseAddress! + written * channels,
                    into: buffer,
                    frames: count,
                    channels: channels
                )
            }
            do {
                try file.write(from: buffer)
            } catch {
                throw Failure.encodeFailed(error.localizedDescription)
            }
            written += count
            try report(progress, Double(written) / Double(block.frameCount))
        }
    }

    /// Rate or channel count changes, so `AVAudioConverter` does the work —
    /// including the mono fold-down and the mono-to-stereo spread.
    private static func writeConverted(
        _ block: PCMBlock,
        to file: AVAudioFile,
        format: AVAudioFormat,
        progress: ProgressSink?
    ) throws {
        guard let sourceFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: block.sampleRate,
            channels: AVAudioChannelCount(block.channelCount),
            interleaved: true
        ), let converter = AVAudioConverter(from: sourceFormat, to: format) else {
            throw Failure.encodeFailed("Couldn't set up the format conversion.")
        }
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue

        // The converter calls the input block synchronously on this thread; the
        // box exists so the cursor can be read after the loop without capturing
        // a mutable local in an escaping block.
        let cursor = FrameCursor()
        let input: AVAudioConverterInputBlock = { _, status in
            let consumed = cursor.frames
            guard consumed < block.frameCount else {
                status.pointee = .endOfStream
                return nil
            }
            let count = min(chunkFrames, block.frameCount - consumed)
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: sourceFormat,
                frameCapacity: AVAudioFrameCount(count)
            ), let destination = buffer.floatChannelData?[0] else {
                status.pointee = .endOfStream
                return nil
            }
            buffer.frameLength = AVAudioFrameCount(count)
            block.samples.withUnsafeBufferPointer { source in
                // Interleaved on both sides: one contiguous copy, no restriding.
                destination.update(
                    from: source.baseAddress! + consumed * block.channelCount,
                    count: count * block.channelCount
                )
            }
            cursor.frames += count
            status.pointee = .haveData
            return buffer
        }

        // Enough room for the chunk plus resampler slack.
        let ratio = format.sampleRate / block.sampleRate
        let capacity = AVAudioFrameCount(Double(chunkFrames) * ratio) + 8192

        while true {
            guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
                throw Failure.encodeFailed("Couldn't allocate a write buffer.")
            }
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError, withInputFrom: input)
            if status == .error {
                throw Failure.encodeFailed(
                    conversionError?.localizedDescription ?? "The format conversion failed."
                )
            }
            if output.frameLength > 0 {
                do {
                    try file.write(from: output)
                } catch {
                    throw Failure.encodeFailed(error.localizedDescription)
                }
            }
            try report(progress, min(Double(cursor.frames) / Double(block.frameCount), 1))
            if status == .endOfStream { break }
            if status == .inputRanDry && output.frameLength == 0 { break }
        }
    }

    /// What each format asks `AVAudioFile` to write.
    ///
    /// WAV and CAF are 32-bit float: the editor's own canonical sample *is* a
    /// float, so float out is the only choice under which decoding a lossless
    /// file and writing it straight back is sample-identical. AIFF cannot carry
    /// float without becoming AIFC, so it writes 24-bit big-endian integer and
    /// is the one uncompressed format where a float source is not bit-exact.
    private static func writerSettings(
        format: AudioFormatKind,
        sampleRate: Double,
        channels: Int,
        bitRateKbps: Int?
    ) -> [String: Any] {
        var settings: [String: Any] = [
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels
        ]
        switch format {
        case .wav, .caf:
            settings[AVFormatIDKey] = kAudioFormatLinearPCM
            settings[AVLinearPCMBitDepthKey] = 32
            settings[AVLinearPCMIsFloatKey] = true
            settings[AVLinearPCMIsBigEndianKey] = false
            settings[AVLinearPCMIsNonInterleaved] = false
        case .aiff:
            settings[AVFormatIDKey] = kAudioFormatLinearPCM
            settings[AVLinearPCMBitDepthKey] = 24
            settings[AVLinearPCMIsFloatKey] = false
            settings[AVLinearPCMIsBigEndianKey] = true
            settings[AVLinearPCMIsNonInterleaved] = false
        case .m4aAAC:
            settings[AVFormatIDKey] = kAudioFormatMPEG4AAC
            settings[AVEncoderBitRateKey] = (bitRateKbps ?? 256) * 1000
        case .m4aALAC:
            settings[AVFormatIDKey] = kAudioFormatAppleLossless
            settings[AVEncoderBitDepthHintKey] = 24
        case .flac:
            settings[AVFormatIDKey] = kAudioFormatFLAC
            settings[AVEncoderBitDepthHintKey] = 24
        case .mp3, .opus:
            // Unreachable. `encode` routes both to ffmpeg, and the intermediate
            // it stages on the way is a `.wav`.
            settings[AVFormatIDKey] = kAudioFormatLinearPCM
        }
        return settings
    }

    /// Single-threaded write cursor for the converter's input block. Unchecked
    /// because the converter drives the block synchronously from the calling
    /// thread — there is no second writer.
    private final class FrameCursor: @unchecked Sendable {
        var frames = 0
    }

    // MARK: - Interleaving

    // The two functions the rest of the editor must never have to write again.
    // `buffer.stride` is the distance between successive frames of one channel,
    // which is 1 for a deinterleaved buffer and `channelCount` for an
    // interleaved one — so the same call is correct for both and there is no
    // branch to get backwards.
    //
    // `vDSP_mmov` copies an M×N submatrix: one column (M = 1), `frames` rows,
    // with a row stride on each side. That is exactly a strided copy, and it is
    // the non-deprecated way to spell one. `cblas_scopy` was the first choice
    // and reads better, but it is deprecated as of macOS 13.3 in favour of the
    // ILP64 headers, and eight warnings from this file would have buried the
    // six `AVURLAsset` ones above that are deliberate and worth reading.

    /// Deinterleaved (or interleaved) buffer → canonical interleaved samples.
    private static func interleave(
        _ buffer: AVAudioPCMBuffer,
        into destination: UnsafeMutablePointer<Float>,
        frames: Int,
        channels: Int
    ) {
        guard let data = buffer.floatChannelData else { return }
        let sourceStride = vDSP_Length(buffer.stride)
        let destinationStride = vDSP_Length(channels)
        for channel in 0..<channels {
            vDSP_mmov(
                data[channel],
                destination + channel,
                1,
                vDSP_Length(frames),
                sourceStride,
                destinationStride
            )
        }
    }

    /// Canonical interleaved samples → whatever layout the buffer wants.
    private static func deinterleave(
        _ source: UnsafePointer<Float>,
        into buffer: AVAudioPCMBuffer,
        frames: Int,
        channels: Int
    ) {
        guard let data = buffer.floatChannelData else { return }
        let sourceStride = vDSP_Length(channels)
        let destinationStride = vDSP_Length(buffer.stride)
        for channel in 0..<channels {
            vDSP_mmov(
                source + channel,
                data[channel],
                1,
                vDSP_Length(frames),
                sourceStride,
                destinationStride
            )
        }
    }

    // MARK: - Format line

    private static func formatLine(
        formatID: AudioFormatID,
        bitsPerChannel: Int,
        bitRateKbps: Int?,
        sampleRate: Double,
        channels: Int,
        fallbackName: String
    ) -> String {
        var parts: [String] = []

        let codec: String
        var isLinearPCM = false
        switch formatID {
        case kAudioFormatLinearPCM:
            isLinearPCM = true
            codec = fallbackName.isEmpty ? "PCM" : fallbackName.uppercased()
        case kAudioFormatMPEGLayer3: codec = "MP3"
        case kAudioFormatMPEGLayer1: codec = "MP1"
        case kAudioFormatMPEGLayer2: codec = "MP2"
        case kAudioFormatMPEG4AAC, kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_HE_V2,
             kAudioFormatMPEG4AAC_LD, kAudioFormatMPEG4AAC_ELD: codec = "AAC"
        case kAudioFormatAppleLossless: codec = "Apple Lossless"
        case kAudioFormatFLAC: codec = "FLAC"
        case kAudioFormatOpus: codec = "Opus"
        case kAudioFormatAppleIMA4: codec = "IMA4"
        case kAudioFormatAC3, kAudioFormatEnhancedAC3: codec = "AC-3"
        default: codec = fallbackName.isEmpty ? "Audio" : fallbackName.uppercased()
        }
        parts.append(codec)

        if isLinearPCM, bitsPerChannel > 0 {
            parts.append("\(bitsPerChannel)-bit")
        } else if let bitRateKbps, bitRateKbps > 0 {
            parts.append("\(bitRateKbps) kbps")
        }

        let rate = sampleRate / 1000
        let rateText = rate == rate.rounded()
            ? String(format: "%.0f kHz", rate)
            : String(format: "%.1f kHz", rate)
        let layout = switch channels {
        case 1: "mono"
        case 2: "stereo"
        default: "\(channels) channels"
        }
        parts.append("\(rateText) \(layout)")

        return parts.joined(separator: " · ")
    }

    /// Bits per second inferred from the file on disk. Container overhead and
    /// embedded artwork make this a few kbps high, which is the same number
    /// every file inspector shows, so it matches what the user expects to see.
    private static func estimatedBitRateKbps(of url: URL, duration: TimeInterval) -> Int? {
        guard duration > 0.1,
              let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size > 0
        else { return nil }
        return Int((Double(size) * 8 / duration / 1000).rounded())
    }
}

// MARK: - AVAudioPCMBuffer bridge

extension PCMBlock {
    /// The block as a standard deinterleaved `AVAudioPCMBuffer`, which is what
    /// `AVAudioEngine` and `RenderEngine`'s return type want. Lives here so the
    /// interleaving rule has exactly one implementation in the editor.
    func makeBuffer() -> AVAudioPCMBuffer? {
        guard channelCount > 0, sampleRate > 0, frameCount > 0,
              let format = AVAudioFormat(
                  standardFormatWithSampleRate: sampleRate,
                  channels: AVAudioChannelCount(channelCount)
              ),
              let buffer = AVAudioPCMBuffer(
                  pcmFormat: format,
                  frameCapacity: AVAudioFrameCount(frameCount)
              ),
              let data = buffer.floatChannelData
        else { return nil }

        buffer.frameLength = AVAudioFrameCount(frameCount)
        let destinationStride = vDSP_Length(buffer.stride)
        samples.withUnsafeBufferPointer { source in
            for channel in 0..<channelCount {
                vDSP_mmov(
                    source.baseAddress! + channel,
                    data[channel],
                    1,
                    vDSP_Length(frameCount),
                    vDSP_Length(channelCount),
                    destinationStride
                )
            }
        }
        return buffer
    }

    /// An `AVAudioPCMBuffer` read back into the canonical layout.
    init?(_ buffer: AVAudioPCMBuffer) {
        let channels = Int(buffer.format.channelCount)
        let frames = Int(buffer.frameLength)
        guard channels > 0, frames > 0, let data = buffer.floatChannelData else { return nil }

        var samples = [Float](repeating: 0, count: frames * channels)
        let sourceStride = vDSP_Length(buffer.stride)
        samples.withUnsafeMutableBufferPointer { output in
            for channel in 0..<channels {
                vDSP_mmov(
                    data[channel],
                    output.baseAddress! + channel,
                    1,
                    vDSP_Length(frames),
                    sourceStride,
                    vDSP_Length(channels)
                )
            }
        }
        self.init(
            samples: samples,
            sampleRate: buffer.format.sampleRate,
            channelCount: channels
        )
    }
}
