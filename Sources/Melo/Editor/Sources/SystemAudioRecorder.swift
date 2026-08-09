// Melo/Editor/Sources/SystemAudioRecorder.swift
import AVFoundation
import AudioToolbox
import Foundation
import Synchronization
import os

// MARK: - What to record

/// Everything coming out of the Mac, or one app.
///
/// One app is the interesting case and the one no other audio editor offers: Melo
/// already knows which processes are making sound, with names and icons, because the
/// live path taps them. Recording one of them is the same tap with the mute behaviour
/// inverted.
enum RecordingSource: Equatable, Hashable, Sendable {
    case everything
    case app(pid: pid_t, name: String)

    var displayName: String {
        switch self {
        case .everything: return "Everything"
        case .app(_, let name): return name
        }
    }

    /// What the recorded file is called, which becomes the clip's name in the editor.
    var fileBaseName: String {
        switch self {
        case .everything: return "System recording"
        case .app(_, let name): return "\(name) recording"
        }
    }
}

// MARK: - The recorder

/// Captures the Mac's own output to a file, then hands the file to the editor.
///
/// This is a separate, minimal tap on purpose. `ProcessTapController` is 2278 lines,
/// `@MainActor`, and wired into routing, crossfade, aggregate mirroring and device
/// health; threading a record path through it would put recording state inside the
/// live playback path. The precedent for a throwaway tap is
/// `AudioEngine.runFirstRunAudioPrimer(soundURL:)`, which builds one and tears it down.
@MainActor
final class SystemAudioRecorder: ObservableObject {
    enum State: Equatable {
        case idle
        case arming
        case recording
        case stopping
        case finished(URL)
        case failed(String)

        var isBusy: Bool {
            switch self {
            case .arming, .recording, .stopping: return true
            case .idle, .finished, .failed: return false
            }
        }
    }

    private static let logger = Logger(subsystem: "io.github.megavessal.Melo", category: "SystemAudioRecorder")

    @Published private(set) var state: State = .idle
    /// 0…1 peak, smoothed for display. Feeds `VUMeter`.
    @Published private(set) var level: Float = 0
    @Published private(set) var elapsed: TimeInterval = 0
    /// Non-zero means the writer fell behind and the recording has gaps. Shown, not hidden.
    @Published private(set) var droppedFrameCount: Int = 0
    /// True when Core Audio answered the start with `kAudioDevicePermissionsError`,
    /// so the sheet can offer the Privacy pane instead of a generic error.
    @Published private(set) var needsPermission = false

    private var tap: SystemCaptureTap?
    private var meterTask: Task<Void, Never>?
    private var scratchDirectory: URL?

    /// Non-nil means this recorder is a picture of a state. It never creates a tap.
    private let isSeeded: Bool

    init() {
        isSeeded = false
    }

    /// Seeded for rendering. Sets the published state directly and refuses to start.
    init(seed: SystemRecordSeed?) {
        isSeeded = seed != nil
        guard let seed else { return }
        state = seed.state
        level = seed.level
        elapsed = seed.elapsed
        droppedFrameCount = seed.droppedFrameCount
        needsPermission = seed.needsPermission
    }

    // MARK: Start

    func start(source: RecordingSource, permission: AudioRecordingPermission?) async {
        guard !isSeeded, !state.isBusy else { return }

        if permission?.status == .denied {
            needsPermission = true
            state = .failed("macOS is blocking system audio for Melo.")
            return
        }

        needsPermission = false
        droppedFrameCount = 0
        elapsed = 0
        level = 0
        state = .arming

        let configuration: SystemCaptureTap.Configuration
        do {
            configuration = try Self.makeConfiguration(for: source)
        } catch {
            state = .failed(error.localizedDescription)
            return
        }
        scratchDirectory = configuration.destinationURL.deletingLastPathComponent()

        let capture = SystemCaptureTap(configuration: configuration)
        do {
            // Core Audio may block here while macOS presents its permission sheet,
            // exactly as the first-run primer does, so it never runs on the main actor.
            try await Task.detached(priority: .userInitiated) { try capture.start() }.value
        } catch {
            capture.hardStop()
            cleanUpScratch()
            permission?.recordCaptureStartFailure(error)
            needsPermission = AudioRecordingPermission.isPermissionError(error)
            state = .failed(Self.message(for: error, permissionDenied: needsPermission))
            Self.logger.error("Recording could not start: \(error.localizedDescription, privacy: .public)")
            return
        }

        permission?.recordCaptureStarted()
        tap = capture
        state = .recording
        startMetering(capture)
    }

    // MARK: Stop

    /// Stops, closes the file and returns it. Nil when nothing was recorded.
    @discardableResult
    func stop() async -> URL? {
        guard case .recording = state, let capture = tap else { return nil }
        state = .stopping
        meterTask?.cancel()
        meterTask = nil

        // Teardown blocks: `AudioDeviceDestroyIOProcID` waits for the IO cycle, and the
        // writer thread has to finish its final drain before the file is closed.
        let url = await Task.detached(priority: .userInitiated) { capture.stopAndFinish() }.value

        tap = nil
        level = 0
        droppedFrameCount = capture.droppedFrames

        guard let url else {
            cleanUpScratch()
            state = .failed("That recording came out empty.")
            return nil
        }

        state = .finished(url)
        return url
    }

    /// Stops and throws the file away. Used when the sheet closes mid-recording, so a
    /// dismissed sheet can never leave an aggregate device behind.
    func cancel() {
        meterTask?.cancel()
        meterTask = nil
        guard let capture = tap else {
            cleanUpScratch()
            if state.isBusy { state = .idle }
            return
        }
        tap = nil
        state = .idle
        level = 0
        let scratch = scratchDirectory
        scratchDirectory = nil
        Task.detached(priority: .utility) {
            capture.hardStop()
            if let scratch { try? FileManager.default.removeItem(at: scratch) }
        }
    }

    /// Called once the editor has taken ownership of the recording.
    func forgetScratchDirectory() {
        scratchDirectory = nil
    }


    private func cleanUpScratch() {
        guard let scratch = scratchDirectory else { return }
        scratchDirectory = nil
        try? FileManager.default.removeItem(at: scratch)
    }

    // MARK: Metering

    private func startMetering(_ capture: SystemCaptureTap) {
        meterTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(DesignTokens.Timing.vuMeterUpdateInterval))
                guard let self, !Task.isCancelled else { return }
                // Decay on the reader side. The audio thread stores an instantaneous
                // peak and does no smoothing, because smoothing state is one more
                // thing to get wrong in a realtime callback.
                self.level = max(capture.peakLevel, self.level * 0.82)
                self.elapsed = capture.capturedDuration
                self.droppedFrameCount = capture.droppedFrames
            }
        }
    }

    // MARK: Setup

    private static func makeConfiguration(
        for source: RecordingSource
    ) throws -> SystemCaptureTap.Configuration {
        let outputDevice = try AudioDeviceID.readDefaultOutputDevice()
        guard outputDevice.isValid else { throw RecordingSetupFailure.noOutputDevice }
        let outputUID = try outputDevice.readDeviceUID()
        guard !outputUID.isEmpty else { throw RecordingSetupFailure.noOutputDevice }

        let processObjects = (try? AudioObjectID.readProcessList()) ?? []
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let ownObjects = processObjects.filter { (try? $0.readProcessPID()) == ownPID }

        let targets: [AudioObjectID]
        switch source {
        case .everything:
            targets = []
        case .app(let pid, _):
            targets = processObjects.filter { (try? $0.readProcessPID()) == pid }
            guard !targets.isEmpty else { throw RecordingSetupFailure.appNotPlaying }
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeloCuttingRoom", isDirectory: true)
            .appendingPathComponent("Recording-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        return SystemCaptureTap.Configuration(
            captureEverything: source == .everything,
            processObjectIDs: targets,
            // Melo's own output is excluded from a global capture, so playing the clip
            // back in the editor while recording cannot feed itself.
            excludedProcessObjectIDs: ownObjects,
            outputDeviceUID: outputUID,
            destinationURL: directory.appendingPathComponent("\(source.fileBaseName).caf")
        )
    }

    private static func message(for error: Error, permissionDenied: Bool) -> String {
        if permissionDenied {
            return "macOS is blocking system audio for Melo."
        }
        if let setup = error as? RecordingSetupFailure {
            return setup.errorDescription ?? "Melo couldn't start recording."
        }
        return "Melo couldn't start recording. \((error as NSError).localizedDescription)"
    }
}

// MARK: - Setup failures

enum RecordingSetupFailure: LocalizedError, Equatable {
    case noOutputDevice
    case appNotPlaying
    case tapUnavailable
    case aggregateUnavailable
    case fileNotWritable

    var errorDescription: String? {
        switch self {
        case .noOutputDevice:
            return "There's no audio output to record from."
        case .appNotPlaying:
            return "That app stopped making sound. Pick another, or record everything."
        case .tapUnavailable:
            // Whether a second tap over a process Melo is already tapping works is
            // unverified. If it does not, this is the message the user gets.
            return "Melo couldn't tap that app. Try recording everything instead."
        case .aggregateUnavailable:
            return "Core Audio wouldn't set up the recording device."
        case .fileNotWritable:
            return "Melo couldn't create the recording file."
        }
    }
}

// MARK: - The tap

/// One process tap, one private aggregate device, one IO proc, one writer thread.
///
/// Teardown order is not optional and is documented at `TapResources.swift:15` —
/// stop, destroy the IO proc, destroy the aggregate, destroy the tap. Getting it wrong
/// leaks an aggregate device into the user's system, which is why every path out of
/// this class goes through `TapResources.destroy()` rather than unwinding by hand.
final class SystemCaptureTap: @unchecked Sendable {
    struct Configuration: Sendable {
        var captureEverything: Bool
        var processObjectIDs: [AudioObjectID]
        var excludedProcessObjectIDs: [AudioObjectID]
        var outputDeviceUID: String
        var destinationURL: URL
    }

    private static let logger = Logger(subsystem: "io.github.megavessal.Melo", category: "SystemCaptureTap")

    private let configuration: Configuration
    // Passed to AudioDeviceCreateIOProcIDWithBlock; the callback itself runs on Core
    // Audio's realtime HAL thread, not on this queue.
    private let callbackQueue = DispatchQueue(label: "Melo.CuttingRoom.CaptureTap", qos: .userInitiated)

    private var resources = TapResources()
    private var sink: CaptureSink?
    private var writerThread: Thread?
    private let writerFinished = DispatchSemaphore(value: 0)
    private var destinationURL: URL?
    private let isActive = Atomic<Bool>(false)

    init(configuration: Configuration) {
        self.configuration = configuration
    }

    deinit {
        // Last line of defence. A recorder that is deallocated while active would
        // otherwise leave a private aggregate device registered with coreaudiod, and
        // that outlives Melo quitting.
        //
        // The writer is stopped in the completion, not before it: the IO proc has to
        // be gone before the ring stops being drained, or the audio thread is still
        // pushing frames at a reader that has quit. Same order as every other path
        // here, just asynchronous.
        if isActive.load(ordering: .acquiring) {
            let capture = sink
            resources.destroyAsync { capture?.requestStop() }
        }
    }

    // MARK: Levels

    var peakLevel: Float { sink.map { Float(bitPattern: $0.peakBits.load(ordering: .relaxed)) } ?? 0 }
    var droppedFrames: Int { sink?.droppedFrames.load(ordering: .relaxed) ?? 0 }
    var capturedDuration: TimeInterval {
        guard let sink, sink.sampleRate > 0 else { return 0 }
        return TimeInterval(sink.capturedFrames.load(ordering: .relaxed)) / sink.sampleRate
    }

    // MARK: Start

    /// Never call this on the main actor: `AudioDeviceStart` blocks while macOS
    /// presents the system-audio permission sheet.
    func start() throws {
        let description = makeTapDescription()
        var tapID = AudioObjectID.unknown
        let tapStatus = AudioHardwareCreateProcessTap(description, &tapID)
        guard tapStatus == noErr, tapID.isValid else {
            Self.logger.error("AudioHardwareCreateProcessTap failed: OSStatus \(tapStatus)")
            throw RecordingSetupFailure.tapUnavailable
        }
        resources.tapID = tapID
        resources.tapDescription = description

        let asbd = (try? tapID.readAudioTapStreamBasicDescription()) ?? AudioStreamBasicDescription()
        let sampleRate = asbd.mSampleRate > 0 ? asbd.mSampleRate : 48_000
        let channelCount = asbd.mChannelsPerFrame > 0 ? Int(asbd.mChannelsPerFrame) : 2

        var aggregateID = AudioObjectID.unknown
        let aggregateStatus = AudioHardwareCreateAggregateDevice(
            makeAggregateDescription(tapUUID: description.uuid) as CFDictionary,
            &aggregateID
        )
        guard aggregateStatus == noErr, aggregateID.isValid else {
            Self.logger.error("AudioHardwareCreateAggregateDevice failed: OSStatus \(aggregateStatus)")
            resources.destroy()
            throw RecordingSetupFailure.aggregateUnavailable
        }
        resources.aggregateDeviceID = aggregateID
        CrashGuard.trackDevice(aggregateID)

        guard aggregateID.waitUntilReady(timeout: 2.0) else {
            resources.destroy()
            throw RecordingSetupFailure.aggregateUnavailable
        }

        let file: AVAudioFile
        do {
            file = try Self.makeFile(at: configuration.destinationURL, sampleRate: sampleRate, channelCount: channelCount)
        } catch {
            resources.destroy()
            throw RecordingSetupFailure.fileNotWritable
        }
        destinationURL = configuration.destinationURL

        // Four seconds of slack between the HAL and the disk. A 512-frame IO cycle at
        // 48 kHz is ~10.7 ms and the writer polls every 20 ms, so this is roughly two
        // hundred times the steady-state need — the margin is for a spinning-disk stall.
        let capture = CaptureSink(
            sampleRate: sampleRate,
            channelCount: channelCount,
            ringFrames: Int(sampleRate * 4),
            maximumCallbackFrames: 8_192,
            file: file
        )
        sink = capture

        var procID: AudioDeviceIOProcID?
        // The block captures the sink strongly rather than `self` weakly: a weak load
        // on the audio thread takes a runtime side-table lock, and this callback must
        // not take one. The HAL owns the block, so destroying the IO proc releases the
        // sink — there is no cycle and no ARC traffic inside the callback.
        let ioStatus = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, callbackQueue) { _, inInputData, _, _, _ in
            capture.consume(inInputData)
        }
        guard ioStatus == noErr, let procID else {
            Self.logger.error("AudioDeviceCreateIOProcIDWithBlock failed: OSStatus \(ioStatus)")
            resources.destroy()
            sink = nil
            throw RecordingSetupFailure.aggregateUnavailable
        }
        resources.deviceProcID = procID

        startWriterThread(capture)

        let startStatus = AudioDeviceStart(aggregateID, procID)
        guard startStatus == noErr else {
            Self.logger.error("AudioDeviceStart failed: OSStatus \(startStatus)")
            // Same order as a normal stop, even though no callback has run yet:
            // one teardown sequence, so there is no second one to get wrong.
            resources.destroy()
            stopWriterThread()
            sink = nil
            // The permission model reads this exact shape: an NSOSStatusErrorDomain
            // error carrying kAudioDevicePermissionsError is the only thing Melo calls
            // a denial. See AudioRecordingPermission.isPermissionError.
            throw NSError(
                domain: NSOSStatusErrorDomain,
                code: Int(startStatus),
                userInfo: [NSLocalizedDescriptionKey: "Core Audio wouldn't start the recording (\(startStatus))."]
            )
        }

        isActive.store(true, ordering: .releasing)
    }

    // MARK: Stop

    /// Tears everything down and returns the finished file, or nil if it holds no audio.
    /// Blocks; call it off the main actor.
    func stopAndFinish() -> URL? {
        guard isActive.exchange(false, ordering: .acquiringAndReleasing) else { return nil }

        // Full documented order in one call. `AudioDeviceDestroyIOProcID` blocks until
        // the callback returns, so once this line completes the audio thread is gone
        // and the ring buffer has one last writer-thread drain to do.
        resources.destroy()
        stopWriterThread()

        let frames = sink?.capturedFrames.load(ordering: .relaxed) ?? 0
        sink = nil

        guard frames > 0, let url = destinationURL,
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    /// Teardown with no file. Safe to call more than once and safe to call after a
    /// partially-failed start.
    func hardStop() {
        isActive.store(false, ordering: .releasing)
        resources.destroy()
        stopWriterThread()
        sink = nil
    }

    // MARK: Writer thread

    private func startWriterThread(_ capture: CaptureSink) {
        let finished = writerFinished
        let thread = Thread {
            capture.runWriteLoop()
            finished.signal()
        }
        thread.name = "Melo.CuttingRoom.RecordWriter"
        thread.qualityOfService = .userInitiated
        thread.stackSize = 512 * 1_024
        writerThread = thread
        thread.start()
    }

    private func stopWriterThread() {
        guard writerThread != nil else { return }
        sink?.requestStop()
        _ = writerFinished.wait(timeout: .now() + 5)
        writerThread = nil
    }

    // MARK: Descriptions

    private func makeTapDescription() -> CATapDescription {
        let description: CATapDescription
        if configuration.captureEverything {
            description = CATapDescription(
                stereoGlobalTapButExcludeProcesses: configuration.excludedProcessObjectIDs
            )
        } else {
            description = CATapDescription(stereoMixdownOfProcesses: configuration.processObjectIDs)
        }
        description.uuid = UUID()
        description.name = "Melo Cutting Room"
        description.isPrivate = true
        // The live path uses `.mutedWhenTapped` because it re-renders the audio.
        // A recording must never take the sound away from the person making it.
        description.muteBehavior = .unmuted
        return description
    }

    private func makeAggregateDescription(tapUUID: UUID) -> [String: Any] {
        [
            kAudioAggregateDeviceNameKey: "Melo Cutting Room Recorder",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: configuration.outputDeviceUID,
            kAudioAggregateDeviceClockDeviceKey: configuration.outputDeviceUID,
            // Private: never offered to the user as an output device, never selected
            // as the default, and destroyed with the recording.
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: configuration.outputDeviceUID]
            ],
            // Off, following the reasoning at ProcessTapController.swift:511-517: the
            // tap and the aggregate's only sub-device are the same output device, so
            // they share a clock domain and drift compensation would insert or delete
            // a sample against an offset that does not exist.
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapDriftCompensationKey: false,
                    kAudioSubTapUIDKey: tapUUID.uuidString
                ]
            ]
        ]
    }

    /// CAF float32 at the tap's own rate and channel count. No conversion, no
    /// resampling, nothing lossy between the tap and the disk — and CAF has no 4 GB
    /// ceiling, which WAV does.
    private static func makeFile(at url: URL, sampleRate: Double, channelCount: Int) throws -> AVAudioFile {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channelCount,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        return try AVAudioFile(
            forWriting: url,
            settings: settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: true
        )
    }
}

// MARK: - The realtime side

/// Everything the HAL callback touches, and nothing else.
///
/// The callback interleaves into a pre-allocated scratch buffer, takes a peak, and
/// pushes frames into a lock-free ring. It never allocates, never touches the
/// filesystem, and never takes a lock. The writer thread on the other side of the ring
/// does all three.
private final class CaptureSink: @unchecked Sendable {
    let sampleRate: Double
    let channelCount: Int
    let peakBits = Atomic<UInt32>(0)
    let capturedFrames = Atomic<Int>(0)
    let droppedFrames = Atomic<Int>(0)

    /// Set by whoever is tearing down; the writer thread polls it. It lives here
    /// rather than on the tap because `Atomic` is non-copyable and cannot be passed
    /// as an ordinary parameter or captured by a closure.
    private let stopRequested = Atomic<Bool>(false)

    private let ring: CaptureRingBuffer
    private let scratch: UnsafeMutablePointer<Float>
    private let scratchFrames: Int
    private var file: AVAudioFile?

    init(sampleRate: Double, channelCount: Int, ringFrames: Int, maximumCallbackFrames: Int, file: AVAudioFile) {
        self.sampleRate = sampleRate
        self.channelCount = max(1, channelCount)
        self.ring = CaptureRingBuffer(channelCount: self.channelCount, capacityFrames: ringFrames)
        self.scratchFrames = maximumCallbackFrames
        self.scratch = .allocate(capacity: maximumCallbackFrames * self.channelCount)
        self.scratch.initialize(repeating: 0, count: maximumCallbackFrames * self.channelCount)
        self.file = file
    }

    deinit {
        scratch.deinitialize(count: scratchFrames * channelCount)
        scratch.deallocate()
    }

    // MARK: Audio thread

    @inline(__always)
    func consume(_ bufferList: UnsafePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: bufferList)
        )
        guard buffers.count > 0 else { return }

        let channels = channelCount
        let bytesPerSample = MemoryLayout<Float>.size
        var frames = 0

        if buffers.count == 1 {
            // Interleaved, or a single-channel tap.
            let bufferChannels = Int(buffers[0].mNumberChannels)
            guard bufferChannels == channels, let raw = buffers[0].mData else { return }
            frames = Int(buffers[0].mDataByteSize) / (bytesPerSample * channels)
            let usable = min(frames, scratchFrames)
            guard usable > 0 else { return }
            scratch.update(from: raw.assumingMemoryBound(to: Float.self), count: usable * channels)
            finish(usable: usable, offered: frames)
            return
        }

        // Deinterleaved: one buffer per channel, which is what a process tap normally
        // hands over. Interleave into the scratch so the file writer has one layout.
        let planes = min(buffers.count, channels)
        frames = Int(buffers[0].mDataByteSize) / bytesPerSample
        let usable = min(frames, scratchFrames)
        guard usable > 0 else { return }

        for plane in 0..<planes {
            guard let raw = buffers[plane].mData else { continue }
            let source = raw.assumingMemoryBound(to: Float.self)
            var frame = 0
            var offset = plane
            while frame < usable {
                scratch[offset] = source[frame]
                frame += 1
                offset += channels
            }
        }
        // A tap that reports more channels than it delivers planes would otherwise
        // leave stale samples from the previous callback in those slots.
        if planes < channels {
            for plane in planes..<channels {
                var frame = 0
                var offset = plane
                while frame < usable {
                    scratch[offset] = 0
                    frame += 1
                    offset += channels
                }
            }
        }
        finish(usable: usable, offered: frames)
    }

    @inline(__always)
    private func finish(usable: Int, offered: Int) {
        let total = usable * channelCount
        var peak: Float = 0
        var index = 0
        while index < total {
            let magnitude = Swift.abs(scratch[index])
            if magnitude > peak { peak = magnitude }
            index += 1
        }
        peakBits.store(peak.bitPattern, ordering: .relaxed)

        if ring.write(scratch, frameCount: usable) {
            capturedFrames.wrappingAdd(usable, ordering: .relaxed)
        } else {
            droppedFrames.wrappingAdd(usable, ordering: .relaxed)
        }
        if offered > usable {
            droppedFrames.wrappingAdd(offered - usable, ordering: .relaxed)
        }
    }

    // MARK: Writer thread

    /// Polls the ring every 20 ms and writes whatever is there. Nothing signals this
    /// thread from the audio thread — signalling a semaphore from a HAL callback is the
    /// other way to do it and it can block. Polling cannot.
    func requestStop() {
        stopRequested.store(true, ordering: .releasing)
    }

    func runWriteLoop() {
        let chunkFrames = 4_096
        guard let file,
              let buffer = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat,
                frameCapacity: AVAudioFrameCount(chunkFrames)
              ),
              let destination = buffer.floatChannelData?[0] else {
            self.file = nil
            return
        }

        while !stopRequested.load(ordering: .acquiring) {
            drain(into: buffer, destination: destination, file: file, chunkFrames: chunkFrames)
            Thread.sleep(forTimeInterval: 0.02)
        }
        // Final drain after the IO proc is destroyed, so the tail of the recording is
        // on disk before the file is closed.
        drain(into: buffer, destination: destination, file: file, chunkFrames: chunkFrames)

        // AVAudioFile flushes and closes on deallocation.
        self.file = nil
    }

    private func drain(
        into buffer: AVAudioPCMBuffer,
        destination: UnsafeMutablePointer<Float>,
        file: AVAudioFile,
        chunkFrames: Int
    ) {
        while true {
            let framesRead = ring.read(into: destination, maxFrames: chunkFrames)
            guard framesRead > 0 else { return }
            buffer.frameLength = AVAudioFrameCount(framesRead)
            do {
                try file.write(from: buffer)
            } catch {
                return
            }
        }
    }
}

// MARK: - Ring buffer

/// Single-producer, single-consumer float ring. The HAL callback is the only writer,
/// the file-writer thread is the only reader, and the two cursors are monotonic frame
/// counts so a full buffer is distinguishable from an empty one without a third field.
private final class CaptureRingBuffer: @unchecked Sendable {
    private let channelCount: Int
    private let capacityFrames: Int
    private let mask: Int
    private let storage: UnsafeMutablePointer<Float>
    private let writeCursor = Atomic<Int>(0)
    private let readCursor = Atomic<Int>(0)

    init(channelCount: Int, capacityFrames: Int) {
        self.channelCount = max(1, channelCount)
        var capacity = 1_024
        while capacity < capacityFrames { capacity <<= 1 }
        self.capacityFrames = capacity
        self.mask = capacity - 1
        let sampleCount = capacity * self.channelCount
        self.storage = .allocate(capacity: sampleCount)
        self.storage.initialize(repeating: 0, count: sampleCount)
    }

    deinit {
        storage.deinitialize(count: capacityFrames * channelCount)
        storage.deallocate()
    }

    /// Audio thread. Returns false when there is no room, which the caller counts as
    /// dropped frames rather than blocking or growing the buffer.
    @inline(__always)
    func write(_ source: UnsafePointer<Float>, frameCount: Int) -> Bool {
        guard frameCount > 0, frameCount <= capacityFrames else { return false }
        let write = writeCursor.load(ordering: .relaxed)
        let read = readCursor.load(ordering: .acquiring)
        guard capacityFrames - (write - read) >= frameCount else { return false }

        let start = write & mask
        let firstFrames = Swift.min(frameCount, capacityFrames - start)
        storage.advanced(by: start * channelCount)
            .update(from: source, count: firstFrames * channelCount)
        if firstFrames < frameCount {
            storage.update(
                from: source.advanced(by: firstFrames * channelCount),
                count: (frameCount - firstFrames) * channelCount
            )
        }
        writeCursor.store(write + frameCount, ordering: .releasing)
        return true
    }

    /// Writer thread. Returns the number of frames copied out.
    func read(into destination: UnsafeMutablePointer<Float>, maxFrames: Int) -> Int {
        let read = readCursor.load(ordering: .relaxed)
        let write = writeCursor.load(ordering: .acquiring)
        let available = Swift.min(write - read, maxFrames)
        guard available > 0 else { return 0 }

        let start = read & mask
        let firstFrames = Swift.min(available, capacityFrames - start)
        destination.update(
            from: storage.advanced(by: start * channelCount),
            count: firstFrames * channelCount
        )
        if firstFrames < available {
            destination.advanced(by: firstFrames * channelCount)
                .update(from: storage, count: (available - firstFrames) * channelCount)
        }
        readCursor.store(read + available, ordering: .releasing)
        return available
    }
}
