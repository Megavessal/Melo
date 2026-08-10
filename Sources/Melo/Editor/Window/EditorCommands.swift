import AppKit
import SwiftUI

// MARK: - Modifiers

/// The four modifiers this window binds, as a value with no AppKit in it.
///
/// `NSEvent.ModifierFlags` would have served, and did: the first version of this
/// file masked flags by hand at every comparison. The reason for a separate type
/// is that masking. An arrow key arrives carrying `.function` and `.numericPad`
/// on top of whatever the user held, Caps Lock arrives as a modifier in its own
/// right, and every one of those has to be dropped before a comparison means
/// anything. Dropping them once, in `init(_:)`, is what lets the table below be
/// a dictionary lookup instead of a ladder of `subtracting` calls that each have
/// to remember the same three exclusions — and it was a ladder, with the
/// exclusions written once and the ⌘-only branch quietly relying on them.
struct EditorModifiers: OptionSet, Hashable, Sendable {
    let rawValue: Int

    static let control = EditorModifiers(rawValue: 1 << 0)
    static let option = EditorModifiers(rawValue: 1 << 1)
    static let shift = EditorModifiers(rawValue: 1 << 2)
    static let command = EditorModifiers(rawValue: 1 << 3)

    init(rawValue: Int) { self.rawValue = rawValue }

    /// Keeps the four that mean something here and discards the rest.
    ///
    /// `.capsLock` is discarded rather than rejected: someone with Caps Lock on
    /// still means ⌘X by ⌘X, and refusing the event would be a shortcut that
    /// stops working for a reason nothing on screen explains. `.function` and
    /// `.numericPad` are set by macOS on every arrow, Home and End, so a table
    /// that compared raw flags would never match a single arrow key.
    init(_ flags: NSEvent.ModifierFlags) {
        var value: EditorModifiers = []
        if flags.contains(.control) { value.insert(.control) }
        if flags.contains(.option) { value.insert(.option) }
        if flags.contains(.shift) { value.insert(.shift) }
        if flags.contains(.command) { value.insert(.command) }
        self = value
    }

    /// ⌃⌥⇧⌘, which is the order macOS prints them in and therefore the order
    /// the cheat sheet has to print them in — a sheet that spells ⌘⇧Z where
    /// every menu in the system spells ⇧⌘Z is a sheet people stop trusting.
    var display: String {
        var text = ""
        if contains(.control) { text += "⌃" }
        if contains(.option) { text += "⌥" }
        if contains(.shift) { text += "⇧" }
        if contains(.command) { text += "⌘" }
        return text
    }
}

// MARK: - Key spellings

/// The characters `charactersIgnoringModifiers` actually delivers for keys that
/// have no printable form.
///
/// Written out because every one of them has been guessed wrong at least once.
/// The Delete key does not send `\u{8}`; it sends `\u{7F}`, and forward delete
/// sends `\u{F728}`, and a hardware keyboard configured a fourth way sends the
/// first. All three are bound rather than argued about.
enum EditorKey {
    static let space = " "
    /// Backspace proper.
    static let backspace = "\u{8}"
    /// What the Mac Delete key sends.
    static let deleteCharacter = "\u{7F}"
    /// `NSDeleteFunctionKey` — the fn-Delete forward delete.
    static let forwardDelete = "\u{F728}"
    static let up = "\u{F700}"
    static let down = "\u{F701}"
    static let left = "\u{F702}"
    static let right = "\u{F703}"
    static let home = "\u{F729}"
    static let end = "\u{F72B}"
}

/// One key with one set of modifiers held.
///
/// `spellings` is a list because a physical key can send more than one
/// character and all of them mean the same press: Delete has three, and `=`
/// and `+` are one key whose shifted spelling depends on whether the running
/// SDK folds Shift into `charactersIgnoringModifiers` — which is a thing this
/// file should not have to have an opinion about.
struct EditorKeyStroke: Hashable, Sendable {
    var spellings: [String]
    var modifiers: EditorModifiers

    init(_ spellings: [String], _ modifiers: EditorModifiers = []) {
        self.spellings = spellings
        self.modifiers = modifiers
    }

    init(_ spelling: String, _ modifiers: EditorModifiers = []) {
        self.init([spelling], modifiers)
    }

    /// **Derived, never stored.** A stored display string is a second copy of
    /// the binding, and a second copy is the thing the cheat sheet exists to
    /// avoid — the whole point of generating the sheet from this table is that
    /// there is nowhere for a printed key and a bound key to disagree.
    var display: String { modifiers.display + Self.glyph(for: spellings[0]) }

    private static func glyph(for spelling: String) -> String {
        switch spelling {
        case EditorKey.space: return "Space"
        case EditorKey.backspace, EditorKey.deleteCharacter: return "⌫"
        case EditorKey.forwardDelete: return "⌦"
        case EditorKey.up: return "↑"
        case EditorKey.down: return "↓"
        case EditorKey.left: return "←"
        case EditorKey.right: return "→"
        case EditorKey.home: return "↖"
        case EditorKey.end: return "↘"
        default: return spelling.uppercased()
        }
    }
}

/// A key press reduced to the two things the table matches on.
struct EditorKeyChord: Hashable, Sendable {
    /// Lowercased `charactersIgnoringModifiers`.
    var characters: String
    var modifiers: EditorModifiers
}

// MARK: - The table

/// Melo Edit's key equivalents, as a value that can be tested without a
/// window.
///
/// Separated from the monitor that delivers them on purpose. A check that
/// asserts "⇧⌘Z is redo" against a pure function proves the *rule*; only a check
/// that watches `perform` fire proves the rule is connected. Both are cheap, and
/// this project's anchor records a run where four wiring points were severed at
/// once and every rule-only assertion still passed.
///
/// ## Why this is a table and not a `switch`
///
/// It was a `switch`, and a `switch` was fine at fourteen shortcuts. At
/// thirty-six it stops being fine for a reason that has nothing to do with
/// taste: **the cheat sheet.** ⌘/ has to list every binding, and a list written
/// by hand next to a `switch` written by hand is two things that drift, with the
/// drift invisible until someone presses a key the sheet promised. So the sheet
/// reads `EditorShortcut.allCases` and each case's own `strokes`, the matcher
/// reads a dictionary built from the same `strokes`, and there is no third place
/// a binding can be written down.
///
/// `scripts/verify-editor-keys.py` asserts the three properties that makes this
/// worth doing: every case reachable from some chord, no chord claimed twice,
/// every case present in the sheet.
///
/// ## The bare letters
///
/// S, B, L, I, O and M carry no modifier, which is new here — before this pass
/// only Space and Delete did. They are safe for exactly one reason and it is
/// worth naming, because if that reason ever stops holding, six keys start
/// destroying text: `EditorKeyCommandView.handle` returns the event untouched
/// whenever `window.firstResponder is NSTextView`, and a SwiftUI `TextField`
/// being edited *is* an `NSTextView` — the window's field editor, not the
/// `NSTextField` itself. Measured, by executing that guard against a real
/// window with a real focused field, in `scripts/verify-editor-keys.py`.
enum EditorShortcut: String, CaseIterable, Sendable {

    // Playing.
    case playPause
    /// Held, not pressed. The only shortcut with a meaningful key-up.
    case bypassHold
    case toggleLoop
    case setLoopIn
    case setLoopOut

    // Getting around.
    case jumpToStart
    case jumpToEnd
    case nudgeBack
    case nudgeForward
    case previousEdge
    case nextEdge
    case addMarker

    // Choosing.
    case extendSelectionBack
    case extendSelectionForward
    case selectTrackAbove
    case selectTrackBelow
    case selectAllClips
    case deselectAll
    case toggleTrackMute
    case toggleTrackSolo

    // Editing.
    case splitClip
    case cutClips
    case copyClips
    case pasteClips
    case duplicateClips
    /// Delete, which means the selected clips or the selected move depending on
    /// which of the two the document has. See `EditorDeleteTarget`.
    ///
    /// Named for the key rather than for the move it used to be the only way to
    /// remove. The old spelling was `deleteMove`, and a case name that says
    /// which pane it belongs to is how a second pane's Delete ends up as a
    /// second monitor.
    case deleteSelection
    case undo
    case redo

    // Looking.
    case zoomToFit
    case zoomIn
    case zoomOut
    case shortcutSheet

    // Sound in, sound out.
    case openFile
    case pasteLink
    case recordSystem
    case export

    /// Whether a shortcut is a press or a hold.
    ///
    /// Every other shortcut is an event; `bypassHold` is a *state*, and a state
    /// needs both edges. Modelling it as a phase on the existing match rather
    /// than as a second monitor is deliberate — two monitors on one window is
    /// two places for the first-responder guard to drift apart, and the guard is
    /// the whole reason this file exists.
    enum Phase: Sendable {
        case down
        case up
    }

    /// Only the hold answers a key-up. A key-up for any other shortcut is not a
    /// second chance to fire it.
    var respondsToKeyUp: Bool { self == .bypassHold }

    /// Whether holding the key down should keep firing.
    ///
    /// The rule is: repeat when the verb is *movement*, never when the verb
    /// *changes the document*. A held Space would toggle playback at the key
    /// repeat rate, which is a hundred play/pause flips a second rather than one
    /// pause; a held ⌘Z would unwind the whole stack past the point anyone
    /// wanted; a held S would try to split at a playhead that has not moved,
    /// which the store's own guard refuses but which would still be a key that
    /// beeps thirty times. Arrows, zoom and track selection all move, and all of
    /// them are worse without repeat than with it. `bypassHold` handles its own
    /// repeats by ignoring them.
    var repeatsAreMeaningful: Bool {
        switch self {
        case .zoomIn, .zoomOut,
             .nudgeBack, .nudgeForward,
             .previousEdge, .nextEdge,
             .extendSelectionBack, .extendSelectionForward,
             .selectTrackAbove, .selectTrackBelow:
            return true
        default:
            return false
        }
    }

    // MARK: Bindings

    /// Every way of reaching this shortcut.
    ///
    /// More than one entry means a genuine alternative, not a spelling variant —
    /// spellings live inside a stroke. Split has two because ⌘T was here first
    /// and removing a shortcut people have already learned is a cost with no
    /// benefit; zoom has two because ⌘+ is ⇧⌘= on most layouts.
    var strokes: [EditorKeyStroke] {
        switch self {

        // Playing.
        case .playPause:
            return [EditorKeyStroke(EditorKey.space)]
        // B, unmodified, held.
        //
        // The control this drives is the one that lets someone hear their own
        // file against what Melo did to it, which means it has to be findable
        // without looking away from the waveform — so no modifier, and a letter
        // the hand can reach from where it already is. `b` for bypass is the
        // mnemonic, and it collides with nothing else bound here.
        //
        // *Rejected:* holding Option, which is the gesture some plugins use and
        // which arrives as `flagsChanged` rather than a key event — a third
        // event type, on a key macOS itself claims for a dozen things. And `\`,
        // which some DAWs use for A/B: no mnemonic, and it is not the same
        // physical key on an ISO keyboard as on ANSI.
        //
        // *Rejected on this pass:* turning it into a latching toggle because
        // the frame calls it "the A/B compare toggle". A hold is already the
        // right shape for a comparison you make in a second and a half, and it
        // cannot be left on by accident — `observeResign` exists precisely
        // because a stuck bypass is a wrong sound with nothing on screen
        // explaining it. A latch would need that whole failure mode designing
        // again for no gain the frame actually asked for.
        case .bypassHold:
            return [EditorKeyStroke("b")]
        case .toggleLoop:
            return [EditorKeyStroke("l")]
        case .setLoopIn:
            return [EditorKeyStroke("i")]
        case .setLoopOut:
            return [EditorKeyStroke("o")]

        // Getting around.
        case .jumpToStart:
            return [EditorKeyStroke(EditorKey.home)]
        case .jumpToEnd:
            return [EditorKeyStroke(EditorKey.end)]
        case .nudgeBack:
            return [EditorKeyStroke(EditorKey.left)]
        case .nudgeForward:
            return [EditorKeyStroke(EditorKey.right)]
        case .previousEdge:
            return [EditorKeyStroke(EditorKey.left, .option)]
        case .nextEdge:
            return [EditorKeyStroke(EditorKey.right, .option)]
        case .addMarker:
            return [EditorKeyStroke("m")]

        // Choosing.
        case .extendSelectionBack:
            return [EditorKeyStroke(EditorKey.left, .shift)]
        case .extendSelectionForward:
            return [EditorKeyStroke(EditorKey.right, .shift)]
        case .selectTrackAbove:
            return [EditorKeyStroke(EditorKey.up)]
        case .selectTrackBelow:
            return [EditorKeyStroke(EditorKey.down)]
        case .selectAllClips:
            return [EditorKeyStroke("a", .command)]
        case .deselectAll:
            return [EditorKeyStroke("a", [.command, .shift])]
        // ⌥M and ⌥S rather than Logic's bare M and S, because both of those
        // letters are already spoken for here by VEGAS: M is a marker and S is
        // the split the owner named by name. Option keeps the mnemonic and
        // costs one finger. `charactersIgnoringModifiers` is what makes this
        // work at all — with Option held, `characters` is "µ" and "ß".
        case .toggleTrackMute:
            return [EditorKeyStroke("m", .option)]
        case .toggleTrackSolo:
            return [EditorKeyStroke("s", .option)]

        // Editing.
        //
        // **S is the headline of this pass and ⌘T stays anyway.**
        //
        // The owner learned split on S in VEGAS as a kid and asked for it by
        // name. ⌘T was chosen in an earlier pass for a reason that has not
        // expired — recorded here rather than deleted with the binding: ⌘E is
        // the DAW spelling that Ableton and Pro Tools use, ⌘E has shipped in
        // this window as Export and the header button's tooltip says so, and
        // ⇧⌘E was rejected because one Shift away from a key that writes a file
        // to disk is not where a destructive edit belongs.
        //
        // Keeping both costs one row in the cheat sheet and zero ambiguity: a
        // bare S and a ⌘T are different chords, so nothing has to choose. What
        // it buys is that nobody who learned ⌘T last month loses it, which is
        // the whole reason to keep a shortcut alive past its replacement.
        case .splitClip:
            return [EditorKeyStroke("s"), EditorKeyStroke("t", .command)]
        // The gap the owner named. There was no cut at all — copy and Delete,
        // as two presses, with two undo entries.
        case .cutClips:
            return [EditorKeyStroke("x", .command)]
        // ⌘C and ⌘V do the obvious thing to clips. They are safe to take here
        // only because of the first-responder guard in `handle`: inside a text
        // field the field editor gets them first and this never sees them, and
        // with no clip selected they are handed back to the responder chain
        // rather than swallowed.
        case .copyClips:
            return [EditorKeyStroke("c", .command)]
        case .pasteClips:
            return [EditorKeyStroke("v", .command)]
        case .duplicateClips:
            return [EditorKeyStroke("d", .command)]
        case .deleteSelection:
            return [EditorKeyStroke([
                EditorKey.deleteCharacter,
                EditorKey.backspace,
                EditorKey.forwardDelete
            ])]
        case .undo:
            return [EditorKeyStroke("z", .command)]
        case .redo:
            return [EditorKeyStroke("z", [.command, .shift])]

        // Looking.
        case .zoomToFit:
            return [EditorKeyStroke("0", .command)]
        // ⌘+ is ⇧⌘= on most layouts and plain ⌘= on none of them, so both
        // chords mean zoom in and both spellings of the key are listed inside
        // each. The same courtesy for ⌘_ costs one line.
        case .zoomIn:
            return [
                EditorKeyStroke(["=", "+"], .command),
                EditorKeyStroke(["=", "+"], [.command, .shift])
            ]
        case .zoomOut:
            return [
                EditorKeyStroke(["-", "_"], .command),
                EditorKeyStroke(["-", "_"], [.command, .shift])
            ]
        // ⌘/ is what macOS itself trained people to expect from a help sheet,
        // and unlike ⌘? it needs no Shift to reach on a UK or a US layout.
        // `?` is in the spellings because ⇧⌘/ is how a US layout types ⌘? and
        // some SDKs fold Shift into `charactersIgnoringModifiers` while others
        // do not — the same uncertainty the zoom keys are written around.
        case .shortcutSheet:
            return [
                EditorKeyStroke(["/", "?"], .command),
                EditorKeyStroke(["/", "?"], [.command, .shift])
            ]

        // Sound in, sound out.
        case .openFile:
            return [EditorKeyStroke("o", .command)]
        // The other two ways a sound gets in. They sat behind the empty state,
        // which stops existing the moment a document opens, so before these they
        // were reachable once per launch. Neither collides: nothing in this
        // window binds ⌘L or ⌘R, and this app has no menu bar to lose them to.
        case .pasteLink:
            return [EditorKeyStroke("l", .command)]
        case .recordSystem:
            return [EditorKeyStroke("r", .command)]
        case .export:
            return [EditorKeyStroke("e", .command)]
        }
    }

    /// The strokes the cheat sheet prints, which is not always all of them.
    ///
    /// A stroke that differs from an earlier one by nothing but Shift is a
    /// layout accommodation rather than an alternative: ⌘+ is ⇧⌘= on most
    /// keyboards and plain ⌘= on none of them, so both are bound and the key
    /// works either way. Printing "⌘= or ⇧⌘=" would tell the reader there are
    /// two shortcuts where there is one key, which is a worse sheet than one
    /// that says less. Dropped from the *printing*, never from the *binding* —
    /// the binding is what makes the key work at all.
    var printedStrokes: [EditorKeyStroke] {
        var kept: [EditorKeyStroke] = []
        for stroke in strokes {
            let isShiftVariantOfSomethingKept = stroke.modifiers.contains(.shift) && kept.contains {
                $0.spellings == stroke.spellings && $0.modifiers == stroke.modifiers.subtracting(.shift)
            }
            if !isShiftVariantOfSomethingKept { kept.append(stroke) }
        }
        return kept
    }

    // MARK: What the cheat sheet prints

    /// Where a shortcut sits in the sheet. Declaration order inside a section is
    /// the printed order, so the enum above is also the layout.
    enum Section: String, CaseIterable, Sendable {
        case playing = "Playing"
        case moving = "Getting around"
        case choosing = "Choosing"
        case editing = "Editing"
        case looking = "Looking"
        case sound = "Sound in, sound out"
    }

    var section: Section {
        switch self {
        case .playPause, .bypassHold, .toggleLoop, .setLoopIn, .setLoopOut:
            return .playing
        case .jumpToStart, .jumpToEnd, .nudgeBack, .nudgeForward,
             .previousEdge, .nextEdge, .addMarker:
            return .moving
        case .extendSelectionBack, .extendSelectionForward,
             .selectTrackAbove, .selectTrackBelow,
             .selectAllClips, .deselectAll, .toggleTrackMute, .toggleTrackSolo:
            return .choosing
        case .splitClip, .cutClips, .copyClips, .pasteClips, .duplicateClips,
             .deleteSelection, .undo, .redo:
            return .editing
        case .zoomToFit, .zoomIn, .zoomOut, .shortcutSheet:
            return .looking
        case .openFile, .pasteLink, .recordSystem, .export:
            return .sound
        }
    }

    /// The line the sheet prints. Melo's voice: what it does, not how it works,
    /// and never longer than the row it sits in.
    var title: String {
        switch self {
        case .playPause: return "Play or pause"
        case .bypassHold: return "Hold to hear the original"
        case .toggleLoop: return "Loop the selection"
        case .setLoopIn: return "Loop starts here"
        case .setLoopOut: return "Loop ends here"
        case .jumpToStart: return "Back to the start"
        case .jumpToEnd: return "Out to the end"
        case .nudgeBack: return "Nudge back"
        case .nudgeForward: return "Nudge forward"
        case .previousEdge: return "Previous clip edge"
        case .nextEdge: return "Next clip edge"
        case .addMarker: return "Drop a marker"
        case .extendSelectionBack: return "Stretch the selection back"
        case .extendSelectionForward: return "Stretch the selection forward"
        case .selectTrackAbove: return "Track above"
        case .selectTrackBelow: return "Track below"
        case .selectAllClips: return "Select every clip"
        case .deselectAll: return "Select nothing"
        case .toggleTrackMute: return "Mute this track"
        case .toggleTrackSolo: return "Solo this track"
        case .splitClip: return "Split at the playhead"
        case .cutClips: return "Cut"
        case .copyClips: return "Copy"
        case .pasteClips: return "Paste at the playhead"
        case .duplicateClips: return "Duplicate"
        case .deleteSelection: return "Delete"
        case .undo: return "Undo"
        case .redo: return "Redo"
        case .zoomToFit: return "Fit it all in"
        case .zoomIn: return "Zoom in"
        case .zoomOut: return "Zoom out"
        case .shortcutSheet: return "This list"
        case .openFile: return "Add a file"
        case .pasteLink: return "Paste a link"
        case .recordSystem: return "Record this Mac"
        case .export: return "Save it out"
        }
    }

    /// Words someone would type into the sheet's search field that are not
    /// already in the title.
    ///
    /// Single distinctive words, following the anchor's finding about search
    /// vocabulary: a phrase gets split into tokens anyway, and a common word
    /// lifts every row it appears in as much as the one it was meant for.
    var searchKeywords: [String] {
        switch self {
        case .playPause: return ["transport", "stop"]
        case .bypassHold: return ["bypass", "compare", "a/b", "dry", "before"]
        case .toggleLoop: return ["repeat", "cycle"]
        case .setLoopIn: return ["in", "punch"]
        case .setLoopOut: return ["out", "punch"]
        case .jumpToStart: return ["home", "rewind", "top"]
        case .jumpToEnd: return ["tail"]
        case .nudgeBack, .nudgeForward: return ["playhead", "cursor", "scrub", "arrow"]
        case .previousEdge, .nextEdge: return ["boundary", "snap", "transient"]
        case .addMarker: return ["marker", "cue", "flag"]
        case .extendSelectionBack, .extendSelectionForward: return ["range", "grow"]
        case .selectTrackAbove, .selectTrackBelow: return ["lane", "arrow"]
        case .selectAllClips: return ["everything"]
        case .deselectAll: return ["clear", "none"]
        case .toggleTrackMute: return ["silence", "lane"]
        case .toggleTrackSolo: return ["alone", "lane"]
        case .splitClip: return ["cut", "slice", "divide", "razor", "chop"]
        case .cutClips: return ["remove", "lift"]
        case .copyClips: return ["clipboard"]
        case .pasteClips: return ["clipboard", "insert"]
        case .duplicateClips: return ["repeat", "clone"]
        case .deleteSelection: return ["remove", "erase", "backspace"]
        case .undo: return ["back", "mistake"]
        case .redo: return ["again"]
        case .zoomToFit: return ["whole", "everything", "overview"]
        case .zoomIn: return ["closer", "magnify"]
        case .zoomOut: return ["wider", "further"]
        case .shortcutSheet: return ["keys", "help", "keyboard", "cheat"]
        case .openFile: return ["import", "sound", "audio"]
        case .pasteLink: return ["url", "youtube", "download"]
        case .recordSystem: return ["capture", "system"]
        case .export: return ["render", "bounce", "share", "file"]
        }
    }

    /// Everything the sheet's search matches against, lowercased once.
    ///
    /// The chord displays are in here so typing "⌘X" finds Cut, and the plain
    /// words are in here so typing "cmd x" does too — nobody types ⌘ into a
    /// search field.
    var searchText: String {
        var parts = [title] + searchKeywords + strokes.map(\.display)
        for stroke in strokes {
            if stroke.modifiers.contains(.command) { parts += ["cmd", "command"] }
            if stroke.modifiers.contains(.shift) { parts.append("shift") }
            if stroke.modifiers.contains(.option) { parts += ["option", "alt"] }
            if stroke.modifiers.contains(.control) { parts += ["ctrl", "control"] }
            for spelling in stroke.spellings where spelling.count == 1 {
                parts.append(spelling)
            }
        }
        return parts.joined(separator: " ").lowercased()
    }

    // MARK: Matching

    /// Every chord in the table, with every shortcut that claims it.
    ///
    /// A dictionary of *arrays* rather than of shortcuts, so a chord claimed
    /// twice is visible instead of silently swallowing whichever entry
    /// `allCases` reached second. `verify-editor-keys.py` asserts every value
    /// here has exactly one element; this shape is what lets it.
    static let chordOwners: [EditorKeyChord: [EditorShortcut]] = {
        var owners: [EditorKeyChord: [EditorShortcut]] = [:]
        for shortcut in allCases {
            for stroke in shortcut.strokes {
                for spelling in stroke.spellings {
                    let chord = EditorKeyChord(
                        characters: spelling.lowercased(),
                        modifiers: stroke.modifiers
                    )
                    owners[chord, default: []].append(shortcut)
                }
            }
        }
        return owners
    }()

    /// First claimant wins, which is defined behaviour rather than good
    /// behaviour — the verify script is what makes sure there is never a second.
    private static let lookup: [EditorKeyChord: EditorShortcut] =
        chordOwners.compactMapValues(\.first)

    /// - Parameters:
    ///   - characters: `NSEvent.charactersIgnoringModifiers`. Ignoring modifiers
    ///     is what keeps ⌥M arriving as `"m"` rather than as `"µ"`, so an
    ///     Option binding is one entry instead of a table of dead keys per
    ///     layout.
    ///   - modifiers: `NSEvent.modifierFlags`, unfiltered; `EditorModifiers`
    ///     does the masking.
    ///   - phase: `.up` matches `bypassHold` and nothing else.
    static func match(
        characters: String,
        modifiers: NSEvent.ModifierFlags,
        phase: Phase
    ) -> EditorShortcut? {
        let chord = EditorKeyChord(
            characters: characters.lowercased(),
            modifiers: EditorModifiers(modifiers)
        )
        guard let shortcut = lookup[chord] else { return nil }
        guard phase == .down || shortcut.respondsToKeyUp else { return nil }
        return shortcut
    }
}

// MARK: - What Delete removes

/// What one press of Delete removes.
///
/// A pure value with a pure function to produce it, for the reason the file's
/// other rules are: this is the decision a wrong answer destroys something
/// over, and it should be assertable without a window, a document or a key
/// event. `EditorKeyCommands` does no arithmetic of its own — it asks this and
/// obeys.
enum EditorDeleteTarget: Equatable, Sendable {
    case clips([Clip.ID])
    case move(Move.ID)
    case nothing

    /// **Clips win when there are any.**
    ///
    /// The two selections are not mutually exclusive — clicking a clip does not
    /// clear the stack's selection and clicking a move does not clear the
    /// timeline's — so with both showing, one key has to choose, and the choice
    /// is visible to nobody before they press it. That is the real defect, and
    /// the durable fix is not here: it is that selecting in one pane should
    /// clear the other, in `ChainPanelView` and `EditorWaveformView`. Until then
    /// this is the least-bad rule, for two reasons rather than a preference.
    ///
    /// First, it self-corrects in one press. `EditorStore.mutate` prunes
    /// `selectedClipIDs` against the document, so deleting the selected clips
    /// empties the set — the *next* Delete therefore falls through to the move,
    /// with no state cleared by hand and no trap where the same key keeps
    /// removing the same wrong thing.
    ///
    /// Second, the timeline selection is the one the user almost always made
    /// most recently: a move stays selected from whenever its inspector was
    /// last open, while a clip is selected by clicking the clip.
    ///
    /// Both are recoverable — every path goes through `mutate`, so ⌘Z brings
    /// back either one — which bounds how wrong this can be, and is not a
    /// licence to guess.
    static func resolve(clipIDs: Set<Clip.ID>, moveID: Move.ID?) -> EditorDeleteTarget {
        if !clipIDs.isEmpty { return .clips(Array(clipIDs)) }
        if let moveID { return .move(moveID) }
        return .nothing
    }
}

// MARK: - Installing them

extension View {
    /// Installs Melo Edit's key equivalents, and the sheet that lists them, for
    /// as long as this view is in a window.
    ///
    /// - Parameters:
    ///   - store: everything a shortcut changes goes through here, including the
    ///     ones belonging to panes this piece does not own. A shortcut that
    ///     reached into `EditorWaveformView` to zoom it would be a second way to
    ///     drive a pane, and the second way is always the one that rots.
    ///   - onExport: presenting `ExportSheet` is the window's own state, not the
    ///     store's, so ⌘E comes back out rather than going in.
    ///   - onOpenFile: likewise — the file picker is a window affordance.
    ///
    /// ⌘/ is the exception to that pattern and does *not* come back out. The
    /// cheat sheet is generated from the table in this file and is of no
    /// interest to the window, so routing it through `EditorRootView` would be
    /// a parameter that exists only to be passed back down. The signature is
    /// unchanged from before this pass for the same reason: one call site, and
    /// nothing there needs to know the sheet exists.
    func editorKeyCommands(
        store: EditorStore,
        onExport: @escaping () -> Void,
        onOpenFile: @escaping () -> Void,
        onPasteLink: @escaping () -> Void,
        onRecord: @escaping () -> Void
    ) -> some View {
        modifier(
            EditorKeyCommandsModifier(
                store: store,
                onExport: onExport,
                onOpenFile: onOpenFile,
                onPasteLink: onPasteLink,
                onRecord: onRecord
            )
        )
    }
}

private struct EditorKeyCommandsModifier: ViewModifier {
    let store: EditorStore
    let onExport: () -> Void
    let onOpenFile: () -> Void
    let onPasteLink: () -> Void
    let onRecord: () -> Void

    @State private var showingShortcuts = false

    func body(content: Content) -> some View {
        content
            .background(
                EditorKeyCommands(
                    store: store,
                    onExport: onExport,
                    onOpenFile: onOpenFile,
                    onPasteLink: onPasteLink,
                    onRecord: onRecord,
                    onShowShortcuts: { showingShortcuts = true }
                )
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
            )
            // An attached sheet is its own window, so `handle`'s
            // `event.window === window` guard means none of these thirty-six
            // keys reach the monitor while the sheet is up — which is what lets
            // the sheet have a search field people can type "s" into. Closing it
            // is the sheet's own Done button, for the same reason.
            .sheet(isPresented: $showingShortcuts) {
                EditorShortcutSheet(isPresented: $showingShortcuts)
            }
    }
}

/// ## Why a local event monitor rather than hidden `Button`s
///
/// Melo's popup reaches for `.keyboardShortcut` on a real button, and for ⌘K on
/// a control that is visibly there, that is the right answer. It is the wrong
/// one here for two reasons that both come from this window having text in it.
///
/// Space, Delete and now six bare letters carry no modifier. A
/// `.keyboardShortcut(.space, modifiers: [])` fires while a `TextField` has the
/// insertion point, so typing a filename into the export sheet or a frequency
/// into a move would start and stop playback a word at a time — and after this
/// pass, typing a track name would split a clip on the first S.
/// `MenuBarPopupView.handleKeyPress` already answers this exact question the
/// same way — `if NSApp.keyWindow?.firstResponder is NSTextView { return
/// .ignored }` — and that guard is what this needs, which means it needs the
/// event rather than a shortcut.
///
/// ⌘Z is the second reason, and it is subtler: inside a text field ⌘Z means undo
/// what I just typed, and taking it away to undo a *move* is the kind of thing
/// that loses someone a sentence. The same first-responder guard hands it back.
///
/// One mechanism for all of them, uniformly guarded, is also why every shortcut
/// goes through here rather than splitting the modified ones off into buttons.
private struct EditorKeyCommands: NSViewRepresentable {
    let store: EditorStore
    let onExport: () -> Void
    let onOpenFile: () -> Void
    let onPasteLink: () -> Void
    let onRecord: () -> Void
    let onShowShortcuts: () -> Void

    func makeNSView(context: Context) -> EditorKeyCommandView {
        EditorKeyCommandView()
    }

    func updateNSView(_ nsView: EditorKeyCommandView, context: Context) {
        let router = EditorShortcutRouter(
            store: store,
            onExport: onExport,
            onOpenFile: onOpenFile,
            onPasteLink: onPasteLink,
            onRecord: onRecord,
            onShowShortcuts: onShowShortcuts
        )
        nsView.perform = { router.perform($0, phase: $1) }
    }
}

/// The one place a shortcut becomes a call.
///
/// A value with a method rather than a closure built inside `updateNSView`,
/// which is what it was. The reason is the anchor's: a check that asserts ⌘X is
/// `cutClips` proves the *table*, and this project has already shipped a run
/// where four wiring points were severed and every table-level assertion still
/// passed. `scripts/verify-editor-keys.py` constructs this router over a
/// recording store and fires all thirty-six cases through it, which is the only
/// way to catch an arm that matches, returns `true`, and calls nothing.
///
/// Every arm is one call. The arithmetic behind the new verbs is in
/// `EditorKeyboardActions.swift` as methods on the store, so the key and the
/// button that will eventually do the same thing reach it by the same route —
/// the rule `EditorTransportCommands.swift` was written to enforce.
@MainActor
struct EditorShortcutRouter {
    let store: EditorStore
    let onExport: () -> Void
    let onOpenFile: () -> Void
    let onPasteLink: () -> Void
    let onRecord: () -> Void
    let onShowShortcuts: () -> Void

    /// Returns whether the shortcut actually did something. `false` sends the
    /// key back to the responder chain — see `EditorKeyCommandView.handle`.
    func perform(_ shortcut: EditorShortcut, phase: EditorShortcut.Phase) -> Bool {
        switch shortcut {
        case .bypassHold:
            store.setBypassHeld(phase == .down)
        case .playPause:
            store.togglePlayback()
        case .toggleLoop:
            store.toggleLoop()
        case .setLoopIn:
            return store.setLoopIn()
        case .setLoopOut:
            return store.setLoopOut()

        case .jumpToStart:
            store.jumpToStart()
        case .jumpToEnd:
            return store.jumpToEnd()
        case .nudgeBack:
            return store.nudgePlayhead(steps: -1)
        case .nudgeForward:
            return store.nudgePlayhead(steps: 1)
        case .previousEdge:
            return store.jumpToClipEdge(forward: false)
        case .nextEdge:
            return store.jumpToClipEdge(forward: true)
        case .addMarker:
            return store.addMarkerAtPlayhead()

        case .extendSelectionBack:
            return store.extendSelection(steps: -1)
        case .extendSelectionForward:
            return store.extendSelection(steps: 1)
        case .selectTrackAbove:
            return store.selectAdjacentTrack(offset: -1)
        case .selectTrackBelow:
            return store.selectAdjacentTrack(offset: 1)
        case .selectAllClips:
            return store.selectAllClips()
        case .deselectAll:
            return store.deselectEverything()
        case .toggleTrackMute:
            return store.toggleMuteOnSelectedTrack()
        case .toggleTrackSolo:
            return store.toggleSoloOnSelectedTrack()

        case .splitClip:
            // The store's own guard is the authority on whether a point is
            // splittable — `splitClip` returns `nil` when the playhead is
            // not strictly inside — so this reads the result rather than
            // predicting it. A third copy of that predicate (the clip menu
            // has the second) is how the menu and the key end up
            // disagreeing about the same clip.
            var split = false
            for id in store.selectedClipIDs {
                if store.splitClip(id, at: store.playhead) != nil { split = true }
            }
            return split
        case .cutClips:
            return store.cutSelectedClips()
        case .copyClips:
            guard !store.selectedClipIDs.isEmpty else { return false }
            store.copyClips(Array(store.selectedClipIDs))
        case .pasteClips:
            guard store.canPasteClips else { return false }
            store.pasteClips(at: store.playhead, track: store.selectedTrackID)
        case .duplicateClips:
            return store.duplicateSelectedClips()
        case .deleteSelection:
            switch EditorDeleteTarget.resolve(
                clipIDs: store.selectedClipIDs,
                moveID: store.selectedMoveID
            ) {
            case .clips(let ids):
                // `resolve` is handed `selectedClipIDs`, so this set *is* the
                // selection — and `removeSelectedClips` takes it out through
                // one `mutate`, which is one ⌘Z instead of one per clip. The
                // equality is checked rather than assumed because the resolved
                // value is the authority here, not the store's field; if
                // `resolve` ever answers a subset, this obeys it and pays the
                // extra undo entries.
                if Set(ids) == store.selectedClipIDs {
                    store.removeSelectedClips()
                } else {
                    for id in ids { store.removeClip(id) }
                }
            case .move(let id):
                store.remove(id)
            case .nothing:
                return false
            }
        case .undo:
            store.undo()
        case .redo:
            store.redo()

        case .zoomToFit:
            store.zoomToFit()
        case .zoomIn:
            store.zoomIn()
        case .zoomOut:
            store.zoomOut()
        case .shortcutSheet:
            onShowShortcuts()

        case .openFile:
            onOpenFile()
        case .pasteLink:
            onPasteLink()
        case .recordSystem:
            onRecord()
        case .export:
            onExport()
        }
        return true
    }
}

/// Holds the monitor and tears it down when the view leaves its window, the same
/// shape `WindowAppearanceTrackerView` uses to hang behaviour off a window a
/// SwiftUI view cannot otherwise see.
final class EditorKeyCommandView: NSView {
    /// Returns whether the shortcut did anything.
    var perform: ((EditorShortcut, EditorShortcut.Phase) -> Bool)?

    /// Tracked so the hold can be broken by something other than the key coming
    /// back up. See `releaseBypassIfHeld()`.
    private var isBypassHeld = false

    /// Both tokens are `nonisolated(unsafe)` for the same reason as
    /// `OnboardingWindowController.guideRequestObserver`: `deinit` is
    /// nonisolated under Swift 6 and cannot read a `@MainActor` property, and
    /// both have to be unregistered there. Safe in fact — each is written only
    /// from the main actor in the methods below, and `deinit` cannot run
    /// concurrently with any of them.
    nonisolated(unsafe) private var monitor: Any?
    nonisolated(unsafe) private var resignObserver: NSObjectProtocol?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            releaseBypassIfHeld()
            removeMonitor()
        } else {
            installMonitor()
            observeResign()
        }
    }

    deinit {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        if let resignObserver {
            NotificationCenter.default.removeObserver(resignObserver)
        }
    }

    private func installMonitor() {
        guard monitor == nil else { return }
        // No `MainActor.assumeIsolated` here, unlike `ClickOutsideCoordinator`:
        // this handler is already main-actor isolated by the SDK, and wrapping it
        // would push `NSEvent` — which is explicitly non-`Sendable` — out through
        // the closure's return type.
        //
        // `keyUp` as well as `keyDown`, for `bypassHold` and nothing else.
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            self?.handle(event) ?? event
        }
    }

    private func removeMonitor() {
        guard let monitor else { return }
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
    }

    /// The failure this exists for: hold B, ⌘-Tab away, let go. The key-up lands
    /// in the other app, this window never hears it, and Melo is left bypassed
    /// with no key held and nothing on screen explaining why the sound is wrong.
    /// A hold has to be released by *losing the hold*, which quitting the window
    /// is a way of doing.
    private func observeResign() {
        guard resignObserver == nil, let window else { return }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.releaseBypassIfHeld()
            }
        }
    }

    private func releaseBypassIfHeld() {
        guard isBypassHeld else { return }
        isBypassHeld = false
        _ = perform?(.bypassHold, .up)
    }

    /// - Returns: `nil` to swallow the event, or the event to pass it along.
    ///
    /// **Not private, and that is the point of the whole file.** Six bare
    /// letters were added on the VEGAS pass and every one of them is a key
    /// someone types into a track name; the guard below is the only thing
    /// standing between those two facts. `scripts/verify-editor-keys.py` calls
    /// this directly, against a real `NSWindow` with a real focused
    /// `NSTextField`, and asserts the event comes back untouched — because a
    /// check that reads the guard is not a check that the guard runs, which is
    /// the failure this project's anchor records more than once.
    func handle(_ event: NSEvent) -> NSEvent? {
        // The monitor is application-wide, so the window check is what keeps
        // Space from pausing Melo Edit while someone is in Settings. It
        // also covers sheets for free: an attached sheet is its own window, so
        // the export sheet's own keys — and the cheat sheet's search field —
        // never reach here.
        guard let window, event.window === window else { return event }
        // The field editor wins every key it can use. See the type comment.
        // Releasing first: someone holding B who clicks into a text field has
        // stopped comparing, and the alternative is a bypass nothing can clear.
        if window.firstResponder is NSTextView {
            releaseBypassIfHeld()
            return event
        }

        let phase: EditorShortcut.Phase = event.type == .keyUp ? .up : .down

        guard
            let characters = event.charactersIgnoringModifiers,
            let shortcut = EditorShortcut.match(
                characters: characters,
                modifiers: event.modifierFlags,
                phase: phase
            )
        else {
            return event
        }

        if shortcut == .bypassHold {
            // A held key repeats, and the second keyDown is not a second press.
            let held = phase == .down
            guard held != isBypassHeld else { return nil }
            isBypassHeld = held
        } else if event.isARepeat, !shortcut.repeatsAreMeaningful {
            // Swallowed rather than passed along: this key *is* bound here, and
            // handing the repeat to the responder chain would beep.
            return nil
        }

        // **A shortcut that did nothing gives the key back.** ⌘C with no clip
        // selected, ⌘V with an empty clipboard, S with the playhead outside
        // every selected clip, Delete with nothing selected at all: swallowing
        // those makes a key that is silently dead, which is the failure this
        // project's anchor records more than once. Returning the event lets the
        // responder chain answer — which for an unbound key is the system beep,
        // and a beep is feedback where silence is not.
        //
        // It also stops this window from taking ⌘C and ⌘V away from anything
        // else that might want them, without needing to know what that is.
        return perform?(shortcut, phase) == true ? nil : event
    }
}
