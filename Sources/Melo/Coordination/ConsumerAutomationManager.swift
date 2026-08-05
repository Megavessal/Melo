import Foundation

/// Runs the deliberately small automation system used by the Everyday tab.
/// It supports only three understandable triggers: an app opens, headphones or
/// speakers connect, or a chosen time arrives.
@Observable
@MainActor
final class ConsumerAutomationManager {
    private unowned let audioEngine: AudioEngine
    private var task: Task<Void, Never>?
    private var knownOpenApps = Set<String>()
    private var knownOutputDevices = Set<String>()
    private var hasSeededPresenceBaseline = false
    private var dailyFireKeys: [UUID: String] = [:]

    private(set) var lastRunText: String?
    private(set) var isRunning = false

    init(audioEngine: AudioEngine) {
        self.audioEngine = audioEngine
    }

    func start() {
        guard task == nil else { return }
        isRunning = true
        task = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.checkNow()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        isRunning = false
        hasSeededPresenceBaseline = false
    }

    func checkNow(now: Date = .now) {
        let openApps = Set(audioEngine.processMonitor.openApps.map(\.persistenceIdentifier))
        let outputDevices = Set(audioEngine.outputDevices.map(\.uid))
        // The engine discovers apps and devices asynchronously. The first poll
        // therefore establishes a baseline even if the sets were empty when
        // the manager was constructed, preventing startup from looking like a
        // wave of fresh connection/open events.
        let newlyOpened = hasSeededPresenceBaseline
            ? openApps.subtracting(knownOpenApps)
            : []
        let newlyConnected = hasSeededPresenceBaseline
            ? outputDevices.subtracting(knownOutputDevices)
            : []
        hasSeededPresenceBaseline = true

        defer {
            knownOpenApps = openApps
            knownOutputDevices = outputDevices
        }

        let calendar = Calendar.current
        let hour = calendar.component(.hour, from: now)
        let minute = calendar.component(.minute, from: now)
        let dayParts = calendar.dateComponents([.year, .month, .day], from: now)
        let dayKey = String(
            format: "%04d-%02d-%02d",
            dayParts.year ?? 0,
            dayParts.month ?? 0,
            dayParts.day ?? 0
        )

        for automation in audioEngine.settingsManager.consumerAutomations where automation.isEnabled {
            guard let scene = audioEngine.settingsManager.scene(id: automation.sceneID) else { continue }

            let shouldRun: Bool
            switch automation.trigger {
            case let .appOpens(identifier, _):
                shouldRun = newlyOpened.contains(identifier)
            case let .deviceConnects(uid, _):
                shouldRun = newlyConnected.contains(uid)
            case let .daily(targetHour, targetMinute):
                let reachedTime = hour > targetHour || (hour == targetHour && minute >= targetMinute)
                shouldRun = reachedTime && dailyFireKeys[automation.id] != dayKey
                if shouldRun { dailyFireKeys[automation.id] = dayKey }
            }

            guard shouldRun else { continue }
            audioEngine.applyConsumerScene(scene, recordUndo: true, reason: automation.trigger.title)
            lastRunText = "Applied \(scene.name) — \(automation.trigger.title)"
        }
    }
}
