// Melo/Views/Rows/DeviceInspector/DeviceInspectorInfo.swift
import AudioToolbox
import CoreAudio
import Foundation

// MARK: - DeviceInspectorInfo

/// Snapshot of device facts displayed in the inspector pane.
nonisolated struct DeviceInspectorInfo: Equatable {
    let transportLabel: String
    let sampleRate: Double
    let availableSampleRates: [Double]
    let sampleRateSettable: Bool
    let formatLabel: String?
    let outputChannelCount: Int
    let estimatedLatencyMilliseconds: Double?
    let clockSourceName: String?
    let hogModeOwner: pid_t
    let uid: String

    static let empty = DeviceInspectorInfo(
        transportLabel: "—",
        sampleRate: 0,
        availableSampleRates: [],
        sampleRateSettable: false,
        formatLabel: nil,
        outputChannelCount: 0,
        estimatedLatencyMilliseconds: nil,
        clockSourceName: nil,
        hogModeOwner: -1,
        uid: ""
    )
}

// MARK: - Formatters

nonisolated extension DeviceInspectorInfo {
    /// "48 kHz" for integer kilohertz, "44.1 kHz" otherwise.
    static func formatSampleRate(_ rate: Double) -> String {
        guard rate > 0 else { return "—" }
        let khz = rate / 1000
        if khz == floor(khz) {
            return String(format: "%.0f kHz", khz)
        }
        return String(format: "%.1f kHz", khz)
    }

    /// "24-bit PCM" for linear PCM streams; nil for non-LPCM or zero bit depth
    /// (Bluetooth typically reports 0 since the codec path hides the format).
    static func formatPhysicalFormat(_ asbd: AudioStreamBasicDescription?) -> String? {
        guard let asbd else { return nil }
        guard asbd.mFormatID == kAudioFormatLinearPCM else { return nil }
        guard asbd.mBitsPerChannel > 0 else { return nil }
        return "\(asbd.mBitsPerChannel)-bit PCM"
    }

    var channelSummary: String {
        switch outputChannelCount {
        case 0: return "Not reported"
        case 1: return "Mono"
        case 2: return "Stereo"
        default: return "\(outputChannelCount) channels"
        }
    }

    var responsivenessSummary: String {
        guard let latency = estimatedLatencyMilliseconds else {
            return transportLabel.contains("Bluetooth") ? "Normal wireless delay" : "Not reported"
        }
        if latency < 15 { return "Very responsive" }
        if latency < 40 { return "Responsive" }
        if latency < 100 { return "Normal" }
        return "Noticeable delay"
    }

    var everydayQualitySummary: String {
        if sampleRate >= 48_000, formatLabel?.contains("24-bit") == true {
            return "High-quality audio"
        }
        if sampleRate >= 44_100 {
            return "Great for everyday listening"
        }
        return "Standard audio"
    }

    /// Human-readable hog-mode owner string for the inline row.
    /// Returns nil when the device is not held exclusively by another process.
    static func formatHogModeOwner(_ owner: pid_t, processName: String?) -> String? {
        guard owner > 0, owner != getpid() else { return nil }
        if let processName, !processName.isEmpty {
            return "In exclusive use by \(processName) (PID \(owner))"
        }
        return "In exclusive use by PID \(owner)"
    }
}

// MARK: - InfoGridLayout

/// Pure layout function: given a `DeviceInspectorInfo`, returns the ordered
/// list of rows to render. Enables structural tests without view introspection.
nonisolated struct InfoGridLayout: Equatable {
    enum Row: Equatable {
        case transport(String)
        case sampleRate(display: String, isPicker: Bool, options: [Double])
        case format(String)
        case channels(String)
        case latency(String)
        case clock(String)
        case deviceID(String)
    }

    let rows: [Row]

    init(info: DeviceInspectorInfo) {
        var rows: [Row] = []

        rows.append(.transport(info.transportLabel))

        let isPicker = info.sampleRateSettable && info.availableSampleRates.count > 1
        rows.append(
            .sampleRate(
                display: DeviceInspectorInfo.formatSampleRate(info.sampleRate),
                isPicker: isPicker,
                options: isPicker ? info.availableSampleRates : []
            )
        )

        if let formatLabel = info.formatLabel {
            rows.append(.format(formatLabel))
        }

        rows.append(.channels(info.channelSummary))
        if let latency = info.estimatedLatencyMilliseconds {
            rows.append(.latency(String(format: "%.1f ms", latency)))
        }
        if let clockSourceName = info.clockSourceName, !clockSourceName.isEmpty {
            rows.append(.clock(clockSourceName))
        }

        rows.append(.deviceID(info.uid))

        self.rows = rows
    }
}
