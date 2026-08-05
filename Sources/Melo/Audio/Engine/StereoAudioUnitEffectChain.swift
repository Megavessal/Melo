// Melo/Audio/Engine/StereoAudioUnitEffectChain.swift
// Audio Unit hosting additions for Melo, based on the GPL-3.0 FineTune codebase.

import AudioToolbox
import AVFAudio
import CoreAudio
import Foundation

private final class AudioUnitInputContext: @unchecked Sendable {
    // Written and read only by the aggregate device's realtime IO thread.
    var source: UnsafeMutablePointer<AudioBufferList>?
}

private let meloAudioUnitInputCallback: AURenderCallback = {
    refCon,
    _,
    _,
    _,
    frameCount,
    destinationData in
    guard let destinationData else { return kAudio_ParamError }
    let context = Unmanaged<AudioUnitInputContext>.fromOpaque(refCon).takeUnretainedValue()
    guard let sourcePointer = context.source else { return kAudio_ParamError }

    let source = UnsafeMutableAudioBufferListPointer(sourcePointer)
    let destination = UnsafeMutableAudioBufferListPointer(destinationData)
    guard source.count == destination.count else { return kAudio_ParamError }

    let byteCount = UInt32(frameCount) * UInt32(MemoryLayout<Float>.size)
    for index in 0..<source.count {
        let sourceBuffer = source[index]
        guard let sourceData = sourceBuffer.mData else { return kAudio_ParamError }
        var destinationBuffer = destination[index]
        destinationBuffer.mNumberChannels = sourceBuffer.mNumberChannels
        destinationBuffer.mDataByteSize = byteCount
        if let destinationPointer = destinationBuffer.mData {
            memcpy(destinationPointer, sourceData, Int(byteCount))
        } else {
            destinationBuffer.mData = sourceData
        }
        destination[index] = destinationBuffer
    }
    return noErr
}

enum StereoAudioUnitChainError: LocalizedError {
    case invalidConfiguration
    case operationFailed(operation: String, status: OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            return "The Audio Unit chain requires a positive sample rate and buffer size."
        case let .operationFailed(operation, status):
            return "\(operation) failed (Core Audio error \(status))."
        }
    }
}

/// An ordered, manually rendered Audio Unit chain for a stereo Float32 IOProc.
///
/// Construction, replacement, and destruction must happen away from the realtime callback and
/// only after the owning AudioDevice IOProc can no longer reference the old chain.
/// `processInterleavedInPlace` performs no allocation, locking, logging, or dispatch and is
/// intended to be called by one realtime thread at a time.
final class StereoAudioUnitEffectChain: @unchecked Sendable {
    private final class Stage {
        let slotID: UUID
        // Retaining the wrapper keeps both AUv2 instances and out-of-process AUv3 proxies alive.
        let wrapper: AVAudioUnit
        let audioUnit: AudioUnit
        let inputContext: AudioUnitInputContext

        init(
            slotID: UUID,
            wrapper: AVAudioUnit,
            audioUnit: AudioUnit,
            inputContext: AudioUnitInputContext
        ) {
            self.slotID = slotID
            self.wrapper = wrapper
            self.audioUnit = audioUnit
            self.inputContext = inputContext
        }
    }

    let sampleRate: Double
    let maximumFrames: UInt32
    var isEmpty: Bool { stages.isEmpty }
    var slotIDs: [UUID] { stages.map(\.slotID) }

    func isCompatible(with configuration: AudioUnitRenderConfiguration) -> Bool {
        abs(sampleRate - configuration.sampleRate) < 0.5
            && maximumFrames >= configuration.maximumFrames
    }

    private let stages: [Stage]
    private let pingStorage: UnsafeMutablePointer<Float>
    private let pongStorage: UnsafeMutablePointer<Float>
    private let pingList: UnsafeMutableAudioBufferListPointer
    private let pongList: UnsafeMutableAudioBufferListPointer

    init(units: [AudioUnitRuntimeUnit], sampleRate: Double, maximumFrames: UInt32) throws {
        guard sampleRate > 0, maximumFrames > 0 else {
            throw StereoAudioUnitChainError.invalidConfiguration
        }
        self.sampleRate = sampleRate
        self.maximumFrames = maximumFrames

        let sampleCapacity = Int(maximumFrames) * 2
        pingStorage = .allocate(capacity: sampleCapacity)
        pongStorage = .allocate(capacity: sampleCapacity)
        pingStorage.initialize(repeating: 0, count: sampleCapacity)
        pongStorage.initialize(repeating: 0, count: sampleCapacity)

        pingList = AudioBufferList.allocate(maximumBuffers: 2)
        pongList = AudioBufferList.allocate(maximumBuffers: 2)
        Self.configure(
            pingList,
            storage: pingStorage,
            channelCapacity: Int(maximumFrames),
            frameCount: maximumFrames
        )
        Self.configure(
            pongList,
            storage: pongStorage,
            channelCapacity: Int(maximumFrames),
            frameCount: maximumFrames
        )

        var configuredStages: [Stage] = []
        configuredStages.reserveCapacity(units.count)
        let format = Self.noninterleavedStereoFormat(sampleRate: sampleRate)
        for item in units {
            do {
                let audioUnit = item.audioUnit.audioUnit
                let context = AudioUnitInputContext()
                try Self.configure(
                    audioUnit,
                    format: format,
                    maximumFrames: maximumFrames,
                    inputContext: context
                )
                configuredStages.append(Stage(
                    slotID: item.slotID,
                    wrapper: item.audioUnit,
                    audioUnit: audioUnit,
                    inputContext: context
                ))
            } catch {
                // Unsupported channel layouts, stale registrations, and individual plug-in
                // failures are a per-stage bypass. The remaining compatible stages still run.
                AudioUnitUninitialize(item.audioUnit.audioUnit)
            }
        }
        stages = configuredStages
    }

    deinit {
        for stage in stages.reversed() {
            AudioUnitUninitialize(stage.audioUnit)
        }
        pingList.unsafeMutablePointer.deallocate()
        pongList.unsafeMutablePointer.deallocate()
        let sampleCapacity = Int(maximumFrames) * 2
        pingStorage.deinitialize(count: sampleCapacity)
        pongStorage.deinitialize(count: sampleCapacity)
        pingStorage.deallocate()
        pongStorage.deallocate()
    }

    /// Processes interleaved stereo Float32 samples in place. If one plug-in fails for a quantum,
    /// that stage is skipped, later stages still render, and the first error is returned.
    @inline(__always)
    func processInterleavedInPlace(
        _ samples: UnsafeMutablePointer<Float>,
        frameCount: UInt32,
        timestamp: UnsafePointer<AudioTimeStamp>
    ) -> OSStatus {
        guard frameCount <= maximumFrames else { return kAudioUnitErr_TooManyFramesToProcess }
        guard frameCount > 0, !stages.isEmpty else { return noErr }

        let frames = Int(frameCount)
        let capacity = Int(maximumFrames)
        let left = pingStorage
        let right = pingStorage.advanced(by: capacity)
        var frame = 0
        while frame < frames {
            left[frame] = samples[frame * 2]
            right[frame] = samples[frame * 2 + 1]
            frame += 1
        }
        Self.configure(
            pingList,
            storage: pingStorage,
            channelCapacity: capacity,
            frameCount: frameCount
        )

        var sourceIsPing = true
        var firstError: OSStatus = noErr
        var index = 0
        while index < stages.count {
            let stage = stages[index]
            let source = sourceIsPing ? pingList : pongList
            let destination = sourceIsPing ? pongList : pingList
            let destinationStorage = sourceIsPing ? pongStorage : pingStorage
            Self.configure(
                destination,
                storage: destinationStorage,
                channelCapacity: capacity,
                frameCount: frameCount
            )
            stage.inputContext.source = source.unsafeMutablePointer

            var flags: AudioUnitRenderActionFlags = []
            let status = AudioUnitRender(
                stage.audioUnit,
                &flags,
                timestamp,
                0,
                frameCount,
                destination.unsafeMutablePointer
            )
            if status == noErr {
                sourceIsPing.toggle()
            } else if firstError == noErr {
                firstError = status
            }
            index += 1
        }

        let result = sourceIsPing ? pingList : pongList
        guard result.count == 2,
              let resultLeft = result[0].mData?.assumingMemoryBound(to: Float.self),
              let resultRight = result[1].mData?.assumingMemoryBound(to: Float.self) else {
            return firstError == noErr ? kAudio_ParamError : firstError
        }
        frame = 0
        while frame < frames {
            samples[frame * 2] = resultLeft[frame]
            samples[frame * 2 + 1] = resultRight[frame]
            frame += 1
        }
        return firstError
    }

    private static func configure(
        _ audioUnit: AudioUnit,
        format: AudioStreamBasicDescription,
        maximumFrames: UInt32,
        inputContext: AudioUnitInputContext
    ) throws {
        var maximumFrames = maximumFrames
        try check(AudioUnitSetProperty(
            audioUnit,
            kAudioUnitProperty_MaximumFramesPerSlice,
            kAudioUnitScope_Global,
            0,
            &maximumFrames,
            UInt32(MemoryLayout<UInt32>.size)
        ), "Setting the Audio Unit buffer size")

        var format = format
        try check(AudioUnitSetProperty(
            audioUnit,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Input,
            0,
            &format,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        ), "Setting the Audio Unit input format")
        try check(AudioUnitSetProperty(
            audioUnit,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Output,
            0,
            &format,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        ), "Setting the Audio Unit output format")

        var callback = AURenderCallbackStruct(
            inputProc: meloAudioUnitInputCallback,
            inputProcRefCon: Unmanaged.passUnretained(inputContext).toOpaque()
        )
        try check(AudioUnitSetProperty(
            audioUnit,
            kAudioUnitProperty_SetRenderCallback,
            kAudioUnitScope_Input,
            0,
            &callback,
            UInt32(MemoryLayout<AURenderCallbackStruct>.size)
        ), "Connecting the Audio Unit")
        try check(AudioUnitInitialize(audioUnit), "Starting the Audio Unit")
    }

    private static func noninterleavedStereoFormat(sampleRate: Double) -> AudioStreamBasicDescription {
        let bytes = UInt32(MemoryLayout<Float>.size)
        return AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat
                | kAudioFormatFlagIsPacked
                | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: bytes,
            mFramesPerPacket: 1,
            mBytesPerFrame: bytes,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 32,
            mReserved: 0
        )
    }

    @inline(__always)
    private static func configure(
        _ list: UnsafeMutableAudioBufferListPointer,
        storage: UnsafeMutablePointer<Float>,
        channelCapacity: Int,
        frameCount: UInt32
    ) {
        list.count = 2
        let bytes = frameCount * UInt32(MemoryLayout<Float>.size)
        list[0] = AudioBuffer(
            mNumberChannels: 1,
            mDataByteSize: bytes,
            mData: UnsafeMutableRawPointer(storage)
        )
        list[1] = AudioBuffer(
            mNumberChannels: 1,
            mDataByteSize: bytes,
            mData: UnsafeMutableRawPointer(storage.advanced(by: channelCapacity))
        )
    }

    private static func check(_ status: OSStatus, _ operation: String) throws {
        guard status == noErr else {
            throw StereoAudioUnitChainError.operationFailed(operation: operation, status: status)
        }
    }
}
