// Melo/Audio/Types/CallActivityDetector.swift
import Foundation

/// Decides whether a communication app is *on a call* rather than merely making
/// a noise.
///
/// The rule it replaces had no such distinction: one poll above -42 dBFS from
/// any app on the communication list engaged ducking, so a Slack message chime
/// dropped every other app to 20% and a flat 1.5 s hold kept it there. A chime
/// is one short burst; a call is continuous. Onset therefore needs a *run* of
/// polls at a level speech actually reaches, and only the release is lenient.
///
/// Pure and self-contained on purpose: `scripts/verify-unasked-actions.py`
/// compiles this file and runs chime-shaped and call-shaped level sequences
/// through it, which a rule living inside `CallDuckingManager` could not be.
struct CallActivityDetector {
    /// Peak a poll must reach to count toward engaging. -34 dBFS: conversational
    /// speech clears this comfortably, interface blips and idle noise do not.
    static let onsetLevel: Float = 0.02

    /// Peak that keeps an engaged duck engaged. Deliberately *below*
    /// `onsetLevel` — consonant gaps within a sentence dip far below the onset
    /// level, and re-deciding on every dip is what makes ducking pump.
    static let sustainLevel: Float = 0.008

    /// Consecutive polls above `onsetLevel` needed to engage. At the manager's
    /// 250 ms poll interval this is 750 ms of unbroken sound, longer than the
    /// message and mention chimes Slack, Discord and Teams play.
    static let onsetPolls = 3

    /// How long the level must stay below `sustainLevel` before releasing.
    /// Longer than the 1.5 s it replaces, not shorter: with false onsets
    /// filtered out, the remaining failure is releasing during an ordinary
    /// pause in conversation and immediately re-engaging.
    static let releaseMilliseconds = 4_000

    private var consecutiveLoudPolls = 0

    /// Whether this app is currently considered to be on a call.
    private(set) var isEngaged = false

    /// Feeds one poll's peak level and returns the new engaged state.
    mutating func update(peak: Float) -> Bool {
        if isEngaged {
            isEngaged = peak >= Self.sustainLevel
            if !isEngaged { consecutiveLoudPolls = 0 }
            return isEngaged
        }
        consecutiveLoudPolls = peak >= Self.onsetLevel ? consecutiveLoudPolls + 1 : 0
        isEngaged = consecutiveLoudPolls >= Self.onsetPolls
        return isEngaged
    }
}
