// Melo/Views/MenuBar/MenuBarIconMotion.swift
// Occasional, small motion for the pixel menu bar mark while audio is playing.

import AppKit
import Observation

/// Drives the optional "react to audio" animation on the menu bar mark.
///
/// The menu bar lives in peripheral vision, which is far more motion-sensitive
/// than the centre of the screen, so every number here is chosen to stay under
/// the threshold where movement becomes something you cannot stop noticing:
///
///  - the nudge is small (one cell) and brief (350ms out and back),
///  - it fires on a randomised 6–14s gap, because a fixed interval is what turns
///    an idle animation into a tic you start anticipating,
///  - it stays still for the first 30s of playback, since the moment audio
///    starts is already competing for attention,
///  - and it does nothing at all under Reduce Motion.
@MainActor
@Observable
final class MenuBarIconMotion {
    /// The phase the icon should currently draw, 0 = at rest.
    private(set) var offsetCells: Int = 0

    @ObservationIgnored private var scheduleTimer: Timer?
    @ObservationIgnored private var frameTimer: Timer?
    @ObservationIgnored private var playbackBeganAt: Date?
    @ObservationIgnored private var isRunning = false
    @ObservationIgnored private var frameIndex = 0

    /// Tuning constants, kept together so they are easy to argue with.
    private static let settleAfterPlaybackStarts: TimeInterval = 30
    private static let gapRange: ClosedRange<TimeInterval> = 6...14
    private static let frameDuration: TimeInterval = 0.35 / 4

    /// Call whenever the "is audio being processed" answer changes.
    func setAudioActive(_ active: Bool, enabled: Bool) {
        let shouldRun = active && enabled && !Self.reduceMotionEnabled
        if active {
            if playbackBeganAt == nil { playbackBeganAt = Date() }
        } else {
            playbackBeganAt = nil
        }
        guard shouldRun != isRunning else { return }
        isRunning = shouldRun
        if shouldRun { scheduleNext() } else { stop() }
    }

    func stop() {
        scheduleTimer?.invalidate()
        scheduleTimer = nil
        frameTimer?.invalidate()
        frameTimer = nil
        if offsetCells != 0 { offsetCells = 0 }
    }

    private static var reduceMotionEnabled: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Out one cell and back: 1 → 0 → -1 → 0.
    private static let nudgeSequence = [1, 0, -1, 0]

    private func scheduleNext() {
        scheduleTimer?.invalidate()
        let gap = TimeInterval.random(in: Self.gapRange)
        // Timer fires on the main run loop, so the work is already on the main
        // actor. `assumeIsolated` states that rather than hopping through a Task,
        // which under Swift 6 would mean sending the timer and the closure's
        // captures across an isolation boundary.
        scheduleTimer = Timer.scheduledTimer(withTimeInterval: gap, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.playIfSettled()
            }
        }
    }

    private func playIfSettled() {
        guard isRunning else { return }
        guard let began = playbackBeganAt, Date().timeIntervalSince(began) >= Self.settleAfterPlaybackStarts else {
            // Too soon after playback started. Wait out another gap rather than
            // firing the moment the settle window closes, so the first nudge is
            // not itself perfectly predictable.
            scheduleNext()
            return
        }
        frameIndex = 0
        frameTimer?.invalidate()
        frameTimer = Timer.scheduledTimer(withTimeInterval: Self.frameDuration, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.advanceFrame()
            }
        }
    }

    /// Frame cursor lives on the instance rather than as a local captured by the
    /// timer closure: an escaping closure cannot mutate a local `var` across
    /// concurrency domains, and the timer itself is read from `frameTimer` so it
    /// never has to be captured either.
    private func advanceFrame() {
        guard isRunning else {
            stop()
            return
        }
        let sequence = Self.nudgeSequence
        guard frameIndex < sequence.count else {
            endNudge()
            return
        }
        offsetCells = sequence[frameIndex]
        frameIndex += 1
        if frameIndex == sequence.count {
            endNudge()
        }
    }

    private func endNudge() {
        frameTimer?.invalidate()
        frameTimer = nil
        scheduleNext()
    }
}
