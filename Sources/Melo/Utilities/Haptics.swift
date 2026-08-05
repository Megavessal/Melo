// Melo/Utilities/Haptics.swift
import AppKit

/// Trackpad haptic feedback for control detents.
///
/// macOS Force Touch trackpads expose the same alignment feedback that the
/// system uses when you drag a window edge to a snap point or scrub past a
/// marker in a timeline. Audio controls have real detents — unity gain,
/// 100% before boost, flat EQ, centered stereo field — and firing a tick as
/// the value crosses one is the difference between a slider that reports a
/// number and a slider that feels like hardware.
///
/// `NSHapticFeedbackManager` is a no-op on Macs without a Force Touch
/// trackpad and respects the user's system haptics setting, so no capability
/// check is required. It must be called on the main thread.
@MainActor
enum Haptics {

    /// Whether detent feedback is enabled. Wire this to a Settings toggle if
    /// you expose one; defaults on because the system already lets users
    /// disable trackpad feedback globally.
    static var isEnabled = true

    /// Fires an alignment tick — the light, precise detent used for snapping.
    /// Use when a dragged value crosses a meaningful boundary.
    static func detent() {
        guard isEnabled else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(
            .alignment,
            performanceTime: .now
        )
    }

    /// Fires a level-change tick — slightly heavier. Use for discrete
    /// stepping (arrow-key volume, boost chevrons, segmented controls).
    static func step() {
        guard isEnabled else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(
            .levelChange,
            performanceTime: .now
        )
    }

    /// Fires a generic tick for a completed, committed action — applying a
    /// preset, confirming a route change.
    static func commit() {
        guard isEnabled else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(
            .generic,
            performanceTime: .now
        )
    }
}

// MARK: - Detent crossing

/// Tracks a continuous value and reports when it crosses one of a fixed set
/// of detents, so a haptic fires exactly once per crossing rather than on
/// every frame of a drag.
///
/// Usage inside a view:
/// ```swift
/// @State private var detents = DetentTracker(values: [0.5, 1.0])
/// ...
/// .onChange(of: value) { _, new in
///     if detents.crossed(new) { Haptics.detent() }
/// }
/// ```
struct DetentTracker {
    private let values: [Double]
    private let tolerance: Double
    private var lastValue: Double?

    /// - Parameters:
    ///   - values: Detent positions in the same units as the tracked value.
    ///   - tolerance: How close counts as "on" the detent. Keep this small
    ///     relative to the value range; too large and fast drags swallow it.
    init(values: [Double], tolerance: Double = 0.004) {
        self.values = values.sorted()
        self.tolerance = tolerance
    }

    /// Returns `true` exactly once per detent crossing.
    ///
    /// Catches both landing *on* a detent and stepping *over* it, so a fast
    /// drag that jumps from 0.48 to 0.53 still ticks at 0.5.
    mutating func crossed(_ newValue: Double) -> Bool {
        defer { lastValue = newValue }
        guard let previous = lastValue else { return false }
        guard previous != newValue else { return false }

        let lower = min(previous, newValue)
        let upper = max(previous, newValue)

        return values.contains { detent in
            let landedOn = abs(newValue - detent) <= tolerance
                && abs(previous - detent) > tolerance
            let steppedOver = lower < detent && detent < upper
            return landedOn || steppedOver
        }
    }

    /// Clears history — call when a drag begins so the first frame of a new
    /// gesture doesn't tick against a stale value.
    mutating func reset() {
        lastValue = nil
    }
}
