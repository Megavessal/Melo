// Melo/Audio/Engine/AudioEngine.swift
import AppKit
import AudioToolbox
import Foundation
import os
import UserNotifications

@Observable
@MainActor
final class AudioEngine {
    let processMonitor: any AudioProcessMonitoring
    let deviceMonitor: any AudioDeviceProviding
    let bluetoothDeviceMonitor: BluetoothDeviceMonitor
    let deviceVolumeMonitor: any DeviceVolumeProviding
    let volumeState: VolumeState
    let settingsManager: SettingsManager
    let audioUnitHost: AudioUnitHost
    let autoEQProfileManager: AutoEQProfileManager
    let permission: AudioRecordingPermission
    let appListCoordinator: AppListCoordinator
    let consumerUndoManager: ConsumerUndoManager

    #if !APP_STORE
    let ddcController: DDCController
    #endif

    private var taps: [pid_t: any ProcessTapControlling] = [:]
    /// First permission-triggering AudioDeviceStart calls may wait for macOS.
    /// Keep them off the main actor and suppress duplicate activation attempts.
    @ObservationIgnored private var pendingTapActivationPIDs: Set<pid_t> = []
    private var isApplyingConsumerState = false
    private var callDuckingActive = false
    private var communicationAppPIDs: Set<pid_t> = []
    private var callDuckingMonitoringPIDs: Set<pid_t> = []
    private var batterySavingAudioActive = false
    private var callDuckingGain: Float = 1.0

    private struct AudioUnitRebuildKey: Hashable {
        let pid: pid_t
        let scope: AudioUnitProcessingScope
    }

    @ObservationIgnored private var audioUnitRebuildTasks: [AudioUnitRebuildKey: Task<Void, Never>] = [:]
    @ObservationIgnored private var audioUnitRebuildTokens: [AudioUnitRebuildKey: UUID] = [:]

    /// Factory for creating tap controllers. Overridable for testing.
    private let tapFactory: @MainActor (AudioApp, [String], String?) throws -> any ProcessTapControlling

    /// Closure to check if a device is alive. Overridable for testing.
    private let isAliveCheck: (AudioDeviceID) -> Bool

    /// One-shot HAL listeners for devices that were present but not alive during priority resolution.
    /// Keyed by AudioDeviceID. Each entry holds the device UID, listener block, and a timeout task.
    private var aliveWatchers: [AudioDeviceID: (uid: String, block: AudioObjectPropertyListenerBlock, timeout: Task<Void, Never>)] = [:]

    /// Number of pending alive watchers (exposed for testing).
    var pendingAliveWatcherCount: Int { aliveWatchers.count }

    private var appliedPIDs: Set<pid_t> = []
    private var appDeviceRouting: [pid_t: String] = [:]  // pid → deviceUID (always explicit)
    private var followsDefault: Set<pid_t> = []  // Apps that follow system default
    /// The last output default confirmed by Melo (user change or programmatic switch).
    /// Used to restore after macOS auto-switches to a lower-priority device.
    private var lastConfirmedDefaultUID: String?
    /// Timestamp of the last auto-switch override. Used to distinguish rapid BT auto-switches
    /// (< 1s apart) from deliberate user changes (> 1s after last override).
    private var lastAutoSwitchOverrideTime: Date?
    private var pendingCleanup: [pid_t: Task<Void, Never>] = [:]  // Grace period for stale tap cleanup
    private var staleCleanupTask: Task<Void, Never>?  // Debounced cleanup scheduling
    /// Long enough to absorb brief Core Audio `isRunning` flicker without
    /// leaving the macOS system-audio privacy indicator active for 30 seconds.
    private let staleTapGracePeriodSeconds: Double = 5
    private var healthMonitorTask: Task<Void, Never>?  // Periodic tap health monitor
    private var tapRecoveryCooldownUntil: [pid_t: Date] = [:]  // Prevents tap recreation thrashing
    /// Used to distinguish a genuinely new Core Audio process from periodic
    /// monitor refreshes (and from open-app-only changes). A new process is a
    /// sensible retry boundary for non-permission startup failures.
    private var lastObservedAudioAppIDs: Set<pid_t> = []
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Melo", category: "AudioEngine")

    // MARK: - Priority State Machine

    /// Tracks whether we're waiting for macOS to potentially auto-switch after a device connect.
    private enum PriorityState {
        case stable
        case pendingAutoSwitch(connectedDeviceUID: String, timeoutTask: Task<Void, Never>)
    }

    private var outputPriorityState: PriorityState = .stable
    private var inputPriorityState: PriorityState = .stable

    /// Grace period for auto-switch detection (wired devices)
    private let autoSwitchGracePeriod: TimeInterval = 2.0

    /// Extended grace period for Bluetooth devices (firmware handshake takes longer)
    private let btAutoSwitchGracePeriod: TimeInterval = 5.0

    // MARK: - Echo Suppression

    private let outputEchoTracker = EchoTracker(label: "Output")
    private let inputEchoTracker = EchoTracker(label: "Input")

    var outputDevices: [AudioDevice] {
        deviceMonitor.outputDevices
    }

    func outputVolumeBackend(for deviceID: AudioDeviceID) -> VolumeControlTier {
        deviceVolumeMonitor.outputVolumeBackend(for: deviceID)
    }

    var inputDevices: [AudioDevice] {
        deviceMonitor.inputDevices
    }

    /// Output devices sorted by user-defined priority order.
    /// Devices in the priority list appear in that order; new/unknown devices are appended alphabetically.
    var prioritySortedOutputDevices: [AudioDevice] {
        let devices = outputDevices
        let priorityOrder = settingsManager.devicePriorityOrder
        let devicesByUID = Dictionary(devices.map { ($0.uid, $0) }, uniquingKeysWith: { _, latest in latest })

        // Collect devices in priority order (skip stale UIDs)
        var sorted: [AudioDevice] = []
        var seen = Set<String>()
        for uid in priorityOrder {
            if let device = devicesByUID[uid] {
                sorted.append(device)
                seen.insert(uid)
            }
        }

        // Append new devices alphabetically
        let remaining = devices
            .filter { !seen.contains($0.uid) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        sorted.append(contentsOf: remaining)

        return sorted
    }

    /// Input devices sorted by user-defined priority order.
    var prioritySortedInputDevices: [AudioDevice] {
        let devices = inputDevices
        let priorityOrder = settingsManager.inputDevicePriorityOrder
        let devicesByUID = Dictionary(devices.map { ($0.uid, $0) }, uniquingKeysWith: { _, latest in latest })

        var sorted: [AudioDevice] = []
        var seen = Set<String>()
        for uid in priorityOrder {
            if let device = devicesByUID[uid] {
                sorted.append(device)
                seen.insert(uid)
            }
        }

        let remaining = devices
            .filter { !seen.contains($0.uid) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        sorted.append(contentsOf: remaining)

        return sorted
    }

    /// Registers any output devices not yet in the priority list.
    /// Call this when devices change (not from computed properties).
    func registerNewDevicesInPriority() {
        for device in outputDevices {
            settingsManager.ensureDeviceInPriority(device.uid)
        }
        for device in inputDevices {
            settingsManager.ensureInputDeviceInPriority(device.uid)
        }
    }

    /// Returns the highest-priority device that is both connected and alive.
    /// `isDeviceAlive()` is checked internally — callers never need to check separately.
    static func resolveHighestPriority(
        priorityOrder: [String],
        connectedDevices: [AudioDevice],
        excluding: String? = nil,
        isAlive: ((AudioDeviceID) -> Bool)? = nil
    ) -> AudioDevice? {
        let aliveCheck = isAlive ?? { $0.isDeviceAlive() }
        let connected = Dictionary(
            connectedDevices.map { ($0.uid, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
        for uid in priorityOrder {
            guard uid != excluding,
                  let device = connected[uid],
                  aliveCheck(device.id) else { continue }
            return device
        }
        // Fallback: any alive connected device not excluded
        return connectedDevices.first {
            $0.uid != excluding && aliveCheck($0.id)
        }
    }


    init(
        permission: AudioRecordingPermission,
        settingsManager: SettingsManager,
        autoEQProfileManager: AutoEQProfileManager,
        deviceProvider: (any AudioDeviceProviding)? = nil,
        processMonitor: (any AudioProcessMonitoring)? = nil,
        deviceVolumeMonitor: (any DeviceVolumeProviding)? = nil,
        tapFactory: (@MainActor (AudioApp, [String], String?) throws -> any ProcessTapControlling)? = nil,
        isAlive: ((AudioDeviceID) -> Bool)? = nil,
        startMonitorsAutomatically: Bool = true
    ) {
        self.permission = permission
        let manager = settingsManager
        self.settingsManager = manager
        self.audioUnitHost = AudioUnitHost()
        self.appListCoordinator = AppListCoordinator(settingsManager: manager)
        self.consumerUndoManager = ConsumerUndoManager()
        self.autoEQProfileManager = autoEQProfileManager
        self.volumeState = VolumeState(settingsManager: manager)
        self.isAliveCheck = isAlive ?? { $0.isDeviceAlive() }

        // If a custom deviceProvider is given, use it directly.
        // Otherwise create a real AudioDeviceMonitor (needed by DeviceVolumeMonitor and default tap factory).
        let realDeviceMonitor: AudioDeviceMonitor?
        if let provider = deviceProvider {
            realDeviceMonitor = provider as? AudioDeviceMonitor
            self.deviceMonitor = provider
        } else {
            let monitor = AudioDeviceMonitor()
            realDeviceMonitor = monitor
            self.deviceMonitor = monitor
        }
        self.processMonitor = processMonitor ?? AudioProcessMonitor()
        self.bluetoothDeviceMonitor = BluetoothDeviceMonitor()

        #if !APP_STORE
        let ddc = DDCController(settingsManager: manager)
        self.ddcController = ddc
        if let dvMonitor = deviceVolumeMonitor {
            self.deviceVolumeMonitor = dvMonitor
        } else {
            guard let realDeviceMonitor else {
                preconditionFailure("AudioEngine: must provide deviceVolumeMonitor when deviceProvider is not AudioDeviceMonitor")
            }
            self.deviceVolumeMonitor = DeviceVolumeMonitor(deviceMonitor: realDeviceMonitor, settingsManager: manager, ddcController: ddc)
        }
        #else
        if let dvMonitor = deviceVolumeMonitor {
            self.deviceVolumeMonitor = dvMonitor
        } else {
            guard let realDeviceMonitor else {
                preconditionFailure("AudioEngine: must provide deviceVolumeMonitor when deviceProvider is not AudioDeviceMonitor")
            }
            self.deviceVolumeMonitor = DeviceVolumeMonitor(deviceMonitor: realDeviceMonitor, settingsManager: manager)
        }
        #endif

        // Tap factory: use provided factory or default to ProcessTapController
        if let factory = tapFactory {
            self.tapFactory = factory
        } else {
            self.tapFactory = { app, deviceUIDs, preferredSource in
                if deviceUIDs.count == 1 {
                    return ProcessTapController(
                        app: app,
                        targetDeviceUID: deviceUIDs[0],
                        deviceMonitor: realDeviceMonitor,
                        preferredTapSourceDeviceUID: preferredSource
                    )
                } else {
                    return ProcessTapController(
                        app: app,
                        targetDeviceUIDs: deviceUIDs,
                        deviceMonitor: realDeviceMonitor,
                        preferredTapSourceDeviceUID: preferredSource
                    )
                }
            }
        }

        outputEchoTracker.onTimeout = { [weak self] _ in
            self?.restoreConfirmedDefault()
        }
        inputEchoTracker.onTimeout = { [weak self] _ in
            guard let self, self.settingsManager.appSettings.lockInputDevice else { return }
            self.restoreLockedInputDevice()
        }

        // Wire callbacks — needed for both test and production mode
        wireCallbacks()
        audioUnitHost.onProfileRuntimeChanged = { [weak self] profileID in
            self?.handleAudioUnitProfileRuntimeChanged(profileID)
        }

        // Core Audio has no public system-audio permission preflight/request API.
        // Normal launches therefore queue a real tap activation automatically;
        // only AudioDeviceStart success/failure updates the permission status.
        permission.onRequestAccess = { [weak self] in
            self?.beginCapturePermissionAttempt()
        }

        if startMonitorsAutomatically {
            // Mark startup pending before monitor discovery so the first real
            // audio process can activate immediately. This never calls TCC or
            // prompts by itself; only a subsequent process-tap IO start can.
            permission.startAutomatically()

            Task { @MainActor in
                // Process-object discovery is read-only and doesn't capture audio.
                // Keep it running so a pending request can start as soon as an app
                // actually plays audio.
                self.processMonitor.start()
                self.deviceMonitor.start()
                // Bluetooth is deliberately absent from this block. Launching
                // Melo is not reaching for a Bluetooth feature, so nothing here
                // may touch IOBluetooth — see
                // `startBluetoothMonitoringIfEnabled()`.

                #if !APP_STORE
                ddc.onProbeCompleted = { [weak self] in
                    self?.deviceVolumeMonitor.refreshAfterDDCProbe()
                    self?.refreshAllTapOutputStates()
                }
                ddc.start()
                #endif

                // Start device volume monitor AFTER deviceMonitor.start() populates devices
                self.deviceVolumeMonitor.start()

                self.applyPersistedSettings()
                self.registerNewDevicesInPriority()
                // Seed the confirmed default from whatever macOS has at startup
                self.lastConfirmedDefaultUID = self.deviceVolumeMonitor.defaultDeviceUID
                if manager.appSettings.lockInputDevice {
                    self.restoreLockedInputDevice()
                }
            }
        }
    }

    private func beginCapturePermissionAttempt() {
        processMonitor.start()
        applyPersistedSettings()
    }

    private func recordCaptureStarted() {
        let wasAuthorized = permission.status == .authorized
        permission.recordCaptureStarted()
        startHealthMonitor()

        if !wasAuthorized {
            logger.info("Audio capture authorized by a successful process-tap IO start")
        }
    }

    private func recordCaptureStartFailure(_ error: Error) {
        permission.recordCaptureStartFailure(error)
    }

    /// Wire all event callbacks from monitors to AudioEngine handlers.
    private func wireCallbacks() {
        // Sync device volume changes to taps for VU meter accuracy
        deviceVolumeMonitor.onVolumeChanged = { [weak self] deviceID, newVolume in
            guard let self else { return }
            guard let deviceUID = self.deviceMonitor.outputDevices.first(where: { $0.id == deviceID })?.uid else { return }
            let loudnessEnabled = self.settingsManager.appSettings.loudnessCompensationEnabled
            for (_, tap) in self.taps {
                if tap.currentDeviceUID == deviceUID {
                    tap.currentDeviceVolume = newVolume
                    if tap.currentDeviceUIDs.count == 1,
                       self.outputVolumeBackend(for: deviceID) == .software {
                        tap.volume = self.effectiveVolume(for: tap.app.id, deviceUIDs: tap.currentDeviceUIDs)
                    }
                    tap.updateLoudnessCompensation(
                        volume: self.effectiveLoudnessVolume(for: tap),
                        enabled: loudnessEnabled
                    )
                }
            }
            if self.outputVolumeBackend(for: deviceID) == .software {
                self.reconcileTapRequirements()
            }
        }

        deviceVolumeMonitor.onMuteChanged = { [weak self] deviceID, isMuted in
            guard let self else { return }
            guard let deviceUID = self.deviceMonitor.outputDevices.first(where: { $0.id == deviceID })?.uid else { return }
            for (_, tap) in self.taps {
                if tap.currentDeviceUID == deviceUID {
                    tap.isDeviceMuted = isMuted
                    if tap.currentDeviceUIDs.count == 1,
                       self.outputVolumeBackend(for: deviceID) == .software {
                        tap.volume = self.effectiveVolume(for: tap.app.id, deviceUIDs: tap.currentDeviceUIDs)
                    }
                }
            }
            if self.outputVolumeBackend(for: deviceID) == .software {
                self.reconcileTapRequirements()
            }
        }

        processMonitor.onAppsChanged = { [weak self] apps in
            guard let self else { return }

            let currentIDs = Set(apps.map(\.id))
            let hasNewAudioProcess = !currentIDs.subtracting(self.lastObservedAudioAppIDs).isEmpty
            self.lastObservedAudioAppIDs = currentIDs

            // A generic HAL/setup failure can be process-specific. Retry once
            // when a genuinely new Core Audio process arrives, but never retry
            // an explicit permission denial automatically.
            if hasNewAudioProcess {
                self.permission.retryAutomaticallyAfterEnvironmentChange()
            }

            self.applyPersistedSettings()
            self.scheduleStaleCleanup()
        }

        // Priority order closures — only for concrete AudioDeviceMonitor
        if let realMonitor = deviceMonitor as? AudioDeviceMonitor {
            realMonitor.outputPriorityOrder = { [weak self] in
                self?.settingsManager.devicePriorityOrder ?? []
            }
            realMonitor.inputPriorityOrder = { [weak self] in
                self?.settingsManager.inputDevicePriorityOrder ?? []
            }
            realMonitor.onBTDeviceSampleRateChanged = { [weak self] uid, newRate in
                Task { @MainActor [weak self] in
                    await self?.handleBTDeviceSampleRateChanged(uid: uid, newRate: newRate)
                }
            }
        }

        deviceMonitor.onDeviceDisconnected = { [weak self] deviceUID, deviceName in
            self?.handleDeviceDisconnected(deviceUID, name: deviceName)
            self?.bluetoothDeviceMonitor.refresh()
        }

        deviceMonitor.onDeviceConnected = { [weak self] deviceUID, deviceName in
            self?.handleDeviceConnected(deviceUID, name: deviceName)
            self?.bluetoothDeviceMonitor.notifyDeviceAppearedInCoreAudio()
        }

        deviceMonitor.onInputDeviceDisconnected = { [weak self] deviceUID, deviceName in
            self?.logger.info("Input device disconnected: \(deviceName) (\(deviceUID))")
            self?.handleInputDeviceDisconnected(deviceUID)
        }

        deviceMonitor.onInputDeviceConnected = { [weak self] deviceUID, deviceName in
            self?.logger.info("Input device connected: \(deviceName) (\(deviceUID))")
            self?.settingsManager.ensureInputDeviceInPriority(deviceUID)
            self?.handleInputDeviceConnected(deviceUID, name: deviceName)
        }

        deviceVolumeMonitor.onDefaultDeviceChanged = { [weak self] newDefaultUID in
            self?.handleDefaultDeviceChanged(newDefaultUID)
        }

        deviceVolumeMonitor.onDefaultInputDeviceChanged = { [weak self] newDefaultInputUID in
            Task { @MainActor [weak self] in
                self?.handleDefaultInputDeviceChanged(newDefaultInputUID)
            }
        }
    }

    var apps: [AudioApp] {
        processMonitor.activeApps
    }

    // MARK: - Displayable Apps (Audio Active + Open + Pinned Closed)

    /// All user-facing apps available to the mixer. NSWorkspace placeholders let
    /// users set up an app before it plays audio; when Core Audio exposes that app,
    /// the same persistence identifier seamlessly becomes an active row.
    var displayableApps: [DisplayableApp] {
        DisplayableApp.merged(
            activeApps: apps,
            openApps: processMonitor.openApps,
            pinnedAppInfo: appListCoordinator.pinnedAppInfo(),
            isPinned: { appListCoordinator.isPinned(identifier: $0) },
            isIgnored: { appListCoordinator.isIgnored(identifier: $0) }
        )
    }

    // MARK: - Pinning

    /// Pin an active app so it remains visible when inactive.
    func pinApp(_ app: AudioApp) {
        appListCoordinator.pinApp(app)
    }

    /// Pin an app Melo has never seen run, so its controls are in the popup
    /// waiting for it. The identifier must be the one the app will arrive under
    /// when it finally plays — `AudioApp.persistenceIdentifier(...)` is the only
    /// rule that produces it, and `InstalledApp` uses that same rule.
    func pinApp(identifier: String, displayName: String, bundleID: String?) {
        appListCoordinator.pinApp(
            identifier: identifier,
            displayName: displayName,
            bundleID: bundleID
        )
    }

    /// Unpin an app by its persistence identifier.
    func unpinApp(_ identifier: String) {
        appListCoordinator.unpinApp(identifier)
    }

    /// Check if an app is pinned.
    func isPinned(_ app: AudioApp) -> Bool {
        appListCoordinator.isPinned(app)
    }

    /// Check if an identifier is pinned (for inactive apps).
    func isPinned(identifier: String) -> Bool {
        appListCoordinator.isPinned(identifier: identifier)
    }

    // MARK: - Ignored Apps

    /// Hide an active app so Melo ignores it entirely. Persists the ignore,
    /// then tears down the live tap so audio returns to natural volume.
    func ignoreApp(_ app: AudioApp) {
        appListCoordinator.recordIgnore(app)

        if let tap = taps.removeValue(forKey: app.id) {
            tap.invalidate()
        }
        appDeviceRouting.removeValue(forKey: app.id)
        followsDefault.remove(app.id)
        appliedPIDs.remove(app.id)
    }

    /// Unhide an app by its persistence identifier.
    /// Immediately creates a tap if the app is currently running.
    func unignoreApp(_ identifier: String) {
        appListCoordinator.clearIgnore(identifier)
        applyPersistedSettings()
    }

    /// Check if an identifier is hidden.
    func isIgnored(identifier: String) -> Bool {
        appListCoordinator.isIgnored(identifier: identifier)
    }

    // MARK: - Inactive App Settings (by persistence identifier)

    /// A playing app can briefly fall out of Core Audio's `isRunning` list while
    /// its tap remains alive during the stale-cleanup grace period. If the app is
    /// still open, route placeholder-row edits through that retained tap as well
    /// as persistence so playback cannot resume with stale DSP state.
    private func retainedTapApp(for identifier: String) -> AudioApp? {
        guard let openPID = processMonitor.openApps.first(where: {
            $0.persistenceIdentifier == identifier
        })?.id,
              let tap = taps[openPID],
              tap.app.persistenceIdentifier == identifier else {
            return nil
        }
        return tap.app
    }

    func getVolumeForInactive(identifier: String) -> Float {
        if let app = retainedTapApp(for: identifier) {
            return getVolume(for: app)
        }
        return appListCoordinator.getVolumeForInactive(identifier: identifier)
    }

    func setVolumeForInactive(identifier: String, to volume: Float) {
        recordConsumerUndo(label: "Changed saved app volume", key: "volume:\(identifier)")
        if let app = retainedTapApp(for: identifier) {
            setVolume(for: app, to: volume)
            return
        }
        appListCoordinator.setVolumeForInactive(identifier: identifier, to: volume)
    }

    func getBoostForInactive(identifier: String) -> BoostLevel {
        if let app = retainedTapApp(for: identifier) {
            return getBoost(for: app)
        }
        return appListCoordinator.getBoostForInactive(identifier: identifier)
    }

    func setBoostForInactive(identifier: String, to boost: BoostLevel) {
        recordConsumerUndo(label: "Changed saved app boost", key: "boost:\(identifier)")
        if let app = retainedTapApp(for: identifier) {
            setBoost(for: app, to: boost)
            return
        }
        appListCoordinator.setBoostForInactive(identifier: identifier, to: boost)
    }

    func getMuteForInactive(identifier: String) -> Bool {
        if let app = retainedTapApp(for: identifier) {
            return getMute(for: app)
        }
        return appListCoordinator.getMuteForInactive(identifier: identifier)
    }

    func setMuteForInactive(identifier: String, to muted: Bool) {
        recordConsumerUndo(label: muted ? "Muted saved app" : "Unmuted saved app", key: "mute:\(identifier)")
        if let app = retainedTapApp(for: identifier) {
            setMute(for: app, to: muted)
            return
        }
        appListCoordinator.setMuteForInactive(identifier: identifier, to: muted)
    }

    func getEQSettingsForInactive(identifier: String) -> EQSettings {
        if let app = retainedTapApp(for: identifier) {
            return getEQSettings(for: app)
        }
        return appListCoordinator.getEQSettingsForInactive(identifier: identifier)
    }

    func setEQSettingsForInactive(_ settings: EQSettings, identifier: String) {
        recordConsumerUndo(label: "Changed saved app sound", key: "eq:\(identifier)")
        if let app = retainedTapApp(for: identifier) {
            setEQSettings(settings, for: app)
            return
        }
        appListCoordinator.setEQSettingsForInactive(settings, identifier: identifier)
    }

    func getStereoFieldSettingsForInactive(identifier: String) -> StereoFieldSettings {
        if let app = retainedTapApp(for: identifier) {
            return getStereoFieldSettings(for: app)
        }
        return appListCoordinator.getStereoFieldSettingsForInactive(identifier: identifier)
    }

    func setStereoFieldSettingsForInactive(_ settings: StereoFieldSettings, identifier: String) {
        recordConsumerUndo(label: "Changed saved app balance", key: "balance:\(identifier)")
        if let app = retainedTapApp(for: identifier) {
            setStereoFieldSettings(settings, for: app)
            return
        }
        appListCoordinator.setStereoFieldSettingsForInactive(settings, identifier: identifier)
    }

    func getDeviceRoutingForInactive(identifier: String) -> String? {
        if let app = retainedTapApp(for: identifier), let deviceUID = getDeviceUID(for: app) {
            return deviceUID
        }
        return appListCoordinator.getDeviceRoutingForInactive(identifier: identifier)
    }

    func setDeviceRoutingForInactive(identifier: String, deviceUID: String?) {
        recordConsumerUndo(label: "Changed where saved app plays", key: "route:\(identifier)")
        if let app = retainedTapApp(for: identifier) {
            setDevice(for: app, deviceUID: deviceUID)
            return
        }
        appListCoordinator.setDeviceRoutingForInactive(identifier: identifier, deviceUID: deviceUID)
    }

    func isFollowingDefaultForInactive(identifier: String) -> Bool {
        if let app = retainedTapApp(for: identifier) {
            return isFollowingDefault(for: app)
        }
        return appListCoordinator.isFollowingDefaultForInactive(identifier: identifier)
    }

    func getDeviceSelectionModeForInactive(identifier: String) -> DeviceSelectionMode {
        if let app = retainedTapApp(for: identifier) {
            return getDeviceSelectionMode(for: app)
        }
        return appListCoordinator.getDeviceSelectionModeForInactive(identifier: identifier)
    }

    func setDeviceSelectionModeForInactive(identifier: String, to mode: DeviceSelectionMode) {
        recordConsumerUndo(label: "Changed where saved app plays", key: "route-mode:\(identifier)")
        if let app = retainedTapApp(for: identifier) {
            setDeviceSelectionMode(for: app, to: mode)
            return
        }
        appListCoordinator.setDeviceSelectionModeForInactive(identifier: identifier, to: mode)
    }

    func getSelectedDeviceUIDsForInactive(identifier: String) -> Set<String> {
        if let app = retainedTapApp(for: identifier) {
            return getSelectedDeviceUIDs(for: app)
        }
        return appListCoordinator.getSelectedDeviceUIDsForInactive(identifier: identifier)
    }

    func setSelectedDeviceUIDsForInactive(identifier: String, to uids: Set<String>) {
        recordConsumerUndo(label: "Changed where saved app plays", key: "route-devices:\(identifier)")
        if let app = retainedTapApp(for: identifier) {
            setSelectedDeviceUIDs(for: app, to: uids)
            return
        }
        appListCoordinator.setSelectedDeviceUIDsForInactive(identifier: identifier, to: uids)
    }

    /// Begins paired-device discovery. **Only a user reaching for a Bluetooth
    /// feature may call this** — the first call is what makes macOS show its
    /// Bluetooth prompt, so the caller decides whether that prompt arrives with
    /// a reason on screen.
    ///
    /// It used to be called from the startup task above, behind a second guard
    /// on `onboardingVersionCompleted`. That guard was described as putting a
    /// Bluetooth onboarding page ahead of the system dialog. The page is real —
    /// it is page 3 of first-run setup, and `FirstRunOnboardingView` is one of
    /// this function's four call sites — but the guard was never what made the
    /// page arrive first: `SettingsManager.decodeSettings` stamps onboarding
    /// complete for every pre-existing install, so on any Mac that already had
    /// Melo both guards passed and launch touched IOBluetooth regardless. The
    /// gate only ever protected new installs, who are the one cohort the page
    /// already covers. Not touching IOBluetooth at launch at all is what
    /// actually holds, so the guard is gone rather than tightened.
    ///
    /// `bluetoothFeaturesEnabled` stays: someone who switched the feature off is
    /// never asked. `BluetoothDeviceMonitor.start()` is idempotent, so calling
    /// this from more than one entry point is safe.
    func startBluetoothMonitoringIfEnabled() {
        guard settingsManager.appSettings.bluetoothFeaturesEnabled else { return }
        bluetoothDeviceMonitor.start()
    }

    /// Audio levels for all active apps (for VU meter visualization)
    /// Returns a dictionary mapping PID to peak audio level (0-1)
    var audioLevels: [pid_t: Float] {
        var levels: [pid_t: Float] = [:]
        for (pid, tap) in taps {
            levels[pid] = tap.audioLevel
        }
        return levels
    }

    /// Get audio level for a specific app
    func getAudioLevel(for app: AudioApp) -> Float {
        taps[app.id]?.audioLevel ?? 0.0
    }

    /// Plays Melo's short first-run sound through a temporary process tap.
    /// Core Audio presents the system-audio permission sheet only when real tap
    /// IO starts, so this is the earliest honest request path available. The
    /// potentially blocking AudioDeviceStart call runs off the main actor.
    func runFirstRunAudioPrimer(soundURL: URL) async throws {
        if permission.status == .authorized {
            try await playPrimerSoundDirectly(soundURL)
            return
        }

        permission.beginFirstRunPrimerAttempt()
        let sound = try makePrimerSound(soundURL)
        guard sound.play() else {
            throw NSError(
                domain: "Melo.FirstRunAudioPrimer",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Melo could not play the introduction sound."]
            )
        }
        defer { sound.stop() }

        let processObjectIDs = try await waitForOwnAudioProcessObjects()
        guard let outputUID = deviceVolumeMonitor.defaultDeviceUID, !outputUID.isEmpty else {
            throw NSError(
                domain: "Melo.FirstRunAudioPrimer",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "No audio output is available."]
            )
        }

        let ownPID = ProcessInfo.processInfo.processIdentifier
        let ownApp = AudioApp(
            id: ownPID,
            processObjectIDs: processObjectIDs,
            // Named for what is actually playing. This said "Melo Introduction",
            // after a two-second clip that no longer exists; the primer now plays
            // the theme's opening bar, and this name is what the user sees if the
            // tap surfaces during the permission request.
            name: "Melo Theme",
            icon: NSApplication.shared.applicationIconImage ?? NSImage(),
            bundleID: Bundle.main.bundleIdentifier,
            executablePath: Bundle.main.executableURL?.path
        )
        let tap = try tapFactory(ownApp, [outputUID], outputUID)

        do {
            try await tap.activateWithoutBlockingMainThread(initial: TapInitialState())
            recordCaptureStarted()

            // The first play creates Melo's Core Audio process and gets the
            // permission flow started. Replay the chime after authorization so
            // the confirmation is heard through Melo's newly active route.
            sound.stop()
            sound.currentTime = 0
            guard sound.play() else {
                throw NSError(
                    domain: "Melo.FirstRunAudioPrimer",
                    code: 6,
                    userInfo: [NSLocalizedDescriptionKey: "Melo could not replay the introduction sound."]
                )
            }
            let playbackNanos = UInt64(max(0.8, sound.duration + 0.12) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: playbackNanos)
            await tap.invalidateAsync()
        } catch {
            await tap.invalidateAsync()
            recordCaptureStartFailure(error)
            throw error
        }
    }

    private func makePrimerSound(_ url: URL) throws -> NSSound {
        guard let sound = NSSound(contentsOf: url, byReference: false) else {
            throw NSError(
                domain: "Melo.FirstRunAudioPrimer",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "The introduction sound could not be loaded."]
            )
        }
        sound.volume = 0.72
        return sound
    }

    private func playPrimerSoundDirectly(_ url: URL) async throws {
        let sound = try makePrimerSound(url)
        guard sound.play() else {
            throw NSError(
                domain: "Melo.FirstRunAudioPrimer",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "Melo could not play the introduction sound."]
            )
        }
        try? await Task.sleep(for: .seconds(2))
        sound.stop()
    }

    private func waitForOwnAudioProcessObjects() async throws -> [AudioObjectID] {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        for _ in 0..<30 {
            try Task.checkCancellation()
            let matches = (try? AudioObjectID.readProcessList())?.filter {
                (try? $0.readProcessPID()) == ownPID && $0.readProcessIsRunning()
            } ?? []
            if !matches.isEmpty { return matches }
            try await Task.sleep(for: .milliseconds(70))
        }
        throw NSError(
            domain: "Melo.FirstRunAudioPrimer",
            code: 5,
            userInfo: [NSLocalizedDescriptionKey: "Melo could not prepare its audio connection. Try playing the sound again."]
        )
    }

    func start() {
        // Monitors have internal guards against double-starting
        processMonitor.start()
        deviceMonitor.start()
        permission.startAutomatically()
        applyPersistedSettings()
        if permission.status == .authorized {
            startHealthMonitor()
        }

        // Restore locked input device if feature is enabled
        if settingsManager.appSettings.lockInputDevice {
            restoreLockedInputDevice()
        }

        logger.info("AudioEngine started")
    }

    func stop() {
        stopHealthMonitor()
        for task in audioUnitRebuildTasks.values { task.cancel() }
        audioUnitRebuildTasks.removeAll()
        audioUnitRebuildTokens.removeAll()
        processMonitor.stop()
        deviceMonitor.stop()
        for tap in taps.values {
            tap.invalidate()
        }
        taps.removeAll()
        logger.info("AudioEngine stopped")
    }

    /// Explicit shutdown for app termination. Ensures all listeners are cleaned up.
    /// Call from applicationWillTerminate or equivalent lifecycle hook.
    /// Note: For menu bar apps, process exit cleans up resources anyway, so this is optional.
    func shutdown() {
        stop()
        deviceVolumeMonitor.stop()
        logger.info("AudioEngine shutdown complete")
    }

    // MARK: - Consumer Scenes, Undo & Repair

    func captureConsumerScene(
        name: String = "Current Setup",
        symbolName: String = "slider.horizontal.3"
    ) -> ConsumerScene {
        let names = Dictionary(
            uniqueKeysWithValues: displayableApps.map { ($0.id, $0.displayName) }
        )
        let volumeMonitor = deviceVolumeMonitor as? DeviceVolumeMonitor
        let volumeByUID = Dictionary(uniqueKeysWithValues: outputDevices.map {
            ($0.uid, deviceVolumeMonitor.volumes[$0.id] ?? 1.0)
        })
        let muteByUID = Dictionary(uniqueKeysWithValues: outputDevices.map {
            ($0.uid, deviceVolumeMonitor.muteStates[$0.id] ?? false)
        })
        return settingsManager.makeConsumerScene(
            name: name,
            symbolName: symbolName,
            defaultOutputDeviceUID: deviceVolumeMonitor.defaultDeviceUID,
            systemOutputDeviceUID: volumeMonitor?.systemDeviceUID,
            deviceVolumes: volumeByUID,
            deviceMutes: muteByUID,
            appNames: names,
            audioUnitProfiles: audioUnitHost.consumerSceneProfiles()
        )
    }

    @discardableResult
    func saveCurrentConsumerScene(name: String, symbolName: String) -> ConsumerScene {
        let scene = captureConsumerScene(name: name, symbolName: symbolName)
        return settingsManager.saveScene(scene)
    }

    @discardableResult
    func updateConsumerScene(id: UUID) -> ConsumerScene? {
        guard let existing = settingsManager.scene(id: id) else { return nil }
        var replacement = captureConsumerScene(name: existing.name, symbolName: existing.symbolName)
        replacement.id = existing.id
        replacement.createdAt = existing.createdAt
        return settingsManager.saveScene(replacement)
    }

    func applyConsumerScene(
        _ scene: ConsumerScene,
        recordUndo: Bool = true,
        reason: String? = nil
    ) {
        if recordUndo && !isApplyingConsumerState {
            let previous = captureConsumerScene(
                name: "Before \(scene.name)",
                symbolName: "arrow.uturn.backward"
            )
            consumerUndoManager.record(
                label: reason.map { "\($0): \(scene.name)" } ?? "Applied \(scene.name)",
                key: "scene:\(scene.id.uuidString)",
                snapshot: previous
            )
        }

        isApplyingConsumerState = true
        defer { isApplyingConsumerState = false }

        settingsManager.replaceConsumerAudioSettings(with: scene)
        audioUnitHost.replaceProfilesForConsumerScene(scene.audioUnitProfiles)

        if let uid = scene.defaultOutputDeviceUID,
           let device = outputDevices.first(where: { $0.uid == uid }) {
            _ = setDefaultOutputDevice(device.id)
        }

        for device in outputDevices {
            if let volume = scene.deviceVolumes[device.uid] {
                deviceVolumeMonitor.setVolume(for: device.id, to: volume)
            }
            if let muted = scene.deviceMutes[device.uid] {
                deviceVolumeMonitor.setMute(for: device.id, to: muted)
            }
        }

        setAutoEQPreampEnabled(scene.autoEQPreampEnabled)
        for uid in scene.deviceAutoEQ.keys {
            applyAutoEQToTaps(for: uid)
        }

        if let volumeMonitor = deviceVolumeMonitor as? DeviceVolumeMonitor {
            if scene.systemSoundsFollowsDefault {
                volumeMonitor.setSystemFollowDefault()
            } else if let uid = scene.systemOutputDeviceUID,
                      let device = outputDevices.first(where: { $0.uid == uid }) {
                volumeMonitor.setSystemDeviceExplicit(device.id)
            }
        }

        // Rebuild the in-memory mirrors from the newly installed Scene.
        volumeState.resetAll()
        appliedPIDs.removeAll()
        appDeviceRouting.removeAll()
        followsDefault.removeAll()

        for app in apps {
            let identifier = app.persistenceIdentifier
            let volume = settingsManager.getVolume(for: identifier)
                ?? settingsManager.appSettings.defaultNewAppVolume
            let boost = settingsManager.getBoost(for: identifier) ?? .x1
            let muted = settingsManager.getMute(for: identifier) ?? false
            let eq = settingsManager.getEQSettings(for: identifier)
            let stereo = settingsManager.getStereoFieldSettings(for: identifier)
            let mode = settingsManager.getDeviceSelectionMode(for: identifier) ?? .single

            setVolume(for: app, to: volume)
            setBoost(for: app, to: boost)
            setMute(for: app, to: muted)
            setEQSettings(eq, for: app)
            setStereoFieldSettings(stereo, for: app)
            setDeviceSelectionMode(for: app, to: mode)

            if mode == .multi {
                setSelectedDeviceUIDs(
                    for: app,
                    to: settingsManager.getSelectedDeviceUIDs(for: identifier) ?? []
                )
            } else if settingsManager.isFollowingDefault(for: identifier) {
                setDevice(for: app, deviceUID: nil)
            } else {
                setDevice(for: app, deviceUID: settingsManager.getDeviceRouting(for: identifier))
            }
        }

        setLoudnessCompensationEnabled(scene.globalAudio.loudnessCompensationEnabled)
        setLoudnessEqualizationEnabled(scene.globalAudio.loudnessEqualizationEnabled)
        setAdaptiveAudioSettings(scene.globalAudio.adaptiveAudio)
        setPrivacyFriendlyProcessingEnabled(scene.globalAudio.privacyFriendlyProcessingEnabled)
        applyPersistedSettings()
        reconcileTapRequirements()
    }

    func undoLastConsumerChange() {
        guard let record = consumerUndoManager.takeLatest() else { return }
        applyConsumerScene(record.snapshot, recordUndo: false, reason: "Undo")
    }

    func repairConsumerAudio() {
        let previous = captureConsumerScene(
            name: "Before Audio Repair",
            symbolName: "arrow.uturn.backward"
        )
        consumerUndoManager.record(
            label: "Fixed common audio problems",
            key: "repair-audio",
            snapshot: previous
        )

        // Tear down Melo's live routes first. Orphan cleanup is intentionally
        // designed for devices left by a previous process, so running it while
        // current taps still own aggregate devices could invalidate them behind
        // their backs. This short reset is safer and lets the normal reconciler
        // rebuild only the routes that are still needed.
        for task in audioUnitRebuildTasks.values { task.cancel() }
        audioUnitRebuildTasks.removeAll()
        audioUnitRebuildTokens.removeAll()
        for tap in taps.values { tap.invalidate() }
        taps.removeAll()
        OrphanedTapCleanup.destroyOrphanedDevices()
        deviceVolumeMonitor.refreshOutputDeviceStates()
        appliedPIDs.removeAll()
        applyPersistedSettings()
        reconcileTapRequirements()
        audioUnitHost.refreshCatalog()
    }

    var consumerDiagnosticText: String {
        let permissionText: String
        switch permission.status {
        case .authorized: permissionText = "Audio access: Ready"
        case .unknown: permissionText = "Audio access: Not checked yet"
        case .denied: permissionText = "Audio access: Needs permission"
        case .unavailable: permissionText = "Audio access: Unavailable"
        }
        let defaultName = outputDevices.first(where: { $0.uid == deviceVolumeMonitor.defaultDeviceUID })?.name
            ?? "No output selected"
        let pluginText = audioUnitHost.lastError.map { "Effects: \($0)" } ?? "Effects: Ready"
        return [
            permissionText,
            "Current output: \(defaultName)",
            "Connected outputs: \(outputDevices.count)",
            "Apps available to Melo: \(displayableApps.count)",
            "Active audio controls: \(taps.count)",
            pluginText
        ].joined(separator: "\n")
    }

    private func recordConsumerUndo(label: String, key: String) {
        guard !isApplyingConsumerState else { return }
        consumerUndoManager.record(
            label: label,
            key: key,
            snapshot: captureConsumerScene(
                name: "Before \(label)",
                symbolName: "arrow.uturn.backward"
            )
        )
    }

    /// Consumer-facing output volume entry point. Centralizing this lets the
    /// Recent Changes feature cover sliders, keyboard control, and the HUD
    /// without changing the device monitor's lower-level responsibilities.
    func setOutputDeviceVolume(for deviceID: AudioDeviceID, to volume: Float) {
        let device = outputDevices.first { $0.id == deviceID }
        let name = device?.name ?? "output"
        let key = device?.uid ?? String(deviceID)
        recordConsumerUndo(label: "Changed \(name) volume", key: "device-volume:\(key)")
        deviceVolumeMonitor.setVolume(for: deviceID, to: volume)
    }

    func setOutputDeviceMute(for deviceID: AudioDeviceID, to muted: Bool) {
        let device = outputDevices.first { $0.id == deviceID }
        let name = device?.name ?? "output"
        let key = device?.uid ?? String(deviceID)
        recordConsumerUndo(
            label: muted ? "Muted \(name)" : "Unmuted \(name)",
            key: "device-mute:\(key)"
        )
        deviceVolumeMonitor.setMute(for: deviceID, to: muted)
    }

    // MARK: - Settings Restore

    /// Rebuilds live state after the user imports a settings backup.
    func handleSettingsImported() {
        for task in audioUnitRebuildTasks.values { task.cancel() }
        audioUnitRebuildTasks.removeAll()
        audioUnitRebuildTokens.removeAll()
        for tap in taps.values { tap.invalidate() }
        taps.removeAll()
        appliedPIDs.removeAll()
        appDeviceRouting.removeAll()
        followsDefault.removeAll()
        volumeState.resetAll()
        callDuckingActive = false
        communicationAppPIDs.removeAll()
        callDuckingMonitoringPIDs.removeAll()
        callDuckingGain = 1.0
        batterySavingAudioActive = false
        deviceVolumeMonitor.refreshOutputDeviceStates()
        applyPersistedSettings()
        setLoudnessCompensationEnabled(settingsManager.appSettings.loudnessCompensationEnabled)
        setLoudnessEqualizationEnabled(settingsManager.appSettings.loudnessEqualizationEnabled)
        setAdaptiveAudioSettings(settingsManager.appSettings.adaptiveAudio)
        setMonoAudioEnabled(settingsManager.appSettings.monoAudioEnabled)
        reconcileTapRequirements()
    }

    // MARK: - Settings Reset

    /// Resets all persisted settings and synchronizes in-memory engine state.
    /// Active taps are kept alive but reverted to defaults (unity volume, unmuted, flat EQ).
    func handleSettingsReset() {
        // 1. Clear persisted state
        settingsManager.resetAllSettings()
        audioUnitHost.resetProfiles()

        // 2. Clear in-memory routing and tracking state
        appliedPIDs.removeAll()
        appDeviceRouting.removeAll()
        followsDefault.removeAll()

        // 3. Clear cached per-app audio state and temporary consumer features.
        volumeState.resetAll()
        callDuckingActive = false
        communicationAppPIDs.removeAll()
        callDuckingMonitoringPIDs.removeAll()
        callDuckingGain = 1.0
        batterySavingAudioActive = false

        // 4. Refresh output state caches so software-backed devices reset to defaults.
        deviceVolumeMonitor.refreshOutputDeviceStates()

        // 5. Push defaults to all active taps
        for tap in taps.values {
            applyTapOutputState(to: tap, for: tap.app.id, deviceUIDs: tap.currentDeviceUIDs)
            tap.updateEQSettings(.flat)
            tap.updateStereoFieldSettings(.centered)
            tap.updateMonoAudio(enabled: false)
            tap.updateAutoEQProfile(nil)
            tap.updateLoudnessCompensation(volume: effectiveLoudnessVolume(for: tap), enabled: false)
            tap.updateLoudnessEqualization(.init())
        }

        // 6. Re-apply from clean settings (re-establishes routing to system default)
        applyPersistedSettings()
        reconcileTapRequirements()

        logger.info("Settings reset: engine state synchronized")
    }

    func setVolume(for app: AudioApp, to volume: Float) {
        recordConsumerUndo(label: "Changed \(app.name) volume", key: "volume:\(app.persistenceIdentifier)")
        volumeState.setVolume(for: app.id, to: volume, identifier: app.persistenceIdentifier)
        if let tap = taps[app.id] {
            tap.volume = effectiveVolume(for: app.id, deviceUIDs: tap.currentDeviceUIDs)
            if settingsManager.appSettings.loudnessCompensationEnabled {
                tap.updateLoudnessCompensation(
                    volume: effectiveLoudnessVolume(for: tap),
                    enabled: true
                )
            }
        }
        reconcileTapRequirement(for: app)
    }

    func getVolume(for app: AudioApp) -> Float {
        volumeState.getVolume(for: app.id)
    }

    // MARK: - Boost

    func setBoost(for app: AudioApp, to boost: BoostLevel) {
        recordConsumerUndo(label: "Changed \(app.name) boost", key: "boost:\(app.persistenceIdentifier)")
        volumeState.setBoost(for: app.id, to: boost, identifier: app.persistenceIdentifier)
        if let tap = taps[app.id] {
            tap.volume = effectiveVolume(for: app.id, deviceUIDs: tap.currentDeviceUIDs)
        }
        reconcileTapRequirement(for: app)
    }

    func getBoost(for app: AudioApp) -> BoostLevel {
        volumeState.getBoost(for: app.id)
    }

    /// Effective gain for ProcessTapController: app volume × boost, plus optional
    /// single-device software output gain for software-backed devices.
    /// Single-device-routed apps on `.software`-backed devices always receive the
    /// device's software gain; multi-destination routing keeps `appGain` alone
    /// because per-device software gain has no unambiguous meaning across fan-out.
    private func effectiveVolume(for pid: pid_t, deviceUIDs: [String]? = nil) -> Float {
        var appGain = volumeState.getVolume(for: pid) * volumeState.getBoost(for: pid).rawValue
        if callDuckingActive && !communicationAppPIDs.contains(pid) {
            appGain *= callDuckingGain
        }

        guard let resolvedUIDs = deviceUIDs, resolvedUIDs.count == 1,
              let primaryUID = resolvedUIDs.first,
              let device = deviceMonitor.device(for: primaryUID),
              outputVolumeBackend(for: device.id) == .software else {
            return appGain
        }

        return appGain * deviceVolumeMonitor.outputProcessingGain(for: device.id)
    }

    /// Estimated listening level for loudness compensation: device volume × per-app slider.
    /// Does not include boost (intentional amplification beyond reference).
    /// The compensator's phon estimation clamps to [0,1] so values > 1 are treated as reference.
    private func effectiveLoudnessVolume(for tap: any ProcessTapControlling) -> Float {
        tap.currentDeviceVolume * volumeState.getVolume(for: tap.app.id)
    }

    private func applyTapOutputState(to tap: any ProcessTapControlling, for pid: pid_t, deviceUIDs: [String]? = nil) {
        let resolvedUIDs = deviceUIDs ?? tap.currentDeviceUIDs
        tap.volume = effectiveVolume(for: pid, deviceUIDs: resolvedUIDs)
        tap.isMuted = volumeState.getMute(for: pid)

        if let primaryUID = resolvedUIDs.first,
           let device = deviceMonitor.device(for: primaryUID) {
            tap.currentDeviceVolume = deviceVolumeMonitor.volumes[device.id] ?? 1.0
            tap.isDeviceMuted = deviceVolumeMonitor.muteStates[device.id] ?? false
        } else {
            tap.currentDeviceVolume = 1.0
            tap.isDeviceMuted = false
        }
    }

    private func refreshAllTapOutputStates() {
        for tap in taps.values {
            applyTapOutputState(to: tap, for: tap.app.id, deviceUIDs: tap.currentDeviceUIDs)
        }
    }


    /// Keeps a lightweight pass-through tap only for the call apps selected by
    /// the user so Melo can tell whether they are producing sound. This state is
    /// temporary and does not alter any saved app setting.
    func setCallDuckingMonitoringPIDs(_ pids: Set<pid_t>) {
        guard callDuckingMonitoringPIDs != pids else { return }
        callDuckingMonitoringPIDs = pids
        reconcileTapRequirements()
    }

    /// Applies a temporary, non-persisted reduction to non-call apps. Saved app
    /// volumes are never rewritten, so restoration is exact.
    func setCallDucking(active: Bool, communicationPIDs: Set<pid_t>) {
        guard callDuckingActive != active || communicationAppPIDs != communicationPIDs else { return }
        callDuckingActive = active
        communicationAppPIDs = communicationPIDs
        if !active { callDuckingGain = 1.0 }
        reconcileTapRequirements()
        refreshAllTapOutputStates()
    }

    /// Updates only the temporary call reduction. This is driven from a short
    /// main-actor ramp so the real-time callback receives a plain scalar value.
    func setCallDuckingGain(_ gain: Float) {
        let clamped = min(1.0, max(0.0, gain))
        guard abs(callDuckingGain - clamped) > 0.0001 else { return }
        callDuckingGain = clamped
        refreshAllTapOutputStates()
    }

    /// Temporarily pauses automatic sound enhancement while on battery. Manual
    /// app volume, routing, EQ, AutoEQ, and effects remain available.
    func setBatterySavingAudioActive(_ active: Bool) {
        guard batterySavingAudioActive != active else { return }
        batterySavingAudioActive = active
        let loudnessSettings = makeLoudnessEqualizerSettings()
        for tap in taps.values {
            tap.updateLoudnessCompensation(
                volume: effectiveLoudnessVolume(for: tap),
                enabled: settingsManager.appSettings.loudnessCompensationEnabled && !active
            )
            tap.updateLoudnessEqualization(loudnessSettings)
        }
        reconcileTapRequirements()
    }

    func toggleMute(for app: AudioApp) {
        let current = volumeState.getMute(for: app.id)
        setMute(for: app, to: !current)
    }

    func currentVolume(for app: AudioApp) -> Float {
        volumeState.getVolume(for: app.id)
    }

    func isMuted(for app: AudioApp) -> Bool {
        volumeState.getMute(for: app.id)
    }

    func isAudibleNow(bundleID: String) -> Bool {
        guard let app = apps.first(where: { $0.bundleID == bundleID }) else {
            return false
        }
        return app.processObjectIDs.contains { $0.readProcessIsRunning() }
    }

    func setMute(for app: AudioApp, to muted: Bool) {
        recordConsumerUndo(label: muted ? "Muted \(app.name)" : "Unmuted \(app.name)", key: "mute:\(app.persistenceIdentifier)")
        volumeState.setMute(for: app.id, to: muted, identifier: app.persistenceIdentifier)
        taps[app.id]?.isMuted = muted
        reconcileTapRequirement(for: app)
    }

    func getMute(for app: AudioApp) -> Bool {
        volumeState.getMute(for: app.id)
    }

    /// Update EQ settings for an app
    func setEQSettings(_ settings: EQSettings, for app: AudioApp) {
        recordConsumerUndo(label: "Changed \(app.name) sound", key: "eq:\(app.persistenceIdentifier)")
        // Save first even if capture has not started yet. The app may be open but
        // not currently rendering, or permission/device setup may still be pending.
        // tapInitialState(forApp:) will apply this state on the first later activation.
        settingsManager.setEQSettings(settings, for: app.persistenceIdentifier)
        taps[app.id]?.updateEQSettings(settings)
        reconcileTapRequirement(for: app)
    }

    /// Get EQ settings for an app
    func getEQSettings(for app: AudioApp) -> EQSettings {
        return settingsManager.getEQSettings(for: app.persistenceIdentifier)
    }

    func setMonoAudioEnabled(_ enabled: Bool) {
        if settingsManager.appSettings.monoAudioEnabled != enabled {
            var updated = settingsManager.appSettings
            updated.monoAudioEnabled = enabled
            settingsManager.updateAppSettings(updated)
        }
        for tap in taps.values { tap.updateMonoAudio(enabled: enabled) }
        reconcileTapRequirements()
    }

    /// Update and persist per-app stereo balance. Persistence does not depend on
    /// a currently active tap, so pinned/inactive state remains consistent.
    func setStereoFieldSettings(_ settings: StereoFieldSettings, for app: AudioApp) {
        recordConsumerUndo(label: "Changed \(app.name) balance", key: "balance:\(app.persistenceIdentifier)")
        let normalized = settings.normalized
        settingsManager.setStereoFieldSettings(normalized, for: app.persistenceIdentifier)
        taps[app.id]?.updateStereoFieldSettings(normalized)
        reconcileTapRequirement(for: app)
    }

    func getStereoFieldSettings(for app: AudioApp) -> StereoFieldSettings {
        settingsManager.getStereoFieldSettings(for: app.persistenceIdentifier)
    }

    // MARK: - Per-Device AutoEQ

    func getAutoEQProfile(for deviceUID: String) -> AutoEQProfile? {
        guard let selection = settingsManager.getAutoEQSelection(for: deviceUID) else { return nil }
        return autoEQProfileManager.profile(for: selection.profileID)
    }

    func setAutoEQProfile(for deviceUID: String, profileID: String?) {
        if let profileID {
            settingsManager.setAutoEQSelection(for: deviceUID, to: AutoEQSelection(profileID: profileID, isEnabled: true))
        } else {
            settingsManager.setAutoEQSelection(for: deviceUID, to: nil)
        }
        reconcileTapRequirements()
        applyAutoEQToTaps(for: deviceUID)
    }

    func setAutoEQEnabled(for deviceUID: String, enabled: Bool) {
        guard var selection = settingsManager.getAutoEQSelection(for: deviceUID) else { return }
        selection.isEnabled = enabled
        settingsManager.setAutoEQSelection(for: deviceUID, to: selection)
        reconcileTapRequirements()
        applyAutoEQToTaps(for: deviceUID)
    }

    func getAutoEQSelection(for deviceUID: String) -> AutoEQSelection? {
        settingsManager.getAutoEQSelection(for: deviceUID)
    }

    var autoEQPreampEnabled: Bool {
        settingsManager.autoEQPreampEnabled
    }

    func setAutoEQPreampEnabled(_ enabled: Bool) {
        settingsManager.autoEQPreampEnabled = enabled
        for tap in taps.values {
            tap.setAutoEQPreampEnabled(enabled)
        }
    }

    func setLoudnessCompensationEnabled(_ enabled: Bool) {
        recordConsumerUndo(label: "Changed Sound Balance", key: "global:loudness-compensation")
        reconcileTapRequirements()
        for tap in taps.values {
            tap.updateLoudnessCompensation(volume: effectiveLoudnessVolume(for: tap), enabled: enabled && !batterySavingAudioActive)
        }
    }

    func setLoudnessEqualizationEnabled(_ enabled: Bool) {
        recordConsumerUndo(label: "Changed Sound Balance", key: "global:loudness-equalization")
        _ = enabled // The persisted settings snapshot is the source of truth.
        reconcileTapRequirements()
        let settings = makeLoudnessEqualizerSettings()
        for tap in taps.values {
            tap.updateLoudnessEqualization(settings)
        }
    }

    func setAdaptiveAudioSettings(_ adaptiveAudio: AdaptiveAudioSettings) {
        recordConsumerUndo(label: "Changed Smart Sound", key: "global:adaptive-audio")
        if settingsManager.appSettings.adaptiveAudio != adaptiveAudio {
            var appSettings = settingsManager.appSettings
            appSettings.adaptiveAudio = adaptiveAudio
            settingsManager.updateAppSettings(appSettings)
        }
        var settings = makeLoudnessEqualizerSettings()
        // The binding setter has normally committed already; accepting the
        // value explicitly keeps this method deterministic in tests/previews.
        settings.adaptiveAudio = adaptiveAudio
        settings.widebandLevelingEnabled = settingsManager.appSettings.loudnessEqualizationEnabled
            || (adaptiveAudio.enabled && adaptiveAudio.smartNormalizationEnabled)
        settings.enabled = !batterySavingAudioActive && (settings.widebandLevelingEnabled
            || (adaptiveAudio.enabled
                && (adaptiveAudio.contentAwareEQEnabled || adaptiveAudio.smartNormalizationEnabled || adaptiveAudio.dialogueBoostEnabled)))
        applyAdaptiveIntensity(to: &settings, adaptiveAudio: adaptiveAudio)
        reconcileTapRequirements()
        for tap in taps.values {
            tap.updateLoudnessEqualization(settings)
        }
    }

    /// Applies the user's privacy preference after its binding has persisted.
    /// Untouched apps are returned to Core Audio's normal path immediately.
    func setPrivacyFriendlyProcessingEnabled(_ enabled: Bool) {
        recordConsumerUndo(label: "Changed audio privacy", key: "global:privacy")
        if settingsManager.appSettings.privacyFriendlyProcessingEnabled != enabled {
            var updated = settingsManager.appSettings
            updated.privacyFriendlyProcessingEnabled = enabled
            settingsManager.updateAppSettings(updated)
        }
        reconcileTapRequirements()
    }

    private func makeLoudnessEqualizerSettings() -> LoudnessEqualizerSettings {
        var result = LoudnessEqualizerSettings()
        let adaptive = settingsManager.appSettings.adaptiveAudio
        result.adaptiveAudio = adaptive
        result.widebandLevelingEnabled = !batterySavingAudioActive && (
            settingsManager.appSettings.loudnessEqualizationEnabled
                || (adaptive.enabled && adaptive.smartNormalizationEnabled)
        )
        result.enabled = !batterySavingAudioActive && (
            result.widebandLevelingEnabled
                || (adaptive.enabled && (adaptive.contentAwareEQEnabled || adaptive.dialogueBoostEnabled))
        )
        applyAdaptiveIntensity(to: &result, adaptiveAudio: adaptive)
        return result
    }

    private func applyAdaptiveIntensity(
        to settings: inout LoudnessEqualizerSettings,
        adaptiveAudio: AdaptiveAudioSettings
    ) {
        guard adaptiveAudio.enabled else { return }
        settings.targetLoudnessDb = -18
        settings.maxBoostDb = adaptiveAudio.intensity.maxLevelerBoostDb
        settings.maxCutDb = adaptiveAudio.intensity.maxLevelerCutDb
        settings.compressionThresholdOffsetDb = 4
        settings.compressionRatio = adaptiveAudio.intensity.compressionRatio
        settings.compressionKneeDb = 10
        settings.analysisWindowMs = 300
        settings.analysisHopMs = 75
        settings.detectorAttackMs = 20
        settings.detectorReleaseMs = 750
        settings.gainAttackMs = 120
        settings.gainReleaseMs = 2_400
        settings.noiseFloorThresholdDb = -45
        settings.lowLevelMaxBoostDb = 0.25
    }

    /// Apply AutoEQ profile to all taps currently routed to the given device.
    private func applyAutoEQToTaps(for deviceUID: String) {
        for tap in taps.values {
            guard tap.currentDeviceUID == deviceUID else { continue }
            applyAutoEQToTap(tap)
        }
    }

    /// Synchronous in-memory AutoEQ profile lookup. nil = not yet cached.
    private func autoEQProfileForActivation(deviceUID: String) -> AutoEQProfile? {
        guard let device = deviceMonitor.device(for: deviceUID), device.supportsAutoEQ else { return nil }
        guard let selection = settingsManager.getAutoEQSelection(for: deviceUID), selection.isEnabled else { return nil }
        return autoEQProfileManager.profile(for: selection.profileID)
    }

    private func tapInitialState(forApp app: AudioApp, primaryDeviceUID: String, deviceVolume: Float) -> TapInitialState {
        let loudnessEqSettings = makeLoudnessEqualizerSettings()
        return TapInitialState(
            eqSettings: settingsManager.getEQSettings(for: app.persistenceIdentifier),
            stereoFieldSettings: settingsManager.getStereoFieldSettings(for: app.persistenceIdentifier),
            autoEQProfile: autoEQProfileForActivation(deviceUID: primaryDeviceUID),
            autoEQPreampEnabled: settingsManager.autoEQPreampEnabled,
            loudnessVolume: deviceVolume * volumeState.getVolume(for: app.id),
            loudnessCompensationEnabled: settingsManager.appSettings.loudnessCompensationEnabled && !batterySavingAudioActive,
            loudnessEqualizerSettings: loudnessEqSettings,
            monoAudioEnabled: settingsManager.appSettings.monoAudioEnabled
        )
    }

    // MARK: - Audio Unit Runtime Scheduling

    private func handleAudioUnitProfileRuntimeChanged(_ profileID: String) {
        // An enabled Audio Unit is itself a reason to capture; removing or
        // bypassing the final unit may make an otherwise untouched app eligible
        // to return to its normal Core Audio path.
        reconcileTapRequirements()

        if profileID == AudioUnitHost.systemProfileID {
            // The master chain is stateful, so every live tap gets its own unique pair.
            for tap in taps.values {
                scheduleAudioUnitRuntime(
                    for: tap,
                    profileID: AudioUnitHost.systemProfileID,
                    scope: .system
                )
            }
        } else {
            for tap in taps.values where tap.app.persistenceIdentifier == profileID {
                scheduleAudioUnitRuntime(for: tap, profileID: profileID, scope: .app)
            }
        }
    }

    private func scheduleFreshAudioUnitRuntimes(for tap: any ProcessTapControlling) {
        audioUnitHost.ensureProfile(
            id: tap.app.persistenceIdentifier,
            displayName: tap.app.name
        )
        scheduleAudioUnitRuntime(
            for: tap,
            profileID: tap.app.persistenceIdentifier,
            scope: .app
        )
        scheduleAudioUnitRuntime(
            for: tap,
            profileID: AudioUnitHost.systemProfileID,
            scope: .system
        )
    }

    private func scheduleAudioUnitRebuildIfNeeded(for tap: any ProcessTapControlling) {
        guard tap.needsAudioUnitRuntimeRebuild else { return }
        scheduleFreshAudioUnitRuntimes(for: tap)
    }

    private func scheduleAudioUnitRuntime(
        for tap: any ProcessTapControlling,
        profileID: String,
        scope: AudioUnitProcessingScope
    ) {
        guard let configuration = tap.audioUnitRenderConfiguration else { return }

        let pid = tap.app.id
        let expectedControllerID = ObjectIdentifier(tap as AnyObject)
        let key = AudioUnitRebuildKey(pid: pid, scope: scope)
        let token = UUID()
        audioUnitRebuildTasks[key]?.cancel()
        audioUnitRebuildTokens[key] = token

        let task = Task { @MainActor [weak self] in
            // Ensure the task is recorded before a plug-in-free profile can complete immediately.
            await Task.yield()
            guard let self else { return }
            defer {
                if self.audioUnitRebuildTokens[key] == token {
                    self.audioUnitRebuildTasks.removeValue(forKey: key)
                    self.audioUnitRebuildTokens.removeValue(forKey: key)
                }
            }

            guard !Task.isCancelled,
                  let liveTap = self.taps[pid],
                  ObjectIdentifier(liveTap as AnyObject) == expectedControllerID else { return }

            do {
                let pair = try await self.audioUnitHost.makeRuntimePair(
                    for: profileID,
                    configuration: configuration
                )
                try Task.checkCancellation()
                guard let currentTap = self.taps[pid],
                      ObjectIdentifier(currentTap as AnyObject) == expectedControllerID,
                      currentTap.audioUnitRenderConfiguration == configuration else {
                    // A route/sample-rate promotion happened during instantiation. Its completion
                    // path will schedule another build with the current format.
                    return
                }
                currentTap.installAudioUnitRuntimePair(pair, scope: scope)
            } catch is CancellationError {
                return
            } catch {
                self.audioUnitHost.lastError = "Couldn’t prepare Audio Units for \(liveTap.app.name): \(error.localizedDescription)"
            }
        }
        audioUnitRebuildTasks[key] = task
    }

    /// Skips AutoEQ entirely for devices that don't support it (speakers, HDMI, etc.).
    /// If the profile isn't loaded yet, triggers an async fetch and applies when ready.
    private func applyAutoEQToTap(_ tap: any ProcessTapControlling) {
        guard let deviceUID = tap.currentDeviceUID else { return }

        // Skip AutoEQ for non-headphone devices (or if device not found in monitor)
        guard let device = deviceMonitor.device(for: deviceUID) else {
            logger.debug("AutoEQ skip for \(tap.app.name): device \(deviceUID) not found in monitor")
            return
        }
        guard device.supportsAutoEQ else {
            tap.updateAutoEQProfile(nil)
            logger.debug("AutoEQ skip for \(tap.app.name): \(device.name) doesn't support AutoEQ")
            return
        }

        guard let selection = settingsManager.getAutoEQSelection(for: deviceUID),
              selection.isEnabled else {
            tap.updateAutoEQProfile(nil)
            logger.debug("AutoEQ skip for \(tap.app.name): no selection or disabled for \(device.name)")
            return
        }

        // Try in-memory first (instant)
        if let profile = autoEQProfileManager.profile(for: selection.profileID) {
            tap.updateAutoEQProfile(profile)
            return
        }

        // Profile not loaded yet — fetch asynchronously
        tap.updateAutoEQProfile(nil)
        Task { @MainActor in
            guard let profile = await autoEQProfileManager.resolveProfile(for: selection.profileID) else { return }
            // Verify tap still exists and is still routed to the same device
            guard tap.currentDeviceUID == deviceUID else { return }
            guard let latestSelection = settingsManager.getAutoEQSelection(for: deviceUID),
                  latestSelection.profileID == selection.profileID,
                  latestSelection.isEnabled else { return }
            tap.updateAutoEQProfile(profile)
        }
    }

    /// Sets the system default output device, routes followsDefault apps, and registers
    /// an echo so the resulting CoreAudio callback is consumed rather than treated as
    /// an external change.
    /// UI code should call this instead of `deviceVolumeMonitor.setDefaultDevice` directly.
    @discardableResult
    func setDefaultOutputDevice(_ deviceID: AudioDeviceID) -> Bool {
        recordConsumerUndo(label: "Changed speakers or headphones", key: "default-output")
        guard deviceVolumeMonitor.setDefaultDevice(deviceID) else { return false }
        if let uid = deviceMonitor.outputDevices.first(where: { $0.id == deviceID })?.uid {
            outputEchoTracker.increment(uid)
            lastConfirmedDefaultUID = uid
            routeFollowsDefaultApps(to: uid)
        }
        return true
    }

    /// Sets the output device for an app.
    /// - Parameters:
    ///   - app: The app to route
    ///   - deviceUID: The device UID to route to, or nil to follow system default
    func setDevice(for app: AudioApp, deviceUID: String?) {
        recordConsumerUndo(label: "Changed where \(app.name) plays", key: "route:\(app.persistenceIdentifier)")
        if let deviceUID = deviceUID {
            // Explicit device selection - stop following default
            followsDefault.remove(app.id)
            // Defensive: re-persist routing even if in-memory state matches,
            // to guard against settings file corruption or incomplete prior writes
            settingsManager.setDeviceRouting(for: app.persistenceIdentifier, deviceUID: deviceUID)

            // If transitioning from follows-default to explicit and tap has a stream-specific
            // source, refresh to mixdown so it won't go stale when the default changes later.
            if let tap = taps[app.id], tap.tapSourceDeviceUID != nil {
                Task {
                    do {
                        try await tap.refreshTapSource(nil)
                        self.applyTapOutputState(to: tap, for: app.id)
                        self.scheduleAudioUnitRebuildIfNeeded(for: tap)
                    } catch {
                        self.logger.error("Failed to refresh tap source for \(app.name): \(error)")
                    }
                }
            }

            guard appDeviceRouting[app.id] != deviceUID else {
                reconcileTapRequirement(for: app)
                return
            }
            appDeviceRouting[app.id] = deviceUID
        } else {
            // "System Audio" selected - follow default
            followsDefault.insert(app.id)
            settingsManager.setFollowDefault(for: app.persistenceIdentifier)

            // Route to current default (if available)
            guard let defaultUID = deviceVolumeMonitor.defaultDeviceUID else {
                // No default available yet - routing will happen when default becomes available
                // via handleDefaultDeviceChanged callback
                logger.warning("No default device available for \(app.name), will route when available")
                return
            }
            guard appDeviceRouting[app.id] != defaultUID else {
                reconcileTapRequirement(for: app)
                return
            }
            appDeviceRouting[app.id] = defaultUID
        }

        // Switch tap if needed
        guard let targetUID = appDeviceRouting[app.id] else { return }
        let preferredTapSourceUID = preferredTapSourceDeviceUID(forOutputUIDs: [targetUID], isFollowsDefault: followsDefault.contains(app.id))
        if let tap = taps[app.id] {
            Task {
                do {
                    try await tap.switchDevice(to: targetUID, preferredTapSourceDeviceUID: preferredTapSourceUID)
                    self.applyTapOutputState(to: tap, for: app.id, deviceUIDs: [targetUID])
                    self.applyAutoEQToTap(tap)
                    self.scheduleAudioUnitRebuildIfNeeded(for: tap)
                    self.reconcileTapRequirement(for: app)
                    self.logger.debug("Switched \(app.name) to device: \(targetUID)")
                } catch {
                    self.logger.error("Failed to switch device for \(app.name): \(error.localizedDescription)")
                }
            }
        } else {
            reconcileTapRequirement(for: app)
        }
    }

    func getDeviceUID(for app: AudioApp) -> String? {
        appDeviceRouting[app.id]
    }

    /// Returns true if the app follows system default device
    func isFollowingDefault(for app: AudioApp) -> Bool {
        followsDefault.contains(app.id)
    }

    // MARK: - Multi-Device Selection

    /// Gets the device selection mode for an app
    func getDeviceSelectionMode(for app: AudioApp) -> DeviceSelectionMode {
        volumeState.getDeviceSelectionMode(for: app.id)
    }

    /// Sets the device selection mode for an app.
    /// Triggers tap reconfiguration when mode changes.
    func setDeviceSelectionMode(for app: AudioApp, to mode: DeviceSelectionMode) {
        recordConsumerUndo(label: "Changed where \(app.name) plays", key: "route-mode:\(app.persistenceIdentifier)")
        let previousMode = volumeState.getDeviceSelectionMode(for: app.id)
        volumeState.setDeviceSelectionMode(for: app.id, to: mode, identifier: app.persistenceIdentifier)

        guard previousMode != mode else { return }

        Task {
            await updateTapForCurrentMode(for: app)
        }
    }

    /// Gets the selected device UIDs for multi-mode
    func getSelectedDeviceUIDs(for app: AudioApp) -> Set<String> {
        volumeState.getSelectedDeviceUIDs(for: app.id)
    }

    /// Sets the selected device UIDs for multi-mode.
    /// Triggers tap reconfiguration when in multi mode.
    func setSelectedDeviceUIDs(for app: AudioApp, to uids: Set<String>) {
        recordConsumerUndo(label: "Changed where \(app.name) plays", key: "route-devices:\(app.persistenceIdentifier)")
        let previousUIDs = volumeState.getSelectedDeviceUIDs(for: app.id)
        volumeState.setSelectedDeviceUIDs(for: app.id, to: uids, identifier: app.persistenceIdentifier)

        guard previousUIDs != uids,
              getDeviceSelectionMode(for: app) == .multi else { return }

        Task {
            await updateTapForCurrentMode(for: app)
        }
    }

    /// Updates tap configuration based on current mode and selected devices
    private func updateTapForCurrentMode(for app: AudioApp) async {
        let mode = getDeviceSelectionMode(for: app)

        let deviceUIDs: [String]
        switch mode {
        case .single:
            if isFollowingDefault(for: app), let defaultUID = deviceVolumeMonitor.defaultDeviceUID {
                deviceUIDs = [defaultUID]
            } else if let deviceUID = appDeviceRouting[app.id] {
                deviceUIDs = [deviceUID]
            } else if let defaultUID = deviceVolumeMonitor.defaultDeviceUID {
                deviceUIDs = [defaultUID]
            } else {
                logger.warning("No device available for \(app.name) in single mode")
                return
            }

        case .multi:
            let selectedUIDs = getSelectedDeviceUIDs(for: app).sorted()
            if selectedUIDs.isEmpty {
                return
            }
            deviceUIDs = selectedUIDs
        }

        // Update or create tap with the device set
        if let tap = taps[app.id] {
            // Tap exists - update devices
            if tap.currentDeviceUIDs != deviceUIDs {
                do {
                    let preferredTapSourceUID = preferredTapSourceDeviceUID(forOutputUIDs: deviceUIDs, isFollowsDefault: followsDefault.contains(app.id))
                    try await tap.updateDevices(to: deviceUIDs, preferredTapSourceDeviceUID: preferredTapSourceUID)
                    applyTapOutputState(to: tap, for: app.id, deviceUIDs: deviceUIDs)
                    scheduleAudioUnitRebuildIfNeeded(for: tap)
                    logger.debug("Updated \(app.name) to \(deviceUIDs.count) device(s)")
                } catch {
                    logger.error("Failed to update devices for \(app.name): \(error.localizedDescription)")
                }
            }
        } else {
            // No tap exists - create one
            ensureTapWithDevices(for: app, deviceUIDs: deviceUIDs)
        }
    }

    /// Creates a tap with the specified device UIDs
    private func ensureTapWithDevices(for app: AudioApp, deviceUIDs: [String]) {
        guard !deviceUIDs.isEmpty else { return }
        guard taps[app.id] == nil, !pendingTapActivationPIDs.contains(app.id) else { return }
        guard permission.allowsCaptureAttempt else { return }

        let preferredTapSourceUID = preferredTapSourceDeviceUID(forOutputUIDs: deviceUIDs, isFollowsDefault: followsDefault.contains(app.id))
        do {
            let tap = try tapFactory(app, deviceUIDs, preferredTapSourceUID)
            applyTapOutputState(to: tap, for: app.id, deviceUIDs: deviceUIDs)

            let initial = tapInitialState(
                forApp: app,
                primaryDeviceUID: deviceUIDs[0],
                deviceVolume: tap.currentDeviceVolume
            )
            activateNewTap(
                tap,
                for: app,
                initial: initial,
                successMessage: "Created tap for \(app.name) on \(deviceUIDs.count) device(s)"
            )
        } catch {
            recordCaptureStartFailure(error)
            logger.error("Failed to create tap for \(app.name): \(error.localizedDescription)")
        }
    }

    /// Installs a newly-created tap. Before access is proven, the Core Audio
    /// start call runs asynchronously so the macOS permission sheet can never
    /// freeze Melo's SwiftUI windows. Once authorized, ordinary route creation
    /// retains the established synchronous path for deterministic updates.
    private func activateNewTap(
        _ tap: any ProcessTapControlling,
        for app: AudioApp,
        initial: TapInitialState,
        successMessage: String
    ) {
        if permission.status == .authorized {
            do {
                try tap.activate(initial: initial)
                completeNewTapActivation(tap, for: app, initial: initial, successMessage: successMessage)
            } catch {
                recordCaptureStartFailure(error)
                logger.error("Failed to activate tap for \(app.name): \(error.localizedDescription)")
            }
            return
        }

        pendingTapActivationPIDs.insert(app.id)
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.pendingTapActivationPIDs.remove(app.id) }
            do {
                try await tap.activateWithoutBlockingMainThread(initial: initial)
                guard app.processObjectIDs.contains(where: { $0.readProcessIsRunning() }) else {
                    await tap.invalidateAsync()
                    return
                }
                self.completeNewTapActivation(tap, for: app, initial: initial, successMessage: successMessage)
                self.applyPersistedSettings()
            } catch {
                await tap.invalidateAsync()
                self.recordCaptureStartFailure(error)
                self.logger.error("Failed to activate tap for \(app.name): \(error.localizedDescription)")
            }
        }
    }

    private func completeNewTapActivation(
        _ tap: any ProcessTapControlling,
        for app: AudioApp,
        initial: TapInitialState,
        successMessage: String
    ) {
        taps[app.id] = tap
        recordCaptureStarted()
        scheduleFreshAudioUnitRuntimes(for: tap)
        if initial.autoEQProfile == nil {
            applyAutoEQToTap(tap)
        }
        logger.debug("\(successMessage, privacy: .public)")
    }

    // MARK: - Privacy-Friendly Tap Activation

    /// Whether a profile contains an Audio Unit that can alter the signal.
    private func hasActiveAudioUnits(profileID: String) -> Bool {
        audioUnitHost.slots(for: profileID).contains {
            $0.isEnabled && !$0.isBypassed
        }
    }

    /// Returns true when bypassing Melo would change the requested result.
    /// The process monitor and app list do not require capture; only DSP,
    /// per-app gain/mute, routing, or software-backed device gain do.
    private func requiresTap(
        for app: AudioApp,
        deviceUIDs: [String],
        mode: DeviceSelectionMode
    ) -> Bool {
        let appSettings = settingsManager.appSettings
        let adaptive = appSettings.adaptiveAudio
        let hasAutomaticGlobalProcessing = !batterySavingAudioActive && (
            appSettings.loudnessCompensationEnabled
                || appSettings.loudnessEqualizationEnabled
                || (adaptive.enabled
                    && (adaptive.contentAwareEQEnabled
                        || adaptive.smartNormalizationEnabled
                        || adaptive.dialogueBoostEnabled))
        )
        let hasGlobalProcessing = hasAutomaticGlobalProcessing
            || appSettings.monoAudioEnabled
            || callDuckingMonitoringPIDs.contains(app.id)
            || (callDuckingActive && !communicationAppPIDs.contains(app.id))

        let hasPerAppProcessing = volumeState.getVolume(for: app.id) != 1
            || volumeState.getBoost(for: app.id) != .x1
            || volumeState.getMute(for: app.id)
            || settingsManager.getEQSettings(for: app.persistenceIdentifier) != .flat
            || settingsManager.getStereoFieldSettings(for: app.persistenceIdentifier) != .centered

        // A fixed output or fan-out route cannot be honored by pass-through audio.
        let hasCustomRouting = !settingsManager.isFollowingDefault(for: app.persistenceIdentifier)
            || mode == .multi
        let hasAudioUnits = hasActiveAudioUnits(profileID: AudioUnitHost.systemProfileID)
            || hasActiveAudioUnits(profileID: app.persistenceIdentifier)

        var hasDeviceProcessing = false
        for uid in deviceUIDs {
            if settingsManager.getAutoEQSelection(for: uid)?.isEnabled == true {
                hasDeviceProcessing = true
                break
            }
            if let device = deviceMonitor.device(for: uid),
               outputVolumeBackend(for: device.id) == .software,
               (deviceVolumeMonitor.outputProcessingGain(for: device.id) != 1
                    || deviceVolumeMonitor.muteStates[device.id] == true) {
                hasDeviceProcessing = true
                break
            }
        }

        return TapActivationPolicy.requiresTap(
            privacyFriendlyProcessingEnabled: appSettings.privacyFriendlyProcessingEnabled,
            hasGlobalProcessing: hasGlobalProcessing,
            hasPerAppProcessing: hasPerAppProcessing,
            hasCustomRouting: hasCustomRouting,
            hasAudioUnits: hasAudioUnits,
            hasDeviceProcessing: hasDeviceProcessing
        )
    }

    private func removeTapForPrivacy(for pid: pid_t) {
        guard let tap = taps.removeValue(forKey: pid) else { return }

        for scope in [AudioUnitProcessingScope.app, .system] {
            let key = AudioUnitRebuildKey(pid: pid, scope: scope)
            audioUnitRebuildTasks.removeValue(forKey: key)?.cancel()
            audioUnitRebuildTokens.removeValue(forKey: key)
        }

        tap.invalidate()
        logger.debug("Released unchanged audio path for PID \(pid)")
    }

    /// Re-evaluates one app after an inline mixer edit.
    private func reconcileTapRequirement(for app: AudioApp) {
        guard settingsManager.appSettings.privacyFriendlyProcessingEnabled else {
            appliedPIDs.remove(app.id)
            applyPersistedSettings()
            return
        }

        let mode = volumeState.getDeviceSelectionMode(for: app.id)
        let deviceUIDs: [String]
        if mode == .multi {
            deviceUIDs = Array(volumeState.getSelectedDeviceUIDs(for: app.id)).sorted()
        } else if let uid = appDeviceRouting[app.id] ?? deviceVolumeMonitor.defaultDeviceUID {
            deviceUIDs = [uid]
        } else {
            deviceUIDs = []
        }

        if !deviceUIDs.isEmpty, requiresTap(for: app, deviceUIDs: deviceUIDs, mode: mode) {
            appliedPIDs.remove(app.id)
            applyPersistedSettings()
        } else {
            removeTapForPrivacy(for: app.id)
            appliedPIDs.insert(app.id)
        }
    }

    /// Reconciles every live audio app after a global processing preference,
    /// output gain, AutoEQ, or Audio Unit chain changes.
    private func reconcileTapRequirements() {
        let activeIDs = Set(apps.map(\.id))
        let tapsToRelease = taps.compactMap { pid, tap -> pid_t? in
            guard activeIDs.contains(pid) else { return nil }
            let mode = volumeState.getDeviceSelectionMode(for: pid)
            return requiresTap(for: tap.app, deviceUIDs: tap.currentDeviceUIDs, mode: mode)
                ? nil
                : pid
        }
        for pid in tapsToRelease {
            removeTapForPrivacy(for: pid)
        }

        appliedPIDs.subtract(activeIDs)
        applyPersistedSettings()
    }

    func applyPersistedSettings() {
        guard permission.allowsCaptureAttempt else { return }

        // Warm the AutoEQ cache for every (app, device) selection so that subsequent
        // tap activations can apply correction synchronously inside activate(initial:)
        // instead of falling back to the async resolve path. Imported profiles are
        // already loaded by AutoEQProfileManager.init.
        let selectedProfileIDs: Set<String> = Set(apps.compactMap { app -> String? in
            let deviceUID = appDeviceRouting[app.id] ?? deviceVolumeMonitor.defaultDeviceUID
            guard let deviceUID, let selection = settingsManager.getAutoEQSelection(for: deviceUID) else { return nil }
            return selection.isEnabled ? selection.profileID : nil
        })
        let manager = autoEQProfileManager
        Task { @MainActor in
            for id in selectedProfileIDs where manager.profile(for: id) == nil {
                _ = await manager.resolveProfile(for: id)
            }
        }

        for app in apps {
            guard !appliedPIDs.contains(app.id) else { continue }
            guard !settingsManager.isIgnored(app.persistenceIdentifier) else { continue }

            // Load saved device selection mode (single vs multi)
            let savedMode = volumeState.loadSavedDeviceSelectionMode(for: app.id, identifier: app.persistenceIdentifier)
            let mode = savedMode ?? .single

            // Load saved volume, mute, and boost state
            let savedVolume = volumeState.loadSavedVolume(for: app.id, identifier: app.persistenceIdentifier)
            let savedMute = volumeState.loadSavedMute(for: app.id, identifier: app.persistenceIdentifier)
            _ = volumeState.loadSavedBoost(for: app.id, identifier: app.persistenceIdentifier)

            // Handle multi-device mode
            if mode == .multi {
                if let savedUIDs = volumeState.loadSavedSelectedDeviceUIDs(for: app.id, identifier: app.persistenceIdentifier),
                   !savedUIDs.isEmpty {
                    // Filter to currently available devices, maintaining deterministic order
                    let availableUIDs = savedUIDs.filter { deviceMonitor.device(for: $0) != nil }
                        .sorted()  // Deterministic ordering
                    if !availableUIDs.isEmpty {
                        logger.debug("Restoring multi-device mode for \(app.name) with \(availableUIDs.count) device(s)")
                        ensureTapWithDevices(for: app, deviceUIDs: availableUIDs)

                        // Mark as applied if tap created successfully
                        guard taps[app.id] != nil else { continue }
                        // Set primary device routing so the UI row renders
                        appDeviceRouting[app.id] = availableUIDs[0]
                        appliedPIDs.insert(app.id)

                        // Apply volume (with boost) and mute
                        if savedVolume != nil {
                            if let tap = taps[app.id] {
                                applyTapOutputState(to: tap, for: app.id, deviceUIDs: availableUIDs)
                            }
                        }
                        if let muted = savedMute, muted {
                            taps[app.id]?.isMuted = true
                        }
                        continue  // Skip single-device path
                    }
                    // All saved devices unavailable - fall through to single-device mode
                    logger.debug("All multi-mode devices unavailable for \(app.name), falling back to single mode")
                }
            }

            // Single-device mode (or multi-mode fallback)
            let deviceUID: String
            if settingsManager.isFollowingDefault(for: app.persistenceIdentifier) {
                // App follows system default (new app or explicitly set to follow)
                followsDefault.insert(app.id)
                guard let defaultUID = deviceVolumeMonitor.defaultDeviceUID else {
                    logger.warning("No default device available for \(app.name), deferring setup")
                    continue
                }
                deviceUID = defaultUID
                logger.debug("App \(app.name) follows system default: \(deviceUID)")
            } else if let savedDeviceUID = settingsManager.getDeviceRouting(for: app.persistenceIdentifier),
                      deviceMonitor.device(for: savedDeviceUID) != nil {
                // Explicit device routing exists and device is available
                deviceUID = savedDeviceUID
                logger.debug("Applying saved device routing to \(app.name): \(deviceUID)")
            } else {
                // Saved device temporarily unavailable: fall back to system default for now
                // Don't persist - keep original device preference for when it reconnects
                followsDefault.insert(app.id)
                guard let defaultUID = deviceVolumeMonitor.defaultDeviceUID else {
                    logger.warning("No default device for \(app.name), deferring setup")
                    continue
                }
                deviceUID = defaultUID
                logger.debug("App \(app.name) device temporarily unavailable, using default: \(deviceUID)")
            }
            appDeviceRouting[app.id] = deviceUID

            // Listing and remembering an app do not require capture. In privacy-
            // friendly mode, leave an unchanged app on its normal Core Audio path.
            if !requiresTap(for: app, deviceUIDs: [deviceUID], mode: mode) {
                removeTapForPrivacy(for: app.id)
                appliedPIDs.insert(app.id)
                continue
            }

            // If a tap already exists but is on the wrong device (e.g., app reappeared
            // after the default changed while it was absent), switch it.
            if let existingTap = taps[app.id], existingTap.currentDeviceUIDs != [deviceUID] {
                let preferredSource = preferredTapSourceDeviceUID(forOutputUIDs: [deviceUID], isFollowsDefault: followsDefault.contains(app.id))
                Task {
                    do {
                        try await existingTap.switchDevice(to: deviceUID, preferredTapSourceDeviceUID: preferredSource)
                        self.applyTapOutputState(to: existingTap, for: app.id, deviceUIDs: [deviceUID])
                        self.applyAutoEQToTap(existingTap)
                        self.scheduleAudioUnitRebuildIfNeeded(for: existingTap)
                    } catch {
                        self.logger.error("Failed to re-route \(app.name) to \(deviceUID): \(error.localizedDescription)")
                    }
                }
                appliedPIDs.insert(app.id)
                continue
            }

            // Create a tap only when the selected processing policy requires one.
            ensureTapExists(for: app, deviceUID: deviceUID)

            // Only mark as applied if tap was successfully created
            // This allows retry on next applyPersistedSettings() call if tap failed
            guard taps[app.id] != nil else { continue }
            appliedPIDs.insert(app.id)

            if savedVolume != nil {
                let effective = effectiveVolume(for: app.id, deviceUIDs: [deviceUID])
                let displayPercent = Int(effective * 100)
                logger.debug("Applying saved volume \(displayPercent)% (with boost) to \(app.name)")
                taps[app.id]?.volume = effective
            }

            if let muted = savedMute, muted {
                logger.debug("Applying saved mute state to \(app.name)")
                taps[app.id]?.isMuted = true
            }
        }
    }

    private func ensureTapExists(for app: AudioApp, deviceUID: String) {
        guard taps[app.id] == nil, !pendingTapActivationPIDs.contains(app.id) else { return }
        guard permission.allowsCaptureAttempt else { return }

        let preferredTapSourceUID = preferredTapSourceDeviceUID(forOutputUIDs: [deviceUID], isFollowsDefault: followsDefault.contains(app.id))
        do {
            let tap = try tapFactory(app, [deviceUID], preferredTapSourceUID)
            applyTapOutputState(to: tap, for: app.id, deviceUIDs: [deviceUID])

            let initial = tapInitialState(
                forApp: app,
                primaryDeviceUID: deviceUID,
                deviceVolume: tap.currentDeviceVolume
            )
            activateNewTap(
                tap,
                for: app,
                initial: initial,
                successMessage: "Created tap for \(app.name)"
            )
        } catch {
            recordCaptureStartFailure(error)
            logger.error("Failed to create tap for \(app.name): \(error.localizedDescription)")
        }
    }

    /// Restores the default to `lastConfirmedDefaultUID` (what the user/Melo intended).
    /// Falls back to highest-priority device if the confirmed device is gone.
    private func restoreConfirmedDefault() {
        if let restoreUID = lastConfirmedDefaultUID,
           let device = deviceMonitor.device(for: restoreUID),
           isAliveCheck(device.id) {
            if deviceVolumeMonitor.defaultDeviceUID != restoreUID {
                if deviceVolumeMonitor.setDefaultDevice(device.id) {
                    outputEchoTracker.increment(restoreUID)
                    logger.info("Restored default → \(device.name)")
                }
            }
            routeFollowsDefaultApps(to: restoreUID)
        } else {
            reEvaluateOutputDefault()
        }
    }

    /// Ensures system default matches highest-priority alive connected device.
    /// Routes followsDefault apps and switches their taps if default changes.
    /// Returns the resolved target UID.
    @discardableResult
    private func reEvaluateOutputDefault(excluding: String? = nil) -> String? {
        guard let target = Self.resolveHighestPriority(
            priorityOrder: settingsManager.devicePriorityOrder,
            connectedDevices: outputDevices,
            excluding: excluding,
            isAlive: isAliveCheck
        ) else { return nil }

        let currentDefault = deviceVolumeMonitor.defaultDeviceUID
        if target.uid != currentDefault {
            if deviceVolumeMonitor.setDefaultDevice(target.id) {
                outputEchoTracker.increment(target.uid)
                logger.info("System default → \(target.name)")
            }
        }

        lastConfirmedDefaultUID = target.uid
        routeFollowsDefaultApps(to: target.uid)
        return target.uid
    }

    /// Ensures system default input matches highest-priority alive connected input device.
    /// Returns the resolved target UID.
    @discardableResult
    private func reEvaluateInputDefault(excluding: String? = nil) -> String? {
        guard let target = Self.resolveHighestPriority(
            priorityOrder: settingsManager.inputDevicePriorityOrder,
            connectedDevices: inputDevices,
            excluding: excluding,
            isAlive: isAliveCheck
        ) else { return nil }

        if target.uid != deviceVolumeMonitor.defaultInputDeviceUID {
            if deviceVolumeMonitor.setDefaultInputDevice(target.id) {
                inputEchoTracker.increment(target.uid)
                logger.info("Default input → \(target.name)")
            }
        }
        return target.uid
    }

    /// Routes all followsDefault apps to the given device UID and switches their taps.
    /// Early-exits if all apps are already routed to the target (avoids unnecessary tap switches).
    private func routeFollowsDefaultApps(to targetUID: String) {
        guard !followsDefault.allSatisfy({ appDeviceRouting[$0] == targetUID }) else { return }

        for pid in followsDefault {
            appDeviceRouting[pid] = targetUID
        }

        var tapsToSwitch: [(app: AudioApp, tap: any ProcessTapControlling)] = []
        for app in apps {
            guard followsDefault.contains(app.id), let tap = taps[app.id] else { continue }
            tapsToSwitch.append((app, tap))
        }
        guard !tapsToSwitch.isEmpty else { return }

        Task {
            for (app, tap) in tapsToSwitch {
                do {
                    let preferredTapSourceUID = self.preferredTapSourceDeviceUID(forOutputUIDs: [targetUID], isFollowsDefault: true)
                    try await tap.switchDevice(to: targetUID, preferredTapSourceDeviceUID: preferredTapSourceUID)
                    self.applyTapOutputState(to: tap, for: app.id, deviceUIDs: [targetUID])
                    self.applyAutoEQToTap(tap)
                    self.scheduleAudioUnitRebuildIfNeeded(for: tap)
                } catch {
                    self.logger.error("Failed to switch \(app.name) to \(targetUID): \(error.localizedDescription)")
                }
            }
        }
    }

    /// Called when device disappears - updates routing and switches taps immediately
    private func handleDeviceDisconnected(_ deviceUID: String, name deviceName: String) {
        // Clean up alive watcher — use UID lookup since device is already removed from monitor
        removeAliveWatcher(forUID: deviceUID)

        // If we were waiting for macOS to auto-switch to this device, cancel — it's gone
        if case .pendingAutoSwitch(let uid, let task) = outputPriorityState, uid == deviceUID {
            task.cancel()
            outputPriorityState = .stable
        }

        // Snapshot before async callbacks can update it. Only send play/pause
        // when a routed app was audibly active; otherwise a toggle could start
        // playback that was already paused.
        let wasDefaultOutput = deviceUID == deviceVolumeMonitor.defaultDeviceUID
        let audiblyAffectedTaps = taps.values.filter { tap in
            tap.currentDeviceUIDs.contains(deviceUID) && tap.audioLevel >= 0.008
        }
        let hadAudiblePlayback = !audiblyAffectedTaps.isEmpty
        let wasOnlyRouteForAudibleApp = audiblyAffectedTaps.contains { tap in
            tap.currentDeviceUIDs.allSatisfy { $0 == deviceUID }
        }
        if (wasDefaultOutput || wasOnlyRouteForAudibleApp),
           hadAudiblePlayback,
           settingsManager.appSettings.pauseOnHeadphoneDisconnect,
           Self.looksLikeHeadphones(deviceName) {
            PlaybackPauseService.sendPlayPause()
        }

        // Use priority-based fallback (resolve checks isDeviceAlive internally)
        let fallbackDevice = Self.resolveHighestPriority(
            priorityOrder: settingsManager.devicePriorityOrder,
            connectedDevices: outputDevices,
            excluding: deviceUID,
            isAlive: isAliveCheck
        )

        var affectedApps: [AudioApp] = []
        var singleModeTapsToSwitch: [(tap: any ProcessTapControlling, fallbackUID: String)] = []
        var multiModeTapsToUpdate: [(tap: any ProcessTapControlling, remainingUIDs: [String])] = []

        // Iterate over taps instead of apps - apps list may be empty if disconnected device
        // was the system default (CoreAudio removes app from process list when output disappears)
        for tap in taps.values {
            let app = tap.app
            let mode = getDeviceSelectionMode(for: app)

            // Check if this tap uses the disconnected device
            guard tap.currentDeviceUIDs.contains(deviceUID) else { continue }

            affectedApps.append(app)

            if mode == .multi && tap.currentDeviceUIDs.count > 1 {
                // Multi-device mode: remove disconnected device, keep others
                let remainingUIDs = tap.currentDeviceUIDs.filter { $0 != deviceUID }.sorted()
                if !remainingUIDs.isEmpty {
                    multiModeTapsToUpdate.append((tap: tap, remainingUIDs: remainingUIDs))
                    // Update in-memory selection to remove disconnected device (don't persist)
                    var currentSelection = volumeState.getSelectedDeviceUIDs(for: app.id)
                    currentSelection.remove(deviceUID)
                    volumeState.setSelectedDeviceUIDs(for: app.id, to: currentSelection, identifier: nil)
                    continue
                }
                // All devices gone in multi-mode, fall through to single-device fallback
            }

            // Single-device mode (or multi-mode with no remaining devices): switch to fallback
            if let fallback = fallbackDevice {
                appDeviceRouting[app.id] = fallback.uid
                // Set to follow default in-memory (UI shows "System Audio")
                // Don't persist - original device preference stays in settings for reconnection
                followsDefault.insert(app.id)
                singleModeTapsToSwitch.append((tap: tap, fallbackUID: fallback.uid))
            } else {
                logger.error("No fallback device available for \(app.name)")
            }
        }

        // Execute device switches
        if !singleModeTapsToSwitch.isEmpty || !multiModeTapsToUpdate.isEmpty {
            Task {
                // Handle single-mode switches — source device is dead, skip crossfade
                for (tap, fallbackUID) in singleModeTapsToSwitch {
                    do {
                        let preferredTapSourceUID = self.preferredTapSourceDeviceUID(forOutputUIDs: [fallbackUID], isFollowsDefault: true)
                        try await tap.switchDevice(to: fallbackUID, preferredTapSourceDeviceUID: preferredTapSourceUID, sourceDeviceDead: true)
                        self.applyTapOutputState(to: tap, for: tap.app.id, deviceUIDs: [fallbackUID])
                        self.applyAutoEQToTap(tap)
                        self.scheduleAudioUnitRebuildIfNeeded(for: tap)
                    } catch {
                        self.logger.error("Failed to switch \(tap.app.name) to fallback: \(error.localizedDescription)")
                    }
                }

                // Handle multi-mode updates (remove disconnected device from aggregate)
                // Source device is dead, skip crossfade
                for (tap, remainingUIDs) in multiModeTapsToUpdate {
                    do {
                        let preferredTapSourceUID = self.preferredTapSourceDeviceUID(forOutputUIDs: remainingUIDs, isFollowsDefault: self.followsDefault.contains(tap.app.id))
                        try await tap.updateDevices(to: remainingUIDs, preferredTapSourceDeviceUID: preferredTapSourceUID, sourceDeviceDead: true)
                        self.applyTapOutputState(to: tap, for: tap.app.id, deviceUIDs: remainingUIDs)
                        self.scheduleAudioUnitRebuildIfNeeded(for: tap)
                        self.logger.debug("Removed \(deviceName) from \(tap.app.name) multi-device output")
                    } catch {
                        self.logger.error("Failed to update \(tap.app.name) devices: \(error.localizedDescription)")
                    }
                }
            }
        }

        if !affectedApps.isEmpty {
            let fallbackName = fallbackDevice?.name ?? "none"
            logger.info("\(deviceName) disconnected, \(affectedApps.count) app(s) affected")
            if settingsManager.appSettings.showDeviceDisconnectAlerts {
                showDisconnectNotification(deviceName: deviceName, fallbackName: fallbackName, affectedApps: affectedApps)
            }
        }

        // If the disconnected device was the system default, override to priority fallback
        if wasDefaultOutput {
            reEvaluateOutputDefault(excluding: deviceUID)
        }
    }

    private static func looksLikeHeadphones(_ name: String) -> Bool {
        let words = ["airpods", "headphone", "headset", "earbud", "earbuds", "buds", "beats"]
        return words.contains { name.localizedCaseInsensitiveContains($0) }
    }

    /// Called when a device appears - switches pinned apps back to their preferred device
    private func handleDeviceConnected(_ deviceUID: String, name deviceName: String) {
        // Register newly connected device in priority list
        settingsManager.ensureDeviceInPriority(deviceUID)

        var affectedApps: [AudioApp] = []
        var tapsToSwitch: [any ProcessTapControlling] = []

        // Iterate over taps for consistency with handleDeviceDisconnected
        for tap in taps.values {
            let app = tap.app

            // Skip apps that are PERSISTED as following default - they don't have explicit device preferences
            // Note: in-memory followsDefault may include temporarily displaced apps, so check persisted state
            guard !settingsManager.isFollowingDefault(for: app.persistenceIdentifier) else { continue }

            // Check if this app was pinned to the reconnected device (from persisted settings)
            let persistedUID = settingsManager.getDeviceRouting(for: app.persistenceIdentifier)
            guard persistedUID == deviceUID else { continue }

            // App was pinned to this device - switch it back
            guard appDeviceRouting[app.id] != deviceUID else { continue }

            affectedApps.append(app)
            appDeviceRouting[app.id] = deviceUID
            // Remove from followsDefault since we're restoring explicit routing
            followsDefault.remove(app.id)
            tapsToSwitch.append(tap)
        }

        if !tapsToSwitch.isEmpty {
            Task {
                for tap in tapsToSwitch {
                    do {
                        let preferredTapSourceUID = self.preferredTapSourceDeviceUID(forOutputUIDs: [deviceUID], isFollowsDefault: false)
                        try await tap.switchDevice(to: deviceUID, preferredTapSourceDeviceUID: preferredTapSourceUID)
                        self.applyTapOutputState(to: tap, for: tap.app.id, deviceUIDs: [deviceUID])
                        self.applyAutoEQToTap(tap)
                        self.scheduleAudioUnitRebuildIfNeeded(for: tap)
                    } catch {
                        self.logger.error("Failed to switch \(tap.app.name) back to \(deviceName): \(error.localizedDescription)")
                    }
                }
            }
        }

        // Second pass: restore multi-device apps that had this device in their selection
        var multiModeTapsToUpdate: [any ProcessTapControlling] = []
        for tap in taps.values {
            let app = tap.app
            guard settingsManager.getDeviceSelectionMode(for: app.persistenceIdentifier) == .multi else { continue }
            guard let persistedUIDs = settingsManager.getSelectedDeviceUIDs(for: app.persistenceIdentifier),
                  persistedUIDs.contains(deviceUID) else { continue }
            let currentUIDs = volumeState.getSelectedDeviceUIDs(for: app.id)
            guard !currentUIDs.contains(deviceUID) else { continue }

            // Add the reconnected device back to in-memory selection
            var updatedUIDs = currentUIDs
            updatedUIDs.insert(deviceUID)
            volumeState.setSelectedDeviceUIDs(for: app.id, to: updatedUIDs, identifier: app.persistenceIdentifier)
            multiModeTapsToUpdate.append(tap)
        }

        if !multiModeTapsToUpdate.isEmpty {
            Task {
                for tap in multiModeTapsToUpdate {
                    await self.updateTapForCurrentMode(for: tap.app)
                }
            }
            logger.info("\(deviceName) reconnected, restored to \(multiModeTapsToUpdate.count) multi-device app(s)")
        }

        if !affectedApps.isEmpty {
            logger.info("\(deviceName) reconnected, switched \(affectedApps.count) app(s) back")
            if settingsManager.appSettings.showDeviceDisconnectAlerts {
                showReconnectNotification(deviceName: deviceName, affectedApps: affectedApps)
            }
        }

        // Only override the default if the newly connected device IS the highest-priority
        // device (i.e., a higher-priority device just came back). If a lower-priority device
        // connects while the user is on a higher-priority device, respect the current default —
        // the user chose it. We still enter PENDING_AUTOSWITCH to guard against macOS
        // auto-switching to the new device.
        let currentDefault = deviceVolumeMonitor.defaultDeviceUID
        let isNewDeviceHigherPriority = (deviceUID == Self.resolveHighestPriority(
            priorityOrder: settingsManager.devicePriorityOrder,
            connectedDevices: outputDevices,
            isAlive: isAliveCheck
        )?.uid)

        // If this device is present but not alive, watch for it to become alive
        if let device = deviceMonitor.device(for: deviceUID),
           !isAliveCheck(device.id) {
            installAliveWatcher(deviceID: device.id, uid: deviceUID, name: deviceName)
        }

        if isNewDeviceHigherPriority, deviceUID != currentDefault {
            // A higher-priority device reconnected — switch to it
            reEvaluateOutputDefault()
        } else if !isNewDeviceHigherPriority, currentDefault == deviceUID {
            // macOS already auto-switched to the lower-priority device — restore
            // what the user was on (not highest priority — they may have chosen a mid-priority device)
            restoreConfirmedDefault()
        }

        // Cancel any existing PENDING_AUTOSWITCH before entering a new one.
        if case .pendingAutoSwitch(_, let oldTask) = outputPriorityState {
            oldTask.cancel()
            outputPriorityState = .stable
        }

        // Always enter PENDING_AUTOSWITCH for the newly connected device.
        // macOS may auto-switch to it multiple times during BT firmware handshake.
        // Without this grace period, auto-switches would be treated as "genuine user change".
        let transport = deviceMonitor.device(for: deviceUID)?.id.readTransportType()
        let timeout = (transport == .bluetooth || transport == .bluetoothLE)
            ? btAutoSwitchGracePeriod
            : autoSwitchGracePeriod

        let timeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard let self, !Task.isCancelled else { return }
            self.outputPriorityState = .stable
            self.logger.debug("Auto-switch grace period expired, no macOS switch detected")
        }

        lastAutoSwitchOverrideTime = nil
        outputPriorityState = .pendingAutoSwitch(
            connectedDeviceUID: deviceUID,
            timeoutTask: timeoutTask
        )
        logger.debug("Entered PENDING_AUTOSWITCH for \(deviceName) (\(timeout)s grace)")
    }

    // MARK: - Alive Watchers

    /// Installs a one-shot HAL listener for kAudioDevicePropertyDeviceIsAlive on a device
    /// that is present but not yet alive. When the device becomes alive, re-runs
    /// handleDeviceConnected so priority is re-evaluated. Self-removes after firing or timeout.
    private func installAliveWatcher(deviceID: AudioDeviceID, uid: String, name: String) {
        guard aliveWatchers[deviceID] == nil else { return }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self, self.isAliveCheck(deviceID) else { return }
                self.logger.info("Device became alive: \(name) (\(uid)), re-evaluating priority")
                self.removeAliveWatcher(deviceID)
                self.handleDeviceConnected(uid, name: name)
            }
        }

        let status = AudioObjectAddPropertyListenerBlock(deviceID, &address, .main, block)
        guard status == noErr else {
            logger.warning("Failed to install alive watcher for \(name) (\(deviceID)): \(status)")
            return
        }

        let timeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard let self, !Task.isCancelled else { return }
            self.logger.debug("Alive watcher timed out for \(name) (\(uid))")
            self.removeAliveWatcher(deviceID)
        }

        aliveWatchers[deviceID] = (uid: uid, block: block, timeout: timeoutTask)
        logger.debug("Installed alive watcher for \(name) (\(uid))")
    }

    /// Removes a one-shot alive watcher by device ID, cleaning up the HAL listener and timeout.
    private func removeAliveWatcher(_ deviceID: AudioDeviceID) {
        guard let watcher = aliveWatchers.removeValue(forKey: deviceID) else { return }
        watcher.timeout.cancel()

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectRemovePropertyListenerBlock(deviceID, &address, .main, watcher.block)
        if status != noErr && status != OSStatus(kAudioHardwareBadObjectError) {
            logger.warning("Failed to remove alive watcher for device \(deviceID): \(status)")
        }
    }

    /// Removes a one-shot alive watcher by device UID. Used during disconnect when the
    /// device is already removed from the monitor's list and device(for:) returns nil.
    private func removeAliveWatcher(forUID uid: String) {
        guard let (deviceID, _) = aliveWatchers.first(where: { $0.value.uid == uid }) else { return }
        removeAliveWatcher(deviceID)
    }

    private func showReconnectNotification(deviceName: String, affectedApps: [AudioApp]) {
        let content = UNMutableNotificationContent()
        content.title = "Audio Device Reconnected"
        content.body = "\"\(deviceName)\" is back. \(affectedApps.count) app(s) switched back."
        content.sound = nil

        let request = UNNotificationRequest(
            identifier: "device-reconnect-\(deviceName)",
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request) { [weak self] error in
            if let error {
                self?.logger.error("Failed to show notification: \(error.localizedDescription)")
            }
        }
    }

    private func showDisconnectNotification(deviceName: String, fallbackName: String, affectedApps: [AudioApp]) {
        let content = UNMutableNotificationContent()
        content.title = "Audio Device Disconnected"
        content.body = "\"\(deviceName)\" disconnected. \(affectedApps.count) app(s) switched to \(fallbackName)"
        content.sound = nil

        let request = UNNotificationRequest(
            identifier: "device-disconnect-\(deviceName)",
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request) { [weak self] error in
            if let error {
                self?.logger.error("Failed to show notification: \(error.localizedDescription)")
            }
        }
    }

    /// Called when system default output device changes - switches apps that follow default
    private func handleDefaultDeviceChanged(_ newDefaultUID: String) {
        // State machine: if we're waiting for macOS to auto-switch after a device connect,
        // check whether this change is the expected auto-switch or user intent.
        if case .pendingAutoSwitch(let pendingUID, let timeoutTask) = outputPriorityState {
            // Check echoes FIRST — Melo's own changes (UI, restoreConfirmedDefault)
            // create echoes. Consuming before Case 1 ensures Melo UI changes aren't
            // mistaken for macOS auto-switches.
            if outputEchoTracker.consume(newDefaultUID) {
                return
            }

            if newDefaultUID == pendingUID {
                // Settling heuristic: if >1s since last override, BT auto-switches have
                // settled. This is likely the user changing via System Settings — accept it.
                // BT auto-switches happen within ms; user actions take >1s.
                if let lastOverride = lastAutoSwitchOverrideTime,
                   Date().timeIntervalSince(lastOverride) > 1.0 {
                    timeoutTask.cancel()
                    outputPriorityState = .stable
                    lastConfirmedDefaultUID = newDefaultUID
                    lastAutoSwitchOverrideTime = nil
                    routeFollowsDefaultApps(to: newDefaultUID)
                    let deviceName = deviceMonitor.device(for: newDefaultUID)?.name ?? newDefaultUID
                    logger.info("Accepted user change to \(deviceName) (settled >1s)")
                    return
                }

                // Case 1: macOS auto-switched to the newly connected device — restore what
                // the user was on. Re-enter PENDING_AUTOSWITCH for further auto-switches.
                timeoutTask.cancel()
                restoreConfirmedDefault()
                lastAutoSwitchOverrideTime = Date()
                let transport = deviceMonitor.device(for: pendingUID)?.id.readTransportType()
                let timeout = (transport == .bluetooth || transport == .bluetoothLE)
                    ? btAutoSwitchGracePeriod
                    : autoSwitchGracePeriod
                let newTimeoutTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(timeout))
                    guard let self, !Task.isCancelled else { return }
                    self.outputPriorityState = .stable
                    self.lastAutoSwitchOverrideTime = nil
                    self.logger.debug("Auto-switch grace period expired after override")
                }
                outputPriorityState = .pendingAutoSwitch(
                    connectedDeviceUID: pendingUID,
                    timeoutTask: newTimeoutTask
                )
                return
            }

            // Case 3: Genuine user intent (different device, not our echo) — respect it.
            timeoutTask.cancel()
            outputPriorityState = .stable
            lastAutoSwitchOverrideTime = nil
        }

        // Suppress echo from our own priority-based override (when not in pendingAutoSwitch)
        if outputEchoTracker.consume(newDefaultUID) {
            return
        }

        // If any echo counter is pending, another override is in flight — skip interim routing
        if outputEchoTracker.hasPending {
            logger.debug("Skipping followsDefault routing — echo pending")
            return
        }

        // Check if the new default device is known and alive.
        guard let newDevice = deviceMonitor.device(for: newDefaultUID) else {
            // Device not yet in monitor's list (e.g., BT device default-changed before device-list
            // notification). Defer — the upcoming handleDeviceConnected will enforce priority.
            logger.debug("Default changed to unknown device \(newDefaultUID), deferring to device list refresh")
            return
        }

        let newDeviceIsAlive = isAliveCheck(newDevice.id)

        if !newDeviceIsAlive {
            // Dead device became default (race with disconnect) — override to priority fallback
            reEvaluateOutputDefault()
        } else {
            // Genuine change to a live device — route followsDefault apps
            lastConfirmedDefaultUID = newDefaultUID
            routeFollowsDefaultApps(to: newDefaultUID)

            let affectedApps = apps.filter { followsDefault.contains($0.id) }
            if !affectedApps.isEmpty {
                let deviceName = deviceMonitor.device(for: newDefaultUID)?.name ?? "Default Output"
                logger.info("Default changed to \(deviceName), \(affectedApps.count) app(s) following")
                if settingsManager.appSettings.showDeviceDisconnectAlerts {
                    showDefaultChangedNotification(newDeviceName: deviceName, affectedApps: affectedApps)
                }
            }
        }
    }

    private func showDefaultChangedNotification(newDeviceName: String, affectedApps: [AudioApp]) {
        let content = UNMutableNotificationContent()
        content.title = "Default Audio Device Changed"
        content.body = "\(affectedApps.count) app(s) switched to \"\(newDeviceName)\""
        content.sound = nil

        let request = UNNotificationRequest(
            identifier: "default-device-changed",
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request) { [weak self] error in
            if let error {
                self?.logger.error("Failed to show notification: \(error.localizedDescription)")
            }
        }
    }

    /// Returns the preferred tap source device UID for stream-specific capture.
    /// Only follows-default apps use stream-specific taps (multichannel preserved, tap always
    /// valid because the app switches device when default changes). Explicitly-routed apps
    /// always use stereo mixdown (nil) — their tap never goes stale when the default changes.
    private func preferredTapSourceDeviceUID(forOutputUIDs outputUIDs: [String], isFollowsDefault: Bool) -> String? {
        guard isFollowsDefault else { return nil }
        guard let defaultUID = deviceVolumeMonitor.defaultDeviceUID else { return nil }
        return outputUIDs.contains(defaultUID) ? defaultUID : nil
    }

    private func cleanupStaleTaps() {
        let activePIDs = Set(apps.map { $0.id })
        let stalePIDs = Set(taps.keys).subtracting(activePIDs)

        // Cancel cleanup for PIDs that reappeared — but only if bundleID matches.
        // PID reuse by a different app should not rescue the old tap.

        for pid in activePIDs {
            guard let task = pendingCleanup[pid] else { continue }

            let reappearedApp = apps.first { $0.id == pid }
            let existingTap = taps[pid]

            if let reappearedApp, let existingTap,
               reappearedApp.bundleID != existingTap.app.bundleID {
                // PID was reused by a different app — let the old tap be destroyed
                logger.debug("PID \(pid) reused by different app (\(reappearedApp.bundleID ?? "nil") vs \(existingTap.app.bundleID ?? "nil")), not cancelling cleanup")
                continue
            }

            pendingCleanup.removeValue(forKey: pid)
            task.cancel()
            // Don't remove from appliedPIDs — the tap is still alive and the aggregate
            // device is still running. The process just transiently stopped audio I/O
            // during a device change (kAudioProcessPropertyIsRunning flicker).
            // Device routing is already handled by routeFollowsDefaultApps (follows-default)
            // or stays put (explicit routing). Re-processing would cause an unnecessary
            // crossfade that interrupts audio.
            logger.debug("Cancelled pending cleanup for PID \(pid) - app reappeared")
        }

        // Schedule cleanup for newly stale PIDs (with grace period)
        for pid in stalePIDs {
            guard pendingCleanup[pid] == nil else { continue }  // Already pending

            pendingCleanup[pid] = Task { @MainActor in
                try? await Task.sleep(for: .seconds(self.staleTapGracePeriodSeconds))
                guard !Task.isCancelled else { return }

                // Double-check still stale
                let currentPIDs = Set(self.apps.map { $0.id })
                guard !currentPIDs.contains(pid) else {
                    self.pendingCleanup.removeValue(forKey: pid)
                    return
                }

                // Now safe to cleanup
                if let tap = self.taps.removeValue(forKey: pid) {
                    tap.invalidate()
                    self.logger.debug("Cleaned up stale tap for PID \(pid)")
                }
                self.appDeviceRouting.removeValue(forKey: pid)
                self.followsDefault.remove(pid)
                self.appliedPIDs.remove(pid)  // Allow re-initialization if app resumes
                self.pendingCleanup.removeValue(forKey: pid)
            }
        }

        // Include pending PIDs in cleanup exclusion to avoid premature state cleanup
        let pidsToKeep = activePIDs.union(Set(pendingCleanup.keys))
        appliedPIDs = appliedPIDs.intersection(pidsToKeep)
        followsDefault = followsDefault.intersection(pidsToKeep)
        volumeState.cleanup(keeping: pidsToKeep)
    }

    /// Debounced stale tap cleanup — coalesces rapid app-list changes into a single cleanup pass.
    private func scheduleStaleCleanup() {
        staleCleanupTask?.cancel()
        staleCleanupTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            self.cleanupStaleTaps()
        }
    }

    // MARK: - Tap Health Monitor

    /// Starts a periodic health check that recreates unresponsive taps.
    /// Checks every 2 seconds; after 3 consecutive misses (~6s), the tap is presumed dead.
    private func startHealthMonitor() {
        guard healthMonitorTask == nil else { return }
        healthMonitorTask = Task { @MainActor [weak self] in
            var consecutiveMisses: [pid_t: Int] = [:]
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, let self else { return }

                // Skip entirely when no taps exist — avoids unnecessary work at idle (#176)
                guard !self.taps.isEmpty else { continue }

                let now = Date()

                for (pid, tap) in self.taps {
                    // Skip muted apps — no callbacks while muted isn't a health signal
                    guard !tap.isMuted else { continue }

                    // Skip PIDs in recovery cooldown to prevent recreation thrashing
                    if let cooldownEnd = self.tapRecoveryCooldownUntil[pid], now < cooldownEnd {
                        continue
                    }

                    guard tap.isHealthCheckEligible(minActiveSeconds: 5.0) else { continue }

                    // Only health-check apps that are actively streaming (isRunning=true).
                    // Paused apps have no callbacks, which is normal — not a health signal.
                    let isActivelyStreaming = self.processMonitor.activeApps.contains { $0.id == pid }
                    guard isActivelyStreaming else {
                        consecutiveMisses[pid] = 0
                        continue
                    }

                    if tap.hasRecentAudioCallback(within: 3.0) {
                        consecutiveMisses[pid] = 0
                    } else {
                        let misses = (consecutiveMisses[pid] ?? 0) + 1
                        consecutiveMisses[pid] = misses

                        if misses >= 3 {
                            self.logger.warning("Tap for PID \(pid) unresponsive (\(misses) misses), recreating")
                            consecutiveMisses[pid] = 0
                            await self.recreateTap(for: pid)
                        }
                    }
                }

                // Prune entries for PIDs no longer tracked
                consecutiveMisses = consecutiveMisses.filter { self.taps[$0.key] != nil }
                self.tapRecoveryCooldownUntil = self.tapRecoveryCooldownUntil.filter { self.taps[$0.key] != nil }
            }
        }
    }

    private func stopHealthMonitor() {
        healthMonitorTask?.cancel()
        healthMonitorTask = nil
    }

    /// Tears down and recreates a tap for a given PID, preserving routing and settings.
    /// Async: awaits full CoreAudio resource teardown before creating the replacement tap
    /// to prevent orphaned IO procs from accumulating (issue #176).
    private func recreateTap(for pid: pid_t) async {
        guard let oldTap = taps.removeValue(forKey: pid) else { return }
        let deviceUIDs = oldTap.currentDeviceUIDs
        await oldTap.invalidateAsync()

        // Set cooldown to prevent thrashing
        tapRecoveryCooldownUntil[pid] = Date().addingTimeInterval(20)

        // Find the current AudioApp entry for this PID
        guard let app = apps.first(where: { $0.id == pid }) else {
            logger.debug("No active app for PID \(pid), skipping tap recreation")
            appliedPIDs.remove(pid)
            return
        }

        // Allow re-initialization
        appliedPIDs.remove(pid)

        // Re-route to the same device(s), preserving multi-device routing
        if deviceUIDs.count > 1 {
            ensureTapWithDevices(for: app, deviceUIDs: deviceUIDs)
            if taps[app.id] != nil {
                appDeviceRouting[app.id] = deviceUIDs[0]
            }
        } else if let deviceUID = deviceUIDs.first {
            ensureTapExists(for: app, deviceUID: deviceUID)
        }

        // Mark as applied to avoid redundant re-processing in applyPersistedSettings
        if taps[pid] != nil {
            appliedPIDs.insert(pid)
        }

        // Restore mute state
        if let muted = volumeState.loadSavedMute(for: pid, identifier: app.persistenceIdentifier), muted {
            taps[pid]?.isMuted = true
        }
    }

    /// Recreates the aggregate at the device's new rate for every tap on a BT output that changed
    /// sample rate (A2DP↔SCO), so each tap's IOProc re-rates to match. Falls back to a full tap
    /// recreate if the in-controller recreation throws.
    private func handleBTDeviceSampleRateChanged(uid: String, newRate: Double) async {
        logger.info("[RATE] BT output \(uid, privacy: .public) → \(newRate, format: .fixed(precision: 0)) Hz — recreating affected taps (clean dip)")
        let affected = taps.filter { $0.value.currentDeviceUIDs.contains(uid) }
        for (pid, tap) in affected {
            do {
                logger.info("[RATE] Recreating tap for PID \(pid)")
                try await tap.recreateForOutputRateChange()
                scheduleAudioUnitRebuildIfNeeded(for: tap)
            } catch {
                logger.error("[RATE] Recreate failed for PID \(pid): \(error.localizedDescription) — falling back to full recreate")
                await recreateTap(for: pid)
            }
        }
    }

    // MARK: - Input Device Lock

    /// Handles changes to the default input device.
    /// Uses state machine to distinguish auto-switch (from device connection) vs user action.
    private func handleDefaultInputDeviceChanged(_ newDefaultInputUID: String) {
        // State machine: if we're waiting for macOS to auto-switch after input device connect,
        // check whether this change is the expected auto-switch or user intent.
        if case .pendingAutoSwitch(let pendingUID, let timeoutTask) = inputPriorityState {
            if newDefaultInputUID == pendingUID, settingsManager.appSettings.lockInputDevice {
                // Case 1: macOS auto-switched to the newly connected device — restore locked device.
                // Re-enter PENDING_AUTOSWITCH because macOS may auto-switch multiple times.
                timeoutTask.cancel()
                restoreLockedInputDevice()
                let transport = deviceMonitor.inputDevice(for: pendingUID)?.id.readTransportType()
                let timeout = (transport == .bluetooth || transport == .bluetoothLE)
                    ? btAutoSwitchGracePeriod
                    : autoSwitchGracePeriod
                let newTimeoutTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(timeout))
                    guard let self, !Task.isCancelled else { return }
                    self.inputPriorityState = .stable
                    self.logger.debug("Input auto-switch grace period expired after override")
                }
                inputPriorityState = .pendingAutoSwitch(
                    connectedDeviceUID: pendingUID,
                    timeoutTask: newTimeoutTask
                )
                return
            }
            // Case 2: Our own echo from the override. Consume without disrupting state machine.
            if inputEchoTracker.consume(newDefaultInputUID) {
                return
            }
            // Case 3: Genuine user intent — respect it.
            timeoutTask.cancel()
            inputPriorityState = .stable
        }

        // Suppress echo from our own input device override (when not in pendingAutoSwitch)
        if inputEchoTracker.consume(newDefaultInputUID) {
            return
        }

        // If any input echo counter is pending, skip routing
        if inputEchoTracker.hasPending {
            logger.debug("Skipping input routing — echo pending")
            return
        }

        // If lock is disabled, let system control input freely
        guard settingsManager.appSettings.lockInputDevice else { return }

        // Restore the locked device — any change outside Melo's UI is either
        // macOS auto-switch or System Settings, and the lock should hold either way.
        // Users change the lock via Melo's UI (setLockedInputDevice).
        guard let lockedUID = settingsManager.lockedInputDeviceUID else { return }
        if newDefaultInputUID != lockedUID {
            restoreLockedInputDevice()
        }
    }

    /// Restores the locked input device, or falls back to built-in mic if unavailable.
    private func restoreLockedInputDevice() {
        guard let lockedUID = settingsManager.lockedInputDeviceUID,
              let lockedDevice = deviceMonitor.inputDevice(for: lockedUID) else {
            // No locked device or it's unavailable - fall back to built-in
            lockToBuiltInMicrophone()
            return
        }

        // Don't restore if already on the locked device
        guard deviceVolumeMonitor.defaultInputDeviceUID != lockedUID else { return }

        logger.info("Restoring locked input device: \(lockedDevice.name)")
        if deviceVolumeMonitor.setDefaultInputDevice(lockedDevice.id) {
            inputEchoTracker.increment(lockedDevice.uid)
        }
    }

    /// Locks the input device to the built-in microphone.
    /// This is a fallback — does NOT update preferredInputDeviceUID.
    private func lockToBuiltInMicrophone() {
        guard let builtInMic = deviceMonitor.inputDevices.first(where: {
            $0.id.readTransportType() == .builtIn
        }) else {
            logger.warning("No built-in microphone found")
            return
        }

        applyInputDeviceLock(builtInMic)
    }

    /// Applies input device lock without changing the user's preferred device.
    /// Used for fallback scenarios (disconnect, built-in mic recovery).
    private func applyInputDeviceLock(_ device: AudioDevice) {
        logger.info("Locking input device to: \(device.name)")
        settingsManager.setLockedInputDeviceUID(device.uid)
        if deviceVolumeMonitor.setDefaultInputDevice(device.id) {
            inputEchoTracker.increment(device.uid)
        }
    }

    /// Called when the user toggles lockInputDevice ON in settings.
    /// Captures the current default input device as the locked and preferred device.
    func handleInputLockEnabled() {
        guard let currentUID = deviceVolumeMonitor.defaultInputDeviceUID,
              let device = deviceMonitor.inputDevice(for: currentUID) else {
            return
        }
        logger.info("Input lock enabled, locking to current default: \(device.name)")
        settingsManager.setLockedInputDeviceUID(device.uid)
        settingsManager.setPreferredInputDeviceUID(device.uid)
    }

    /// Called when user explicitly selects an input device (via Melo UI).
    /// Persists the choice and applies the change.
    func setLockedInputDevice(_ device: AudioDevice) {
        logger.info("User locked input device to: \(device.name)")

        // Persist the choice — both current lock and preferred (user intent)
        settingsManager.setLockedInputDeviceUID(device.uid)
        settingsManager.setPreferredInputDeviceUID(device.uid)

        // Apply the change
        if deviceVolumeMonitor.setDefaultInputDevice(device.id) {
            inputEchoTracker.increment(device.uid)
        }
    }

    /// Called when an input device connects — restores locked/preferred device and guards against auto-switch.
    private func handleInputDeviceConnected(_ deviceUID: String, name deviceName: String) {
        guard settingsManager.appSettings.lockInputDevice else { return }

        // If the reconnected device is the user's preferred device, restore the lock to it
        if let preferredUID = settingsManager.preferredInputDeviceUID,
           deviceUID == preferredUID,
           settingsManager.lockedInputDeviceUID != preferredUID,
           let device = deviceMonitor.inputDevice(for: deviceUID) {
            logger.info("Preferred input device reconnected: \(deviceName), restoring lock")
            settingsManager.setLockedInputDeviceUID(device.uid)
        }

        // Restore the user's locked device (not priority-based — lock overrides priority)
        restoreLockedInputDevice()

        // Cancel any existing PENDING_AUTOSWITCH before entering a new one
        if case .pendingAutoSwitch(_, let oldTask) = inputPriorityState {
            oldTask.cancel()
        }

        // Always enter PENDING_AUTOSWITCH — macOS may auto-switch to the newly connected
        // device multiple times during BT handshake, even if we just restored the lock.
        let transport = deviceMonitor.inputDevice(for: deviceUID)?.id.readTransportType()
        let timeout = (transport == .bluetooth || transport == .bluetoothLE)
            ? btAutoSwitchGracePeriod
            : autoSwitchGracePeriod

        let timeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard let self, !Task.isCancelled else { return }
            self.inputPriorityState = .stable
            self.logger.debug("Input auto-switch grace period expired, no macOS switch detected")
        }

        inputPriorityState = .pendingAutoSwitch(
            connectedDeviceUID: deviceUID,
            timeoutTask: timeoutTask
        )
    }

    /// Handles input device disconnect — uses priority fallback, then built-in mic.
    private func handleInputDeviceDisconnected(_ deviceUID: String) {
        // If we were waiting for macOS to auto-switch to this device, cancel — it's gone
        if case .pendingAutoSwitch(let uid, let task) = inputPriorityState, uid == deviceUID {
            task.cancel()
            inputPriorityState = .stable
        }

        // Snapshot before async callbacks can update it
        let wasDefaultInput = deviceUID == deviceVolumeMonitor.defaultInputDeviceUID

        let priorityFallback = Self.resolveHighestPriority(
            priorityOrder: settingsManager.inputDevicePriorityOrder,
            connectedDevices: inputDevices,
            excluding: deviceUID,
            isAlive: isAliveCheck
        )

        // If the disconnected device was the default input, override to priority fallback
        if wasDefaultInput {
            reEvaluateInputDefault(excluding: deviceUID)
        }

        // If the locked device disconnected, update the lock to the fallback (or built-in mic)
        guard settingsManager.appSettings.lockInputDevice,
              settingsManager.lockedInputDeviceUID == deviceUID else { return }

        if let fallbackDevice = priorityFallback {
            logger.info("Locked input device disconnected, falling back to priority: \(fallbackDevice.name)")
            if wasDefaultInput {
                // Default already switched above, just update the lock setting
                settingsManager.setLockedInputDeviceUID(fallbackDevice.uid)
            } else {
                applyInputDeviceLock(fallbackDevice)
            }
        } else {
            logger.info("Locked input device disconnected, falling back to built-in mic")
            lockToBuiltInMicrophone()
        }
    }
}

// MARK: - URLHandlerEngine Conformance

extension AudioEngine: URLHandlerEngine {}
