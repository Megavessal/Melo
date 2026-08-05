import AppKit
import Foundation
import Observation
import os
import UniformTypeIdentifiers

nonisolated struct MeloDiagnosticsSnapshot: Codable, Sendable {
    let generatedAt: Date
    let launchAtLogin: Bool
    let showInDock: Bool
    let quietAppBehavior: String
    let menuBarStyle: String
    let popupSize: String
    let profileCount: Int
    let sceneCount: Int
    let automationCount: Int
    let userPresetCount: Int
    let outputDevicePreferenceCount: Int
    let inputDevicePreferenceCount: Int
}

nonisolated private struct MeloDiagnosticReport: Codable, Sendable {
    let schemaVersion: Int
    let reportID: UUID
    let createdAt: Date
    let reason: String
    let meloVersion: String
    let meloBuild: String
    let macOSVersion: String
    let architecture: String
    let bundleIdentifier: String
    let diagnosticsUploadConfigured: Bool
    let snapshot: MeloDiagnosticsSnapshot
}

@Observable
@MainActor
final class AppSupportCoordinator {
    private let settings: SettingsManager
    private let onboarding: OnboardingWindowController
    private let whatsNew: WhatsNewCoordinator
    private let audioEngine: AudioEngine
    private let sparkle: SparkleUpdateController
    private let logger = Logger(subsystem: "dev.local.Melo", category: "AppSupport")

    private(set) var isCreatingReport = false
    private(set) var reportStatusMessage: String?

    var canCheckForPublishedUpdates: Bool {
        sparkle.isConfigured && sparkle.canCheckForUpdates
    }

    init(
        settings: SettingsManager,
        onboarding: OnboardingWindowController,
        whatsNew: WhatsNewCoordinator,
        audioEngine: AudioEngine,
        sparkle: SparkleUpdateController
    ) {
        self.settings = settings
        self.onboarding = onboarding
        self.whatsNew = whatsNew
        self.audioEngine = audioEngine
        self.sparkle = sparkle
    }

    func applyDockPreferenceAtLaunch() {
        applyDockVisibility(settings.appSettings.showInDock, activate: false)
    }

    func setDockVisible(_ visible: Bool) {
        var appSettings = settings.appSettings
        appSettings.showInDock = visible
        settings.appSettings = appSettings
        applyDockVisibility(visible, activate: visible)
    }

    func toggleDockVisibility() {
        setDockVisible(!settings.appSettings.showInDock)
    }

    func replayTutorial() {
        onboarding.replay()
    }

    func showWhatsNew() {
        whatsNew.replay()
    }

    func checkForUpdates() {
        sparkle.checkNow()
    }

    func createDiagnosticReport(reason: String = "manual") {
        guard !isCreatingReport else { return }
        isCreatingReport = true
        reportStatusMessage = "Preparing report…"

        let snapshot = settings.makeDiagnosticsSnapshot()
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown"
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "dev.local.Melo"
        let diagnosticsEndpoint = (Bundle.main.object(forInfoDictionaryKey: "MeloDiagnosticsEndpoint") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        Task { [weak self] in
            guard let self else { return }
            do {
                let temporaryArchive = try await Task.detached(priority: .utility) {
                    try Self.makeDiagnosticArchive(
                        reason: reason,
                        version: version,
                        build: build,
                        bundleIdentifier: bundleIdentifier,
                        uploadConfigured: URL(string: diagnosticsEndpoint)?.scheme?.lowercased() == "https",
                        snapshot: snapshot
                    )
                }.value

                NSApp.activate(ignoringOtherApps: true)
                let panel = NSSavePanel()
                panel.title = "Save Melo Diagnostic Report"
                panel.message = "The report contains technical details and no recorded audio. Review it before sharing."
                panel.prompt = "Save Report"
                panel.allowedContentTypes = [.zip]
                panel.canCreateDirectories = true
                panel.nameFieldStringValue = temporaryArchive.lastPathComponent

                if panel.runModal() == .OK, let destination = panel.url {
                    try? FileManager.default.removeItem(at: destination)
                    try FileManager.default.copyItem(at: temporaryArchive, to: destination)
                    NSWorkspace.shared.activateFileViewerSelecting([destination])
                    reportStatusMessage = "Report saved"
                } else {
                    reportStatusMessage = nil
                }
                try? FileManager.default.removeItem(at: temporaryArchive)
            } catch {
                logger.error("Could not create diagnostic report: \(error.localizedDescription)")
                reportStatusMessage = "Could not create report"
            }
            isCreatingReport = false
        }
    }

    func eraseAllDataAndRestart() {
        do {
            settings.prepareForFullErase()
            audioEngine.shutdown()

            let scriptURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("melo-reset-\(UUID().uuidString).sh")
            let appURL = Bundle.main.bundleURL
            let pid = ProcessInfo.processInfo.processIdentifier
            let bundleIdentifier = Bundle.main.bundleIdentifier ?? "dev.local.Melo"
            let home = FileManager.default.homeDirectoryForCurrentUser.path

            let script = """
            #!/bin/zsh
            set -u
            OLD_PID=\(pid)
            APP=\(Self.shellQuote(appURL.path))
            HOME_DIR=\(Self.shellQuote(home))
            BUNDLE_ID=\(Self.shellQuote(bundleIdentifier))

            for i in {1..120}; do
              kill -0 "$OLD_PID" 2>/dev/null || break
              sleep 0.1
            done

            /usr/bin/defaults delete "$BUNDLE_ID" >/dev/null 2>&1 || true
            rm -rf "$HOME_DIR/Library/Application Support/Melo"
            rm -rf "$HOME_DIR/Library/Caches/$BUNDLE_ID"
            rm -rf "$HOME_DIR/Library/Saved Application State/$BUNDLE_ID.savedState"
            rm -rf "$HOME_DIR/Library/HTTPStorages/$BUNDLE_ID"
            rm -rf "$HOME_DIR/Library/WebKit/$BUNDLE_ID"
            rm -f "$HOME_DIR/Library/Preferences/$BUNDLE_ID.plist"

            sleep 0.6
            /usr/bin/open "$APP"
            rm -f "$0"
            """

            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: scriptURL.path
            )

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = [scriptURL.path]
            try process.run()
            NSApp.terminate(nil)
        } catch {
            logger.error("Could not erase and restart Melo: \(error.localizedDescription)")
            reportStatusMessage = "Could not restart Melo"
        }
    }

    private func applyDockVisibility(_ visible: Bool, activate: Bool) {
        let policy: NSApplication.ActivationPolicy = visible ? .regular : .accessory
        guard NSApp.setActivationPolicy(policy) else {
            logger.error("Could not change Dock visibility")
            return
        }
        // A tile that has just appeared takes whatever icon is set at that
        // moment, so re-assert the appearance-matched artwork here.
        if visible {
            DockIconAppearanceCoordinator.shared.apply()
        }
        if activate {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private nonisolated static func makeDiagnosticArchive(
        reason: String,
        version: String,
        build: String,
        bundleIdentifier: String,
        uploadConfigured: Bool,
        snapshot: MeloDiagnosticsSnapshot
    ) throws -> URL {
        let fileManager = FileManager.default
        let reportID = UUID()
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("Melo-Diagnostic-\(reportID.uuidString)", isDirectory: true)
        try? fileManager.removeItem(at: root)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

        let system = ProcessInfo.processInfo.operatingSystemVersion
        let report = MeloDiagnosticReport(
            schemaVersion: 1,
            reportID: reportID,
            createdAt: Date(),
            reason: reason,
            meloVersion: version,
            meloBuild: build,
            macOSVersion: "\(system.majorVersion).\(system.minorVersion).\(system.patchVersion)",
            architecture: currentArchitecture(),
            bundleIdentifier: bundleIdentifier,
            diagnosticsUploadConfigured: uploadConfigured,
            snapshot: snapshot
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(report).write(to: root.appendingPathComponent("report.json"), options: .atomic)
        try encoder.encode(snapshot).write(to: root.appendingPathComponent("settings-summary.json"), options: .atomic)

        let summary = """
        Melo Diagnostic Report
        ======================
        Report ID: \(reportID.uuidString)
        Created: \(Date().ISO8601Format())
        Reason: \(reason)
        Melo: \(version) (\(build))
        macOS: \(report.macOSVersion)
        Architecture: \(report.architecture)

        This report does not contain recorded audio. App names and file contents are excluded by default.
        """
        try summary.write(to: root.appendingPathComponent("summary.txt"), atomically: true, encoding: .utf8)

        let logs = runAndCapture(
            "/usr/bin/log",
            arguments: ["show", "--last", "15m", "--style", "compact", "--predicate", "process == \"Melo\""]
        )
        try redact(logs).write(to: root.appendingPathComponent("recent-logs.txt"), atomically: true, encoding: .utf8)

        if let crash = latestCrashReport() {
            try? fileManager.copyItem(at: crash, to: root.appendingPathComponent("latest-crash.ips"))
        }

        if let updatesDirectory = try? UpdateStartupConfirmation.updateStorageDirectory() {
            let updateLogs = ((try? fileManager.contentsOfDirectory(
                at: updatesDirectory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )) ?? [])
                .filter { $0.pathExtension.lowercased() == "log" }
                .sorted { lhs, rhs in
                    let left = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    let right = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    return left > right
                }
                .prefix(3)
            for (index, source) in updateLogs.enumerated() {
                let destination = root.appendingPathComponent("update-log-\(index + 1).txt")
                if let text = try? String(contentsOf: source, encoding: .utf8) {
                    try? redact(text).write(to: destination, atomically: true, encoding: .utf8)
                }
            }
        }

        let manifest = """
        {
          "format": "MeloDiagnosticReport",
          "schemaVersion": 1,
          "reportID": "\(reportID.uuidString)",
          "containsRecordedAudio": false,
          "automaticUploadConfigured": \(uploadConfigured ? "true" : "false")
        }
        """
        try manifest.write(to: root.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let archive = fileManager.temporaryDirectory
            .appendingPathComponent("Melo-Diagnostic-\(formatter.string(from: Date())).zip")
        try? fileManager.removeItem(at: archive)
        try run("/usr/bin/ditto", arguments: ["-c", "-k", "--sequesterRsrc", root.path, archive.path])
        try? fileManager.removeItem(at: root)
        return archive
    }

    private nonisolated static func latestCrashReport() -> URL? {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)
        let candidates = ((try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []).filter {
            $0.lastPathComponent.hasPrefix("Melo-") && $0.pathExtension == "ips"
        }
        return candidates.max { lhs, rhs in
            let left = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let right = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return left < right
        }
    }

    private nonisolated static func currentArchitecture() -> String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }

    private nonisolated static func run(_ executable: String, arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw NSError(
                domain: "Melo.Diagnostics",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: output]
            )
        }
    }

    private nonisolated static func runAndCapture(_ executable: String, arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(decoding: data, as: UTF8.self)
        } catch {
            return "Could not collect logs: \(error.localizedDescription)"
        }
    }

    private nonisolated static func redact(_ text: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return text.replacingOccurrences(of: home, with: "/Users/<user>")
    }

    private nonisolated static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
