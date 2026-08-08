import Foundation
import UserNotifications
import os

/// Melo asks for notification permission when the feature becomes relevant, not
/// during launch. A cold system prompt half a second after first launch — before
/// the user has seen what Melo does or met device alerts — is the pattern Apple's
/// own guidance warns against, and it is the one people reflexively decline.
@MainActor
enum NotificationAuthorization {
    // nonisolated: the authorization callback arrives on an arbitrary queue, and a
    // MainActor-isolated logger cannot be captured by that Sendable closure.
    private nonisolated static let logger = Logger(subsystem: "io.github.megavessal.Melo", category: "Notifications")
    private static var didRequest = false

    static func requestIfNeeded() {
        guard !didRequest else { return }
        didRequest = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, error in
            if let error {
                logger.error("Notification authorization failed: \(error.localizedDescription)")
            }
            // When declined, alerts simply never appear. Melo does not nag.
        }
    }

    /// Launch-time behaviour. An install that has already finished setup and left
    /// device alerts on is re-confirmed silently by the system; a first run waits
    /// until the user has actually completed onboarding.
    static func requestAtLaunchIfAppropriate(_ settings: SettingsManager) {
        guard settings.appSettings.showDeviceDisconnectAlerts,
              settings.appSettings.onboardingVersionCompleted > 0 else { return }
        requestIfNeeded()
    }
}
