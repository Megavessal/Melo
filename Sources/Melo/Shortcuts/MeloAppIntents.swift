import AppIntents
import Foundation

@MainActor
final class MeloIntentBridge {
    static let shared = MeloIntentBridge()

    private weak var audioEngine: AudioEngine?
    private weak var sleepTimer: SleepTimerManager?

    private init() {}

    func configure(audioEngine: AudioEngine, sleepTimer: SleepTimerManager) {
        self.audioEngine = audioEngine
        self.sleepTimer = sleepTimer
    }

    func sceneEntities() -> [MeloSceneEntity] {
        guard let audioEngine else { return [] }
        return audioEngine.settingsManager.consumerScenes.map {
            MeloSceneEntity(id: $0.id, name: $0.name, symbolName: $0.symbolName)
        }
    }

    func appEntities() -> [MeloAudioAppEntity] {
        guard let audioEngine else { return [] }
        return audioEngine.displayableApps.map {
            MeloAudioAppEntity(id: $0.id, name: $0.displayName)
        }
    }

    /// Priority order rather than the raw list: it is the order the user already
    /// arranged in the popup, so the Shortcuts picker and the app agree.
    func outputDeviceEntities() -> [MeloAudioDeviceEntity] {
        guard let audioEngine else { return [] }
        return audioEngine.prioritySortedOutputDevices.map {
            MeloAudioDeviceEntity(id: $0.uid, name: $0.name)
        }
    }

    /// Routed through `AudioEngine.setDefaultOutputDevice`, not through
    /// `deviceVolumeMonitor` — that is the entry point that also re-routes
    /// follows-default apps and registers the echo, so a shortcut leaves the app
    /// in the same state clicking the device in the popup would.
    func setDefaultOutputDevice(uid: String) throws -> String {
        guard let audioEngine else { throw MeloIntentError.appNotReady }
        guard let device = audioEngine.outputDevices.first(where: { $0.uid == uid }) else {
            throw MeloIntentError.deviceNotFound
        }
        guard audioEngine.setDefaultOutputDevice(device.id) else {
            throw MeloIntentError.deviceNotAvailable
        }
        return device.name
    }

    func routeApp(identifier: String, toDeviceUID uid: String) throws -> (app: String, device: String) {
        guard let audioEngine else { throw MeloIntentError.appNotReady }
        guard let device = audioEngine.outputDevices.first(where: { $0.uid == uid }) else {
            throw MeloIntentError.deviceNotFound
        }
        guard let app = audioEngine.apps.first(where: { $0.persistenceIdentifier == identifier }) else {
            throw MeloIntentError.appNotPlaying
        }
        audioEngine.setDevice(for: app, deviceUID: uid)
        return (app.name, device.name)
    }

    func useScene(id: UUID) throws -> String {
        guard let audioEngine else { throw MeloIntentError.appNotReady }
        guard let scene = audioEngine.settingsManager.scene(id: id) else {
            throw MeloIntentError.sceneNotFound
        }
        audioEngine.applyConsumerScene(scene)
        return scene.name
    }

    /// A percent here means what it means everywhere else in Melo: **effective
    /// gain × 100**, base volume multiplied by boost, over 0...400. The
    /// base-volume + boost pair is derived by `VolumeMapping.components`, the
    /// same decomposition the app row's slider uses, rather than by a second
    /// copy of the thresholds — two copies is how the surfaces drifted apart.
    func setVolume(identifier: String, percent: Double) throws -> String {
        guard let audioEngine else { throw MeloIntentError.appNotReady }
        let components = VolumeMapping.components(
            forEffectiveGain: Float(min(Double(IntentSearch.maximumVolumePercent), max(0, percent)) / 100)
        )
        if let app = audioEngine.apps.first(where: { $0.persistenceIdentifier == identifier }) {
            audioEngine.setBoost(for: app, to: components.boost)
            audioEngine.setVolume(for: app, to: components.volume)
            return app.name
        }
        audioEngine.setVolumeForInactive(identifier: identifier, to: components.volume)
        audioEngine.settingsManager.setBoost(for: identifier, to: components.boost)
        return audioEngine.displayableApps.first(where: { $0.id == identifier })?.displayName ?? "App"
    }

    func setMuted(identifier: String, muted: Bool) throws -> String {
        guard let audioEngine else { throw MeloIntentError.appNotReady }
        if let app = audioEngine.apps.first(where: { $0.persistenceIdentifier == identifier }) {
            audioEngine.setMute(for: app, to: muted)
            return app.name
        }
        audioEngine.setMuteForInactive(identifier: identifier, to: muted)
        return audioEngine.displayableApps.first(where: { $0.id == identifier })?.displayName ?? "App"
    }

    func startSleepTimer(minutes: Int) throws {
        guard let sleepTimer else { throw MeloIntentError.appNotReady }
        sleepTimer.start(minutes: minutes)
    }

    func fixAudio() throws {
        guard let audioEngine else { throw MeloIntentError.appNotReady }
        audioEngine.repairConsumerAudio()
    }
}

enum MeloIntentError: Error, CustomLocalizedStringResourceConvertible {
    case appNotReady
    case sceneNotFound
    case deviceNotFound
    case deviceNotAvailable
    case appNotPlaying

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .appNotReady: return "Open Melo once, then try again."
        case .sceneNotFound: return "That Melo Scene is no longer available."
        case .deviceNotFound: return "That output device isn't connected right now."
        case .deviceNotAvailable: return "macOS wouldn't switch to that output device."
        case .appNotPlaying: return "That app isn't playing audio right now, so Melo can't move it."
        }
    }
}

struct MeloSceneEntity: AppEntity, Identifiable, Hashable, Sendable {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Melo Scene")
    static let defaultQuery = MeloSceneQuery()

    let id: UUID
    let name: String
    let symbolName: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", image: .init(systemName: symbolName))
    }
}

struct MeloSceneQuery: EntityQuery {
    func entities(for identifiers: [UUID]) async throws -> [MeloSceneEntity] {
        let all = await MainActor.run { MeloIntentBridge.shared.sceneEntities() }
        let requested = Set(identifiers)
        return all.filter { requested.contains($0.id) }
    }

    func suggestedEntities() async throws -> [MeloSceneEntity] {
        await MainActor.run { MeloIntentBridge.shared.sceneEntities() }
    }
}

struct MeloAudioAppEntity: AppEntity, Identifiable, Hashable, Sendable {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "App in Melo")
    static let defaultQuery = MeloAudioAppQuery()

    let id: String
    let name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }
}

struct MeloAudioAppQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [MeloAudioAppEntity] {
        let all = await MainActor.run { MeloIntentBridge.shared.appEntities() }
        let requested = Set(identifiers)
        return all.filter { requested.contains($0.id) }
    }

    func suggestedEntities() async throws -> [MeloAudioAppEntity] {
        await MainActor.run { MeloIntentBridge.shared.appEntities() }
    }
}

struct MeloAudioDeviceEntity: AppEntity, Identifiable, Hashable, Sendable {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Output Device")
    static let defaultQuery = MeloAudioDeviceQuery()

    /// The device UID, not its `AudioDeviceID`. CoreAudio reassigns numeric IDs
    /// across reconnects, so a shortcut saved against one would silently start
    /// pointing at a different device.
    let id: String
    let name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }
}

struct MeloAudioDeviceQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [MeloAudioDeviceEntity] {
        let all = await MainActor.run { MeloIntentBridge.shared.outputDeviceEntities() }
        let requested = Set(identifiers)
        return all.filter { requested.contains($0.id) }
    }

    func suggestedEntities() async throws -> [MeloAudioDeviceEntity] {
        await MainActor.run { MeloIntentBridge.shared.outputDeviceEntities() }
    }
}

struct UseMeloSceneIntent: AppIntent {
    static let title: LocalizedStringResource = "Use Melo Scene"
    static let description = IntentDescription("Restore a saved Melo sound setup.")
    static let openAppWhenRun = true

    @Parameter(title: "Scene") var scene: MeloSceneEntity

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let name = try MeloIntentBridge.shared.useScene(id: scene.id)
        return .result(dialog: "Using \(name).")
    }
}

struct SetMeloAppVolumeIntent: AppIntent {
    static let title: LocalizedStringResource = "Set App Volume in Melo"
    static let description = IntentDescription("Set one app's volume without changing the rest of your Mac.")
    static let openAppWhenRun = true

    @Parameter(title: "App") var app: MeloAudioAppEntity
    @Parameter(
        title: "Volume",
        description: "Enter a percentage from 0 to 400. 100 is the app's own full volume; above that Melo boosts it."
    ) var percent: Double

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let name = try MeloIntentBridge.shared.setVolume(identifier: app.id, percent: percent)
        let applied = Int(min(Double(IntentSearch.maximumVolumePercent), max(0, percent)))
        return .result(dialog: "Set \(name) to \(applied) percent.")
    }
}

struct SetMeloAppMuteIntent: AppIntent {
    static let title: LocalizedStringResource = "Mute or Unmute App in Melo"
    static let openAppWhenRun = true

    @Parameter(title: "App") var app: MeloAudioAppEntity
    @Parameter(title: "Mute") var muted: Bool

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let name = try MeloIntentBridge.shared.setMuted(identifier: app.id, muted: muted)
        return .result(dialog: muted ? "Muted \(name)." : "Unmuted \(name).")
    }
}

struct SetMeloOutputDeviceIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Output Device in Melo"
    static let description = IntentDescription("Send all sound to a chosen pair of speakers or headphones.")
    static let openAppWhenRun = true

    @Parameter(title: "Output Device") var device: MeloAudioDeviceEntity

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let name = try MeloIntentBridge.shared.setDefaultOutputDevice(uid: device.id)
        return .result(dialog: "Sound is going to \(name).")
    }
}

struct SendMeloAppToDeviceIntent: AppIntent {
    static let title: LocalizedStringResource = "Send App to Output Device in Melo"
    static let description = IntentDescription("Move one app's sound to a chosen output while everything else stays put.")
    static let openAppWhenRun = true

    @Parameter(title: "App") var app: MeloAudioAppEntity
    @Parameter(title: "Output Device") var device: MeloAudioDeviceEntity

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let routed = try MeloIntentBridge.shared.routeApp(identifier: app.id, toDeviceUID: device.id)
        return .result(dialog: "\(routed.app) is now playing on \(routed.device).")
    }
}

struct StartMeloSleepTimerIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Melo Sleep Timer"
    static let description = IntentDescription("Fade out and mute after a chosen number of minutes.")
    static let openAppWhenRun = true

    @Parameter(title: "Minutes", default: 30) var minutes: Int

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let safeMinutes = min(480, max(1, minutes))
        try MeloIntentBridge.shared.startSleepTimer(minutes: safeMinutes)
        return .result(dialog: "Melo will fade out in \(safeMinutes) minutes.")
    }
}

struct FixMeloAudioIntent: AppIntent {
    static let title: LocalizedStringResource = "Fix Melo Audio"
    static let description = IntentDescription("Rebuild Melo's audio connections without deleting settings.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        try MeloIntentBridge.shared.fixAudio()
        return .result(dialog: "Melo rebuilt its audio connections.")
    }
}

struct MeloAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: UseMeloSceneIntent(),
            phrases: ["Use a scene in \(.applicationName)"],
            shortTitle: "Use Scene",
            systemImageName: "square.stack.3d.up"
        )
        AppShortcut(
            intent: SetMeloOutputDeviceIntent(),
            phrases: ["Set the output device in \(.applicationName)"],
            shortTitle: "Set Output Device",
            systemImageName: "hifispeaker.and.homepod"
        )
        AppShortcut(
            intent: StartMeloSleepTimerIntent(),
            phrases: ["Start a sleep timer in \(.applicationName)"],
            shortTitle: "Sleep Timer",
            systemImageName: "moon.zzz"
        )
        AppShortcut(
            intent: FixMeloAudioIntent(),
            phrases: ["Fix audio in \(.applicationName)"],
            shortTitle: "Fix Audio",
            systemImageName: "wrench.and.screwdriver"
        )
    }
}
