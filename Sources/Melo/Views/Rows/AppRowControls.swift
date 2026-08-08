// Melo/Views/Rows/AppRowControls.swift
import SwiftUI

/// Shared controls for app rows: mute button, volume slider, percentage, VU meter, device picker, EQ button.
/// Used by both AppRow (active apps) and InactiveAppRow (pinned inactive apps).
struct AppRowControls: View {
    /// Name of the app these controls belong to, used for the VoiceOver
    /// slider label. Defaulted so existing call sites keep compiling; pass it
    /// from AppRow / InactiveAppRow so the sliders read as "Spotify volume"
    /// rather than four identically named controls.
    var appName: String = ""
    let volume: Float
    let isMuted: Bool
    let devices: [AudioDevice]
    var deviceIconOverrides: [String: String] = [:]
    let selectedDeviceUID: String
    let selectedDeviceUIDs: Set<String>
    let isFollowingDefault: Bool
    let defaultDeviceUID: String?
    let deviceSelectionMode: DeviceSelectionMode
    let boost: BoostLevel
    let isEQExpanded: Bool
    let onVolumeChange: (Float) -> Void
    let onMuteChange: (Bool) -> Void
    let onBoostChange: (BoostLevel) -> Void
    let onDeviceSelected: (String) -> Void
    let onDevicesSelected: (Set<String>) -> Void
    let onDeviceModeChange: (DeviceSelectionMode) -> Void
    let onSelectFollowDefault: () -> Void
    let onEQToggle: () -> Void
    var isRowFocused: Bool = false

    @State private var dragOverrideValue: Double?
    @State private var isEQButtonHovered = false

    private var effectiveGain: Float {
        max(0, min(4, volume * boost.rawValue))
    }

    private var sliderValue: Double {
        dragOverrideValue ?? VolumeMapping.sliderPosition(forEffectiveGain: effectiveGain)
    }

    private func setEffectiveGain(_ gain: Float) {
        let components = VolumeMapping.components(forEffectiveGain: gain)
        onBoostChange(components.boost)
        onVolumeChange(components.volume)
        if isMuted && gain > 0 {
            onMuteChange(false)
        }
    }

    private var sliderBinding: Binding<Double> {
        Binding(
            get: { sliderValue },
            set: { newValue in
                dragOverrideValue = newValue
                setEffectiveGain(VolumeMapping.effectiveGain(forSliderPosition: newValue))
            }
        )
    }

    /// The displayed percentage value, matching EditablePercentage's formula.
    private var displayedPercentage: Int {
        Int(round(Double(VolumeMapping.effectiveGain(forSliderPosition: sliderValue)) * 100))
    }

    /// Show muted icon when muted OR displayed volume is 0%.
    /// Uses percentage threshold (not exact sliderValue == 0) because the x² volume
    /// mapping round-trip can leave sliderValue at tiny non-zero values (e.g. 0.003)
    /// that display as "0%" but fail exact Double equality.
    private var showMutedIcon: Bool { isMuted || displayedPercentage == 0 }

    private var volumeAccessibilityTitle: String {
        appName.isEmpty ? "App volume" : "\(appName) volume"
    }

    /// The slider's position is not a percentage of itself — it maps
    /// non-linearly onto 0–400% effective gain — so VoiceOver has to be told
    /// the gain, not the position.
    private static func gainPercentText(forSliderPosition position: Double) -> String {
        let gain = VolumeMapping.effectiveGain(forSliderPosition: position)
        return "\(Int(round(Double(gain) * 100)))%"
    }

    private var eqButtonColor: Color {
        if isEQExpanded {
            return DesignTokens.Colors.interactiveActive
        } else if isEQButtonHovered {
            return DesignTokens.Colors.interactiveHover
        } else {
            return DesignTokens.Colors.interactiveDefault
        }
    }

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            // Mute button
            MuteButton(
                isMuted: showMutedIcon,
                levelFraction: sliderValue,
                subject: appName
            ) {
                if showMutedIcon {
                    if displayedPercentage == 0 {
                        setEffectiveGain(1.0)
                    }
                    onMuteChange(false)
                } else {
                    onMuteChange(true)
                }
            }

            // Volume slider
            LiquidGlassSlider(
                value: sliderBinding,
                showUnityMarker: true,
                accessibilityTitle: volumeAccessibilityTitle,
                valueDescription: Self.gainPercentText(forSliderPosition:),
                onEditingChanged: { editing in
                    if !editing {
                        dragOverrideValue = nil
                    }
                }
            )
            .frame(width: DesignTokens.Dimensions.sliderWidth)
            .opacity(showMutedIcon ? 0.5 : 1.0)
            .scrollWheelStep(sliderBinding, in: 0.0...1.0)
            // The tour's first step is about this slider and nothing else.
            // Unconditional because only one app row is open at a time, so
            // exactly one of these exists whenever the step is on screen.
            .guidedTourTarget(.appVolume)

            // Unified effective gain percentage: 100% is normal maximum;
            // 101...400% is the continuous boost range.
            EditablePercentage(
                percentage: Binding(
                    get: { displayedPercentage },
                    set: { newPercentage in
                        setEffectiveGain(Float(newPercentage) / 100)
                    }
                ),
                range: 0...400,
                subject: appName,
                isRowFocused: isRowFocused
            )

            // The boost shortcut and slider now describe the same effective gain.
            BoostChevrons(level: boost) { target in
                setEffectiveGain(target.rawValue)
            }

            DevicePicker(
                devices: devices,
                deviceIconOverrides: deviceIconOverrides,
                selectedDeviceUID: selectedDeviceUID,
                selectedDeviceUIDs: selectedDeviceUIDs,
                isFollowingDefault: isFollowingDefault,
                defaultDeviceUID: defaultDeviceUID,
                mode: deviceSelectionMode,
                onModeChange: onDeviceModeChange,
                onDeviceSelected: onDeviceSelected,
                onDevicesSelected: onDevicesSelected,
                onSelectFollowDefault: onSelectFollowDefault,
                showModeToggle: true,
                triggerWidth: 0,
                triggerStyle: .iconOnly
            )

            // EQ button
            Button {
                onEQToggle()
            } label: {
                ZStack {
                    Image(systemName: "slider.vertical.3")
                        .opacity(isEQExpanded ? 0 : 1)
                        .rotationEffect(.degrees(isEQExpanded ? 90 : 0))

                    Image(systemName: "xmark")
                        .opacity(isEQExpanded ? 1 : 0)
                        .rotationEffect(.degrees(isEQExpanded ? 0 : -90))
                }
                .font(DesignTokens.Typography.Scale.body())
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(eqButtonColor)
                .frame(
                    minWidth: DesignTokens.Dimensions.minTouchTarget,
                    minHeight: DesignTokens.Dimensions.minTouchTarget
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.meloHover)
            .accessibilityLabel(isEQExpanded ? "Close Equalizer" : "Equalizer")
            .onHover { isEQButtonHovered = $0 }
            .help(isEQExpanded ? "Close Equalizer" : "Equalizer")
            .animation(DesignTokens.Animation.panel, value: isEQExpanded)
            .animation(DesignTokens.Animation.hover, value: isEQButtonHovered)
        }
        .fixedSize()
    }
}
