import Foundation

@Observable
@MainActor
final class SleepTimerManager {
    private let deviceVolumeMonitor: any DeviceVolumeProviding
    private var timerTask: Task<Void, Never>?

    private(set) var endDate: Date?
    private(set) var remainingSeconds: Int = 0
    private(set) var isFading = false

    init(deviceVolumeMonitor: any DeviceVolumeProviding) {
        self.deviceVolumeMonitor = deviceVolumeMonitor
    }

    var isActive: Bool { endDate != nil }

    var statusText: String {
        if isFading { return "Fading out…" }
        guard remainingSeconds > 0 else { return "Off" }
        let minutes = max(1, Int(ceil(Double(remainingSeconds) / 60)))
        return "About \(minutes) min left"
    }

    func start(minutes: Int) {
        cancel()
        let seconds = max(1, minutes) * 60
        remainingSeconds = seconds
        endDate = Date().addingTimeInterval(TimeInterval(seconds))
        timerTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while self.remainingSeconds > 0 && !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                self.remainingSeconds = max(0, self.remainingSeconds - 1)
            }
            guard !Task.isCancelled else { return }
            await self.fadeOutAndMute()
        }
    }

    func cancel() {
        timerTask?.cancel()
        timerTask = nil
        endDate = nil
        remainingSeconds = 0
        isFading = false
    }

    private func fadeOutAndMute() async {
        let deviceID = deviceVolumeMonitor.defaultDeviceID
        guard deviceID.isValid else {
            cancel()
            return
        }

        isFading = true
        let startingVolume = deviceVolumeMonitor.volumes[deviceID] ?? 1
        let stepCount = 20
        for step in 1...stepCount {
            guard !Task.isCancelled else { return }
            let progress = Float(step) / Float(stepCount)
            deviceVolumeMonitor.setVolume(for: deviceID, to: startingVolume * (1 - progress))
            try? await Task.sleep(for: .milliseconds(500))
        }
        deviceVolumeMonitor.setMute(for: deviceID, to: true)
        // Keep the user's chosen volume ready for the next unmute instead of
        // leaving the device at zero after the timer finishes.
        deviceVolumeMonitor.setVolume(for: deviceID, to: startingVolume)
        timerTask = nil
        endDate = nil
        remainingSeconds = 0
        isFading = false
    }
}
