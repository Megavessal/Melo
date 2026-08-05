// Melo/Audio/Extensions/AudioDeviceID+Info.swift
import AudioToolbox
import Foundation

// MARK: - Device Information

nonisolated extension AudioDeviceID {
    func readDeviceName() throws -> String {
        try readString(kAudioObjectPropertyName)
    }

    func readDeviceUID() throws -> String {
        try readString(kAudioDevicePropertyDeviceUID)
    }

    func readNominalSampleRate() throws -> Float64 {
        try read(kAudioDevicePropertyNominalSampleRate, defaultValue: Float64(48000))
    }

    func readTransportType() -> TransportType {
        let raw = (try? read(kAudioDevicePropertyTransportType, defaultValue: UInt32(0))) ?? 0
        return TransportType(rawValue: raw)
    }
}

// MARK: - Tap Properties

nonisolated extension AudioObjectID {
    func readAudioTapStreamBasicDescription() throws -> AudioStreamBasicDescription {
        try read(kAudioTapPropertyFormat, defaultValue: AudioStreamBasicDescription())
    }
}

// MARK: - Process Properties

nonisolated extension AudioObjectID {
    func readProcessPID() throws -> pid_t {
        try read(kAudioProcessPropertyPID, defaultValue: pid_t(0))
    }

    func readProcessIsRunning() -> Bool {
        (try? readBool(kAudioProcessPropertyIsRunning)) ?? false
    }

    func readProcessBundleID() -> String? {
        try? readString(kAudioProcessPropertyBundleID)
    }
}

// MARK: - Consumer Device Details

nonisolated extension AudioDeviceID {
    /// Best-effort output delay reported by Core Audio. Drivers may omit one or
    /// more pieces, so this deliberately returns nil rather than inventing data.
    func readEstimatedOutputLatencyMilliseconds(sampleRate: Double) -> Double? {
        guard sampleRate > 0 else { return nil }
        let latency: UInt32 = (try? read(kAudioDevicePropertyLatency, scope: .output, defaultValue: UInt32(0))) ?? 0
        let safety: UInt32 = (try? read(kAudioDevicePropertySafetyOffset, scope: .output, defaultValue: UInt32(0))) ?? 0
        let buffer: UInt32 = (try? read(kAudioDevicePropertyBufferFrameSize, scope: .global, defaultValue: UInt32(0))) ?? 0
        let totalFrames = latency + safety + buffer
        guard totalFrames > 0 else { return nil }
        return (Double(totalFrames) / sampleRate) * 1000
    }

    func readClockSourceName() -> String? {
        let sourceID: UInt32 = (try? read(
            kAudioDevicePropertyClockSource,
            scope: .global,
            defaultValue: UInt32(0)
        )) ?? 0
        guard sourceID != 0 else { return nil }
        return readStringWithQualifier(
            kAudioDevicePropertyClockSourceNameForIDCFString,
            scope: .global,
            qualifier: sourceID
        )
    }
}
