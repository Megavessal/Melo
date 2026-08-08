// Melo/Telemetry/TelemetryService.swift
import Foundation
import os

#if canImport(TelemetryDeck)
import TelemetryDeck
#endif

#if canImport(Sentry)
import Sentry
#endif

/// Where the vendor credentials come from.
///
/// They live in `Config/Info.plist` rather than in source so a fork or a local
/// build does not silently report into Melo's own project. An empty value is
/// the normal state of this repository and means "no vendor configured" — the
/// service then stays on `NoOpSink` even with consent granted, so a build
/// without credentials cannot half-work.
///
/// The key names are deliberately vendor-neutral: nothing outside a
/// `#if canImport(...)` block in this module may name a vendor, and a plist key
/// is read by ordinary always-compiled code.
enum TelemetryCredentials {
    static var analyticsAppID: String {
        (Bundle.main.object(forInfoDictionaryKey: "MeloAnalyticsAppID") as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static var crashReportingDSN: String {
        (Bundle.main.object(forInfoDictionaryKey: "MeloCrashReportingDSN") as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// The only way anything is measured in Melo.
///
/// Two invariants, both enforced by `scripts/verify-telemetry.py`:
///
/// 1. Nothing is sent unless `analyticsConsent == .granted`. Every send path
///    guards on it, including the one that runs after the SDKs are up.
/// 2. The vendor SDKs are not *started* unless consent is granted. Starting a
///    crash reporter at launch and then "choosing not to send" is not consent:
///    the SDK installs signal handlers, opens a session, and writes an envelope
///    to disk before any of Melo's own code gets a say. If consent is `.denied`
///    or `.unasked`, `start()` is never reached at all.
@Observable
@MainActor
final class TelemetryService {
    static let shared = TelemetryService()

    /// Mirrors the stored setting. Published so Settings can reflect it without
    /// reading two sources of truth.
    private(set) var consent: AnalyticsConsent = .unasked
    private(set) var isRunning = false

    @ObservationIgnored private weak var settings: SettingsManager?
    @ObservationIgnored private var sink: TelemetrySink = NoOpSink()
    @ObservationIgnored private let environment = TelemetryEnvironment.current()
    @ObservationIgnored private let logger = Logger(subsystem: "dev.melo.telemetry", category: "TelemetryService")

    private init() {}

    // MARK: - Consent

    /// Called once at launch. Reads the stored answer and does nothing else —
    /// in particular it does not start anything unless the stored answer is
    /// already `.granted` from a previous run.
    func configure(settings: SettingsManager) {
        self.settings = settings
        refreshConsent()
    }

    /// Re-reads consent from settings and starts or stops accordingly. Every
    /// place a person can change their mind — the setup page, the one-time
    /// prompt, the Settings switch — calls this rather than poking the SDKs, so
    /// there is exactly one transition to audit.
    func refreshConsent() {
        let stored = settings?.appSettings.analyticsConsent ?? .unasked
        consent = stored
        switch stored {
        case .granted:
            start()
        case .denied, .unasked:
            stop()
        }
    }

    // MARK: - Sending

    /// The entire public sending surface. It takes a `TelemetryEvent` and
    /// nothing else — there is no string-taking overload, and adding one is a
    /// build failure.
    func send(_ event: TelemetryEvent) {
        // Re-checked here even though `sink` is only ever non-no-op while
        // consent is granted: this guard is the one a future reader looks for,
        // and a defence that depends on a field being in the right state is
        // weaker than one that reads the answer.
        guard consent == .granted else { return }
        guard isRunning else { return }
        sink.send(event, environment: environment)
    }

    // MARK: - Vendor lifecycle

    /// Starting the SDKs. Guarded on consent again at the top: this function is
    /// the ignition, and it must be safe to call from anywhere without first
    /// checking, because the one place a check is forgotten is the one that
    /// ships.
    private func start() {
        guard consent == .granted else { return }
        guard !isRunning else { return }

        startAnalytics()
        startCrashReporting()

        #if MELO_DEV
        // No vendor package linked in this build: fall back to printing, so a
        // developer can still see the shape of what would be sent.
        if sink is NoOpSink {
            sink = ConsoleSink()
        }
        #endif

        isRunning = true
        // Sent from here rather than from the launch block so it is structurally
        // impossible for it to precede the consent check.
        send(.appLaunched)
    }

    private func startAnalytics() {
        let appID = TelemetryCredentials.analyticsAppID
        guard !appID.isEmpty else {
            logger.debug("analytics not configured for this build; staying silent")
            return
        }
        #if canImport(TelemetryDeck)
        let config = TelemetryDeck.Config(appID: appID)
        config.defaultSignalPrefix = "Melo."
        TelemetryDeck.initialize(config: config)
        // The vendor derives its default user identifier from the machine.
        // Melo overrides it with one constant so every install reports as the
        // same anonymous subject. This gives up per-user retention on purpose:
        // retention is not worth a stable per-machine key.
        TelemetryDeck.updateDefaultUserID(to: "anonymous")
        sink = VendorAnalyticsSink()
        #endif
    }

    private func startCrashReporting() {
        let dsn = TelemetryCredentials.crashReportingDSN
        guard !dsn.isEmpty else { return }
        #if canImport(Sentry)
        SentrySDK.start { options in
            options.dsn = dsn
            // Everything below is a deliberate narrowing of the vendor's
            // defaults. The default device context includes the machine's name,
            // which people put their own names in, and that is the one thing
            // this whole layer exists to keep on the machine.
            options.sendDefaultPii = false
            options.enableAutoSessionTracking = false
            options.attachScreenshot = false
            options.attachViewHierarchy = false
            options.beforeSend = { event in
                event.context?.removeValue(forKey: "device")
                event.serverName = nil
                event.user = nil
                return event
            }
        }
        #endif
    }

    /// Consent withdrawn, or never given. The analytics sink is dropped so no
    /// further signal can be built, and the crash reporter is closed — a
    /// reporter that has already installed its handlers cannot be un-started,
    /// which is precisely why it is never started before consent.
    private func stop() {
        sink = NoOpSink()
        guard isRunning else { return }
        isRunning = false
        #if canImport(Sentry)
        SentrySDK.close()
        #endif
    }
}
