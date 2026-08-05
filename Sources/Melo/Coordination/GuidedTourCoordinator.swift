import Foundation

@Observable
@MainActor
final class GuidedTourCoordinator {
    enum Step: Int, CaseIterable, Sendable {
        case appList
        case appControls
        case devices
        case autoEQ
        case smartAudio
        case equalizer
        case search
        case settings
    }

    private let settings: SettingsManager

    private(set) var isActive = false
    private(set) var step: Step = .appList

    var isLastStep: Bool { step.rawValue == Step.allCases.count - 1 }

    init(settings: SettingsManager) {
        self.settings = settings
    }

    func beginIfPending() {
        guard settings.appSettings.guidedTourPending,
              settings.appSettings.guidedTourVersionCompleted < MeloExperienceVersion.guidedTour else {
            return
        }
        step = .appList
        isActive = true
    }

    func begin() {
        var appSettings = settings.appSettings
        appSettings.guidedTourPending = true
        settings.appSettings = appSettings
        step = .appList
        isActive = true
    }

    func next() {
        guard let next = Step(rawValue: step.rawValue + 1) else {
            finish()
            return
        }
        step = next
    }

    func back() {
        guard let previous = Step(rawValue: step.rawValue - 1) else { return }
        step = previous
    }

    /// Completes only the tour. Quiet-app behavior remains the user's existing
    /// setting and defaults to Never on a fresh install; setup no longer asks
    /// for this choice or changes it during updates.
    func finish() {
        var appSettings = settings.appSettings
        appSettings.guidedTourPending = false
        appSettings.guidedTourVersionCompleted = MeloExperienceVersion.guidedTour
        settings.appSettings = appSettings
        isActive = false
    }

    func skip() {
        finish()
    }
}
