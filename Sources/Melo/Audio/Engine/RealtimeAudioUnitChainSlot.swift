// Melo/Audio/Engine/RealtimeAudioUnitChainSlot.swift

import Foundation
import Synchronization

/// Single-writer, realtime-reader storage for a rendered Audio Unit chain.
///
/// The main actor owns publication. A HAL callback brackets its unretained pointer load with a
/// reader count, so replacement can retire the old +1 ownership without performing ARC, locking,
/// allocation, or destruction on the audio thread. Sequentially-consistent operations make the
/// critical ordering explicit: a reader either announces itself before an exchange and protects
/// the old pointer, or observes the newly-published pointer.
final class RealtimeAudioUnitChainSlot: @unchecked Sendable {
    private let pointer = Atomic<UnsafeRawPointer?>(nil)
    private let activeReaders = Atomic<Int>(0)

    // Main-actor writer state. Raw pointers each carry the +1 formerly owned by this slot.
    private var retiredPointers: [UnsafeRawPointer] = []
    private var retirementPollScheduled = false

    /// Acquires a borrowed, unretained chain reference for one realtime render quantum.
    /// Every call, including a nil result, must be balanced by `endRead()`.
    @inline(__always)
    nonisolated func beginRead() -> Unmanaged<StereoAudioUnitEffectChain>? {
        _ = activeReaders.wrappingAdd(1, ordering: .sequentiallyConsistent)
        guard let raw = pointer.load(ordering: .sequentiallyConsistent) else { return nil }
        return Unmanaged<StereoAudioUnitEffectChain>.fromOpaque(raw)
    }

    /// Ends a realtime read begun by `beginRead()`.
    @inline(__always)
    nonisolated func endRead() {
        _ = activeReaders.wrappingSubtract(1, ordering: .sequentiallyConsistent)
    }

    /// Returns the current value to the main-actor writer. The slot's +1 keeps it alive.
    @MainActor
    func currentValue() -> StereoAudioUnitEffectChain? {
        guard let raw = pointer.load(ordering: .sequentiallyConsistent) else { return nil }
        return Unmanaged<StereoAudioUnitEffectChain>.fromOpaque(raw).takeUnretainedValue()
    }

    @MainActor
    var hasValue: Bool {
        pointer.load(ordering: .sequentiallyConsistent) != nil
    }

    /// Atomically publishes a new chain. All ownership changes and eventual destruction happen
    /// on the main actor; an old value remains retained until no callback is inside this slot.
    @MainActor
    func replace(with chain: StereoAudioUnitEffectChain?) {
        let newPointer = chain.map {
            UnsafeRawPointer(Unmanaged.passRetained($0).toOpaque())
        }
        guard let oldPointer = pointer.exchange(
            newPointer,
            ordering: .sequentiallyConsistent
        ) else { return }

        retiredPointers.append(oldPointer)
        drainRetiredPointersWhenQuiescent()
    }

    @MainActor
    private func drainRetiredPointersWhenQuiescent() {
        guard !retiredPointers.isEmpty else {
            retirementPollScheduled = false
            return
        }

        guard activeReaders.load(ordering: .sequentiallyConsistent) == 0 else {
            scheduleRetirementPoll()
            return
        }

        retirementPollScheduled = false
        for raw in retiredPointers {
            Unmanaged<StereoAudioUnitEffectChain>.fromOpaque(raw).release()
        }
        retiredPointers.removeAll(keepingCapacity: true)
    }

    @MainActor
    private func scheduleRetirementPoll() {
        guard !retirementPollScheduled else { return }
        retirementPollScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.retirementPollScheduled = false
                self.drainRetiredPointersWhenQuiescent()
            }
        }
    }

    deinit {
        // The IOProc closure keeps its ProcessTapController alive for the callback duration, so
        // slot deinitialization cannot normally overlap a reader. Leak rather than risk a UAF if
        // that lifetime invariant is ever broken by future callback ownership changes.
        guard activeReaders.load(ordering: .sequentiallyConsistent) == 0 else { return }

        if let raw = pointer.exchange(nil, ordering: .sequentiallyConsistent) {
            Unmanaged<StereoAudioUnitEffectChain>.fromOpaque(raw).release()
        }
        for raw in retiredPointers {
            Unmanaged<StereoAudioUnitEffectChain>.fromOpaque(raw).release()
        }
    }
}
