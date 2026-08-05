// Melo/Views/Rows/InactiveAppRow.swift
import SwiftUI

/// A row displaying an app without a live Core Audio process. The app may be open
/// and waiting to play audio, or closed but pinned by the user.
/// Similar to AppRow but:
/// - Uses PinnedAppInfo instead of AudioApp
/// - VU meter always shows 0 (no audio level polling)
/// - Slightly dimmed appearance to indicate inactive state
/// - All settings (volume/mute/EQ/device) work normally and are persisted
struct InactiveAppRow: View {
    let appInfo: PinnedAppInfo
    let icon: NSImage
    let isAppOpen: Bool
    let onAppActivate: () -> Void
    let volume: Float  // Linear gain 0-1 (boost applied separately)
    let devices: [AudioDevice]
    let deviceIconOverrides: [String: String]
    let selectedDeviceUID: String?
    let selectedDeviceUIDs: Set<String>
    let isFollowingDefault: Bool
    let defaultDeviceUID: String?
    let deviceSelectionMode: DeviceSelectionMode
    let isMuted: Bool
    let boost: BoostLevel
    let onBoostChange: (BoostLevel) -> Void
    let onVolumeChange: (Float) -> Void
    let onMuteChange: (Bool) -> Void
    let onDeviceSelected: (String) -> Void
    let onDevicesSelected: (Set<String>) -> Void
    let onDeviceModeChange: (DeviceSelectionMode) -> Void
    let onSelectFollowDefault: () -> Void
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

    @State private var localEQSettings: EQSettings
    @State private var localStereoFieldSettings: StereoFieldSettings
    @State private var isIconHovered = false

    private var displayedPercentage: Int {
        Int(round(Double(max(0, min(4, volume * boost.rawValue))) * 100))
    }

    init(
        appInfo: PinnedAppInfo,
        icon: NSImage,
        isAppOpen: Bool = false,
        onAppActivate: @escaping () -> Void = {},
        volume: Float,
        devices: [AudioDevice],
        deviceIconOverrides: [String: String] = [:],
        selectedDeviceUID: String?,
        selectedDeviceUIDs: Set<String> = [],
        isFollowingDefault: Bool = true,
        defaultDeviceUID: String? = nil,
        deviceSelectionMode: DeviceSelectionMode = .single,
        isMuted: Bool = false,
        boost: BoostLevel = .x1,
        onBoostChange: @escaping (BoostLevel) -> Void = { _ in },
        onVolumeChange: @escaping (Float) -> Void,
        onMuteChange: @escaping (Bool) -> Void,
        onDeviceSelected: @escaping (String) -> Void,
        onDevicesSelected: @escaping (Set<String>) -> Void = { _ in },
        onDeviceModeChange: @escaping (DeviceSelectionMode) -> Void = { _ in },
        onSelectFollowDefault: @escaping () -> Void = {},
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
        self.appInfo = appInfo
        self.icon = icon
        self.isAppOpen = isAppOpen
        self.onAppActivate = onAppActivate
        self.volume = volume
        self.devices = devices
        self.deviceIconOverrides = deviceIconOverrides
        self.selectedDeviceUID = selectedDeviceUID
        self.selectedDeviceUIDs = selectedDeviceUIDs
        self.isFollowingDefault = isFollowingDefault
        self.defaultDeviceUID = defaultDeviceUID
        self.deviceSelectionMode = deviceSelectionMode
        self.isMuted = isMuted
        self.boost = boost
        self.onBoostChange = onBoostChange
        self.onVolumeChange = onVolumeChange
        self.onMuteChange = onMuteChange
        self.onDeviceSelected = onDeviceSelected
        self.onDevicesSelected = onDevicesSelected
        self.onDeviceModeChange = onDeviceModeChange
        self.onSelectFollowDefault = onSelectFollowDefault
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
        self._localEQSettings = State(initialValue: eqSettings)
        self._localStereoFieldSettings = State(initialValue: stereoFieldSettings)
    }

    var body: some View {
        ExpandableGlassRow(isExpanded: isEQExpanded, isFocused: isFocused) {
            // Header: Main row content (always visible)
            HStack(spacing: DesignTokens.Spacing.sm) {
                // VU Meter (always 0 for inactive apps)
                VUMeter(level: 0, isMuted: isMuted || volume == 0)

                // Open placeholders remain launchable/focusable even before Core
                // Audio creates a process object. Closed pinned apps stay static.
                if isAppOpen {
                    Button(action: onAppActivate) {
                        Image(nsImage: icon)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: DesignTokens.Dimensions.rowContentHeight - 4, height: DesignTokens.Dimensions.rowContentHeight - 4)
                            .opacity(isIconHovered ? 0.7 : 1)
                    }
                    .buttonStyle(.meloHover)
                    .accessibilityLabel("Open \(appInfo.displayName)")
                    .help("Open — saved controls apply as soon as audio starts")
                    .onHover { hovering in
                        isIconHovered = hovering
                        if hovering {
                            NSCursor.pointingHand.push()
                        } else {
                            NSCursor.pop()
                        }
                    }
                } else {
                    Image(nsImage: icon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: DesignTokens.Dimensions.rowContentHeight - 4, height: DesignTokens.Dimensions.rowContentHeight - 4)
                }

                // App name + optional routing subtitle (hidden when the app is on
                // system default).
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(appInfo.displayName)
                            .font(DesignTokens.Typography.rowName)
                            .lineLimit(1)
                            .help(appInfo.displayName)
                            .foregroundStyle(DesignTokens.Colors.textPrimary)

                        Button(action: onEQToggle) {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .bold))
                                .rotationEffect(.degrees(isEQExpanded ? 90 : 0))
                                .frame(width: 20, height: 20)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.meloHover)
                        .help(isEQExpanded ? "Hide \(appInfo.displayName) controls" : "Show all \(appInfo.displayName) controls")
                        .accessibilityLabel(isEQExpanded ? "Hide app controls" : "Show all app controls")
                    }

                    if let subtitle = DevicePicker.routingSubtitle(
                        devices: devices,
                        selectedDeviceUID: selectedDeviceUID ?? defaultDeviceUID ?? "",
                        selectedDeviceUIDs: selectedDeviceUIDs,
                        isFollowingDefault: isFollowingDefault,
                        mode: deviceSelectionMode
                    ) {
                        Text(subtitle)
                            .font(.system(size: 9))
                            .foregroundStyle(DesignTokens.Colors.textTertiary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if isMuted {
                    Image(systemName: "speaker.slash.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(DesignTokens.Colors.mutedIndicator)
                }

                Text("\(displayedPercentage)%")
                    .percentageStyle()
            }
            .frame(height: DesignTokens.Dimensions.rowContentHeight)
            .opacity(isAppOpen ? 0.82 : 0.6)
        } expandedContent: {
            VStack(spacing: DesignTokens.Spacing.xs) {
                AppRowControls(
                    // Gives VoiceOver "Spotify volume" instead of a bare "App volume".
                    appName: appInfo.displayName,
                    volume: volume,
                    isMuted: isMuted,
                    devices: devices,
                    deviceIconOverrides: deviceIconOverrides,
                    selectedDeviceUID: selectedDeviceUID ?? defaultDeviceUID ?? "",
                    selectedDeviceUIDs: selectedDeviceUIDs,
                    isFollowingDefault: isFollowingDefault,
                    defaultDeviceUID: defaultDeviceUID,
                    deviceSelectionMode: deviceSelectionMode,
                    boost: boost,
                    isEQExpanded: isEQExpanded,
                    onVolumeChange: onVolumeChange,
                    onMuteChange: onMuteChange,
                    onBoostChange: onBoostChange,
                    onDeviceSelected: onDeviceSelected,
                    onDevicesSelected: onDevicesSelected,
                    onDeviceModeChange: onDeviceModeChange,
                    onSelectFollowDefault: onSelectFollowDefault,
                    onEQToggle: onEQToggle,
                    isRowFocused: isFocused
                )
                .frame(maxWidth: .infinity, alignment: .trailing)

                Divider()
                    .padding(.vertical, 2)

                EQPanelView(
                    settings: $localEQSettings,
                    userPresets: userPresets,
                    onPresetSelected: { preset in
                        localEQSettings = preset.settings
                        onEQChange(preset.settings)
                    },
                    onUserPresetSelected: { userPreset in
                        localEQSettings = userPreset.settings
                        onUserPresetSelected(userPreset)
                    },
                    onSettingsChanged: { settings in
                        onEQChange(settings)
                    },
                    onSavePreset: onSavePreset,
                    onDeleteUserPreset: onDeleteUserPreset,
                    onRenameUserPreset: onRenameUserPreset
                )

                StereoFieldControlView(
                    settings: $localStereoFieldSettings,
                    onSettingsChanged: onStereoFieldChange
                )
            }
            .padding(.top, DesignTokens.Spacing.sm)
        }
        .onChange(of: eqSettings) { _, newValue in
            localEQSettings = newValue
        }
        .onChange(of: stereoFieldSettings) { _, newValue in
            localStereoFieldSettings = newValue
        }
    }
}
