// Melo/Settings/SettingsManager.swift
import Foundation
import os
import ServiceManagement
import AppKit


nonisolated enum MeloExperienceVersion {
    // Bumped only when first-run setup gains a page that asks something new, so
    // people who finished an older version are asked once. Routine releases must
    // leave this alone — `OnboardingWindowController.showIfNeeded()` replays the
    // whole flow for anyone below it.
    //
    // Held at 3 through the release that restored setup's Bluetooth page, which
    // is the closest call this constant has had. Against bumping, and decisive:
    // `decodeSettings` below migrates every pre-existing install to
    // `bluetoothFeaturesEnabled = true`, so a replay would put a page in front
    // of that cohort whose question is already answered yes; and
    // `WhatsNewCoordinator.showIfNeeded` stamps the current build as seen
    // whenever setup suppresses it, so the bump would silently consume this
    // release's What's New for everyone who already had Melo. For it: the
    // bundle identifier changed this release, which revokes every macOS
    // permission grant once, and a replayed flow is where those three prompts
    // are explained. That is real, and it is answered where each permission is
    // actually needed — the popup already has copy for Bluetooth waiting and
    // Bluetooth refused, and the audio and volume-key prompts re-raise in
    // context too. A release note carries the news to that cohort instead.
    static let onboarding = 3
    static let guidedTour = 2
}

// MARK: - Analytics Consent

/// Three states, not a Bool, because "has not been asked yet" and "said no"
/// have to behave differently: the first may raise a prompt exactly once, the
/// second must never raise one again. Collapsing them into `false` is how an
/// opt-in prompt turns into a nag.
///
/// `.unasked` is the only permitted default, and only a control the user
/// operated may write `.granted`. `scripts/verify-telemetry.py` fails the build
/// if either of those stops being true.
nonisolated enum AnalyticsConsent: String, Codable, Sendable {
    case unasked
    case granted
    case denied
}

// MARK: - Pinned App Info

struct PinnedAppInfo: Codable, Equatable {
    let persistenceIdentifier: String
    let displayName: String
    let bundleID: String?
}

// MARK: - Ignored App Info

struct IgnoredAppInfo: Codable, Equatable {
    let persistenceIdentifier: String
    let displayName: String
    let bundleID: String?
}

// MARK: - App-Wide Settings Model

nonisolated struct AppSettings: Codable, Equatable {
    // General
    var launchAtLogin: Bool = false
    var menuBarIconStyle: MenuBarIconStyle = .default
    var menuBarInfoStyle: MenuBarInfoStyle = .iconOnly
    /// Off by default. The menu bar sits in peripheral vision, which is far more
    /// motion-sensitive than the centre of the screen, so movement there is
    /// opt-in rather than something a new user has to discover and switch off.
    var menuBarIconMotion: Bool = false
    /// Whether the user has said Melo may look for paired Bluetooth devices.
    /// Not the same as macOS having allowed it: the first IOBluetooth call is
    /// what raises the system prompt, and this flag only decides whether that
    /// call is ever made. Off by default, and answered in one of two places that
    /// each have the reason on screen: setup's Bluetooth page, or the switch in
    /// Settings › General. Entering device-priority editing in the popup does
    /// not answer it — that is where an install which already said yes first
    /// reaches IOBluetooth. Nothing at launch reads it at all.
    var bluetoothFeaturesEnabled: Bool = false
    var onboardingVersionCompleted: Int = 0
    var guidedTourVersionCompleted: Int = 0
    /// Set only when a brand-new user finishes the welcome window. Existing
    /// installations are migrated as complete so updates never replay the tour.
    var guidedTourPending: Bool = false
    /// Highest build whose release notes the user has already been shown. Zero
    /// means "never stamped", which covers both a fresh install and anyone who
    /// upgraded from a release that predates this key — neither should be shown
    /// a What's New window for changes they either never missed or cannot be
    /// told about accurately, so the first launch stamps the current build and
    /// shows nothing.
    var lastSeenReleaseBuild: Int = 0
    var quietMoveDelay: QuietMoveDelayOption = .never
    var showInDock: Bool = false
    /// Off until asked, and off if the answer was no. Nothing in Melo may
    /// change this except a control the user operated — see `AnalyticsConsent`.
    var analyticsConsent: AnalyticsConsent = .unasked

    // Audio
    var defaultNewAppVolume: Float = 1.0      // 100% (unity gain)

    // Input Device Lock
    var lockInputDevice: Bool = true          // Prevent auto-switching input device

    // Notifications
    var showDeviceDisconnectAlerts: Bool = true

    // Audio Processing
    var loudnessCompensationEnabled: Bool = false  // ISO 226:2023 equal-loudness contour compensation
    var loudnessEqualizationEnabled: Bool = false  // Real-time loudness equalization
    var adaptiveAudio: AdaptiveAudioSettings = .init() // Content-aware EQ and hearing protection
    var lowerOtherAppsDuringCalls: Bool = false
    var additionalCallAppIdentifiers: Set<String> = []
    var monoAudioEnabled: Bool = false
    var pauseOnHeadphoneDisconnect: Bool = false
    var reduceProcessingOnBattery: Bool = false
    /// Avoid creating a Core Audio process tap for apps whose audio Melo would
    /// otherwise pass through unchanged. This reduces how often macOS needs to
    /// show its purple system-audio privacy indicator.
    var privacyFriendlyProcessingEnabled: Bool = true

    // Media Keys & HUD
    var hudStyle: HUDStyle = .tahoe                // Visual style of the volume HUD
    var mediaKeyControlEnabled: Bool = true        // Intercept F10/F11/F12 to drive the default output device
    var volumeHotkeyStep: VolumeHotkeyStep = .normal  // Slider-domain step per keypress; user-configurable

    // Global Hotkeys
    // Keyed by ShortcutAction.rawValue. Values mirror what KeyboardShortcuts persists in
    // its UserDefaults; settings.json is the source of truth.
    var customShortcuts: [String: ShortcutCodable] = [:]

    // Appearance
    var appearance: AppearancePreference = .system  // Follow system appearance, or lock light/dark
    var visualTheme: MeloVisualTheme = .systemAccent // Follow the Mac accent by default
    var customAccentHex: String = "#0A84FF"
    var generatedTheme: GeneratedMeloTheme? = nil

    // Popup
    var popupSize: MenuBarPopupSize = .comfortable  // Overall menu bar popup size and density

    init() {}

    mutating func setUnifiedLoudnessEnabled(_ enabled: Bool) {
        loudnessCompensationEnabled = enabled
        loudnessEqualizationEnabled = enabled
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
        menuBarIconStyle = try c.decodeIfPresent(MenuBarIconStyle.self, forKey: .menuBarIconStyle) ?? .default
        menuBarIconMotion = try c.decodeIfPresent(Bool.self, forKey: .menuBarIconMotion) ?? false
        bluetoothFeaturesEnabled = try c.decodeIfPresent(Bool.self, forKey: .bluetoothFeaturesEnabled) ?? false
        menuBarInfoStyle = try c.decodeIfPresent(MenuBarInfoStyle.self, forKey: .menuBarInfoStyle) ?? .iconOnly
        onboardingVersionCompleted = try c.decodeIfPresent(Int.self, forKey: .onboardingVersionCompleted) ?? 0
        guidedTourVersionCompleted = try c.decodeIfPresent(Int.self, forKey: .guidedTourVersionCompleted) ?? 0
        guidedTourPending = try c.decodeIfPresent(Bool.self, forKey: .guidedTourPending) ?? false
        lastSeenReleaseBuild = try c.decodeIfPresent(Int.self, forKey: .lastSeenReleaseBuild) ?? 0
        // Keep quiet apps visible unless the user deliberately chooses a delay.
        // Updates and imported older settings never introduce a new setup prompt
        // or silently move apps out of the main list.
        quietMoveDelay = try c.decodeIfPresent(QuietMoveDelayOption.self, forKey: .quietMoveDelay)
            ?? .never
        showInDock = try c.decodeIfPresent(Bool.self, forKey: .showInDock) ?? false
        // An older settings file has no key here, and an absent key means the
        // question was never put to this person — not that they declined, and
        // certainly not that they agreed. Restoring a backup from a Mac where
        // analytics were on carries the answer across, which is the same
        // promise every other preference in this file makes.
        analyticsConsent = try c.decodeIfPresent(AnalyticsConsent.self, forKey: .analyticsConsent) ?? .unasked
        defaultNewAppVolume = try c.decodeIfPresent(Float.self, forKey: .defaultNewAppVolume) ?? 1.0
        lockInputDevice = try c.decodeIfPresent(Bool.self, forKey: .lockInputDevice) ?? true
        showDeviceDisconnectAlerts = try c.decodeIfPresent(Bool.self, forKey: .showDeviceDisconnectAlerts) ?? true
        loudnessCompensationEnabled = try c.decodeIfPresent(Bool.self, forKey: .loudnessCompensationEnabled) ?? false
        loudnessEqualizationEnabled = try c.decodeIfPresent(Bool.self, forKey: .loudnessEqualizationEnabled) ?? false
        adaptiveAudio = try c.decodeIfPresent(AdaptiveAudioSettings.self, forKey: .adaptiveAudio) ?? .init()
        lowerOtherAppsDuringCalls = try c.decodeIfPresent(Bool.self, forKey: .lowerOtherAppsDuringCalls) ?? false
        additionalCallAppIdentifiers = try c.decodeIfPresent(Set<String>.self, forKey: .additionalCallAppIdentifiers) ?? []
        monoAudioEnabled = try c.decodeIfPresent(Bool.self, forKey: .monoAudioEnabled) ?? false
        pauseOnHeadphoneDisconnect = try c.decodeIfPresent(Bool.self, forKey: .pauseOnHeadphoneDisconnect) ?? false
        reduceProcessingOnBattery = try c.decodeIfPresent(Bool.self, forKey: .reduceProcessingOnBattery) ?? false
        privacyFriendlyProcessingEnabled = try c.decodeIfPresent(
            Bool.self,
            forKey: .privacyFriendlyProcessingEnabled
        ) ?? true
        hudStyle = try c.decodeIfPresent(HUDStyle.self, forKey: .hudStyle) ?? .tahoe
        mediaKeyControlEnabled = try c.decodeIfPresent(Bool.self, forKey: .mediaKeyControlEnabled) ?? true
        volumeHotkeyStep = try c.decodeIfPresent(VolumeHotkeyStep.self, forKey: .volumeHotkeyStep) ?? .normal
        customShortcuts = try c.decodeIfPresent([String: ShortcutCodable].self, forKey: .customShortcuts) ?? [:]
        appearance = try c.decodeIfPresent(AppearancePreference.self, forKey: .appearance) ?? .system
        visualTheme = try c.decodeIfPresent(MeloVisualTheme.self, forKey: .visualTheme) ?? .systemAccent
        customAccentHex = try c.decodeIfPresent(String.self, forKey: .customAccentHex) ?? "#0A84FF"
        generatedTheme = try c.decodeIfPresent(GeneratedMeloTheme.self, forKey: .generatedTheme)?.normalized
        if visualTheme == .aiGenerated && generatedTheme == nil {
            visualTheme = .systemAccent
        }
        popupSize = try c.decodeIfPresent(MenuBarPopupSize.self, forKey: .popupSize) ?? .comfortable
    }
}

// MARK: - Settings Manager

/// How the settings file loaded at launch. Observable so the UI can tell the
/// user their configuration was rebuilt; a silent reset to defaults is
/// indistinguishable from a fresh install, which is how data loss goes
/// unreported.
nonisolated enum SettingsRecoveryState: Equatable, Sendable {
    /// Loaded normally, or a genuinely fresh install.
    case normal
    /// The primary file was unreadable and `settings.backup.json` was used.
    case restoredFromBackup
    /// Neither file was usable; everything is back to factory values.
    case resetToDefaults
}

@Observable
@MainActor
final class SettingsManager {
    /// Read by the UI to surface a recovery notice. See `SettingsRecoveryState`.
    private(set) var recovery: SettingsRecoveryState = .normal
    private var settings: Settings
    private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var persistenceDisabledForErase = false
    private let settingsURL: URL
    /// All disk writes are serialized so an older debounced snapshot can never
    /// finish after (and overwrite) a newer snapshot or the termination flush.
    @ObservationIgnored private let ioQueue = DispatchQueue(
        label: "dev.melo.settings-writer",
        qos: .utility
    )
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Melo", category: "SettingsManager")

    private struct PortableSettingsBackup: Codable {
        static let currentFormat = "MeloSettingsBackup"
        static let currentVersion = 1

        let format: String
        let formatVersion: Int
        let exportedAt: Date
        let settings: Settings
    }

    private enum SettingsBackupError: LocalizedError {
        case wrongFormat
        case newerFormat(Int)

        var errorDescription: String? {
            switch self {
            case .wrongFormat:
                return "This file is not a Melo settings backup."
            case .newerFormat(let version):
                return "This backup was created by a newer Melo backup format (version \(version))."
            }
        }
    }

    struct Settings: Codable {
        var version: Int = 17
        var appVolumes: [String: Float] = [:]
        var appDeviceRouting: [String: String] = [:]  // bundleID → deviceUID
        var appMutes: [String: Bool] = [:]  // bundleID → isMuted
        var appBoosts: [String: Float] = [:]  // bundleID → boost rawValue (1.0, 2.0, 3.0, 4.0)
        var appEQSettings: [String: EQSettings] = [:]  // bundleID → EQ settings
        var appStereoFieldSettings: [String: StereoFieldSettings] = [:]  // bundleID → stereo balance
        var appSettings: AppSettings = AppSettings()  // App-wide settings
        var systemSoundsFollowsDefault: Bool = true  // Whether system sounds follows macOS default
        var appDeviceSelectionMode: [String: DeviceSelectionMode] = [:]  // bundleID → selection mode
        var appSelectedDeviceUIDs: [String: [String]] = [:]  // bundleID → array of device UIDs for multi mode
        var lockedInputDeviceUID: String? = nil  // Current locked input device (updated on fallback)
        var preferredInputDeviceUID: String? = nil  // User's intended input device (survives disconnect)
        var pinnedApps: Set<String> = []  // Persistence identifiers of pinned apps
        var pinnedAppInfo: [String: PinnedAppInfo] = [:]  // Persistence identifier → app metadata
        var ignoredApps: Set<String> = []  // Persistence identifiers of hidden apps
        var ignoredAppInfo: [String: IgnoredAppInfo] = [:]  // Persistence identifier → app metadata

        // DDC monitor speaker volumes (keyed by CoreAudio device UID for stability across reboots)
        var ddcVolumes: [String: Int] = [:]       // device UID → volume (0-100)
        var ddcMuteStates: [String: Bool] = [:]   // device UID → software mute state
        var ddcSavedVolumes: [String: Int] = [:]  // device UID → volume before mute

        // Software-backed output volumes for devices without native volume control
        var softwareDeviceVolumes: [String: Float] = [:]      // device UID → visible volume (0.0-1.0)
        var softwareDeviceMuteStates: [String: Bool] = [:]    // device UID → software mute state
        var softwareDeviceSavedVolumes: [String: Float] = [:] // device UID → volume before mute

        // Per-device volume control tier override (overrides auto-detection).
        // nil/missing → auto-detect (hardware/ddc/software). Populated only by
        // the user via the device detail sheet's manual override toggle.
        var deviceVolumeTierOverride: [String: VolumeControlTier] = [:]
        var deviceIconOverrides: [String: String] = [:]  // device UID → SF Symbol name

        // Device priority (ordered device UIDs, highest priority first)
        var outputDevicePriority: [String] = []
        var inputDevicePriority: [String] = []

        // Hidden devices (UIDs of devices suppressed from the main view)
        var hiddenOutputDeviceUIDs: Set<String> = []
        var hiddenInputDeviceUIDs: Set<String> = []

        // Per-device AutoEQ headphone correction
        var deviceAutoEQ: [String: AutoEQSelection] = [:]  // deviceUID → selection
        var favoriteAutoEQProfiles: Set<String> = []  // profile IDs
        var autoEQPreampEnabled: Bool = true  // Use profile preamp vs bypass (rely on limiter)

        // User-created EQ presets (named EQ curves)
        var userEQPresets: [UserEQPreset] = []

        // Consumer-friendly Scenes and simple trigger-based automations.
        var consumerScenes: [ConsumerScene] = []
        var consumerAutomations: [ConsumerAutomation] = []

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 9
            appVolumes = (try c.decodeIfPresent([String: Float].self, forKey: .appVolumes) ?? [:])
                .filter { $0.value.isFinite && $0.value >= 0 }
                .mapValues { min($0, 1.0) }  // Clamp old volumes > 1.0 (boost is now per-app)
            appDeviceRouting = try c.decodeIfPresent([String: String].self, forKey: .appDeviceRouting) ?? [:]
            appMutes = try c.decodeIfPresent([String: Bool].self, forKey: .appMutes) ?? [:]
            appBoosts = try c.decodeIfPresent([String: Float].self, forKey: .appBoosts) ?? [:]
            appEQSettings = try c.decodeIfPresent([String: EQSettings].self, forKey: .appEQSettings) ?? [:]
            appStereoFieldSettings = (try c.decodeIfPresent([String: StereoFieldSettings].self, forKey: .appStereoFieldSettings) ?? [:])
                .mapValues(\.normalized)
            var decodedAppSettings = try c.decodeIfPresent(AppSettings.self, forKey: .appSettings) ?? AppSettings()
            if !decodedAppSettings.defaultNewAppVolume.isFinite || decodedAppSettings.defaultNewAppVolume < 0 {
                decodedAppSettings.defaultNewAppVolume = 1.0
            }

            appSettings = decodedAppSettings
            systemSoundsFollowsDefault = try c.decodeIfPresent(Bool.self, forKey: .systemSoundsFollowsDefault) ?? true
            appDeviceSelectionMode = try c.decodeIfPresent([String: DeviceSelectionMode].self, forKey: .appDeviceSelectionMode) ?? [:]
            appSelectedDeviceUIDs = try c.decodeIfPresent([String: [String]].self, forKey: .appSelectedDeviceUIDs) ?? [:]
            lockedInputDeviceUID = try c.decodeIfPresent(String.self, forKey: .lockedInputDeviceUID)
            preferredInputDeviceUID = try c.decodeIfPresent(String.self, forKey: .preferredInputDeviceUID)
            pinnedApps = try c.decodeIfPresent(Set<String>.self, forKey: .pinnedApps) ?? []
            pinnedAppInfo = try c.decodeIfPresent([String: PinnedAppInfo].self, forKey: .pinnedAppInfo) ?? [:]
            ignoredApps = try c.decodeIfPresent(Set<String>.self, forKey: .ignoredApps) ?? []
            ignoredAppInfo = try c.decodeIfPresent([String: IgnoredAppInfo].self, forKey: .ignoredAppInfo) ?? [:]
            ddcVolumes = try c.decodeIfPresent([String: Int].self, forKey: .ddcVolumes) ?? [:]
            ddcMuteStates = try c.decodeIfPresent([String: Bool].self, forKey: .ddcMuteStates) ?? [:]
            ddcSavedVolumes = try c.decodeIfPresent([String: Int].self, forKey: .ddcSavedVolumes) ?? [:]
            softwareDeviceVolumes = (try c.decodeIfPresent([String: Float].self, forKey: .softwareDeviceVolumes) ?? [:])
                .filter { $0.value.isFinite && $0.value >= 0 }
                .mapValues { min($0, 1.0) }
            softwareDeviceMuteStates = try c.decodeIfPresent([String: Bool].self, forKey: .softwareDeviceMuteStates) ?? [:]
            softwareDeviceSavedVolumes = (try c.decodeIfPresent([String: Float].self, forKey: .softwareDeviceSavedVolumes) ?? [:])
                .filter { $0.value.isFinite && $0.value >= 0 }
                .mapValues { min($0, 1.0) }
            deviceVolumeTierOverride = try c.decodeIfPresent([String: VolumeControlTier].self, forKey: .deviceVolumeTierOverride) ?? [:]
            deviceIconOverrides = try c.decodeIfPresent([String: String].self, forKey: .deviceIconOverrides) ?? [:]
            outputDevicePriority = try c.decodeIfPresent([String].self, forKey: .outputDevicePriority) ?? []
            inputDevicePriority = try c.decodeIfPresent([String].self, forKey: .inputDevicePriority) ?? []
            hiddenOutputDeviceUIDs = try c.decodeIfPresent(Set<String>.self, forKey: .hiddenOutputDeviceUIDs) ?? []
            hiddenInputDeviceUIDs = try c.decodeIfPresent(Set<String>.self, forKey: .hiddenInputDeviceUIDs) ?? []
            deviceAutoEQ = try c.decodeIfPresent([String: AutoEQSelection].self, forKey: .deviceAutoEQ) ?? [:]
            favoriteAutoEQProfiles = try c.decodeIfPresent(Set<String>.self, forKey: .favoriteAutoEQProfiles) ?? []
            autoEQPreampEnabled = try c.decodeIfPresent(Bool.self, forKey: .autoEQPreampEnabled) ?? true
            userEQPresets = try c.decodeIfPresent([UserEQPreset].self, forKey: .userEQPresets) ?? []
            consumerScenes = try c.decodeIfPresent([ConsumerScene].self, forKey: .consumerScenes) ?? []
            consumerAutomations = try c.decodeIfPresent([ConsumerAutomation].self, forKey: .consumerAutomations) ?? []
        }
    }

    /// `urls(for:in:)` returns an empty array when the domain is unavailable
    /// (sandbox denial, a stripped container). Force-unwrapping `.first`
    /// turned that into a launch crash; the conventional path lets the app
    /// start and, at worst, fail to persist.
    private static func defaultBaseDirectory() -> URL {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("Melo")
    }

    init(directory: URL? = nil) {
        let baseDir = directory ?? Self.defaultBaseDirectory()
        self.settingsURL = baseDir.appendingPathComponent("settings.json")
        self.settings = Settings()
        loadFromDisk()
    }

    func getVolume(for identifier: String) -> Float? {
        settings.appVolumes[identifier]
    }

    func setVolume(for identifier: String, to volume: Float) {
        settings.appVolumes[identifier] = normalizedAppVolume(volume)
        scheduleSave()
    }

    // MARK: - Per-App Boost

    func getBoost(for identifier: String) -> BoostLevel? {
        guard let raw = settings.appBoosts[identifier] else { return nil }
        return BoostLevel(rawValue: raw)
    }

    func setBoost(for identifier: String, to boost: BoostLevel) {
        settings.appBoosts[identifier] = boost.rawValue
        scheduleSave()
    }

    func getDeviceRouting(for identifier: String) -> String? {
        settings.appDeviceRouting[identifier]
    }

    func setDeviceRouting(for identifier: String, deviceUID: String) {
        settings.appDeviceRouting[identifier] = deviceUID
        scheduleSave()
    }

    /// Returns true if the app follows system default (no explicit device routing saved)
    func isFollowingDefault(for identifier: String) -> Bool {
        settings.appDeviceRouting[identifier] == nil
    }

    /// Clears device routing for an app, making it follow system default
    func setFollowDefault(for identifier: String) {
        settings.appDeviceRouting.removeValue(forKey: identifier)
        scheduleSave()
    }

    // MARK: - System Sounds Settings

    /// Returns whether system sounds should follow the macOS default output device
    var isSystemSoundsFollowingDefault: Bool {
        settings.systemSoundsFollowsDefault
    }

    /// Sets whether system sounds should follow the macOS default output device
    func setSystemSoundsFollowDefault(_ follows: Bool) {
        settings.systemSoundsFollowsDefault = follows
        scheduleSave()
    }

    func getMute(for identifier: String) -> Bool? {
        settings.appMutes[identifier]
    }

    func setMute(for identifier: String, to muted: Bool) {
        settings.appMutes[identifier] = muted
        scheduleSave()
    }

    func getEQSettings(for appIdentifier: String) -> EQSettings {
        return settings.appEQSettings[appIdentifier] ?? EQSettings.flat
    }

    func setEQSettings(_ eqSettings: EQSettings, for appIdentifier: String) {
        // Persist only finite, supported values. A single NaN in a Float makes
        // JSONEncoder reject the entire settings document.
        settings.appEQSettings[appIdentifier] = EQSettings(
            bandGains: eqSettings.clampedGains,
            isEnabled: eqSettings.isEnabled
        )
        scheduleSave()
    }

    // MARK: - Per-App Stereo Field

    func getStereoFieldSettings(for appIdentifier: String) -> StereoFieldSettings {
        settings.appStereoFieldSettings[appIdentifier] ?? .centered
    }

    func setStereoFieldSettings(_ stereoFieldSettings: StereoFieldSettings, for appIdentifier: String) {
        settings.appStereoFieldSettings[appIdentifier] = stereoFieldSettings.normalized
        scheduleSave()
    }

    // MARK: - Device Selection Mode

    func getDeviceSelectionMode(for identifier: String) -> DeviceSelectionMode? {
        settings.appDeviceSelectionMode[identifier]
    }

    func setDeviceSelectionMode(for identifier: String, to mode: DeviceSelectionMode) {
        settings.appDeviceSelectionMode[identifier] = mode
        scheduleSave()
    }

    // MARK: - Selected Device UIDs (Multi Mode)

    func getSelectedDeviceUIDs(for identifier: String) -> Set<String>? {
        guard let uids = settings.appSelectedDeviceUIDs[identifier] else { return nil }
        return Set(uids)
    }

    func setSelectedDeviceUIDs(for identifier: String, to uids: Set<String>) {
        settings.appSelectedDeviceUIDs[identifier] = Array(uids)
        scheduleSave()
    }

    // MARK: - Input Device Lock

    var lockedInputDeviceUID: String? {
        settings.lockedInputDeviceUID
    }

    func setLockedInputDeviceUID(_ uid: String?) {
        settings.lockedInputDeviceUID = uid
        scheduleSave()
    }

    var preferredInputDeviceUID: String? {
        settings.preferredInputDeviceUID
    }

    func setPreferredInputDeviceUID(_ uid: String?) {
        settings.preferredInputDeviceUID = uid
        scheduleSave()
    }

    // MARK: - Pinned Apps

    func pinApp(_ identifier: String, info: PinnedAppInfo) {
        settings.pinnedApps.insert(identifier)
        settings.pinnedAppInfo[identifier] = info
        scheduleSave()
    }

    func unpinApp(_ identifier: String) {
        settings.pinnedApps.remove(identifier)
        settings.pinnedAppInfo.removeValue(forKey: identifier)
        scheduleSave()
    }

    func isPinned(_ identifier: String) -> Bool {
        settings.pinnedApps.contains(identifier)
    }

    /// Returns metadata for all pinned apps
    func getPinnedAppInfo() -> [PinnedAppInfo] {
        settings.pinnedApps.compactMap { settings.pinnedAppInfo[$0] }
    }

    // MARK: - Ignored Apps

    func ignoreApp(_ identifier: String, info: IgnoredAppInfo) {
        settings.ignoredApps.insert(identifier)
        settings.ignoredAppInfo[identifier] = info
        // Hiding is mutually exclusive with pinning
        settings.pinnedApps.remove(identifier)
        settings.pinnedAppInfo.removeValue(forKey: identifier)
        // Hiding is a presentation choice, not a reset operation. Keep the mixer
        // profile so an app returns exactly as configured if it is later unhidden.
        scheduleSave()
    }

    func unignoreApp(_ identifier: String) {
        settings.ignoredApps.remove(identifier)
        settings.ignoredAppInfo.removeValue(forKey: identifier)
        scheduleSave()
    }

    func isIgnored(_ identifier: String) -> Bool {
        settings.ignoredApps.contains(identifier)
    }

    func getIgnoredAppInfo() -> [IgnoredAppInfo] {
        settings.ignoredApps.compactMap { settings.ignoredAppInfo[$0] }
    }

    // MARK: - DDC Monitor Volume

    func getDDCVolume(for deviceUID: String) -> Int? {
        settings.ddcVolumes[deviceUID]
    }

    func setDDCVolume(for deviceUID: String, to volume: Int) {
        settings.ddcVolumes[deviceUID] = volume
        scheduleSave()
    }

    func getDDCMuteState(for deviceUID: String) -> Bool {
        settings.ddcMuteStates[deviceUID] ?? false
    }

    func setDDCMuteState(for deviceUID: String, to muted: Bool) {
        settings.ddcMuteStates[deviceUID] = muted
        scheduleSave()
    }

    func getDDCSavedVolume(for deviceUID: String) -> Int? {
        settings.ddcSavedVolumes[deviceUID]
    }

    func setDDCSavedVolume(for deviceUID: String, to volume: Int) {
        settings.ddcSavedVolumes[deviceUID] = volume
        scheduleSave()
    }

    // MARK: - Software Output Device Volume

    func getSoftwareDeviceVolume(for deviceUID: String) -> Float? {
        settings.softwareDeviceVolumes[deviceUID]
    }

    func setSoftwareDeviceVolume(for deviceUID: String, to volume: Float) {
        settings.softwareDeviceVolumes[deviceUID] = normalizedDeviceVolume(volume)
        scheduleSave()
    }

    func getSoftwareDeviceMuteState(for deviceUID: String) -> Bool {
        settings.softwareDeviceMuteStates[deviceUID] ?? false
    }

    func setSoftwareDeviceMuteState(for deviceUID: String, to muted: Bool) {
        settings.softwareDeviceMuteStates[deviceUID] = muted
        scheduleSave()
    }

    func getSoftwareDeviceSavedVolume(for deviceUID: String) -> Float? {
        settings.softwareDeviceSavedVolumes[deviceUID]
    }

    func setSoftwareDeviceSavedVolume(for deviceUID: String, to volume: Float) {
        settings.softwareDeviceSavedVolumes[deviceUID] = normalizedDeviceVolume(volume)
        scheduleSave()
    }

    // MARK: - Per-Device Volume Tier Override

    /// Returns the user-set override tier for a device, or nil when
    /// auto-detection should take effect.
    func getDeviceVolumeTierOverride(for deviceUID: String) -> VolumeControlTier? {
        settings.deviceVolumeTierOverride[deviceUID]
    }

    /// Sets or clears the volume tier override for a device. Passing `nil` removes
    /// the override, returning the device to auto-detection.
    func setDeviceVolumeTierOverride(for deviceUID: String, to tier: VolumeControlTier?) {
        if let tier {
            settings.deviceVolumeTierOverride[deviceUID] = tier
        } else {
            settings.deviceVolumeTierOverride.removeValue(forKey: deviceUID)
        }
        scheduleSave()
    }

    // MARK: - Per-Device Icon Override

    /// Returns the user-chosen SF Symbol override for a device, or nil when
    /// the automatic icon should take effect.
    func getDeviceIconOverride(for deviceUID: String) -> String? {
        settings.deviceIconOverrides[deviceUID]
    }

    /// All UID → symbol overrides, for views that render many devices.
    var deviceIconOverrides: [String: String] {
        settings.deviceIconOverrides
    }

    /// Sets or clears the icon override for a device. Passing `nil` removes
    /// the override, returning the device to its automatic icon.
    func setDeviceIconOverride(for deviceUID: String, to symbol: String?) {
        if let symbol {
            settings.deviceIconOverrides[deviceUID] = symbol
        } else {
            settings.deviceIconOverrides.removeValue(forKey: deviceUID)
        }
        scheduleSave()
    }

    // MARK: - Device Priority

    var devicePriorityOrder: [String] {
        settings.outputDevicePriority
    }

    func setDevicePriorityOrder(_ uids: [String]) {
        settings.outputDevicePriority = uids
        scheduleSave()
    }

    func ensureDeviceInPriority(_ uid: String) {
        guard !settings.outputDevicePriority.contains(uid) else { return }
        settings.outputDevicePriority.append(uid)
        scheduleSave()
    }

    var inputDevicePriorityOrder: [String] {
        settings.inputDevicePriority
    }

    func setInputDevicePriorityOrder(_ uids: [String]) {
        settings.inputDevicePriority = uids
        scheduleSave()
    }

    func ensureInputDeviceInPriority(_ uid: String) {
        guard !settings.inputDevicePriority.contains(uid) else { return }
        settings.inputDevicePriority.append(uid)
        scheduleSave()
    }

    // MARK: - Hidden Devices

    /// Hides an output device from the main view. Has no effect when the device is the current default.
    func hideOutputDevice(uid: String) {
        settings.hiddenOutputDeviceUIDs.insert(uid)
        scheduleSave()
    }

    /// Reveals a previously hidden output device in the main view.
    func unhideOutputDevice(uid: String) {
        settings.hiddenOutputDeviceUIDs.remove(uid)
        scheduleSave()
    }

    /// Returns true if the output device is hidden from the main view.
    func isOutputDeviceHidden(_ uid: String) -> Bool {
        settings.hiddenOutputDeviceUIDs.contains(uid)
    }

    /// All UIDs of hidden output devices.
    var hiddenOutputDeviceUIDs: Set<String> {
        settings.hiddenOutputDeviceUIDs
    }

    /// Flips the hidden state of an output device based on the persisted set.
    /// Prefer this over read-then-hide/unhide from the view layer, which can
    /// desync under rapid taps that re-read stale captured state.
    func toggleOutputDeviceHidden(uid: String) {
        if settings.hiddenOutputDeviceUIDs.contains(uid) {
            settings.hiddenOutputDeviceUIDs.remove(uid)
        } else {
            settings.hiddenOutputDeviceUIDs.insert(uid)
        }
        scheduleSave()
    }

    /// Hides an input device from the main view. Has no effect when the device is the current default.
    func hideInputDevice(uid: String) {
        settings.hiddenInputDeviceUIDs.insert(uid)
        scheduleSave()
    }

    /// Reveals a previously hidden input device in the main view.
    func unhideInputDevice(uid: String) {
        settings.hiddenInputDeviceUIDs.remove(uid)
        scheduleSave()
    }

    /// Returns true if the input device is hidden from the main view.
    func isInputDeviceHidden(_ uid: String) -> Bool {
        settings.hiddenInputDeviceUIDs.contains(uid)
    }

    /// All UIDs of hidden input devices.
    var hiddenInputDeviceUIDs: Set<String> {
        settings.hiddenInputDeviceUIDs
    }

    /// Flips the hidden state of an input device based on the persisted set.
    func toggleInputDeviceHidden(uid: String) {
        if settings.hiddenInputDeviceUIDs.contains(uid) {
            settings.hiddenInputDeviceUIDs.remove(uid)
        } else {
            settings.hiddenInputDeviceUIDs.insert(uid)
        }
        scheduleSave()
    }

    /// Merges reordered connected devices into the full priority list, preserving
    /// disconnected device positions via an anchor algorithm.
    ///
    /// Each disconnected UID is anchored to the last connected UID that preceded it
    /// in `oldPriority`. When rebuilding, disconnected UIDs are inserted after their
    /// anchor (or at the start if no anchor exists).
    ///
    /// - Parameters:
    ///   - oldPriority: The full saved priority list (connected + disconnected UIDs).
    ///   - connectedOrder: The user's reordered list of currently-connected UIDs.
    /// - Returns: Merged priority list preserving disconnected positions relative to connected anchors.
    func mergeDevicePriorityOrder(oldPriority: [String], connectedOrder: [String]) {
        settings.outputDevicePriority = Self.mergePriorityOrder(oldPriority: oldPriority, connectedOrder: connectedOrder)
        scheduleSave()
    }

    /// Input device variant of `mergeDevicePriorityOrder`.
    func mergeInputDevicePriorityOrder(oldPriority: [String], connectedOrder: [String]) {
        settings.inputDevicePriority = Self.mergePriorityOrder(oldPriority: oldPriority, connectedOrder: connectedOrder)
        scheduleSave()
    }

    /// Pure function: merges reordered connected UIDs back into the full priority list.
    ///
    /// Algorithm:
    /// 1. Walk `oldPriority` and assign each disconnected UID an "anchor" — the last
    ///    connected UID that preceded it.  UIDs with no preceding connected UID use
    ///    `nil` anchor (inserted at the front).
    /// 2. Build result from `connectedOrder`, inserting disconnected groups after
    ///    their anchor.
    /// 3. Append any connected UIDs not in `oldPriority` at the end (brand new devices).
    static func mergePriorityOrder(oldPriority: [String], connectedOrder: [String]) -> [String] {
        let connectedSet = Set(connectedOrder)

        // Step 1: Build anchor map — disconnected UID → last connected UID before it (or nil)
        // Also collect ordering of disconnected UIDs per anchor to preserve relative order
        var anchoredGroups: [String?: [String]] = [:]  // anchor → [disconnected UIDs]
        var currentAnchor: String? = nil

        for uid in oldPriority {
            if connectedSet.contains(uid) {
                currentAnchor = uid
            } else {
                anchoredGroups[currentAnchor, default: []].append(uid)
            }
        }

        // Step 2: Build result — insert disconnected groups after their anchors
        var result: [String] = []

        // First, insert any disconnected UIDs anchored to nil (they were before all connected devices)
        if let prefixGroup = anchoredGroups[nil] {
            result.append(contentsOf: prefixGroup)
        }

        for uid in connectedOrder {
            result.append(uid)
            if let group = anchoredGroups[uid] {
                result.append(contentsOf: group)
            }
        }

        return result
    }

    /// Removes per-app settings for apps that are no longer active, not pinned,
    /// and have only default values. Preserves device routing (explicit user intent).
    ///
    /// - Parameter activeIdentifiers: Persistence identifiers of currently active apps.
    func pruneStaleSettings(keeping activeIdentifiers: Set<String>) {
        let allIdentifiers = Set(settings.appVolumes.keys)
            .union(settings.appBoosts.keys)
            .union(settings.appMutes.keys)
            .union(settings.appEQSettings.keys)
            .union(settings.appStereoFieldSettings.keys)
            .union(settings.appDeviceSelectionMode.keys)
            .union(settings.appSelectedDeviceUIDs.keys)

        var pruned = 0
        for identifier in allIdentifiers {
            // Keep active apps
            if activeIdentifiers.contains(identifier) { continue }
            // Keep pinned apps
            if settings.pinnedApps.contains(identifier) { continue }
            // Keep apps with explicit device routing (user intent)
            if settings.appDeviceRouting[identifier] != nil { continue }

            // Check if all remaining settings are default values
            let volume = settings.appVolumes[identifier]
            let mute = settings.appMutes[identifier]
            let eq = settings.appEQSettings[identifier]
            let stereoField = settings.appStereoFieldSettings[identifier]
            let selectionMode = settings.appDeviceSelectionMode[identifier]
            let selectedUIDs = settings.appSelectedDeviceUIDs[identifier]

            let boost = settings.appBoosts[identifier]

            let isDefaultVolume = volume == nil || volume == 1.0
            let isDefaultBoost = boost == nil || boost == BoostLevel.x1.rawValue
            let isDefaultMute = mute == nil || mute == false
            let isDefaultEQ = eq == nil || eq == .flat
            let isDefaultStereoField = stereoField == nil || stereoField == .centered
            let isDefaultSelectionMode = selectionMode == nil
            let isDefaultSelectedUIDs = selectedUIDs == nil || selectedUIDs?.isEmpty == true

            guard isDefaultVolume && isDefaultBoost && isDefaultMute && isDefaultEQ && isDefaultStereoField
                    && isDefaultSelectionMode && isDefaultSelectedUIDs else {
                continue
            }

            // All values are defaults — safe to prune
            settings.appVolumes.removeValue(forKey: identifier)
            settings.appBoosts.removeValue(forKey: identifier)
            settings.appMutes.removeValue(forKey: identifier)
            settings.appEQSettings.removeValue(forKey: identifier)
            settings.appStereoFieldSettings.removeValue(forKey: identifier)
            settings.appDeviceSelectionMode.removeValue(forKey: identifier)
            settings.appSelectedDeviceUIDs.removeValue(forKey: identifier)
            pruned += 1
        }

        if pruned > 0 {
            logger.info("Pruned \(pruned) stale app settings entries")
            scheduleSave()
        }
    }

    // MARK: - Per-Device AutoEQ

    func getAutoEQSelection(for deviceUID: String) -> AutoEQSelection? {
        settings.deviceAutoEQ[deviceUID]
    }

    func setAutoEQSelection(for deviceUID: String, to selection: AutoEQSelection?) {
        settings.deviceAutoEQ[deviceUID] = selection
        scheduleSave()
    }

    func favoriteAutoEQProfile(id: String) {
        settings.favoriteAutoEQProfiles.insert(id)
        scheduleSave()
    }

    func unfavoriteAutoEQProfile(id: String) {
        settings.favoriteAutoEQProfiles.remove(id)
        scheduleSave()
    }

    func isAutoEQFavorite(id: String) -> Bool {
        settings.favoriteAutoEQProfiles.contains(id)
    }

    var favoriteAutoEQProfileIDs: Set<String> {
        settings.favoriteAutoEQProfiles
    }

    var autoEQPreampEnabled: Bool {
        get { settings.autoEQPreampEnabled }
        set {
            settings.autoEQPreampEnabled = newValue
            scheduleSave()
        }
    }

    // MARK: - User EQ Presets

    /// Returns all user-created EQ presets, ordered by creation date (newest first).
    func getUserPresets() -> [UserEQPreset] {
        settings.userEQPresets.sorted { $0.createdAt > $1.createdAt }
    }

    /// Creates a new user EQ preset with the given name and band gains.
    /// Trims whitespace, falls back to "Untitled" for empty names,
    /// and auto-suffixes duplicates Finder-style: "Name (2)", "Name (3)", etc.
    /// Returns the created preset.
    @discardableResult
    func createUserPreset(name: String, settings eqSettings: EQSettings) -> UserEQPreset {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseName = trimmed.isEmpty ? "Untitled" : trimmed
        let finalName = uniquePresetName(baseName)
        let preset = UserEQPreset(name: finalName, settings: eqSettings)
        settings.userEQPresets.append(preset)
        scheduleSave()
        return preset
    }

    /// Renames an existing user preset. Trims whitespace; rejects empty names (no-op).
    /// Auto-suffixes if the new name collides with another preset.
    /// No-op if the preset ID is not found.
    func updateUserPreset(id: UUID, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let index = settings.userEQPresets.firstIndex(where: { $0.id == id }) else { return }
        let finalName = uniquePresetName(trimmed, excluding: id)
        settings.userEQPresets[index].name = finalName
        scheduleSave()
    }

    /// Generates a unique preset name by appending (2), (3), etc. if the name
    /// already exists among user presets. Follows Finder duplicate naming convention.
    /// - Parameters:
    ///   - name: The desired base name.
    ///   - excludeID: A preset ID to exclude from collision checks (used during rename).
    /// - Returns: A unique name, either the original or with a numeric suffix.
    private func uniquePresetName(_ name: String, excluding excludeID: UUID? = nil) -> String {
        let existingNames = Set(
            settings.userEQPresets
                .filter { $0.id != excludeID }
                .map { $0.name }
        )
        guard existingNames.contains(name) else { return name }

        var counter = 2
        while true {
            let candidate = "\(name) (\(counter))"
            if !existingNames.contains(candidate) { return candidate }
            counter += 1
        }
    }

    /// Deletes a user preset by ID. No-op if the preset ID is not found.
    func deleteUserPreset(id: UUID) {
        settings.userEQPresets.removeAll { $0.id == id }
        scheduleSave()
    }

    // MARK: - Scenes & Simple Automations

    var consumerScenes: [ConsumerScene] {
        settings.consumerScenes.sorted { $0.updatedAt > $1.updatedAt }
    }

    var consumerAutomations: [ConsumerAutomation] {
        settings.consumerAutomations
    }

    func scene(id: UUID) -> ConsumerScene? {
        settings.consumerScenes.first { $0.id == id }
    }

    @discardableResult
    func saveScene(_ scene: ConsumerScene) -> ConsumerScene {
        var saved = scene
        let trimmed = saved.name.trimmingCharacters(in: .whitespacesAndNewlines)
        saved.name = trimmed.isEmpty ? "My Scene" : trimmed
        saved.updatedAt = .now
        if let index = settings.consumerScenes.firstIndex(where: { $0.id == saved.id }) {
            settings.consumerScenes[index] = saved
        } else {
            saved.name = uniqueSceneName(saved.name)
            settings.consumerScenes.append(saved)
        }
        scheduleSave()
        return saved
    }

    func deleteScene(id: UUID) {
        settings.consumerScenes.removeAll { $0.id == id }
        settings.consumerAutomations.removeAll { $0.sceneID == id }
        scheduleSave()
    }

    func importScene(_ scene: ConsumerScene) -> ConsumerScene {
        var imported = scene
        imported.id = UUID()
        imported.createdAt = .now
        imported.updatedAt = .now
        imported.name = uniqueSceneName(imported.name)
        settings.consumerScenes.append(imported)
        scheduleSave()
        return imported
    }

    func setAutomation(_ automation: ConsumerAutomation) {
        if let index = settings.consumerAutomations.firstIndex(where: { $0.id == automation.id }) {
            settings.consumerAutomations[index] = automation
        } else {
            settings.consumerAutomations.append(automation)
        }
        scheduleSave()
    }

    func deleteAutomation(id: UUID) {
        settings.consumerAutomations.removeAll { $0.id == id }
        scheduleSave()
    }

    func makeConsumerScene(
        name: String,
        symbolName: String,
        defaultOutputDeviceUID: String?,
        systemOutputDeviceUID: String?,
        deviceVolumes: [String: Float],
        deviceMutes: [String: Bool],
        appNames: [String: String],
        audioUnitProfiles: [AudioUnitProfile]
    ) -> ConsumerScene {
        ConsumerScene(
            name: name,
            symbolName: symbolName,
            defaultOutputDeviceUID: defaultOutputDeviceUID,
            appNames: appNames,
            appVolumes: settings.appVolumes,
            appDeviceRouting: settings.appDeviceRouting,
            appMutes: settings.appMutes,
            appBoosts: settings.appBoosts,
            appEQSettings: settings.appEQSettings,
            appStereoFieldSettings: settings.appStereoFieldSettings,
            appDeviceSelectionMode: settings.appDeviceSelectionMode,
            appSelectedDeviceUIDs: settings.appSelectedDeviceUIDs,
            systemSoundsFollowsDefault: settings.systemSoundsFollowsDefault,
            systemOutputDeviceUID: systemOutputDeviceUID,
            deviceVolumes: deviceVolumes,
            deviceMutes: deviceMutes,
            deviceAutoEQ: settings.deviceAutoEQ,
            autoEQPreampEnabled: settings.autoEQPreampEnabled,
            globalAudio: ConsumerGlobalAudioSnapshot(
                loudnessCompensationEnabled: settings.appSettings.loudnessCompensationEnabled,
                loudnessEqualizationEnabled: settings.appSettings.loudnessEqualizationEnabled,
                adaptiveAudio: settings.appSettings.adaptiveAudio,
                privacyFriendlyProcessingEnabled: settings.appSettings.privacyFriendlyProcessingEnabled
            ),
            audioUnitProfiles: audioUnitProfiles
        )
    }

    func replaceConsumerAudioSettings(with scene: ConsumerScene) {
        settings.appVolumes = scene.appVolumes
        settings.appDeviceRouting = scene.appDeviceRouting
        settings.appMutes = scene.appMutes
        settings.appBoosts = scene.appBoosts
        settings.appEQSettings = scene.appEQSettings
        settings.appStereoFieldSettings = scene.appStereoFieldSettings
        settings.appDeviceSelectionMode = scene.appDeviceSelectionMode
        settings.appSelectedDeviceUIDs = scene.appSelectedDeviceUIDs
        settings.systemSoundsFollowsDefault = scene.systemSoundsFollowsDefault
        settings.deviceAutoEQ = scene.deviceAutoEQ
        settings.autoEQPreampEnabled = scene.autoEQPreampEnabled

        settings.appSettings.loudnessCompensationEnabled = scene.globalAudio.loudnessCompensationEnabled
        settings.appSettings.loudnessEqualizationEnabled = scene.globalAudio.loudnessEqualizationEnabled
        settings.appSettings.adaptiveAudio = scene.globalAudio.adaptiveAudio
        settings.appSettings.privacyFriendlyProcessingEnabled = scene.globalAudio.privacyFriendlyProcessingEnabled
        scheduleSave()
    }

    private func uniqueSceneName(_ requested: String) -> String {
        let trimmed = requested.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? "My Scene" : trimmed
        let existing = Set(settings.consumerScenes.map(\.name))
        guard existing.contains(base) else { return base }
        var counter = 2
        while existing.contains("\(base) (\(counter))") { counter += 1 }
        return "\(base) (\(counter))"
    }

    // MARK: - App-Wide Settings

    var appSettings: AppSettings {
        get { settings.appSettings }
        set { updateAppSettings(newValue) }
    }

    func updateAppSettings(_ newSettings: AppSettings) {
        // Handle launch at login separately via ServiceManagement
        if newSettings.launchAtLogin != settings.appSettings.launchAtLogin {
            setLaunchAtLogin(newSettings.launchAtLogin)
        }
        settings.appSettings = newSettings
        scheduleSave()
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
                logger.info("Registered for launch at login")
            } else {
                try SMAppService.mainApp.unregister()
                logger.info("Unregistered from launch at login")
            }
        } catch {
            logger.error("Failed to set launch at login: \(error.localizedDescription)")
        }
    }

    /// Returns the actual launch at login status from the system
    var isLaunchAtLoginEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    // MARK: - Diagnostics and Full Erase

    func makeDiagnosticsSnapshot() -> MeloDiagnosticsSnapshot {
        MeloDiagnosticsSnapshot(
            generatedAt: Date(),
            launchAtLogin: settings.appSettings.launchAtLogin,
            showInDock: settings.appSettings.showInDock,
            quietAppBehavior: settings.appSettings.quietMoveDelay.title,
            menuBarStyle: settings.appSettings.menuBarIconStyle.rawValue,
            popupSize: settings.appSettings.popupSize.rawValue,
            profileCount: Set(
                Array(settings.appVolumes.keys)
                    + Array(settings.appMutes.keys)
                    + Array(settings.appDeviceRouting.keys)
                    + Array(settings.appEQSettings.keys)
            ).count,
            sceneCount: settings.consumerScenes.count,
            automationCount: settings.consumerAutomations.count,
            userPresetCount: settings.userEQPresets.count,
            outputDevicePreferenceCount: settings.outputDevicePriority.count,
            inputDevicePreferenceCount: settings.inputDevicePriority.count
        )
    }

    /// Prevents termination-time persistence from recreating settings after the
    /// reset helper has been scheduled. The helper removes all user data only
    /// after the current process exits.
    func prepareForFullErase() {
        persistenceDisabledForErase = true
        saveTask?.cancel()
        saveTask = nil
    }

    // MARK: - Reset All Settings

    /// Resets all per-app settings and app-wide settings to defaults
    func resetAllSettings() {
        settings.appVolumes.removeAll()
        settings.appBoosts.removeAll()
        settings.appDeviceRouting.removeAll()
        settings.appMutes.removeAll()
        settings.appEQSettings.removeAll()
        settings.appStereoFieldSettings.removeAll()
        settings.pinnedApps.removeAll()
        settings.pinnedAppInfo.removeAll()
        settings.ignoredApps.removeAll()
        settings.ignoredAppInfo.removeAll()
        settings.appSettings = AppSettings()
        settings.systemSoundsFollowsDefault = true
        settings.lockedInputDeviceUID = nil
        settings.preferredInputDeviceUID = nil
        settings.ddcVolumes.removeAll()
        settings.ddcMuteStates.removeAll()
        settings.ddcSavedVolumes.removeAll()
        settings.softwareDeviceVolumes.removeAll()
        settings.softwareDeviceMuteStates.removeAll()
        settings.softwareDeviceSavedVolumes.removeAll()
        settings.deviceVolumeTierOverride.removeAll()
        settings.deviceIconOverrides.removeAll()
        settings.outputDevicePriority.removeAll()
        settings.inputDevicePriority.removeAll()
        settings.hiddenOutputDeviceUIDs.removeAll()
        settings.hiddenInputDeviceUIDs.removeAll()
        settings.autoEQPreampEnabled = true
        settings.deviceAutoEQ.removeAll()
        settings.favoriteAutoEQProfiles.removeAll()
        settings.appDeviceSelectionMode.removeAll()
        settings.appSelectedDeviceUIDs.removeAll()
        settings.userEQPresets.removeAll()
        settings.consumerScenes.removeAll()
        settings.consumerAutomations.removeAll()

        // Also unregister from launch at login
        try? SMAppService.mainApp.unregister()

        scheduleSave()
        logger.info("Reset all settings to defaults")
    }

    // MARK: - User Backup & Restore

    /// Writes a complete, portable copy of the user's Melo settings.
    func exportSettings(to url: URL) throws {
        let backup = PortableSettingsBackup(
            format: PortableSettingsBackup.currentFormat,
            formatVersion: PortableSettingsBackup.currentVersion,
            exportedAt: Date(),
            settings: settings
        )
        let data = try JSONEncoder.meloPretty.encode(backup)
        try Self.writeData(data, to: url)
    }

    /// Replaces the current settings with a validated backup file.
    /// Runtime audio state is refreshed by the caller after this returns.
    func importSettings(from url: URL) throws {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        var imported: Settings

        if let backup = try? decoder.decode(PortableSettingsBackup.self, from: data) {
            guard backup.format == PortableSettingsBackup.currentFormat else {
                throw SettingsBackupError.wrongFormat
            }
            guard backup.formatVersion <= PortableSettingsBackup.currentVersion else {
                throw SettingsBackupError.newerFormat(backup.formatVersion)
            }
            imported = backup.settings
        } else {
            // Backward compatibility for the raw settings JSON exported by Melo 2.4.
            imported = try decoder.decode(Settings.self, from: data)
        }

        imported.version = max(imported.version, 17)
        if imported.appSettings.launchAtLogin != settings.appSettings.launchAtLogin {
            setLaunchAtLogin(imported.appSettings.launchAtLogin)
        }
        settings = imported
        flushSync()
    }

    /// Rolling known-good copy of `settings.json`, refreshed after every
    /// successful load. Same schema and key names as the live file — it is a
    /// byte copy, not a second format.
    private var backupURL: URL {
        settingsURL.deletingPathExtension().appendingPathExtension("backup.json")
    }

    /// The unreadable file is preserved here for diagnosis. Previously the
    /// corrupted bytes were written to `settings.backup.json`, which meant the
    /// only file named "backup" was the one guaranteed not to load.
    private var quarantineURL: URL {
        settingsURL.deletingPathExtension().appendingPathExtension("corrupt.json")
    }

    private func loadFromDisk() {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else {
            // A settings file that vanished (an interrupted atomic write, an
            // over-eager cleaner) is not a fresh install if a backup survives.
            if restoreFromBackup() {
                recovery = .restoredFromBackup
                logger.warning("settings.json missing; restored from backup")
            }
            return
        }

        do {
            let data = try Data(contentsOf: settingsURL)
            settings = try Self.decodeSettings(from: data)
            recovery = .normal

            logger.debug("Loaded settings with \(self.settings.appVolumes.count) volumes, \(self.settings.appDeviceRouting.count) device routings, \(self.settings.appMutes.count) mutes, \(self.settings.appEQSettings.count) EQ settings")

            // Refresh the known-good copy only after the bytes have proven
            // themselves decodable, so a corrupt file can never become the
            // backup it would later be restored from.
            let url = backupURL
            ioQueue.async {
                try? Self.writeData(data, to: url)
            }
        } catch {
            logger.error("Failed to load settings: \(error.localizedDescription)")
            let quarantine = quarantineURL
            try? FileManager.default.removeItem(at: quarantine)
            try? FileManager.default.copyItem(at: settingsURL, to: quarantine)
            logger.warning("Quarantined unreadable settings as \(quarantine.lastPathComponent)")

            // Resetting straight to defaults silently discarded every app
            // volume, EQ curve and user preset with nothing shown to the user.
            // Prefer the last file that is known to decode.
            if restoreFromBackup() {
                recovery = .restoredFromBackup
                logger.warning("Restored settings from \(self.backupURL.lastPathComponent)")
            } else {
                settings = Settings()
                recovery = .resetToDefaults
                logger.error("No usable backup; settings reset to defaults")
            }
        }
    }

    /// - Returns: `true` when `settings` was replaced from the backup file.
    private func restoreFromBackup() -> Bool {
        guard FileManager.default.fileExists(atPath: backupURL.path),
              let data = try? Data(contentsOf: backupURL),
              let restored = try? Self.decodeSettings(from: data) else { return false }
        settings = restored
        return true
    }

    /// Decode plus the legacy-key migrations, shared by the primary file and
    /// the backup so a restored file gets identical treatment.
    private nonisolated static func decodeSettings(from data: Data) throws -> Settings {
        let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let appSettingsObject = root?["appSettings"] as? [String: Any]
        let hadOnboardingKey = appSettingsObject?["onboardingVersionCompleted"] != nil
        let hadGuidedTourKey = appSettingsObject?["guidedTourVersionCompleted"] != nil
        let hadQuietMoveKey = appSettingsObject?["quietMoveDelay"] != nil
        let hadBluetoothKey = appSettingsObject?["bluetoothFeaturesEnabled"] != nil

        var decoded = try JSONDecoder().decode(Settings.self, from: data)
        decoded.version = max(decoded.version, 17)

        // An existing settings file proves the app was already in use. Older
        // releases did not store onboarding/tour completion, so mark those
        // experiences complete instead of replaying them after an update.
        // Stamping the *current* version here also opts that cohort out of the
        // version-bump replay. Installs that do carry the key sit below the
        // current version and get the added pages once.
        //
        // Bluetooth stays *available* for this cohort, which is not the same as
        // Melo touching it: nothing reaches IOBluetooth until the user asks for
        // something Bluetooth does, so `true` here costs a pre-existing install
        // no prompt it would not otherwise get. Defaulting them to `false`
        // instead would silently take away a feature they already had.
        if !hadBluetoothKey {
            decoded.appSettings.bluetoothFeaturesEnabled = true
        }
        if !hadOnboardingKey {
            decoded.appSettings.onboardingVersionCompleted = MeloExperienceVersion.onboarding
        }
        if !hadGuidedTourKey {
            decoded.appSettings.guidedTourVersionCompleted = MeloExperienceVersion.guidedTour
            decoded.appSettings.guidedTourPending = false
        }
        if !hadQuietMoveKey {
            decoded.appSettings.quietMoveDelay = .never
        }
        return decoded
    }

    private func scheduleSave() {
        guard !persistenceDisabledForErase else { return }
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            let snapshot = settings
            let url = settingsURL
            // The encode itself moved off the main actor. Every debounced
            // mutation — a single app's volume, one EQ band — re-serialised the
            // entire blob (all app volumes, EQ curves, user presets, generated
            // themes) on the MainActor, which is a visible hitch while dragging
            // a slider on a large configuration. Only the immutable snapshot
            // crosses to the writer queue, which is already serialized so
            // ordering is preserved.
            ioQueue.async {
                guard let data = try? JSONEncoder().encode(snapshot) else { return }
                do {
                    try Self.writeData(data, to: url)
                } catch {
                    // Avoid actor hops/logging from the IO queue; failures are
                    // non-fatal and retry on the next settings mutation.
                }
            }
        }
    }

    /// Immediately writes pending changes to disk.
    /// Call this on app termination to prevent data loss.
    func flushSync() {
        guard !persistenceDisabledForErase else { return }
        saveTask?.cancel()
        saveTask = nil
        writeToDisk()
    }

    private func writeToDisk() {
        guard !persistenceDisabledForErase else { return }
        do {
            let data = try JSONEncoder().encode(settings)
            let url = settingsURL
            let result: Result<Void, Error> = ioQueue.sync {
                Result { try Self.writeData(data, to: url) }
            }
            try result.get()

            logger.debug("Saved settings")
        } catch {
            logger.error("Failed to save settings: \(error.localizedDescription)")
        }
    }

    private nonisolated static func writeData(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    private func normalizedDeviceVolume(_ volume: Float) -> Float {
        guard volume.isFinite else { return 1.0 }
        return max(0.0, min(1.0, volume))
    }

    private func normalizedAppVolume(_ volume: Float) -> Float {
        guard volume.isFinite else { return 1.0 }
        return max(0.0, min(1.0, volume))
    }
}

private extension JSONEncoder {
    static var meloPretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
