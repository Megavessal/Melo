import Foundation
import IOKit.ps

@Observable
@MainActor
final class PowerSourceMonitor {
    private let audioEngine: AudioEngine
    private var monitorTask: Task<Void, Never>?

    private(set) var isOnBattery = false

    init(audioEngine: AudioEngine) {
        self.audioEngine = audioEngine
    }

    func start() {
        guard monitorTask == nil else { return }
        refresh()
        monitorTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                self?.refresh()
            }
        }
    }

    func stop() {
        monitorTask?.cancel()
        monitorTask = nil
        audioEngine.setBatterySavingAudioActive(false)
    }

    func refresh() {
        let onBattery = Self.readIsOnBattery()
        isOnBattery = onBattery
        let shouldReduce = audioEngine.settingsManager.appSettings.reduceProcessingOnBattery && onBattery
        audioEngine.setBatterySavingAudioActive(shouldReduce)
    }

    private nonisolated static func readIsOnBattery() -> Bool {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef]
        else { return false }

        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue()
                    as? [String: Any],
                  let state = description[kIOPSPowerSourceStateKey as String] as? String
            else { continue }
            if state == kIOPSBatteryPowerValue as String { return true }
        }
        return false
    }
}
