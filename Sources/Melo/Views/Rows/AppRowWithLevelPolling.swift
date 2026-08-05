// Melo/Views/Rows/AppRowWithLevelPolling.swift
import SwiftUI

/// One 30 Hz tick shared by every visible app row.
///
/// Each row used to own its own `Timer`, so eight audible apps meant eight
/// independent 30 Hz main-thread sources — 240 wakeups a second while the
/// popup was open, all reading the same clock to sample a meter. Rows now
/// observe a single tick, and the timer exists only while at least one row is
/// actually subscribed.
@MainActor
@Observable
final class AudioLevelTicker {
    static let shared = AudioLevelTicker()

    /// Monotonic counter. Rows depend on it via `onChange`; the value itself
    /// carries no meaning beyond "sample your level again".
    private(set) var tick: UInt64 = 0

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var subscriberCount = 0

    private init() {}

    func subscribe() {
        subscriberCount += 1
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(
            withTimeInterval: DesignTokens.Timing.vuMeterUpdateInterval,
            repeats: true
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tick &+= 1
            }
        }
    }

    func unsubscribe() {
        subscriberCount = max(0, subscriberCount - 1)
        guard subscriberCount == 0 else { return }
        timer?.invalidate()
        timer = nil
    }
}

/// App row that polls audio levels at regular intervals
struct AppRowWithLevelPolling: View {
    let app: AudioApp
    let volume: Float
    let isMuted: Bool
    let devices: [AudioDevice]
    let deviceIconOverrides: [String: String]
    let selectedDeviceUID: String
    let selectedDeviceUIDs: Set<String>
    let isFollowingDefault: Bool
    let defaultDeviceUID: String?
    let deviceSelectionMode: DeviceSelectionMode
    let boost: BoostLevel
    let onBoostChange: (BoostLevel) -> Void
    let getAudioLevel: () -> Float
    let isPopupVisible: Bool
    let onVolumeChange: (Float) -> Void
    let onMuteChange: (Bool) -> Void
    let onDeviceSelected: (String) -> Void
    let onDevicesSelected: (Set<String>) -> Void
    let onDeviceModeChange: (DeviceSelectionMode) -> Void
    let onSelectFollowDefault: () -> Void
    let onAppActivate: () -> Void
    let eqSettings: EQSettings
    let stereoFieldSettings: StereoFieldSettings
    let userPresets: [UserEQPreset]
    let onEQChange: (EQSettings) -> Void
    let onStereoFieldChange: (StereoFieldSettings) -> Void
    let onUserPresetSelected: (UserEQPreset) -> Void
    let onSavePreset: (String, EQSettings) -> Void
    let onDeleteUserPreset: (UUID) -> Void
    let onRenameUserPreset: (UUID, String) -> Void
    let isEQExpanded: Bool
    let onEQToggle: () -> Void
    let isFocused: Bool

    @State private var displayLevel: Float = 0
    @State private var isPolling = false

    private var levelTick: UInt64 { AudioLevelTicker.shared.tick }

    init(
        app: AudioApp,
        volume: Float,
        isMuted: Bool,
        devices: [AudioDevice],
        deviceIconOverrides: [String: String] = [:],
        selectedDeviceUID: String,
        selectedDeviceUIDs: Set<String> = [],
        isFollowingDefault: Bool = true,
        defaultDeviceUID: String? = nil,
        deviceSelectionMode: DeviceSelectionMode = .single,
        boost: BoostLevel = .x1,
        onBoostChange: @escaping (BoostLevel) -> Void = { _ in },
        getAudioLevel: @escaping () -> Float,
        isPopupVisible: Bool = true,
        onVolumeChange: @escaping (Float) -> Void,
        onMuteChange: @escaping (Bool) -> Void,
        onDeviceSelected: @escaping (String) -> Void,
        onDevicesSelected: @escaping (Set<String>) -> Void = { _ in },
        onDeviceModeChange: @escaping (DeviceSelectionMode) -> Void = { _ in },
        onSelectFollowDefault: @escaping () -> Void = {},
        onAppActivate: @escaping () -> Void = {},
        eqSettings: EQSettings = EQSettings(),
        stereoFieldSettings: StereoFieldSettings = .centered,
        userPresets: [UserEQPreset] = [],
        onEQChange: @escaping (EQSettings) -> Void = { _ in },
        onStereoFieldChange: @escaping (StereoFieldSettings) -> Void = { _ in },
        onUserPresetSelected: @escaping (UserEQPreset) -> Void = { _ in },
        onSavePreset: @escaping (String, EQSettings) -> Void = { _, _ in },
        onDeleteUserPreset: @escaping (UUID) -> Void = { _ in },
        onRenameUserPreset: @escaping (UUID, String) -> Void = { _, _ in },
        isEQExpanded: Bool = false,
        onEQToggle: @escaping () -> Void = {},
        isFocused: Bool = false
    ) {
        self.app = app
        self.volume = volume
        self.isMuted = isMuted
        self.devices = devices
        self.deviceIconOverrides = deviceIconOverrides
        self.selectedDeviceUID = selectedDeviceUID
        self.selectedDeviceUIDs = selectedDeviceUIDs
        self.isFollowingDefault = isFollowingDefault
        self.defaultDeviceUID = defaultDeviceUID
        self.deviceSelectionMode = deviceSelectionMode
        self.boost = boost
        self.onBoostChange = onBoostChange
        self.getAudioLevel = getAudioLevel
        self.isPopupVisible = isPopupVisible
        self.onVolumeChange = onVolumeChange
        self.onMuteChange = onMuteChange
        self.onDeviceSelected = onDeviceSelected
        self.onDevicesSelected = onDevicesSelected
        self.onDeviceModeChange = onDeviceModeChange
        self.onSelectFollowDefault = onSelectFollowDefault
        self.onAppActivate = onAppActivate
        self.eqSettings = eqSettings
        self.stereoFieldSettings = stereoFieldSettings
        self.userPresets = userPresets
        self.onEQChange = onEQChange
        self.onStereoFieldChange = onStereoFieldChange
        self.onUserPresetSelected = onUserPresetSelected
        self.onSavePreset = onSavePreset
        self.onDeleteUserPreset = onDeleteUserPreset
        self.onRenameUserPreset = onRenameUserPreset
        self.isEQExpanded = isEQExpanded
        self.onEQToggle = onEQToggle
        self.isFocused = isFocused
    }

    var body: some View {
        AppRow(
            app: app,
            volume: volume,
            audioLevel: displayLevel,
            devices: devices,
            deviceIconOverrides: deviceIconOverrides,
            selectedDeviceUID: selectedDeviceUID,
            selectedDeviceUIDs: selectedDeviceUIDs,
            isFollowingDefault: isFollowingDefault,
            defaultDeviceUID: defaultDeviceUID,
            deviceSelectionMode: deviceSelectionMode,
            isMuted: isMuted,
            boost: boost,
            onBoostChange: onBoostChange,
            onVolumeChange: onVolumeChange,
            onMuteChange: onMuteChange,
            onDeviceSelected: onDeviceSelected,
            onDevicesSelected: onDevicesSelected,
            onDeviceModeChange: onDeviceModeChange,
            onSelectFollowDefault: onSelectFollowDefault,
            onAppActivate: onAppActivate,
            eqSettings: eqSettings,
            stereoFieldSettings: stereoFieldSettings,
            userPresets: userPresets,
            onEQChange: onEQChange,
            onStereoFieldChange: onStereoFieldChange,
            onUserPresetSelected: onUserPresetSelected,
            onSavePreset: onSavePreset,
            onDeleteUserPreset: onDeleteUserPreset,
            onRenameUserPreset: onRenameUserPreset,
            isEQExpanded: isEQExpanded,
            onEQToggle: onEQToggle,
            isFocused: isFocused
        )
        .onAppear {
            if isPopupVisible {
                startLevelPolling()
            }
        }
        .onDisappear {
            stopLevelPolling()
        }
        .onChange(of: isPopupVisible) { _, visible in
            if visible {
                startLevelPolling()
            } else {
                stopLevelPolling()
                displayLevel = 0  // Reset meter when hidden
            }
        }
        .onChange(of: levelTick) { _, _ in
            guard isPolling else { return }
            displayLevel = getAudioLevel()
        }
    }

    private func startLevelPolling() {
        guard !isPolling else { return }
        isPolling = true
        AudioLevelTicker.shared.subscribe()
    }

    private func stopLevelPolling() {
        guard isPolling else { return }
        isPolling = false
        AudioLevelTicker.shared.unsubscribe()
    }
}
