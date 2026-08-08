// Melo/Audio/Permission/AudioRecordingPermission.swift
import AppKit
import AudioToolbox
import Foundation
import os

private let logger = Logger(subsystem: "io.github.megavessal.Melo", category: "Permission")

// MARK: - Permission Status

/// Core Audio doesn't expose a public preflight API for process-tap permission.
/// These states therefore describe only what Melo has observed while starting
/// real aggregate-device IO, never a guessed TCC value.
enum AudioCapturePermissionStatus: Equatable {
    /// Melo hasn't successfully started process-tap IO yet.
    case unknown
    /// A process tap and its aggregate device successfully started IO.
    case authorized
    /// Core Audio explicitly returned `kAudioDevicePermissionsError`.
    case denied
    /// Melo attempted to start capture, but another setup/start error prevented it.
    case unavailable
}

// MARK: - AudioRecordingPermission

@Observable
@MainActor
final class AudioRecordingPermission {
    /// Starts unknown because there is no public, non-prompting system-audio
    /// permission query. Tests may seed this value directly inside the module.
    var status: AudioCapturePermissionStatus = .unknown

    /// True while Melo is waiting to prove access with a real IO start. Normal
    /// launches enter this state automatically; if no app has a Core Audio
    /// process yet, the request simply remains pending until one appears.
    private(set) var isRequestPending = false

    /// A diagnostic for an honest unavailable state. The banner supplements this
    /// with actionable, stable copy rather than treating every failure as denial.
    private(set) var lastFailureDescription: String?

    /// AudioEngine installs this callback. It starts the public process-tap path;
    /// these state-machine methods deliberately make no private TCC calls.
    var onRequestAccess: (() -> Void)?

    /// Whether AudioEngine may create/start taps right now.
    var allowsCaptureAttempt: Bool {
        status == .authorized || (status == .unknown && isRequestPending)
    }

    static let systemAudioSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture"
    )!

    /// Start the normal launch-time access attempt. This is intentionally
    /// idempotent: SwiftUI lifecycle callbacks and monitor startup can both ask
    /// the engine to start without producing repeated Core Audio activations.
    /// The macOS prompt, when one is required, is produced only later by
    /// `AudioDeviceStart` on an aggregate containing a real process tap.
    func startAutomatically() {
        guard status == .unknown, !isRequestPending else { return }
        beginAttempt(logMessage: "Starting system-audio capture automatically")
    }


    /// Marks a first-run request as pending without invoking the normal
    /// synchronous tap path. The onboarding primer owns its temporary tap and
    /// starts the potentially blocking AudioDeviceStart call on a worker queue.
    func beginFirstRunPrimerAttempt() {
        guard status != .authorized, !isRequestPending else { return }
        status = .unknown
        isRequestPending = true
        lastFailureDescription = nil
        logger.info("Starting first-run system-audio primer; waiting for Core Audio IO start")
    }

    /// Retry a non-permission setup failure after AudioEngine observes a *new*
    /// audio process. Explicit denial is never retried automatically, avoiding
    /// repeated macOS prompts after the user has said no.
    @discardableResult
    func retryAutomaticallyAfterEnvironmentChange() -> Bool {
        guard status == .unavailable, !isRequestPending else { return false }
        beginAttempt(logMessage: "Retrying system-audio capture after audio environment changed")
        return true
    }

    /// User-initiated retry after changing System Settings. Unlike automatic
    /// retry, this may leave the denied state because the user has explicitly
    /// asked Melo to check the real Core Audio path again.
    func request() {
        guard status != .authorized, !isRequestPending else { return }
        beginAttempt(logMessage: "System-audio capture retry requested")
    }

    private func beginAttempt(logMessage: String) {
        status = .unknown
        isRequestPending = true
        lastFailureDescription = nil
        logger.info("\(logMessage, privacy: .public); waiting for Core Audio IO start")
        onRequestAccess?()
    }

    /// Record authoritative evidence that capture permission is usable.
    func recordCaptureStarted() {
        let changed = status != .authorized
        status = .authorized
        isRequestPending = false
        lastFailureDescription = nil

        if changed {
            logger.info("System-audio capture authorized: Core Audio IO started successfully")
        }
    }

    /// Record an actual process-tap activation failure. Only Core Audio's explicit
    /// permission error is called a denial. Other failures are unavailable, and a
    /// generic failure doesn't revoke an already-proven authorization state.
    func recordCaptureStartFailure(_ error: Error) {
        isRequestPending = false

        if Self.isPermissionError(error) {
            status = .denied
            lastFailureDescription = nil
            logger.error("System-audio capture denied by Core Audio")
            return
        }

        guard status != .authorized else {
            logger.error("A later audio route failed after capture was already authorized: \(error.localizedDescription, privacy: .public)")
            return
        }

        status = .unavailable
        lastFailureDescription = error.localizedDescription
        logger.error("System-audio capture couldn't start: \(error.localizedDescription, privacy: .public)")
    }

    func openSystemAudioSettings() {
        NSWorkspace.shared.open(Self.systemAudioSettingsURL)
    }

    /// NSError wrappers are common around OSStatus failures, so inspect a short
    /// underlying-error chain rather than only the outermost error.
    static func isPermissionError(_ error: Error) -> Bool {
        var current = error as NSError

        for _ in 0..<8 {
            if current.domain == NSOSStatusErrorDomain,
               current.code == Int(kAudioDevicePermissionsError) {
                return true
            }

            guard let underlying = current.userInfo[NSUnderlyingErrorKey] as? NSError else {
                return false
            }
            current = underlying
        }

        return false
    }
}
