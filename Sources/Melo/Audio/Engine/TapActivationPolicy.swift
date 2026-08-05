/// Pure decision policy for whether an app needs a Core Audio process tap.
///
/// Keeping this separate from `AudioEngine` makes the privacy behavior easy to
/// verify without constructing HAL devices in unit tests.
enum TapActivationPolicy {
    static func requiresTap(
        privacyFriendlyProcessingEnabled: Bool,
        hasGlobalProcessing: Bool,
        hasPerAppProcessing: Bool,
        hasCustomRouting: Bool,
        hasAudioUnits: Bool,
        hasDeviceProcessing: Bool
    ) -> Bool {
        guard privacyFriendlyProcessingEnabled else { return true }
        return hasGlobalProcessing
            || hasPerAppProcessing
            || hasCustomRouting
            || hasAudioUnits
            || hasDeviceProcessing
    }
}
