// Melo/Editor/Core/EditorPanel.swift
//
// The docked panels down the right-hand side of Melo Edit, named once.
//
// This lived inside `EditorRootView` as a nested `SidebarSection` for as long
// as the pane state was the window's private business. It stopped being that
// the moment which panels are open became something the session sidecar
// remembers per document: `EditorStore` now has to name a panel twice — once to
// read a saved set back off disk, and once to decide what a document with no
// sidecar opens with — and `scripts/verify-editor-wiring.py` compiles this
// layer with the window layer absent, so Core cannot reach up to the view's
// nested type.
//
// The alternative was raw strings in Core and the enum in the window, which is
// two lists that have to agree about three cases and a spelling. That is the
// defect class this project's anchor already records, so the enum moved down
// instead. The titles come with it — they are the panel's name, and a name that
// lives apart from the thing it names drifts.

import Foundation

/// One docked panel in Melo Edit's right-hand pane.
///
/// `String`-backed because the raw value is what the sidecar stores. Renaming a
/// case therefore orphans whatever was saved under the old spelling, which is
/// survivable — an unrecognised raw value is dropped and the document opens
/// with the default set — but it is not free, so the raw values are deliberately
/// short, lowercase and unrelated to the display titles above them.
enum EditorPanel: String, CaseIterable, Identifiable, Sendable {
    case destination
    case analysis
    /// The **Chain**. `Move` is still the type name, because the panel is the
    /// Chain and the things in it are moves; you build a chain of them. The
    /// raw value stayed `stack` for exactly one release's worth of sidecars
    /// written before the rename — see `migrating(_:)`.
    case chain
    /// The mix's own strip: level, meter, and what the master chain is doing
    /// to everything at once.
    ///
    /// **Full only, and `EditorRootView` is what enforces that** — not this
    /// enum. A panel that filtered itself by mode would make `allCases` lie to
    /// `migrating(_:)`, and then somebody's saved `["master","chain"]` would be
    /// silently pruned to `["chain"]` the first time they opened a document in
    /// Simple. It stays in the set, unpainted, and comes back when they switch
    /// to Full — which is the same rule the mode follows everywhere else: it
    /// adds and removes what is *drawn*, never what is *stored*.
    case master

    var id: Self { self }

    /// What the header says. User-facing.
    var title: String {
        switch self {
        case .destination: return "Where’s it going?"
        case .analysis: return "What I found"
        case .chain: return "The Chain"
        // Not "Master Bus" and not "Output". "Master" is the word every audio
        // tool the owner has used says, including the VEGAS screenshot this
        // pass is drawn from, and it is already the field name on
        // `EditorDocument`. "Everything at once" was written and rejected —
        // Melo's voice is plain, not coy, and a person looking for the master
        // section searches for the word they know.
        case .master: return "Master"
        }
    }

    /// Which panels a document opens with when no sidecar has an opinion.
    ///
    /// A Chain that already has moves in it — a reopened session, a theme with
    /// a starter applied — is the thing to show. Otherwise the destination
    /// picker, because choosing one is the novice's first move and that panel
    /// is where "Fix it again" lives.
    ///
    /// One panel, not all three, and that is a judgement rather than an
    /// oversight. More than one *may* be open now, which is the point of the
    /// rebuild; opening with three means the panel a first-time reader is meant
    /// to answer shares the pane with two they have no use for yet.
    static func defaults(forMoveCount count: Int) -> Set<EditorPanel> {
        count > 0 ? [.chain] : [.destination]
    }

    /// Reads a saved set back, dropping anything this build does not recognise.
    ///
    /// **`"stack"` maps to `.chain`.** Every sidecar written before the rename
    /// carries that spelling, and a strict `init(rawValue:)` would drop it
    /// silently — so somebody who had the Chain open yesterday would open the
    /// same file today with the destination picker showing instead, with
    /// nothing to tell them why. Cheap to keep, and the failure it prevents is
    /// invisible.
    static func migrating(_ raw: [String]) -> Set<EditorPanel> {
        Set(raw.compactMap { value in
            value == "stack" ? .chain : EditorPanel(rawValue: value)
        })
    }
}
