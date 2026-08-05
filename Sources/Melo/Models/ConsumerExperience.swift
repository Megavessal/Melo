import Foundation

/// A complete, shareable snapshot of the parts of Melo a typical person changes.
/// The model intentionally stores existing Melo settings rather than inventing a
/// second audio system, so applying a Scene is predictable and reversible.
nonisolated struct ConsumerScene: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var symbolName: String
    var createdAt: Date
    var updatedAt: Date
    var defaultOutputDeviceUID: String?
    var appNames: [String: String]

    var appVolumes: [String: Float]
    var appDeviceRouting: [String: String]
    var appMutes: [String: Bool]
    var appBoosts: [String: Float]
    var appEQSettings: [String: EQSettings]
    var appStereoFieldSettings: [String: StereoFieldSettings]
    var appDeviceSelectionMode: [String: DeviceSelectionMode]
    var appSelectedDeviceUIDs: [String: [String]]

    var systemSoundsFollowsDefault: Bool
    var systemOutputDeviceUID: String?
    var deviceVolumes: [String: Float]
    var deviceMutes: [String: Bool]
    var deviceAutoEQ: [String: AutoEQSelection]
    var autoEQPreampEnabled: Bool
    var globalAudio: ConsumerGlobalAudioSnapshot
    var audioUnitProfiles: [AudioUnitProfile]

    init(
        id: UUID = UUID(),
        name: String,
        symbolName: String = "slider.horizontal.3",
        createdAt: Date = .now,
        updatedAt: Date = .now,
        defaultOutputDeviceUID: String? = nil,
        appNames: [String: String] = [:],
        appVolumes: [String: Float] = [:],
        appDeviceRouting: [String: String] = [:],
        appMutes: [String: Bool] = [:],
        appBoosts: [String: Float] = [:],
        appEQSettings: [String: EQSettings] = [:],
        appStereoFieldSettings: [String: StereoFieldSettings] = [:],
        appDeviceSelectionMode: [String: DeviceSelectionMode] = [:],
        appSelectedDeviceUIDs: [String: [String]] = [:],
        systemSoundsFollowsDefault: Bool = true,
        systemOutputDeviceUID: String? = nil,
        deviceVolumes: [String: Float] = [:],
        deviceMutes: [String: Bool] = [:],
        deviceAutoEQ: [String: AutoEQSelection] = [:],
        autoEQPreampEnabled: Bool = true,
        globalAudio: ConsumerGlobalAudioSnapshot = .init(),
        audioUnitProfiles: [AudioUnitProfile] = []
    ) {
        self.id = id
        self.name = name
        self.symbolName = symbolName
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.defaultOutputDeviceUID = defaultOutputDeviceUID
        self.appNames = appNames
        self.appVolumes = appVolumes
        self.appDeviceRouting = appDeviceRouting
        self.appMutes = appMutes
        self.appBoosts = appBoosts
        self.appEQSettings = appEQSettings
        self.appStereoFieldSettings = appStereoFieldSettings
        self.appDeviceSelectionMode = appDeviceSelectionMode
        self.appSelectedDeviceUIDs = appSelectedDeviceUIDs
        self.systemSoundsFollowsDefault = systemSoundsFollowsDefault
        self.systemOutputDeviceUID = systemOutputDeviceUID
        self.deviceVolumes = deviceVolumes
        self.deviceMutes = deviceMutes
        self.deviceAutoEQ = deviceAutoEQ
        self.autoEQPreampEnabled = autoEQPreampEnabled
        self.globalAudio = globalAudio
        self.audioUnitProfiles = audioUnitProfiles
    }

    enum CodingKeys: String, CodingKey {
        case id, name, symbolName, createdAt, updatedAt, defaultOutputDeviceUID, appNames
        case appVolumes, appDeviceRouting, appMutes, appBoosts, appEQSettings
        case appStereoFieldSettings, appDeviceSelectionMode, appSelectedDeviceUIDs
        case systemSoundsFollowsDefault, systemOutputDeviceUID, deviceVolumes, deviceMutes
        case deviceAutoEQ, autoEQPreampEnabled, globalAudio, audioUnitProfiles
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Imported Scene"
        symbolName = try c.decodeIfPresent(String.self, forKey: .symbolName) ?? "slider.horizontal.3"
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? .now
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        defaultOutputDeviceUID = try c.decodeIfPresent(String.self, forKey: .defaultOutputDeviceUID)
        appNames = try c.decodeIfPresent([String: String].self, forKey: .appNames) ?? [:]
        appVolumes = try c.decodeIfPresent([String: Float].self, forKey: .appVolumes) ?? [:]
        appDeviceRouting = try c.decodeIfPresent([String: String].self, forKey: .appDeviceRouting) ?? [:]
        appMutes = try c.decodeIfPresent([String: Bool].self, forKey: .appMutes) ?? [:]
        appBoosts = try c.decodeIfPresent([String: Float].self, forKey: .appBoosts) ?? [:]
        appEQSettings = try c.decodeIfPresent([String: EQSettings].self, forKey: .appEQSettings) ?? [:]
        appStereoFieldSettings = try c.decodeIfPresent(
            [String: StereoFieldSettings].self,
            forKey: .appStereoFieldSettings
        ) ?? [:]
        appDeviceSelectionMode = try c.decodeIfPresent(
            [String: DeviceSelectionMode].self,
            forKey: .appDeviceSelectionMode
        ) ?? [:]
        appSelectedDeviceUIDs = try c.decodeIfPresent(
            [String: [String]].self,
            forKey: .appSelectedDeviceUIDs
        ) ?? [:]
        systemSoundsFollowsDefault = try c.decodeIfPresent(
            Bool.self,
            forKey: .systemSoundsFollowsDefault
        ) ?? true
        systemOutputDeviceUID = try c.decodeIfPresent(String.self, forKey: .systemOutputDeviceUID)
        deviceVolumes = try c.decodeIfPresent([String: Float].self, forKey: .deviceVolumes) ?? [:]
        deviceMutes = try c.decodeIfPresent([String: Bool].self, forKey: .deviceMutes) ?? [:]
        deviceAutoEQ = try c.decodeIfPresent([String: AutoEQSelection].self, forKey: .deviceAutoEQ) ?? [:]
        autoEQPreampEnabled = try c.decodeIfPresent(Bool.self, forKey: .autoEQPreampEnabled) ?? true
        globalAudio = try c.decodeIfPresent(
            ConsumerGlobalAudioSnapshot.self,
            forKey: .globalAudio
        ) ?? .init()
        audioUnitProfiles = try c.decodeIfPresent([AudioUnitProfile].self, forKey: .audioUnitProfiles) ?? []
    }

    var appCount: Int {
        Set(appVolumes.keys)
            .union(appDeviceRouting.keys)
            .union(appMutes.keys)
            .union(appBoosts.keys)
            .union(appEQSettings.keys)
            .union(appStereoFieldSettings.keys)
            .union(appDeviceSelectionMode.keys)
            .union(appSelectedDeviceUIDs.keys)
            .count
    }
}

nonisolated struct ConsumerGlobalAudioSnapshot: Codable, Equatable {
    var loudnessCompensationEnabled: Bool
    var loudnessEqualizationEnabled: Bool
    var adaptiveAudio: AdaptiveAudioSettings
    var privacyFriendlyProcessingEnabled: Bool

    init(
        loudnessCompensationEnabled: Bool = false,
        loudnessEqualizationEnabled: Bool = false,
        adaptiveAudio: AdaptiveAudioSettings = .init(),
        privacyFriendlyProcessingEnabled: Bool = true
    ) {
        self.loudnessCompensationEnabled = loudnessCompensationEnabled
        self.loudnessEqualizationEnabled = loudnessEqualizationEnabled
        self.adaptiveAudio = adaptiveAudio
        self.privacyFriendlyProcessingEnabled = privacyFriendlyProcessingEnabled
    }
}

nonisolated enum ConsumerAutomationTrigger: Codable, Equatable {
    case appOpens(identifier: String, displayName: String)
    case deviceConnects(uid: String, displayName: String)
    case daily(hour: Int, minute: Int)

    var title: String {
        switch self {
        case let .appOpens(_, displayName):
            return "When \(displayName) opens"
        case let .deviceConnects(_, displayName):
            return "When \(displayName) connects"
        case let .daily(hour, minute):
            let date = Calendar.current.date(from: DateComponents(hour: hour, minute: minute)) ?? .now
            return "Every day at \(date.formatted(date: .omitted, time: .shortened))"
        }
    }

    var symbolName: String {
        switch self {
        case .appOpens: return "app.badge"
        case .deviceConnects: return "headphones"
        case .daily: return "clock"
        }
    }
}

nonisolated struct ConsumerAutomation: Codable, Identifiable, Equatable {
    var id: UUID
    var isEnabled: Bool
    var sceneID: UUID
    var trigger: ConsumerAutomationTrigger
    var createdAt: Date

    init(
        id: UUID = UUID(),
        isEnabled: Bool = true,
        sceneID: UUID,
        trigger: ConsumerAutomationTrigger,
        createdAt: Date = .now
    ) {
        self.id = id
        self.isEnabled = isEnabled
        self.sceneID = sceneID
        self.trigger = trigger
        self.createdAt = createdAt
    }
}

nonisolated struct ConsumerChangeRecord: Identifiable, Equatable {
    let id: UUID
    let label: String
    let date: Date
    let snapshot: ConsumerScene

    init(id: UUID = UUID(), label: String, date: Date = .now, snapshot: ConsumerScene) {
        self.id = id
        self.label = label
        self.date = date
        self.snapshot = snapshot
    }
}

nonisolated enum ConsumerCommandCategory: String, CaseIterable {
    case scenes = "Scenes"
    case devices = "Speakers & Headphones"
    case controls = "Quick Controls"
    case help = "Help"
}
