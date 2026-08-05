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

    func useScene(id: UUID) throws -> String {
        guard let audioEngine else { throw MeloIntentError.appNotReady }
        guard let scene = audioEngine.settingsManager.scene(id: id) else {
            throw MeloIntentError.sceneNotFound
        }
        audioEngine.applyConsumerScene(scene)
        return scene.name
    }

    func setVolume(identifier: String, percent: Double) throws -> String {
        guard let audioEngine else { throw MeloIntentError.appNotReady }
        let clamped = Float(min(400, max(0, percent)))
        let boost: BoostLevel
        switch clamped {
        case ...100: boost = .x1
        case ...200: boost = .x2
        case ...300: boost = .x3
        default: boost = .x4
        }
        let slider = min(1, clamped / (100 * boost.rawValue))
        if let app = audioEngine.apps.first(where: { $0.persistenceIdentifier == identifier }) {
            audioEngine.setBoost(for: app, to: boost)
            audioEngine.setVolume(for: app, to: slider)
            return app.name
        }
        audioEngine.setVolumeForInactive(identifier: identifier, to: slider)
        audioEngine.settingsManager.setBoost(for: identifier, to: boost)
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

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .appNotReady: return "Open Melo once, then try again."
        case .sceneNotFound: return "That Melo Scene is no longer available."
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
    @Parameter(title: "Volume", description: "Enter a percentage from 0 to 400.") var percent: Double

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let name = try MeloIntentBridge.shared.setVolume(identifier: app.id, percent: percent)
        return .result(dialog: "Set \(name) to \(Int(min(400, max(0, percent)))) percent.")
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
