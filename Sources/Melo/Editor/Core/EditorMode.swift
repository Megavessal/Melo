// Melo/Editor/Core/EditorMode.swift
//
// Simple and Full, and the one list of what the difference is.
//
// `.run-notes/TIMELINE-FRAME.md` recorded a decision *against* two modes — "two
// modes means the user has to know which one they need before they know what
// they want" — and the owner has since asked for them, so it is reversed. The
// old reasoning is not discarded, it is the specification: Simple is the
// default, **nobody is ever asked**, Full is one control away, and the choice
// is remembered once made. A person who never finds the switch has exactly the
// editor the old decision wanted them to have.
//
// This lives in Core rather than in the window for the same reason
// `EditorPanel` moved down: `EditorStore` has to name the mode twice — once to
// read a stored value back, once to say what a first run opens with — and
// `scripts/verify-editor-wiring.py` compiles Core with the window layer absent,
// so Core cannot reach up to a type nested in a view.

import Foundation

/// How much of Melo Edit is drawn.
///
/// `String`-backed because the raw value is what `UserDefaults` stores. An
/// unrecognised value falls back to `.simple`, which is the safe direction:
/// the worst case of a bad read is that somebody who chose Full gets Simple
/// once and presses the switch again, where the reverse would be a first-time
/// reader handed the dense editor with no idea a simpler one exists.
enum EditorMode: String, CaseIterable, Identifiable, Sendable {
    case simple
    case full

    var id: Self { self }

    /// **The default, and it is never asked for.** The whole point of the
    /// reversal recorded above.
    static let initial: EditorMode = .simple

    /// What the switch says it will give you. A verb-free noun, because it
    /// labels a state and not an action — the control's help text carries the
    /// verb.
    var title: String {
        switch self {
        case .simple: return "Simple"
        case .full: return "Full"
        }
    }

    var other: EditorMode {
        self == .simple ? .full : .simple
    }

    /// Everything Full adds, named once.
    ///
    /// **One list, not six booleans.** Six `var showsX: Bool { self == .full }`
    /// properties would be six copies of one rule, and — worse — the Settings
    /// Guide entry, the switch's tooltip and this file would each carry their
    /// own prose about what changes. Those three drift, and the way they drift
    /// is that somebody adds a seventh thing to Full and updates two of them.
    /// The Guide entry and the tooltip are both generated from `summary`
    /// below.
    ///
    /// Ordered as a reader meets them: the pane on the right, then the track
    /// headers, then the strip along the bottom.
    enum Extra: String, CaseIterable, Identifiable, Sendable {
        /// A move's row in the Chain opens into its controls.
        case moveInspectors
        /// The master panel — the mix's own level, its meter, its moves.
        case master
        /// The pan slider on each track header.
        case trackPan
        /// The selected clip's gain, in decibels, as a number you can read.
        case clipGain
        /// The dB ladder beside the track meters.
        case meterScale
        /// The strip under the transport: the selected clip and its numbers.
        case transportRow

        var id: Self { self }

        /// One noun phrase, lower case, so the sentence below reads as a list.
        var summary: String {
            switch self {
            case .moveInspectors: return "each move’s own controls"
            case .master: return "the master panel"
            case .trackPan: return "pan on every track"
            case .clipGain: return "the selected clip’s level in decibels"
            case .meterScale: return "the decibel scale beside the meters"
            case .transportRow: return "a second row under the transport"
            }
        }
    }

    /// Whether this mode draws one of the additions.
    ///
    /// Every call site asks this rather than comparing against `.full`, so the
    /// day a third mode exists there is one function to change and not thirty
    /// equality tests spread across four directories.
    func shows(_ extra: Extra) -> Bool {
        switch self {
        case .simple: return false
        case .full: return true
        }
    }

    /// "each move’s own controls, the master panel, pan on every track, …".
    ///
    /// The tooltip and the Settings Guide entry are both built from this, which
    /// is the only reason those two can be trusted to describe the same
    /// feature.
    static var additionsSentence: String {
        Extra.allCases.map(\.summary).joined(separator: ", ")
    }
}
