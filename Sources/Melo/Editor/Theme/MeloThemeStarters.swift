// Melo/Editor/Theme/MeloThemeStarters.swift
//
// Four one-tap starts for the theme.
//
// Why these exist at all: opening ninety seconds of instrumental in an editor
// with an empty stack is not fun, it is homework. Each starter is a small pile
// of ordinary moves with real numbers in them, so pressing one produces
// something obviously different *and* leaves behind a stack the user can open,
// read, change and switch off. The stack is the tutorial; these just fill it.
//
// Rules every starter here follows:
//
// - **Positions are derived, never hardcoded.** Bar lines come from
//   `MeloThemeRemix.time(atBar:in:)`, which divides whatever duration the
//   decoder reported by 32. A wrong timestamp is worse than a proportional one.
// - **No move that needs a measurement.** `normalize` carries a measured LUFS
//   and an applied gain; nothing here has analysed the file, so nothing here
//   proposes one. That is the destinations path's job, not a starter's.
// - **Nothing is destructive.** Every one of these is a stack, and the stack
//   comes off.

import Foundation

/// A one-tap start on the theme.
///
/// An enum with a `switch` rather than a list of closures, so the set is
/// exhaustive at compile time and greppable: adding a case without giving it
/// moves is a build failure, not a starter that quietly does nothing.
enum MeloThemeStarter: String, CaseIterable, Identifiable, Sendable {
    /// Eight bars out of the middle, cut on the bar line.
    case ringtone
    /// Three-quarter speed with the top rolled off.
    case slowed
    /// Band-limited until it sounds like it is in the next room.
    case throughTheWall
    /// The whole thing, in reverse.
    case backwards

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ringtone: "Ringtone"
        case .slowed: "Slowed"
        case .throughTheWall: "Through the wall"
        case .backwards: "Backwards"
        }
    }

    /// One line. Says what you get, not how it works.
    var blurb: String {
        switch self {
        case .ringtone: "Eight bars, cut on the beat."
        case .slowed: "Three-quarter speed, low end up."
        case .throughTheWall: "Like it's playing next door."
        case .backwards: "All of it, the other way."
        }
    }

    var symbolName: String {
        switch self {
        case .ringtone: "iphone.radiowaves.left.and.right"
        case .slowed: "tortoise"
        case .throughTheWall: "door.left.hand.closed"
        case .backwards: "arrow.uturn.left"
        }
    }

    /// The moves this starter puts on the stack, resolved against a theme that
    /// is `duration` long.
    ///
    /// Returns nothing for a duration that cannot carry bar arithmetic, so a
    /// caller never lands a trim of length zero on the document.
    func moves(forThemeOfLength duration: TimeInterval) -> [Move] {
        guard duration.isFinite, duration > 0 else { return [] }
        let bar = MeloThemeRemix.barLength(in: duration)
        func time(_ line: Int) -> TimeInterval { MeloThemeRemix.time(atBar: line, in: duration) }

        switch self {

        // Bars 9–16: the second eight-bar phrase, which in a thirty-two bar
        // loop is conventionally where the arrangement is fully in. Chosen
        // structurally — nobody on this run has heard the track, and that is
        // stated rather than dressed up as taste.
        case .ringtone:
            return [
                Move(
                    kind: .trim(start: time(8), end: time(16)),
                    rationale: "Bars 9 to 16 — eight bars, about twenty seconds, which is a phone's worth."
                ),
                Move(
                    // 20 ms. Long enough to kill the click of starting mid-loop,
                    // short enough that the first kick still hits like a kick.
                    kind: .fadeIn(length: 0.02, curve: .linear),
                    rationale: "Twenty milliseconds, so the cut doesn't click."
                ),
                Move(
                    kind: .fadeOut(length: bar / 2, curve: .equalPower),
                    rationale: "Half a bar out, so it ends on purpose."
                )
            ]

        // Pitch is preserved — Melo does not ship a pitch shift, on purpose —
        // so this drags rather than droops. The shelves are what make it read
        // as slowed instead of merely slow.
        case .slowed:
            return [
                Move(
                    kind: .trim(start: 0, end: time(16)),
                    rationale: "The first sixteen bars, so three-quarter speed doesn't run to two minutes."
                ),
                Move(
                    kind: .speed(rate: 0.75),
                    rationale: "Three-quarter speed. The pitch stays put, so it drags instead of sagging."
                ),
                Move(
                    kind: .equalizer(
                        bands: [
                            AutoEQFilter(type: .lowShelf, frequency: 100, gainDB: 2.5, q: 0.7),
                            AutoEQFilter(type: .highShelf, frequency: 6000, gainDB: -4.5, q: 0.7)
                        ],
                        // Headroom for the low shelf, the same way Melo's own
                        // EQ takes it back automatically.
                        preampDB: -2.5
                    ),
                    rationale: "Low shelf up, high shelf down. Open it and move either one."
                )
            ]

        // The most extreme of the four, and the one that proves the stack is
        // real: switch off any single move and the effect half-collapses.
        case .throughTheWall:
            return [
                Move(
                    kind: .gain(dB: 4),
                    rationale: "Four decibels up front, to pay for what the next two moves take away."
                ),
                Move(
                    kind: .highPass(frequency: 400),
                    rationale: "Everything under 400 Hz goes. There goes the kick."
                ),
                Move(
                    kind: .equalizer(
                        bands: [AutoEQFilter(type: .highShelf, frequency: 2500, gainDB: -14, q: 0.7)],
                        preampDB: 0
                    ),
                    rationale: "And fourteen decibels off the top. Now it's behind a door."
                ),
                Move(
                    kind: .limiter(ceilingDBTP: -1, releaseMS: 60),
                    rationale: "A ceiling at −1 dBTP, since we added four decibels on faith."
                )
            ]

        // Two moves, deliberately. This one is instantly recognisable without
        // help, and padding it with numbers nobody needs would teach the wrong
        // lesson about what belongs on a stack.
        case .backwards:
            return [
                Move(
                    kind: .reverse,
                    rationale: "Everything runs the other way. Switch it off and it's back."
                ),
                Move(
                    kind: .fadeOut(length: bar / 2, curve: .equalPower),
                    rationale: "The track's first downbeat is now the last thing you hear, so it fades rather than stops dead."
                )
            ]
        }
    }

    /// "3 moves" — shown on the tile, so nobody presses this without knowing a
    /// stack is about to appear.
    func moveCountLabel(forThemeOfLength duration: TimeInterval) -> String {
        let count = moves(forThemeOfLength: duration).count
        return count == 1 ? "1 move" : "\(count) moves"
    }
}
