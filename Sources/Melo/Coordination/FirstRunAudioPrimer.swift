import Foundation

@Observable
@MainActor
final class FirstRunAudioPrimer {
    enum State: Equatable {
        case idle
        case preparing
        case waitingForMacOS
        case ready
        case permissionNeeded
        case unavailable(String)
    }

    private let audioEngine: AudioEngine
    private var task: Task<Void, Never>?
    private(set) var state: State = .idle
    private(set) var hasStarted = false

    init(audioEngine: AudioEngine) {
        self.audioEngine = audioEngine
    }

    func startIfNeeded() {
        guard !hasStarted else { return }
        start()
    }

    func start() {
        task?.cancel()
        hasStarted = true
        state = .preparing

        task = Task { @MainActor [weak self] in
            guard let self else { return }
            guard let url = Bundle.main.url(forResource: "MeloFirstRunIntro", withExtension: "wav") else {
                state = .unavailable("The introduction sound is missing from this build.")
                return
            }

            state = .waitingForMacOS
            do {
                try await audioEngine.runFirstRunAudioPrimer(soundURL: url)
                guard !Task.isCancelled else { return }
                state = .ready
            } catch is CancellationError {
                state = .idle
            } catch {
                guard !Task.isCancelled else { return }
                if AudioRecordingPermission.isPermissionError(error) {
                    state = .permissionNeeded
                } else {
                    state = .unavailable(error.localizedDescription)
                }
            }
        }
    }

    func openSystemSettings() {
        audioEngine.permission.openSystemAudioSettings()
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}
