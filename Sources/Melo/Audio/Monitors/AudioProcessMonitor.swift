// Melo/Audio/Monitors/AudioProcessMonitor.swift
import AppKit
import AudioToolbox
import os

/// Lightweight value for detecting process list changes without comparing icons/names.
private struct AppFingerprint: Hashable {
    let pid: pid_t
    let objectIDs: [AudioObjectID]
    let persistenceIdentifier: String
}

/// Lightweight value for detecting launches and quits even before an app creates
/// a Core Audio process object.
private struct OpenAppFingerprint: Hashable {
    let pid: pid_t
    let persistenceIdentifier: String
    let name: String
}

@Observable
@MainActor
final class AudioProcessMonitor: AudioProcessMonitoring {
    private(set) var activeApps: [AudioApp] = []
    private(set) var openApps: [AudioApp] = []
    var onAppsChanged: (([AudioApp]) -> Void)?

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Melo", category: "AudioProcessMonitor")

    /// Bundle ID prefixes for system daemons that should be filtered from the apps list
    /// These produce system audio (Siri, alerts, notifications) and shouldn't appear as user apps
    private static let systemDaemonPrefixes: [String] = [
        "com.apple.siri",
        "com.apple.Siri",
        "com.apple.assistant",
        "com.apple.audio",
        "com.apple.coreaudio",
        "com.apple.mediaremote",
        "com.apple.accessibility.heard",
        "com.apple.hearingd",
        "com.apple.voicebankingd",
        "com.apple.systemsound",
        "com.apple.FrontBoardServices",
        "com.apple.frontboard",
        "com.apple.springboard",
        "com.apple.notificationcenter",
        "com.apple.NotificationCenter",
        "com.apple.UserNotifications",
        "com.apple.usernotifications",
        "com.apple.SpeechRecognitionCore",
        "com.apple.speech",
        "com.apple.dictation",
        "com.apple.corespeech",
        "com.apple.CoreSpeech",
        "com.apple.VoiceControl",
        "com.apple.voicecontrol",
    ]

    /// Process names for system daemons (fallback when bundle ID is nil or different format)
    private static let systemDaemonNames: [String] = [
        "systemsoundserverd",
        "systemsoundserv",
        "coreaudiod",
        "audiomxd",
        "speechrecognitiond",
        "dictationd",
        "corespeech",
    ]

    /// Returns true if the bundle ID or process name indicates a system daemon that should be filtered
    private func isSystemDaemon(bundleID: String?, name: String) -> Bool {
        // Check bundle ID prefixes
        if let bundleID {
            if Self.systemDaemonPrefixes.contains(where: { bundleID.hasPrefix($0) }) {
                return true
            }
        }

        // Check process name (handles nil bundleID and format variations)
        let lowercaseName = name.lowercased()
        if Self.systemDaemonNames.contains(where: { lowercaseName.hasPrefix($0) }) {
            return true
        }

        return false
    }

    // Property listeners
    private var processListListenerBlock: AudioObjectPropertyListenerBlock?
    private var processListenerBlocks: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]
    private var monitoredProcesses: Set<AudioObjectID> = []
    private var periodicRefreshTask: Task<Void, Never>?
    private var workspaceObserverTokens: [NSObjectProtocol] = []

    private var processListAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyProcessObjectList,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    /// Function type for the private responsibility API
    private typealias ResponsibilityFunc = @convention(c) (pid_t) -> pid_t

    /// Gets the "responsible" PID for a process using Apple's private API.
    /// This is what Activity Monitor uses to show the correct parent for XPC services.
    private func getResponsiblePID(for pid: pid_t) -> pid_t? {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -1), "responsibility_get_pid_responsible_for_pid") else {
            return nil
        }
        let responsiblePID = unsafeBitCast(symbol, to: ResponsibilityFunc.self)(pid)
        return responsiblePID > 0 && responsiblePID != pid ? responsiblePID : nil
    }

    /// Finds the responsible application for a helper/XPC process.
    /// Uses Apple's responsibility API first, falls back to process tree walking.
    private func findResponsibleApp(
        for pid: pid_t,
        in runningAppsByPID: [pid_t: NSRunningApplication]
    ) -> NSRunningApplication? {
        // First try Apple's responsibility API (works for XPC services like Safari's WebKit processes)
        if let responsiblePID = getResponsiblePID(for: pid),
           let app = runningAppsByPID[responsiblePID],
           app.bundleURL?.pathExtension == "app" {
            return app
        }

        // Fall back to walking up the process tree (works for Chrome/Brave helpers)
        var currentPID = pid
        var visited = Set<pid_t>()

        while currentPID > 1 && !visited.contains(currentPID) {
            visited.insert(currentPID)

            // Check if this PID is a proper app bundle (.app, not .xpc service)
            if let app = runningAppsByPID[currentPID],
               app.bundleURL?.pathExtension == "app" {
                return app
            }

            // Get parent PID using sysctl
            var info = kinfo_proc()
            var size = MemoryLayout<kinfo_proc>.size
            var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, currentPID]

            guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { break }

            let parentPID = info.kp_eproc.e_ppid
            if parentPID == currentPID { break }
            currentPID = parentPID
        }

        return nil
    }

    func start() {
        guard processListListenerBlock == nil else { return }

        logger.debug("Starting audio process monitor")

        // Set up listener first
        processListListenerBlock = { [weak self] numberAddresses, addresses in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }

        let status = AudioObjectAddPropertyListenerBlock(
            .system,
            &processListAddress,
            .main,
            processListListenerBlock!
        )

        if status != noErr {
            logger.error("Failed to add process list listener: \(status)")
        }

        startWorkspaceObservers()

        // Initial refresh
        refresh()

        // Periodic refresh as safety net — CoreAudio property listeners can miss
        // notifications during rapid process lifecycle changes (quit + relaunch).
        startPeriodicRefresh()
    }

    func stop() {
        logger.debug("Stopping audio process monitor")

        periodicRefreshTask?.cancel()
        periodicRefreshTask = nil
        stopWorkspaceObservers()

        // Remove process list listener
        if let block = processListListenerBlock {
            AudioObjectRemovePropertyListenerBlock(.system, &processListAddress, .main, block)
            processListListenerBlock = nil
        }

        // Remove all per-process listeners
        removeAllProcessListeners()
    }

    private func startPeriodicRefresh() {
        periodicRefreshTask?.cancel()
        periodicRefreshTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                // 10s is sufficient as a safety net — HAL listeners handle most changes.
                // Lower intervals waste CPU at idle (#176).
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled, let self else { return }
                self.refresh()
            }
        }
    }

    /// NSWorkspace notifications make user-facing apps appear immediately. The
    /// periodic refresh remains as a safety net for activation-policy changes.
    private func startWorkspaceObservers() {
        guard workspaceObserverTokens.isEmpty else { return }

        let center = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
        ]
        workspaceObserverTokens = names.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.refresh()
                }
            }
        }
    }

    private func stopWorkspaceObservers() {
        let center = NSWorkspace.shared.notificationCenter
        for token in workspaceObserverTokens {
            center.removeObserver(token)
        }
        workspaceObserverTokens.removeAll()
    }

    /// Builds the pre-audio app list from ordinary, user-facing macOS apps.
    /// NSWorkspace does not expose an "audio capable" entitlement, so regular
    /// application bundles are the most accurate public preflight signal. Any
    /// accessory/background app that actually uses audio still appears through
    /// the Core Audio process list.
    private func discoverOpenApps(
        from runningApps: [NSRunningApplication],
        excludingPID myPID: pid_t
    ) -> [AudioApp] {
        var byIdentifier: [String: AudioApp] = [:]
        let ownBundleID = Bundle.main.bundleIdentifier

        for runningApp in runningApps {
            guard runningApp.processIdentifier != myPID,
                  !runningApp.isTerminated,
                  runningApp.activationPolicy == .regular,
                  runningApp.bundleURL?.pathExtension.lowercased() == "app",
                  let name = runningApp.localizedName?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty else { continue }

            let bundleID = runningApp.bundleIdentifier
            guard bundleID == nil || bundleID != ownBundleID else { continue }
            guard !isSystemDaemon(bundleID: bundleID, name: name) else { continue }

            let icon = runningApp.icon
                ?? runningApp.bundleURL.map { NSWorkspace.shared.icon(forFile: $0.path) }
                ?? NSImage(systemSymbolName: "app.fill", accessibilityDescription: nil)
                ?? NSImage()
            let app = AudioApp(
                id: runningApp.processIdentifier,
                processObjectIDs: [],
                name: name,
                icon: icon,
                bundleID: bundleID,
                executablePath: runningApp.executableURL?.path
            )

            // Multiple instances of the same bundle share one persisted mixer
            // profile and therefore one row. Pick deterministically to avoid UI churn.
            if let existing = byIdentifier[app.persistenceIdentifier], existing.id < app.id {
                continue
            }
            byIdentifier[app.persistenceIdentifier] = app
        }

        return byIdentifier.values.sorted {
            let comparison = $0.name.localizedCaseInsensitiveCompare($1.name)
            if comparison == .orderedSame {
                return $0.persistenceIdentifier < $1.persistenceIdentifier
            }
            return comparison == .orderedAscending
        }
    }

    private func refresh() {
        do {
            let processIDs = try AudioObjectID.readProcessList()
            let runningApps = NSWorkspace.shared.runningApplications
            let runningAppsByPID = Dictionary(
                runningApps.map { ($0.processIdentifier, $0) },
                uniquingKeysWith: { _, latest in latest }
            )
            let myPID = ProcessInfo.processInfo.processIdentifier
            let discoveredOpenApps = discoverOpenApps(from: runningApps, excludingPID: myPID)

            var appsByPID: [pid_t: AudioApp] = [:]

            for objectID in processIDs {
                guard let pid = try? objectID.readProcessPID(), pid != myPID else { continue }
                guard objectID.readProcessIsRunning() else { continue }

                // Try to find the parent app (for helper processes like Safari Graphics and Media)
                let directApp = runningAppsByPID[pid]

                // Check if it's a real app bundle (.app), not an XPC service (.xpc)
                let isRealApp = directApp?.bundleURL?.pathExtension == "app"
                let resolvedApp = isRealApp ? directApp : findResponsibleApp(for: pid, in: runningAppsByPID)
                let parentPID = resolvedApp?.processIdentifier ?? pid
                let isHelper = parentPID != pid

                // Use resolved app's info, fall back to Core Audio bundle ID
                let name = resolvedApp?.localizedName
                    ?? objectID.readProcessBundleID()?.components(separatedBy: ".").last
                    ?? "Unknown"
                let icon = resolvedApp?.icon
                    ?? NSImage(systemSymbolName: "app.fill", accessibilityDescription: nil)
                    ?? NSImage()
                let bundleID = resolvedApp?.bundleIdentifier ?? objectID.readProcessBundleID()

                // Skip system daemons (siri, coreaudio, etc.) - they shouldn't appear in the apps list
                if isSystemDaemon(bundleID: bundleID, name: name) { continue }

                // Merge helper process objectIDs into parent app entry
                if let existing = appsByPID[parentPID] {
                    if !existing.processObjectIDs.contains(objectID) {
                        var mergedIDs = existing.processObjectIDs
                        mergedIDs.append(objectID)
                        mergedIDs.sort()
                        appsByPID[parentPID] = AudioApp(
                            id: existing.id,
                            processObjectIDs: mergedIDs,
                            name: existing.name,
                            icon: existing.icon,
                            bundleID: existing.bundleID,
                            executablePath: existing.executablePath,
                            isHelperBacked: existing.isHelperBacked || isHelper
                        )
                    }
                } else {
                    appsByPID[parentPID] = AudioApp(
                        id: parentPID,
                        processObjectIDs: [objectID],
                        name: name,
                        icon: icon,
                        bundleID: bundleID,
                        executablePath: resolvedApp?.executableURL?.path,
                        isHelperBacked: isHelper
                    )
                }
            }

            // Update per-process listeners
            updateProcessListeners(for: processIDs)

            // Collapse multiple launched instances of one bundle into a single row
            // and one tap containing every process object. Mixer state is keyed by
            // the same persistence identifier, so showing duplicates would be both
            // visually unstable and ambiguous.
            var appsByIdentifier: [String: AudioApp] = [:]
            for app in appsByPID.values.sorted(by: { $0.id < $1.id }) {
                if let existing = appsByIdentifier[app.persistenceIdentifier] {
                    let mergedObjectIDs = Array(Set(existing.processObjectIDs + app.processObjectIDs)).sorted()
                    appsByIdentifier[app.persistenceIdentifier] = AudioApp(
                        id: existing.id,
                        processObjectIDs: mergedObjectIDs,
                        name: existing.name,
                        icon: existing.icon,
                        bundleID: existing.bundleID,
                        executablePath: existing.executablePath ?? app.executablePath,
                        isHelperBacked: existing.isHelperBacked || app.isHelperBacked
                    )
                } else {
                    appsByIdentifier[app.persistenceIdentifier] = app
                }
            }

            let sorted = appsByIdentifier.values.sorted {
                let comparison = $0.name.localizedCaseInsensitiveCompare($1.name)
                if comparison == .orderedSame {
                    return $0.persistenceIdentifier < $1.persistenceIdentifier
                }
                return comparison == .orderedAscending
            }

            // Only fire callback if the app list actually changed (avoids churn from periodic refresh)
            let oldSet = Set(activeApps.map {
                AppFingerprint(pid: $0.id, objectIDs: $0.processObjectIDs, persistenceIdentifier: $0.persistenceIdentifier)
            })
            let newSet = Set(sorted.map {
                AppFingerprint(pid: $0.id, objectIDs: $0.processObjectIDs, persistenceIdentifier: $0.persistenceIdentifier)
            })
            let oldOpenSet = Set(openApps.map {
                OpenAppFingerprint(pid: $0.id, persistenceIdentifier: $0.persistenceIdentifier, name: $0.name)
            })
            let newOpenSet = Set(discoveredOpenApps.map {
                OpenAppFingerprint(pid: $0.id, persistenceIdentifier: $0.persistenceIdentifier, name: $0.name)
            })

            activeApps = sorted
            openApps = discoveredOpenApps
            if oldSet != newSet || oldOpenSet != newOpenSet {
                onAppsChanged?(activeApps)
            }

        } catch {
            logger.error("Failed to refresh process list: \(error.localizedDescription)")
        }
    }

    private func updateProcessListeners(for processIDs: [AudioObjectID]) {
        let currentSet = Set(processIDs)

        // Remove listeners for processes that are gone
        let removed = monitoredProcesses.subtracting(currentSet)
        for objectID in removed {
            removeProcessListener(for: objectID)
        }

        // Add listeners for new processes
        let added = currentSet.subtracting(monitoredProcesses)
        for objectID in added {
            addProcessListener(for: objectID)
        }

        monitoredProcesses = currentSet
    }

    private func addProcessListener(for objectID: AudioObjectID) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunning,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }

        let status = AudioObjectAddPropertyListenerBlock(objectID, &address, .main, block)

        if status == noErr {
            processListenerBlocks[objectID] = block
        } else {
            logger.warning("Failed to add isRunning listener for \(objectID): \(status)")
        }
    }

    private func removeProcessListener(for objectID: AudioObjectID) {
        guard let block = processListenerBlocks.removeValue(forKey: objectID) else { return }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunning,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectRemovePropertyListenerBlock(objectID, &address, .main, block)
        // Tolerate kAudioHardwareBadObjectError (-66680): process object already destroyed
        if status != noErr && status != OSStatus(kAudioHardwareBadObjectError) {
            logger.warning("Failed to remove isRunning listener for \(objectID): \(status)")
        }
    }

    private func removeAllProcessListeners() {
        for objectID in monitoredProcesses {
            removeProcessListener(for: objectID)
        }
        monitoredProcesses.removeAll()
        processListenerBlocks.removeAll()
    }

}
