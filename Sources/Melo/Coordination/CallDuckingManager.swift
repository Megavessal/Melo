import Foundation
import Observation

/// Detects sound from common communication apps and asks AudioEngine to lower
/// every other app temporarily. Detection and UI state stay on the main actor;
/// the Core Audio callback only sees the resulting lock-free gain value.
@Observable
@MainActor
final class CallDuckingManager {
    private let audioEngine: AudioEngine
    private var monitorTask: Task<Void, Never>?
    private var restoreTask: Task<Void, Never>?
    private var gainRampTask: Task<Void, Never>?
    private var currentGain: Float = 1.0
    private var started = false

    /// One detector per candidate app. Per-app rather than one shared detector
    /// because "has been making sound for 750 ms" is a fact about a process:
    /// pooling the polls would let a chime from one app top up the run started
    /// by a chime from another.
    private var detectors: [pid_t: CallActivityDetector] = [:]

    private(set) var activeCallAppNames: [String] = []

    private static let knownBundleIDs: Set<String> = [
        "us.zoom.xos",
        "com.apple.FaceTime",
        "com.hnc.Discord",
        "com.tinyspeck.slackmacgap",
        "com.microsoft.teams2",
        "com.microsoft.teams",
        "com.cisco.webexmeetingsapp",
        "com.webex.meetingmanager"
    ]

    private static let knownNameFragments = [
        "zoom", "facetime", "discord", "slack", "microsoft teams", "webex"
    ]

    init(audioEngine: AudioEngine) {
        self.audioEngine = audioEngine
    }

    func start() {
        guard !started else { return }
        started = true
        trackEnablement()
        syncMonitor()
    }

    /// `withObservationTracking` fires once, so re-register on every change.
    /// The flag is read in the deferred `Task` because `onChange` runs in
    /// `willSet`, where the property still holds its previous value.
    private func trackEnablement() {
        withObservationTracking {
            _ = audioEngine.settingsManager.appSettings.lowerOtherAppsDuringCalls
        } onChange: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.started else { return }
                self.trackEnablement()
            }
            Task { @MainActor [weak self] in
                guard let self, self.started else { return }
                self.syncMonitor()
            }
        }
    }

    /// Ducking used to poll every 250 ms from launch onwards and only consult
    /// `lowerOtherAppsDuringCalls` inside `evaluate()`, so a feature that is off
    /// by default still woke the main actor four times a second forever. The
    /// loop now exists only while the feature is enabled.
    private func syncMonitor() {
        guard audioEngine.settingsManager.appSettings.lowerOtherAppsDuringCalls else {
            monitorTask?.cancel()
            monitorTask = nil
            // Runs the disabled branch, which restores gain and clears state.
            evaluate()
            return
        }
        guard monitorTask == nil else { return }
        monitorTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.evaluate()
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    func stop() {
        started = false
        monitorTask?.cancel()
        monitorTask = nil
        restoreTask?.cancel()
        restoreTask = nil
        gainRampTask?.cancel()
        gainRampTask = nil
        activeCallAppNames = []
        detectors = [:]
        currentGain = 1.0
        audioEngine.setCallDuckingGain(1.0)
        audioEngine.setCallDucking(active: false, communicationPIDs: [])
        audioEngine.setCallDuckingMonitoringPIDs([])
    }

    func checkNow() { evaluate() }

    private func evaluate() {
        guard audioEngine.settingsManager.appSettings.lowerOtherAppsDuringCalls else {
            restoreTask?.cancel()
            restoreTask = nil
            activeCallAppNames = []
            detectors = [:]
            gainRampTask?.cancel()
            gainRampTask = nil
            currentGain = 1.0
            audioEngine.setCallDuckingGain(1.0)
            audioEngine.setCallDucking(active: false, communicationPIDs: [])
            audioEngine.setCallDuckingMonitoringPIDs([])
            return
        }

        let additional = audioEngine.settingsManager.appSettings.additionalCallAppIdentifiers
        let candidateApps = audioEngine.apps.filter { app in
            Self.knownBundleIDs.contains(app.bundleID ?? "")
                || additional.contains(app.persistenceIdentifier)
                || Self.knownNameFragments.contains(where: { app.name.localizedCaseInsensitiveContains($0) })
        }
        let candidatePIDs = Set(candidateApps.map(\.id))
        audioEngine.setCallDuckingMonitoringPIDs(candidatePIDs)

        // Detectors for apps that quit would otherwise keep their run counter
        // forever, so a relaunched PID could inherit a half-finished onset.
        detectors = detectors.filter { candidatePIDs.contains($0.key) }

        let soundingCallApps = candidateApps.filter { app in
            var detector = detectors[app.id] ?? CallActivityDetector()
            let onCall = detector.update(peak: audioEngine.getAudioLevel(for: app))
            detectors[app.id] = detector
            return onCall
        }

        guard !soundingCallApps.isEmpty else {
            scheduleRestoreIfNeeded()
            return
        }

        restoreTask?.cancel()
        restoreTask = nil
        let wasInactive = activeCallAppNames.isEmpty
        activeCallAppNames = soundingCallApps.map(\.name).sorted()
        audioEngine.setCallDucking(
            active: true,
            communicationPIDs: Set(soundingCallApps.map(\.id))
        )
        if wasInactive {
            rampGain(to: 0.20, milliseconds: 180, deactivateAfter: false)
        }
    }

    private func scheduleRestoreIfNeeded() {
        guard !activeCallAppNames.isEmpty, restoreTask == nil else { return }
        restoreTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(CallActivityDetector.releaseMilliseconds))
            guard !Task.isCancelled, let self else { return }
            self.activeCallAppNames = []
            self.rampGain(to: 1.0, milliseconds: 260, deactivateAfter: true)
            self.restoreTask = nil
        }
    }
    private func rampGain(
        to target: Float,
        milliseconds: Int,
        deactivateAfter: Bool
    ) {
        gainRampTask?.cancel()
        gainRampTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let steps = 9
            let start = self.currentGain
            let stepDelay = max(1, milliseconds / steps)
            for step in 1...steps {
                guard !Task.isCancelled else { return }
                let progress = Float(step) / Float(steps)
                let gain = start + (target - start) * progress
                self.currentGain = gain
                self.audioEngine.setCallDuckingGain(gain)
                try? await Task.sleep(for: .milliseconds(stepDelay))
            }
            guard !Task.isCancelled else { return }
            self.currentGain = target
            self.audioEngine.setCallDuckingGain(target)
            if deactivateAfter {
                self.audioEngine.setCallDucking(active: false, communicationPIDs: [])
            }
            self.gainRampTask = nil
        }
    }

}
