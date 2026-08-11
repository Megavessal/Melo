// Melo/Audio/Engine/AudioUnitHost.swift
// Audio Unit hosting additions for Melo, based on the GPL-3.0 FineTune codebase.

import AudioToolbox
import AVFAudio
import Foundation
import Observation

/// A Codable form of `AudioComponentDescription` suitable for long-term preferences.
///
/// Audio Unit names are user-facing and may change. The type, subtype, and manufacturer
/// tuple is the stable identity used to find the component again on a later launch.
struct AudioComponentKey: Codable, Hashable, Identifiable, Sendable {
    var componentType: UInt32
    var componentSubType: UInt32
    var componentManufacturer: UInt32
    var componentFlags: UInt32
    var componentFlagsMask: UInt32

    init(_ description: AudioComponentDescription) {
        componentType = description.componentType
        componentSubType = description.componentSubType
        componentManufacturer = description.componentManufacturer
        componentFlags = description.componentFlags
        componentFlagsMask = description.componentFlagsMask
    }

    var id: String {
        [componentType, componentSubType, componentManufacturer, componentFlags, componentFlagsMask]
            .map(String.init)
            .joined(separator: ":")
    }

    var audioComponentDescription: AudioComponentDescription {
        AudioComponentDescription(
            componentType: componentType,
            componentSubType: componentSubType,
            componentManufacturer: componentManufacturer,
            componentFlags: componentFlags,
            componentFlagsMask: componentFlagsMask
        )
    }

    var compactName: String {
        "\(Self.fourCC(componentManufacturer)) · \(Self.fourCC(componentSubType))"
    }

    private static func fourCC(_ value: UInt32) -> String {
        let bytes: [UInt8] = [24, 16, 8, 0].map { shift in
            let byte = UInt8(truncatingIfNeeded: value >> UInt32(shift))
            return (32...126).contains(byte) ? byte : 63
        }
        return String(bytes: bytes, encoding: .ascii) ?? "????"
    }
}

struct AudioUnitCatalogItem: Identifiable, Hashable, Sendable {
    let component: AudioComponentKey
    let name: String
    let manufacturerName: String
    let typeName: String
    let version: Int

    var id: String { component.id }
}

/// A plug-in-agnostic fallback for Audio Units that do not vend
/// `fullStateForDocument`. Addresses are the primary identity; the parameter
/// identifier lets Melo recover when a plug-in revision moves an address.
struct AudioUnitParameterSnapshot: Codable, Hashable, Sendable {
    let address: UInt64
    let identifier: String
    let value: Float
}

/// One persisted position in an app's Audio Unit chain.
struct AudioUnitSlot: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    let component: AudioComponentKey
    var name: String
    var manufacturerName: String
    var isEnabled: Bool
    var isBypassed: Bool
    var fullStateData: Data?
    var parameterSnapshots: [AudioUnitParameterSnapshot]?

    init(component: AudioComponentKey, name: String, manufacturerName: String) {
        id = UUID()
        self.component = component
        self.name = name
        self.manufacturerName = manufacturerName
        isEnabled = true
        isBypassed = false
        fullStateData = nil
        parameterSnapshots = nil
    }
}

/// Ordered Audio Unit settings for one Melo audio source.
///
/// `id` is the same stable persistence identifier Melo uses for the app (normally its bundle ID,
/// with Melo's executable fallback for unbundled processes).
struct AudioUnitProfile: Codable, Identifiable, Hashable, Sendable {
    let id: String
    var displayName: String
    var slots: [AudioUnitSlot]
}

/// A configured instance waiting to be moved into a realtime render chain.
struct AudioUnitRuntimeUnit: @unchecked Sendable {
    let slotID: UUID
    let audioUnit: AVAudioUnit
}

/// The format a tap exposes to its per-app and system/master Audio Unit chains.
struct AudioUnitRenderConfiguration: Equatable, Sendable {
    let sampleRate: Double
    let maximumFrames: UInt32
}

enum AudioUnitProcessingScope: String, Hashable, Sendable {
    case app
    case system
}

/// Two independent instances of the same persisted chain. Primary and secondary HAL IOProcs can
/// run concurrently during a route crossfade, so sharing even a nominally stateless plug-in is
/// forbidden.
struct AudioUnitRuntimePair: @unchecked Sendable {
    let primary: StereoAudioUnitEffectChain
    let secondary: StereoAudioUnitEffectChain

    func isCompatible(with configuration: AudioUnitRenderConfiguration) -> Bool {
        primary.isCompatible(with: configuration) && secondary.isCompatible(with: configuration)
    }
}

enum AudioUnitHostError: LocalizedError {
    case missingSlot
    case instantiationFailed(String)
    case invalidStoredState

    var errorDescription: String? {
        switch self {
        case .missingSlot:
            return "The Audio Unit slot no longer exists."
        case let .instantiationFailed(message):
            return message
        case .invalidStoredState:
            return "The saved Audio Unit state could not be read."
        }
    }
}

/// AVFAudio has not annotated `AVAudioUnit` as `Sendable`, although its asynchronous factory
/// transfers the newly-created, otherwise-unreferenced instance to its completion handler.
private struct InstantiatedAudioUnit: @unchecked Sendable {
    let value: AVAudioUnit
}

/// Main-actor owner for Audio Unit discovery, preferences, editors, and offline chain creation.
/// Realtime rendering itself lives in `StereoAudioUnitEffectChain` and never calls this object.
@Observable
@MainActor
final class AudioUnitHost {
    static let systemProfileID = "dev.melo.system-audio"

    private(set) var catalog: [AudioUnitCatalogItem] = []
    private(set) var profiles: [String: AudioUnitProfile] = [:]
    private(set) var runtimeRevision = 0
    var lastError: String?
    private(set) var isScanning = false

    private struct PersistedProfiles: Codable {
        var profiles: [AudioUnitProfile]
    }

    @ObservationIgnored private let defaultsKey = "melo.audio-unit-profiles.v1"
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var editorUnits: [UUID: AVAudioUnit] = [:]
    @ObservationIgnored var onProfileRuntimeChanged: ((String) -> Void)?

    init(defaults: UserDefaults = .standard, scanCatalog: Bool = true) {
        self.defaults = defaults
        restoreProfiles()
        ensureProfile(id: Self.systemProfileID, displayName: "All Captured Apps")
        if scanCatalog {
            refreshCatalog()
        }
    }

    /// Ensures a profile exists for a running or remembered app without disturbing its chain.
    func ensureProfile(id: String, displayName: String) {
        if var existing = profiles[id] {
            guard existing.displayName != displayName else { return }
            existing.displayName = displayName
            profiles[id] = existing
        } else {
            profiles[id] = AudioUnitProfile(id: id, displayName: displayName, slots: [])
        }
        persistProfiles()
    }

    /// Clears all Audio Unit preferences. Every previously-known profile is announced so live
    /// taps replace old processing with explicit empty (passthrough) runtime pairs.
    func resetProfiles() {
        var affectedProfileIDs = Set(profiles.keys)
        affectedProfileIDs.insert(Self.systemProfileID)
        editorUnits.removeAll()
        profiles = [
            Self.systemProfileID: AudioUnitProfile(
                id: Self.systemProfileID,
                displayName: "All Captured Apps",
                slots: []
            )
        ]
        runtimeRevision &+= 1
        defaults.removeObject(forKey: defaultsKey)
        persistProfiles()
        for profileID in affectedProfileIDs {
            onProfileRuntimeChanged?(profileID)
        }
    }

    /// Snapshot used by consumer Scenes. Capturing the existing Codable profile
    /// documents keeps plug-in choices and their saved state together with the rest
    /// of a Scene without exposing plug-in terminology in the Scene UI.
    func consumerSceneProfiles() -> [AudioUnitProfile] {
        profiles.values.sorted { $0.id < $1.id }
    }

    /// Replaces all saved chains when a Scene is applied. Missing plug-ins remain
    /// safely bypassed by the existing runtime builder.
    func replaceProfilesForConsumerScene(_ newProfiles: [AudioUnitProfile]) {
        let oldIDs = Set(profiles.keys)
        var replacement = Dictionary(
            newProfiles.map { ($0.id, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
        if replacement[Self.systemProfileID] == nil {
            replacement[Self.systemProfileID] = AudioUnitProfile(
                id: Self.systemProfileID,
                displayName: "All Captured Apps",
                slots: []
            )
        }
        editorUnits.removeAll()
        profiles = replacement
        runtimeRevision &+= 1
        persistProfiles()
        for profileID in oldIDs.union(replacement.keys) {
            onProfileRuntimeChanged?(profileID)
        }
    }

    func slots(for profileID: String) -> [AudioUnitSlot] {
        profiles[profileID]?.slots ?? []
    }

    func slot(id slotID: UUID) -> AudioUnitSlot? {
        profiles.values.lazy.flatMap(\.slots).first { $0.id == slotID }
    }

    /// Enumerates all installed Effect and MusicEffect components. The UI groups this list by
    /// manufacturer and searches across the component metadata.
    ///
    /// **Off the main thread, and it used to be on it.** `components(matching:)`
    /// asks the system to enumerate every Audio Unit installed on the Mac, and
    /// it was called synchronously from `init`, which is called during launch.
    /// Measured on a machine with a fairly ordinary set of plug-ins it cost
    /// **62ms of a 682ms launch freeze**; the cost is a property of how many
    /// plug-ins the user has, so a producer with a full library pays much more,
    /// and nothing about the result is needed until Settings › Audio Units is
    /// opened.
    ///
    /// *Rejected:* leaving it on the main actor and merely deferring it a
    /// run-loop turn. That moves a 62ms freeze rather than removing one, and a
    /// hitch a moment after launch is still a hitch.
    ///
    /// *Rejected:* scanning lazily on first read of `catalog`. It makes opening
    /// the Audio Units tab pay the whole cost with a spinner, when the scan can
    /// simply be finished by then.
    func refreshCatalog() {
        guard !isScanning else { return }
        isScanning = true
        Task {
            let items = await Self.scanInstalledComponents()
            self.catalog = items
            self.isScanning = false
        }
    }

    /// The enumeration itself, with nothing main-actor about it.
    ///
    /// `nonisolated` and `AudioUnitCatalogItem` is `Sendable`, so the array
    /// crosses back on its own. Nothing here touches `self`: making that
    /// structurally true is what lets the compiler agree this is safe rather
    /// than leaving it to a comment.
    private nonisolated static func scanInstalledComponents() async -> [AudioUnitCatalogItem] {
        await Task.detached(priority: .utility) {
            let manager = AVAudioUnitComponentManager.shared()
            let types = [kAudioUnitType_Effect, kAudioUnitType_MusicEffect]
            var seen = Set<AudioComponentKey>()
            var items: [AudioUnitCatalogItem] = []

            for type in types {
                let wildcard = AudioComponentDescription(
                    componentType: type,
                    componentSubType: 0,
                    componentManufacturer: 0,
                    componentFlags: 0,
                    componentFlagsMask: 0
                )
                for component in manager.components(matching: wildcard) {
                    let key = AudioComponentKey(component.audioComponentDescription)
                    guard seen.insert(key).inserted else { continue }
                    items.append(AudioUnitCatalogItem(
                        component: key,
                        name: component.name,
                        manufacturerName: component.manufacturerName,
                        typeName: component.typeName,
                        version: component.version
                    ))
                }
            }

            return items.sorted {
                let manufacturerOrder = $0.manufacturerName
                    .localizedStandardCompare($1.manufacturerName)
                if manufacturerOrder != .orderedSame {
                    return manufacturerOrder == .orderedAscending
                }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        }.value
    }

    func add(_ item: AudioUnitCatalogItem, to profileID: String) {
        ensureProfile(id: profileID, displayName: profiles[profileID]?.displayName ?? profileID)
        guard var profile = profiles[profileID] else { return }
        profile.slots.append(AudioUnitSlot(
            component: item.component,
            name: item.name,
            manufacturerName: item.manufacturerName
        ))
        profiles[profileID] = profile
        changedRuntimeStructure(for: profileID)
    }

    func remove(slotID: UUID, from profileID: String) {
        guard var profile = profiles[profileID] else { return }
        profile.slots.removeAll { $0.id == slotID }
        profiles[profileID] = profile
        editorUnits.removeValue(forKey: slotID)
        changedRuntimeStructure(for: profileID)
    }

    func move(slotID: UUID, by offset: Int, in profileID: String) {
        guard var profile = profiles[profileID],
              let source = profile.slots.firstIndex(where: { $0.id == slotID }),
              !profile.slots.isEmpty else { return }
        let destination = min(max(0, source + offset), profile.slots.count - 1)
        guard destination != source else { return }
        let slot = profile.slots.remove(at: source)
        profile.slots.insert(slot, at: destination)
        profiles[profileID] = profile
        changedRuntimeStructure(for: profileID)
    }

    func setEnabled(_ enabled: Bool, slotID: UUID, in profileID: String) {
        mutate(slotID: slotID, in: profileID) { $0.isEnabled = enabled }
        if let unit = editorUnits[slotID] {
            let bypassed = slot(id: slotID).map { !$0.isEnabled || $0.isBypassed } ?? true
            unit.auAudioUnit.shouldBypassEffect = bypassed
        }
        changedRuntimeStructure(for: profileID)
    }

    func setBypassed(_ bypassed: Bool, slotID: UUID, in profileID: String) {
        mutate(slotID: slotID, in: profileID) { $0.isBypassed = bypassed }
        editorUnits[slotID]?.auAudioUnit.shouldBypassEffect = bypassed
        changedRuntimeStructure(for: profileID)
    }

    /// Instantiates the editor copy of a slot. Runtime chains always receive fresh instances so
    /// crossfading primary and secondary IOProcs never call the same Audio Unit concurrently.
    func loadEditorUnit(for slotID: UUID) async throws -> AVAudioUnit {
        if let loaded = editorUnits[slotID] { return loaded }
        guard let slot = slot(id: slotID) else { throw AudioUnitHostError.missingSlot }
        let unit = try await instantiate(slot.component.audioComponentDescription)
        restoreState(of: slot, into: unit)
        unit.auAudioUnit.shouldBypassEffect = !slot.isEnabled || slot.isBypassed
        editorUnits[slotID] = unit
        return unit
    }

    /// Builds a fresh ordered render chain off the realtime thread. Callers must publish the
    /// returned immutable chain only while the owning IOProc is stopped or behind an RT-safe swap.
    func makeRuntime(
        for profileID: String,
        sampleRate: Double,
        maximumFrames: UInt32
    ) async throws -> StereoAudioUnitEffectChain {
        let activeSlots = slots(for: profileID).filter(\.isEnabled)
        var runtimeUnits: [AudioUnitRuntimeUnit] = []
        runtimeUnits.reserveCapacity(activeSlots.count)

        for slot in activeSlots {
            do {
                let unit = try await instantiate(slot.component.audioComponentDescription)
                restoreState(of: slot, into: unit)
                unit.auAudioUnit.shouldBypassEffect = slot.isBypassed
                runtimeUnits.append(AudioUnitRuntimeUnit(slotID: slot.id, audioUnit: unit))
            } catch {
                // One unavailable or crashing plug-in must never take the rest of the chain down.
                lastError = "\(slot.name) could not be loaded and was bypassed: \(error.localizedDescription)"
            }
        }

        return try StereoAudioUnitEffectChain(
            units: runtimeUnits,
            sampleRate: sampleRate,
            maximumFrames: maximumFrames
        )
    }

    /// Builds two unique copies for a tap's primary and route-crossfade IOProcs.
    func makeRuntimePair(
        for profileID: String,
        configuration: AudioUnitRenderConfiguration
    ) async throws -> AudioUnitRuntimePair {
        let primary = try await makeRuntime(
            for: profileID,
            sampleRate: configuration.sampleRate,
            maximumFrames: configuration.maximumFrames
        )
        let secondary = try await makeRuntime(
            for: profileID,
            sampleRate: configuration.sampleRate,
            maximumFrames: configuration.maximumFrames
        )
        return AudioUnitRuntimePair(primary: primary, secondary: secondary)
    }

    /// Persists a plug-in's document state and a generic parameter-tree fallback, then asks the
    /// engine to rebuild future runtime chains. Some otherwise-valid Audio Units return nil from
    /// `fullStateForDocument`; their writable parameters must still survive and reach live audio.
    func captureState(slotID: UUID, in profileID: String) {
        guard let unit = editorUnits[slotID] else { return }

        var fullStateData: Data?
        if let state = unit.auAudioUnit.fullStateForDocument {
            do {
                fullStateData = try PropertyListSerialization.data(
                    fromPropertyList: state,
                    format: .binary,
                    options: 0
                )
            } catch {
                lastError = "Couldn’t save \(slot(id: slotID)?.name ?? "Audio Unit") document state: \(error.localizedDescription)"
            }
        }

        let parameterSnapshots: [AudioUnitParameterSnapshot] = unit.auAudioUnit.parameterTree?.allParameters.compactMap { parameter in
            guard parameter.flags.contains(.flag_IsWritable), parameter.value.isFinite else { return nil }
            return AudioUnitParameterSnapshot(
                address: parameter.address,
                identifier: parameter.identifier,
                value: parameter.value
            )
        } ?? []

        guard fullStateData != nil || !parameterSnapshots.isEmpty else { return }
        mutate(slotID: slotID, in: profileID) {
            $0.fullStateData = fullStateData
            $0.parameterSnapshots = parameterSnapshots.isEmpty ? nil : parameterSnapshots
        }
        changedRuntimeStructure(for: profileID)
    }

    private func instantiate(_ description: AudioComponentDescription) async throws -> AVAudioUnit {
        do {
            return try await instantiate(description, options: [.loadOutOfProcess])
        } catch {
            // A small number of legacy AUv2 components cannot be bridged out of process.
            return try await instantiate(description, options: [.loadInProcess])
        }
    }

    private func instantiate(
        _ description: AudioComponentDescription,
        options: AudioComponentInstantiationOptions
    ) async throws -> AVAudioUnit {
        let instantiated: InstantiatedAudioUnit = try await withCheckedThrowingContinuation { continuation in
            AVAudioUnit.instantiate(with: description, options: options) { unit, error in
                if let unit {
                    continuation.resume(returning: InstantiatedAudioUnit(value: unit))
                } else {
                    continuation.resume(throwing: error ?? AudioUnitHostError.instantiationFailed(
                        "The selected Audio Unit could not be loaded."
                    ))
                }
            }
        }
        return instantiated.value
    }

    private func restoreState(of slot: AudioUnitSlot, into unit: AVAudioUnit) {
        if let data = slot.fullStateData {
            do {
                let value = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
                guard let dictionary = value as? [String: Any] else {
                    throw AudioUnitHostError.invalidStoredState
                }
                unit.auAudioUnit.fullStateForDocument = dictionary
            } catch {
                lastError = "\(slot.name) loaded, but its saved document state could not be restored."
            }
        }

        guard let snapshots = slot.parameterSnapshots,
              let parameters = unit.auAudioUnit.parameterTree?.allParameters,
              !parameters.isEmpty else { return }

        for snapshot in snapshots {
            guard snapshot.value.isFinite,
                  let parameter = parameters.first(where: { $0.address == snapshot.address })
                    ?? parameters.first(where: {
                        !snapshot.identifier.isEmpty && $0.identifier == snapshot.identifier
                    }),
                  parameter.flags.contains(.flag_IsWritable) else { continue }

            if parameter.minValue.isFinite,
               parameter.maxValue.isFinite,
               parameter.minValue <= parameter.maxValue {
                parameter.value = min(max(snapshot.value, parameter.minValue), parameter.maxValue)
            } else {
                parameter.value = snapshot.value
            }
        }
    }

    private func mutate(
        slotID: UUID,
        in profileID: String,
        _ body: (inout AudioUnitSlot) -> Void
    ) {
        guard var profile = profiles[profileID],
              let index = profile.slots.firstIndex(where: { $0.id == slotID }) else { return }
        body(&profile.slots[index])
        profiles[profileID] = profile
    }

    private func changedRuntimeStructure(for profileID: String) {
        runtimeRevision &+= 1
        persistProfiles()
        onProfileRuntimeChanged?(profileID)
    }

    private func restoreProfiles() {
        guard let data = defaults.data(forKey: defaultsKey),
              let saved = try? JSONDecoder().decode(PersistedProfiles.self, from: data) else { return }
        profiles = Dictionary(uniqueKeysWithValues: saved.profiles.map { ($0.id, $0) })
    }

    private func persistProfiles() {
        let saved = PersistedProfiles(profiles: profiles.values.sorted { $0.id < $1.id })
        guard let data = try? JSONEncoder().encode(saved) else { return }
        defaults.set(data, forKey: defaultsKey)
    }

    /// Forces the preferences daemon to commit the latest profile document before
    /// app termination or a Mac shutdown. Normal mutations are still persisted
    /// immediately with `set`, while this closes the final durability window.
    func flushSync() {
        _ = defaults.synchronize()
    }
}
