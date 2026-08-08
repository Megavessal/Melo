// Melo/Views/Settings/Tabs/AudioTab.swift
import SwiftUI

@MainActor
struct AudioTab: View {
    @Bindable var settings: SettingsManager
    @Bindable var audioEngine: AudioEngine
    @Bindable var deviceVolumeMonitor: DeviceVolumeMonitor
    @Bindable var callDuckingManager: CallDuckingManager
    @Bindable var powerSourceMonitor: PowerSourceMonitor
    /// The section the Guide sent the reader here to see. No default: dropping
    /// it at the call site is then a build error rather than a tab that quietly
    /// opens at the top again.
    let sectionTarget: SettingsSectionTarget?
    /// Where the scroll view is parked. `scrollPosition` reads this during the
    /// scroll view's own layout, which is why the Guide's target is copied into
    /// it rather than acted on afterwards: a `ScrollViewProxy.scrollTo` issued
    /// after the tab appears rendered nothing at all, and nothing could see that
    /// it had not.
    @State private var scrolledSection: String?

    @State private var showCallAppPicker = false

    /// Memoized sorted output devices for the system-sounds picker.
    @State private var sortedOutputDevices: [AudioDevice] = []

    private var unifiedLoudnessToggleBinding: Binding<Bool> {
        Binding(
            get: {
                settings.appSettings.loudnessCompensationEnabled
                    && settings.appSettings.loudnessEqualizationEnabled
            },
            set: { isEnabled in
                settings.appSettings.setUnifiedLoudnessEnabled(isEnabled)
            }
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                volumeSection
                callsSection
                adaptiveAudioSection
                accessibilitySection
                privacySection
                devicesSection
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .scrollTargetLayout()
        }
        .scrollIndicators(.never)
        .scrollPosition(id: $scrolledSection, anchor: .top)
        // `initial: true` because the tab the reader is sent to is usually
        // built *after* the Guide set the target, so there is no change left
        // to observe by the time this view exists.
        .onChange(of: sectionTarget, initial: true) { _, target in
            if let target { scrolledSection = target.section }
        }
        .onAppear { updateSortedDevices() }
        .onChange(of: audioEngine.outputDevices) { _, _ in updateSortedDevices() }
        .onChange(of: settings.appSettings.lockInputDevice) { oldValue, newValue in
            if !oldValue && newValue {
                audioEngine.handleInputLockEnabled()
            }
        }
        .onChange(of: settings.appSettings.loudnessCompensationEnabled) { _, newValue in
            audioEngine.setLoudnessCompensationEnabled(newValue)
        }
        .onChange(of: settings.appSettings.loudnessEqualizationEnabled) { _, newValue in
            audioEngine.setLoudnessEqualizationEnabled(newValue)
        }
        .onChange(of: settings.appSettings.adaptiveAudio) { _, newValue in
            audioEngine.setAdaptiveAudioSettings(newValue)
        }
        .onChange(of: settings.appSettings.privacyFriendlyProcessingEnabled) { _, newValue in
            audioEngine.setPrivacyFriendlyProcessingEnabled(newValue)
        }
        .onChange(of: settings.appSettings.lowerOtherAppsDuringCalls) { _, _ in
            callDuckingManager.checkNow()
        }
        .onChange(of: settings.appSettings.additionalCallAppIdentifiers) { _, _ in
            callDuckingManager.checkNow()
        }
        .onChange(of: settings.appSettings.monoAudioEnabled) { _, newValue in
            audioEngine.setMonoAudioEnabled(newValue)
        }
        .onChange(of: settings.appSettings.reduceProcessingOnBattery) { _, _ in
            powerSourceMonitor.refresh()
        }
        .sheet(isPresented: $showCallAppPicker) {
            CallAppPickerSheet(settings: settings, apps: audioEngine.displayableApps)
        }
    }

    // MARK: - Calls

    private var callsSection: some View {
        SettingsSection("Calls") {
            SettingsRow(
                "Lower Other Apps During Calls",
                description: "Gently lower other apps while a call app is making sound, then bring them back"
            ) {
                Toggle("", isOn: $settings.appSettings.lowerOtherAppsDuringCalls)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
            }
            SettingsRowDivider()
            SettingsRow(
                "Call Apps",
                description: callDuckingManager.activeCallAppNames.isEmpty
                    ? "Zoom, FaceTime, Teams, Discord, and Slack are recognized automatically"
                    : "Call active: \(callDuckingManager.activeCallAppNames.joined(separator: ", "))"
            ) {
                Button("Choose…") { showCallAppPicker = true }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .id("Calls")
    }

    // MARK: - Accessibility

    private var accessibilitySection: some View {
        SettingsSection("Listening") {
            SettingsRow(
                "Clearer Voices",
                description: "Bring speech forward in movies, calls, and videos"
            ) {
                Toggle("", isOn: Binding(
                    get: { settings.appSettings.adaptiveAudio.dialogueBoostEnabled },
                    set: { enabled in
                        settings.appSettings.adaptiveAudio.dialogueBoostEnabled = enabled
                        if enabled { settings.appSettings.adaptiveAudio.enabled = true }
                    }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
            }
            SettingsRowDivider()
            SettingsRow(
                "Same Sound in Both Ears",
                description: "Combine left and right so both sides play the same sound"
            ) {
                Toggle("", isOn: $settings.appSettings.monoAudioEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
            }
        }
        .id("Listening")
    }

    // MARK: - Privacy

    private var privacySection: some View {
        SettingsSection("Privacy") {
            SettingsRow(
                "Process Only When Needed",
                description: "Leave untouched apps on their normal audio path to reduce the purple macOS indicator"
            ) {
                Toggle("", isOn: $settings.appSettings.privacyFriendlyProcessingEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
                    .help(
                        "macOS still shows its purple system-audio indicator while Melo is changing "
                            + "volume, EQ, normalization, routing, or effects."
                    )
            }
            SettingsRowDivider()
            SettingsRow(
                "Use Less Processing on Battery",
                description: "Pause automatic sound enhancements while unplugged; app volume and routing keep working"
            ) {
                Toggle("", isOn: $settings.appSettings.reduceProcessingOnBattery)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
            }
        }
        .id("Privacy")
    }

    // MARK: - Adaptive Audio

    private var adaptiveAudioSection: some View {
        SettingsSection("Smart Sound") {
            SettingsRow(
                "Smart Sound",
                description: "Gently balance tone and catch sudden loud moments"
            ) {
                Toggle("", isOn: $settings.appSettings.adaptiveAudio.enabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
            }

            if settings.appSettings.adaptiveAudio.enabled {
                SettingsRowDivider()
                SettingsRow(
                    "Strength",
                    description: "Low preserves more dynamics; High applies stronger correction"
                ) {
                    Picker("Strength", selection: $settings.appSettings.adaptiveAudio.intensity) {
                        ForEach(AdaptiveAudioIntensity.allCases) { intensity in
                            Text(intensity.description).tag(intensity)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 240)
                }

                SettingsRowDivider()
                SettingsRow(
                    "Balance Sound Automatically",
                    description: "Make small tone adjustments based on what is playing"
                ) {
                    Toggle("", isOn: $settings.appSettings.adaptiveAudio.contentAwareEQEnabled)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .labelsHidden()
                }

                SettingsRowDivider()
                SettingsRow(
                    "Keep Volume Steady",
                    description: "Reduce sudden jumps without flattening normal movie impact"
                ) {
                    Toggle("", isOn: $settings.appSettings.adaptiveAudio.smartNormalizationEnabled)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .labelsHidden()
                }
            }
        }
        .id("Smart Sound")
    }

    // MARK: - Volume

    private var volumeSection: some View {
        SettingsSection("Volume") {
            SettingsRow(
                "Default Volume",
                description: "Initial volume for new apps"
            ) {
                VolumeSlider(
                    $settings.appSettings.defaultNewAppVolume,
                    range: 0.1...1.0,
                    width: 280
                )
            }
            SettingsRowDivider()
            SettingsRow(
                "Balanced Volume and Fuller Sound",
                description: "Keep apps closer in volume and preserve fullness when listening quietly"
            ) {
                Toggle("", isOn: unifiedLoudnessToggleBinding)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
            }
        }
        .id("Volume")
    }

    // MARK: - Devices

    private var devicesSection: some View {
        SettingsSection("Devices") {
            SettingsRow(
                "Lock Input Device",
                description: "Prevent auto-switching when devices connect"
            ) {
                Toggle("", isOn: $settings.appSettings.lockInputDevice)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
            }
            SettingsRowDivider()
            SettingsRow(
                "Pause When Headphones Disconnect",
                description: "Pause playback if the current headphones unexpectedly disconnect"
            ) {
                Toggle("", isOn: $settings.appSettings.pauseOnHeadphoneDisconnect)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
            }
            SettingsRowDivider()
            SettingsRow(
                "System Sounds",
                description: "Where alerts and effects play"
            ) {
                SystemSoundsDevicePicker(
                    devices: sortedOutputDevices,
                    deviceIconOverrides: audioEngine.settingsManager.deviceIconOverrides,
                    selectedDeviceUID: deviceVolumeMonitor.systemDeviceUID,
                    defaultDeviceUID: deviceVolumeMonitor.defaultDeviceUID,
                    isFollowingDefault: deviceVolumeMonitor.isSystemFollowingDefault,
                    onDeviceSelected: { deviceUID in
                        if let device = sortedOutputDevices.first(where: { $0.uid == deviceUID }) {
                            deviceVolumeMonitor.setSystemDeviceExplicit(device.id)
                        }
                    },
                    onSelectFollowDefault: {
                        deviceVolumeMonitor.setSystemFollowDefault()
                    }
                )
            }
            SettingsRowDivider()
            SettingsRow(
                "Alert Volume",
                description: "Volume for alerts and notifications"
            ) {
                VolumeSlider(
                    Binding(
                        get: { deviceVolumeMonitor.alertVolume },
                        set: { deviceVolumeMonitor.setAlertVolume($0) }
                    ),
                    range: 0...1,
                    width: 280
                )
            }
            .task {
                // No CoreAudio listener for alert volume — must poll via AppleScript.
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(2))
                    deviceVolumeMonitor.refreshAlertVolume()
                }
            }
        }
        .id("Devices")
    }

    private func updateSortedDevices() {
        sortedOutputDevices = audioEngine.prioritySortedOutputDevices
    }
}


@MainActor
private struct CallAppPickerSheet: View {
    @Bindable var settings: SettingsManager
    let apps: [DisplayableApp]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Choose Call Apps")
                .font(.system(size: 20, weight: .semibold, design: .rounded))
            Text("Melo already recognizes common calling apps. Choose the browser you use for Google Meet, or add another app here.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("Melo checks only whether these apps are making sound. It does not save or record their audio.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            List(apps, id: \.id) { app in
                Toggle(isOn: Binding(
                    get: { settings.appSettings.additionalCallAppIdentifiers.contains(app.id) },
                    set: { selected in
                        var identifiers = settings.appSettings.additionalCallAppIdentifiers
                        if selected {
                            identifiers.insert(app.id)
                        } else {
                            identifiers.remove(app.id)
                        }
                        settings.appSettings.additionalCallAppIdentifiers = identifiers
                    }
                )) {
                    HStack(spacing: 8) {
                        Image(nsImage: app.icon).resizable().frame(width: 22, height: 22)
                        Text(app.displayName)
                    }
                }
            }

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 480, height: 480)
    }
}
