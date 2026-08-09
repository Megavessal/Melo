// Melo/Audio/Engine/AppListCoordinator.swift
import Foundation

/// Owns the app-list surface that is pure `SettingsManager` persistence: pinning,
/// the persistence half of ignoring, and per-inactive-app settings. Live tap/engine
/// state (tap teardown on ignore, re-provisioning on unignore) stays in `AudioEngine`,
/// which holds this coordinator and forwards its public app-list API here.
@MainActor
final class AppListCoordinator {
    private let settingsManager: SettingsManager

    init(settingsManager: SettingsManager) {
        self.settingsManager = settingsManager
    }

    // MARK: - Pinning

    func pinApp(_ app: AudioApp) {
        pinApp(
            identifier: app.persistenceIdentifier,
            displayName: app.name,
            bundleID: app.bundleID
        )
    }

    /// Pin an app there is no live `AudioApp` for — one found by name in
    /// `InstalledAppCatalog`, before it has ever played a sound.
    ///
    /// The same write as `pinApp(_:)`, which now funnels through here: one
    /// place builds a `PinnedAppInfo`, so an app pinned from the catalogue and
    /// the same app pinned from its row cannot end up under different keys.
    /// Widening the existing path rather than adding a second one, because two
    /// writers of one setting is how the row and the saved value drift apart.
    func pinApp(identifier: String, displayName: String, bundleID: String?) {
        let info = PinnedAppInfo(
            persistenceIdentifier: identifier,
            displayName: displayName,
            bundleID: bundleID
        )
        settingsManager.pinApp(identifier, info: info)
    }

    func unpinApp(_ identifier: String) {
        settingsManager.unpinApp(identifier)
    }

    func isPinned(_ app: AudioApp) -> Bool {
        settingsManager.isPinned(app.persistenceIdentifier)
    }

    func isPinned(identifier: String) -> Bool {
        settingsManager.isPinned(identifier)
    }

    func pinnedAppInfo() -> [PinnedAppInfo] {
        settingsManager.getPinnedAppInfo()
    }

    // MARK: - Ignored Apps (persistence half; tap teardown stays in AudioEngine)

    func recordIgnore(_ app: AudioApp) {
        let info = IgnoredAppInfo(
            persistenceIdentifier: app.persistenceIdentifier,
            displayName: app.name,
            bundleID: app.bundleID
        )
        settingsManager.ignoreApp(app.persistenceIdentifier, info: info)
    }

    func clearIgnore(_ identifier: String) {
        settingsManager.unignoreApp(identifier)
    }

    func isIgnored(identifier: String) -> Bool {
        settingsManager.isIgnored(identifier)
    }

    // MARK: - Inactive App Settings (by persistence identifier)

    func getVolumeForInactive(identifier: String) -> Float {
        settingsManager.getVolume(for: identifier) ?? 1.0
    }

    func setVolumeForInactive(identifier: String, to volume: Float) {
        settingsManager.setVolume(for: identifier, to: volume)
    }

    func getBoostForInactive(identifier: String) -> BoostLevel {
        settingsManager.getBoost(for: identifier) ?? .x1
    }

    func setBoostForInactive(identifier: String, to boost: BoostLevel) {
        settingsManager.setBoost(for: identifier, to: boost)
    }

    func getMuteForInactive(identifier: String) -> Bool {
        settingsManager.getMute(for: identifier) ?? false
    }

    func setMuteForInactive(identifier: String, to muted: Bool) {
        settingsManager.setMute(for: identifier, to: muted)
    }

    func getEQSettingsForInactive(identifier: String) -> EQSettings {
        settingsManager.getEQSettings(for: identifier)
    }

    func setEQSettingsForInactive(_ settings: EQSettings, identifier: String) {
        settingsManager.setEQSettings(settings, for: identifier)
    }

    func getStereoFieldSettingsForInactive(identifier: String) -> StereoFieldSettings {
        settingsManager.getStereoFieldSettings(for: identifier)
    }

    func setStereoFieldSettingsForInactive(_ settings: StereoFieldSettings, identifier: String) {
        settingsManager.setStereoFieldSettings(settings, for: identifier)
    }

    func getDeviceRoutingForInactive(identifier: String) -> String? {
        settingsManager.getDeviceRouting(for: identifier)
    }

    func setDeviceRoutingForInactive(identifier: String, deviceUID: String?) {
        if let deviceUID = deviceUID {
            settingsManager.setDeviceRouting(for: identifier, deviceUID: deviceUID)
        } else {
            settingsManager.setFollowDefault(for: identifier)
        }
    }

    func isFollowingDefaultForInactive(identifier: String) -> Bool {
        settingsManager.isFollowingDefault(for: identifier)
    }

    func getDeviceSelectionModeForInactive(identifier: String) -> DeviceSelectionMode {
        settingsManager.getDeviceSelectionMode(for: identifier) ?? .single
    }

    func setDeviceSelectionModeForInactive(identifier: String, to mode: DeviceSelectionMode) {
        settingsManager.setDeviceSelectionMode(for: identifier, to: mode)
    }

    func getSelectedDeviceUIDsForInactive(identifier: String) -> Set<String> {
        settingsManager.getSelectedDeviceUIDs(for: identifier) ?? []
    }

    func setSelectedDeviceUIDsForInactive(identifier: String, to uids: Set<String>) {
        settingsManager.setSelectedDeviceUIDs(for: identifier, to: uids)
    }
}
