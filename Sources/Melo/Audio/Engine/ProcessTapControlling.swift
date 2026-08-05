/// Abstraction over process tap controllers for testability.
///
/// **Threading:** The protocol surface is `@MainActor` — AudioEngine and tests
/// interact with controllers from main. The concrete class straddles main and the
/// CoreAudio HAL I/O thread, but the audio callback never goes through this
/// protocol; it reads `nonisolated(unsafe)` atomic fields directly on the concrete
/// type via a `void *` userdata pointer.
@MainActor
protocol ProcessTapControlling: AnyObject, Sendable {
    var app: AudioApp { get }
    var volume: Float { get set }
    var isMuted: Bool { get set }
    var currentDeviceVolume: Float { get set }
    var isDeviceMuted: Bool { get set }
    var audioLevel: Float { get }
    var currentDeviceUID: String? { get }
    var currentDeviceUIDs: [String] { get }
    /// Active tap format used to build realtime Audio Unit runtimes off the HAL thread.
    var audioUnitRenderConfiguration: AudioUnitRenderConfiguration? { get }
    /// True when a route/sample-rate change invalidated one or both runtime pairs.
    var needsAudioUnitRuntimeRebuild: Bool { get }

    func activate(initial: TapInitialState) throws
    /// First-run permission path. The concrete controller moves the potentially
    /// blocking AudioDeviceStart call off the main actor so macOS can present
    /// its system-audio permission sheet without freezing Melo's onboarding.
    func activateWithoutBlockingMainThread(initial: TapInitialState) async throws
    func invalidate()
    func invalidateAsync() async
    func updateEQSettings(_ settings: EQSettings)
    func updateStereoFieldSettings(_ settings: StereoFieldSettings)
    func updateMonoAudio(enabled: Bool)
    func updateAutoEQProfile(_ profile: AutoEQProfile?)
    func setAutoEQPreampEnabled(_ enabled: Bool)
    func updateLoudnessCompensation(volume: Float, enabled: Bool)
    func updateLoudnessEqualization(_ settings: LoudnessEqualizerSettings)
    func installAudioUnitRuntimePair(_ pair: AudioUnitRuntimePair, scope: AudioUnitProcessingScope)
    func switchDevice(to newDeviceUID: String, preferredTapSourceDeviceUID: String?, sourceDeviceDead: Bool) async throws
    func updateDevices(to newDeviceUIDs: [String], preferredTapSourceDeviceUID: String?, sourceDeviceDead: Bool) async throws
    func hasRecentAudioCallback(within seconds: Double) -> Bool
    func isHealthCheckEligible(minActiveSeconds: Double) -> Bool

    var tapSourceDeviceUID: String? { get }
    func refreshTapSource(_ preferredDeviceUID: String?) async throws
    func recreateForOutputRateChange() async throws
}

extension ProcessTapControlling {
    var audioUnitRenderConfiguration: AudioUnitRenderConfiguration? { nil }
    var needsAudioUnitRuntimeRebuild: Bool { false }

    /// Convenience activation with default state. Production callers must pass an
    /// `initial:` populated from persisted settings — defaults leave the first audio
    /// callbacks running with no EQ/AutoEQ/Loudness/Stereo Field and unity volume ramp.
    func activate() throws {
        try activate(initial: TapInitialState())
    }

    func activateWithoutBlockingMainThread(initial: TapInitialState) async throws {
        try activate(initial: initial)
    }

    /// Convenience: defaults sourceDeviceDead to false.
    func switchDevice(to newDeviceUID: String, preferredTapSourceDeviceUID: String?) async throws {
        try await switchDevice(to: newDeviceUID, preferredTapSourceDeviceUID: preferredTapSourceDeviceUID, sourceDeviceDead: false)
    }

    /// Convenience: defaults sourceDeviceDead to false.
    func updateDevices(to newDeviceUIDs: [String], preferredTapSourceDeviceUID: String?) async throws {
        try await updateDevices(to: newDeviceUIDs, preferredTapSourceDeviceUID: preferredTapSourceDeviceUID, sourceDeviceDead: false)
    }

    func invalidateAsync() async {
        invalidate()
    }

    /// Default keeps lightweight test doubles source-compatible. The production
    /// controller overrides this with the lock-free DSP state update.
    func updateStereoFieldSettings(_ settings: StereoFieldSettings) {}
    func updateMonoAudio(enabled: Bool) {}

    func installAudioUnitRuntimePair(_ pair: AudioUnitRuntimePair, scope: AudioUnitProcessingScope) {}

    func refreshTapSource(_ preferredDeviceUID: String?) async throws {
        // Default no-op for mocks that don't override
    }

    func recreateForOutputRateChange() async throws {
        // Default no-op for mocks that don't override
    }
}
