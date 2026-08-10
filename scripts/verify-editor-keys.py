#!/usr/bin/env python3
"""Guards Melo Edit's keyboard.

Thirty-six shortcuts, six of them bare letters, and a cheat sheet that claims to
list all of them. Three properties have to hold or one of those three sentences
becomes a lie:

  * every entry is reachable from some key combination;
  * no two entries resolve from the same combination;
  * every entry appears in the cheat sheet.

None of the three is checked by reading source. The real `EditorCommands.swift`,
`EditorKeyboardActions.swift` and `EditorShortcutSheet.swift` are compiled here
and their own functions are run - `EditorShortcut.match` for reachability,
`EditorShortcut.chordOwners` for collisions, and
`EditorShortcutSheet.groups(matching:)` for the sheet. The store, the timeline
and the playback engine are stubs; every rule under assertion is the real one.
What the stubs cannot prove is that the real `EditorStore` has these methods
with these shapes - only a whole-tree typecheck or a build proves that.

A fourth property is asserted that the brief did not ask for, because a table
that is reachable and unique and listed can still be wired to nothing: the real
`EditorShortcutRouter` is built over a recording store and all thirty-six cases
are fired through it, and each one has to leave an observable change behind.
CLAUDE.md records a run where four wiring points were severed and every
rule-level assertion still passed.

**The section this file exists for is the last one.** Before this pass the only
unmodified keys were Space and Delete. S, B, L, I, O and M were added, and every
one of them is a key someone types into a track name. The only thing standing
between those two facts is `EditorKeyCommandView.handle` refusing every event
while the window's field editor holds first responder - so that guard is run,
against a real `NSWindow` with a real focused `NSTextField`. The assertion that
the probe's synthetic event actually resolves to that window comes first,
because without it every guard assertion after it would be green with the guard
never executing.

Watched fail on 2026-08-10, each restored afterwards, with the count of
assertions that went red:

  * `chordOwners` skipping every Option stroke, so the table and the matcher
    disagree - 8 red, four of them "<name> is reachable from a key combination";
  * ⌥S rebound to bare S, which split already owns - 4 red, leading with
    "one shortcut per combination - s is claimed by toggleTrackSolo, splitClip";
  * the sheet filtering `bypassHold` out of its rows - 2 red,
    "the cheat sheet lists every shortcut - missing: bypassHold";
  * the `firstResponder is NSTextView` guard deleted from `handle` - 14 red,
    leading with "S while typing a track name would split a clip";
  * the `.cutClips` arm of the router replaced with `break`, so it matches,
    returns true and calls nothing - 3 red, leading with "cutClips actually
    reaches the store or the window - nothing observable changed";
  * the sheet's `body` enumerating `EditorShortcut.allCases` itself instead of
    drawing `groups(matching:)` - 1 red, from the structural half below.

Standalone `python3`, no arguments. Exits non-zero and prints every failure.
"""
from __future__ import annotations

import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

root = Path(__file__).resolve().parents[1]
sources = root / "Sources/Melo"
failures: list[str] = []

# The real files under assertion, plus the design tokens the sheet paints with.
UNITS = [
    "Editor/Window/EditorCommands.swift",
    "Editor/Window/EditorKeyboardActions.swift",
    "Editor/Window/EditorShortcutSheet.swift",
    "Views/DesignSystem/DesignTokens.swift",
]

# The project's own settings. Compiling under a lower deployment target is a
# different configuration from the one the code ships in, which this project has
# already been caught by - see CLAUDE.md, "A pre-check only covers the
# configuration you ran it in".
SWIFT_VERSION = "6"
TARGET = "arm64-apple-macosx15.4"

STUB_SWIFT = r"""import AppKit
import Foundation
import SwiftUI

struct Move: Identifiable, Equatable { var id: UUID = UUID() }

struct Clip: Identifiable, Equatable {
    var id: UUID = UUID()
    var sourceID: UUID = UUID()
    var start: TimeInterval = 0
    var sourceIn: TimeInterval = 0
    var sourceOut: TimeInterval = 1
    var duration: TimeInterval { max(0, sourceOut - sourceIn) }
    var end: TimeInterval { start + duration }
}

struct Track: Identifiable, Equatable {
    var id: UUID = UUID()
    var clips: [Clip] = []
}

struct EditorDocument: Equatable {
    var tracks: [Track] = []
    var duration: TimeInterval { tracks.flatMap(\.clips).map(\.end).max() ?? 0 }
}

@MainActor
final class EditorTimeline: ObservableObject {
    static let shared = EditorTimeline()
    var visible: TimeInterval = 10
    var duration: TimeInterval = 60
    func clampToSound(_ t: TimeInterval) -> TimeInterval { min(max(t, 0), duration) }
    func reveal(range: ClosedRange<TimeInterval>) {}
}

@MainActor
final class EditorPlayback: ObservableObject {
    static let shared = EditorPlayback()
    @Published var loops = false
}

@MainActor
final class EditorStore: ObservableObject {
    var calls: [String] = []
    private func note(_ name: String) { calls.append(name) }

    @Published var document: EditorDocument?
    @Published var selection: ClosedRange<TimeInterval>?
    @Published var playhead: TimeInterval = 0
    @Published var selectedMoveID: Move.ID?
    @Published var selectedClipIDs: Set<Clip.ID> = []
    @Published var selectedTrackID: Track.ID?
    var canPasteClips = true

    func setBypassHeld(_ held: Bool) { note("setBypassHeld") }
    func togglePlayback() { note("togglePlayback") }
    func jumpToStart() { note("jumpToStart") }
    func toggleLoop() { note("toggleLoop") }
    func zoomIn() { note("zoomIn") }
    func zoomOut() { note("zoomOut") }
    func zoomToFit() { note("zoomToFit") }
    func undo() { note("undo") }
    func redo() { note("redo") }
    func remove(_ id: Move.ID) { note("remove") }
    func removeClip(_ id: Clip.ID) { note("removeClip") }
    func removeSelectedClips() { note("removeSelectedClips") }
    func toggleMute(_ id: Track.ID) { note("toggleMute") }
    func toggleSolo(_ id: Track.ID) { note("toggleSolo") }
    @discardableResult
    func splitClip(_ id: Clip.ID, at time: TimeInterval) -> Clip.ID? { note("splitClip"); return UUID() }
    func copyClips(_ ids: [Clip.ID]) { note("copyClips") }
    func pasteClips(at time: TimeInterval, track: Track.ID?) { note("pasteClips") }
    @discardableResult
    func duplicateClips(_ ids: [Clip.ID], at time: TimeInterval? = nil) -> [Clip.ID] {
        note("duplicateClips")
        return ids.isEmpty ? [] : [UUID()]
    }
}
"""

MAIN_SWIFT = r"""import AppKit
import Foundation

@MainActor
enum Probe {
    static var failures: [String] = []
}

@MainActor
func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    if !ok {
        let extra = detail()
        Probe.failures.append(extra.isEmpty ? name : "\(name) - \(extra)")
    }
}

func nsFlags(_ modifiers: EditorModifiers) -> NSEvent.ModifierFlags {
    var flags: NSEvent.ModifierFlags = []
    if modifiers.contains(.control) { flags.insert(.control) }
    if modifiers.contains(.option) { flags.insert(.option) }
    if modifiers.contains(.shift) { flags.insert(.shift) }
    if modifiers.contains(.command) { flags.insert(.command) }
    return flags
}

// ---------------------------------------------------------------------------
// 1 - Every entry is reachable from some key combination.
// ---------------------------------------------------------------------------

@MainActor
func checkReachability() {
    for shortcut in EditorShortcut.allCases {
        var reachedBy: [String] = []
        for stroke in shortcut.strokes {
            for spelling in stroke.spellings {
                let clean = nsFlags(stroke.modifiers)
                // Caps Lock, fn and the numeric-pad bit ride along on real
                // events - every arrow key carries two of them - so the same
                // chord is tried dirty as well as clean.
                let dirty = clean.union([.capsLock, .function, .numericPad])
                for flags in [clean, dirty] {
                    for text in [spelling, spelling.uppercased()] {
                        if EditorShortcut.match(characters: text, modifiers: flags, phase: .down) == shortcut {
                            reachedBy.append(text)
                        }
                    }
                }
            }
        }
        check("\(shortcut.rawValue) is reachable from a key combination",
              !reachedBy.isEmpty,
              "no chord in its own strokes matches it back")
    }
}

// ---------------------------------------------------------------------------
// 2 - No two entries resolve from the same combination.
// ---------------------------------------------------------------------------

@MainActor
func checkCollisions() {
    for (chord, owners) in EditorShortcut.chordOwners where owners.count > 1 {
        let names = owners.map(\.rawValue).joined(separator: ", ")
        check("one shortcut per combination", false,
              "\(EditorModifiers(nsFlags(chord.modifiers)).display)\(chord.characters) is claimed by \(names)")
    }
    check("the table binds something", !EditorShortcut.chordOwners.isEmpty)
}

// ---------------------------------------------------------------------------
// 3 - Every entry appears in the cheat sheet.
// ---------------------------------------------------------------------------

@MainActor
func checkCheatSheet() {
    let listed = EditorShortcutSheet.groups(matching: "").flatMap(\.shortcuts)
    let missing = EditorShortcut.allCases.filter { !listed.contains($0) }
    check("the cheat sheet lists every shortcut", missing.isEmpty,
          "missing: \(missing.map(\.rawValue).joined(separator: ", "))")
    check("the cheat sheet lists each shortcut once", listed.count == Set(listed).count)

    for shortcut in EditorShortcut.allCases {
        let byTitle = EditorShortcutSheet.groups(matching: shortcut.title).flatMap(\.shortcuts)
        check("searching the sheet for '\(shortcut.title)' finds \(shortcut.rawValue)",
              byTitle.contains(shortcut))
    }

    // A row with no key printed on it is a row nobody can use, and a key the
    // sheet prints that the table does not bind is a promise it breaks.
    for shortcut in EditorShortcut.allCases {
        let printed = shortcut.printedStrokes
        let displays = printed.map(\.display)
        check("\(shortcut.rawValue) prints a key", !displays.isEmpty && !displays.contains(""))
        check("\(shortcut.rawValue) prints only keys it binds",
              printed.allSatisfy { shortcut.strokes.contains($0) })
        check("\(shortcut.rawValue) has a title", !shortcut.title.isEmpty)
        for stroke in printed {
            for spelling in stroke.spellings {
                check("the key \(stroke.display) printed for \(shortcut.rawValue) works",
                      EditorShortcut.match(
                          characters: spelling,
                          modifiers: nsFlags(stroke.modifiers),
                          phase: .down
                      ) == shortcut)
            }
        }
    }

    // The Shift spelling is bound and not printed, which is the whole point of
    // `printedStrokes` - so assert both halves rather than only the tidy one.
    check("zoom in prints one key", EditorShortcut.zoomIn.printedStrokes.map(\.display) == ["⌘="],
          "\(EditorShortcut.zoomIn.printedStrokes.map(\.display))")
    check("zoom in still answers the shifted spelling",
          EditorShortcut.match(characters: "=", modifiers: [.command, .shift], phase: .down) == .zoomIn)
    check("split prints both of its keys",
          EditorShortcut.splitClip.printedStrokes.map(\.display) == ["S", "⌘T"],
          "\(EditorShortcut.splitClip.printedStrokes.map(\.display))")

    // The search narrows. If every query returned everything the field would be
    // decoration, and this check is the difference between the two.
    let cut = EditorShortcutSheet.groups(matching: "cmd x").flatMap(\.shortcuts)
    check("searching 'cmd x' narrows to Cut", cut == [.cutClips],
          "got \(cut.map(\.rawValue))")
    let nothing = EditorShortcutSheet.groups(matching: "zzzz").flatMap(\.shortcuts)
    check("a query nothing matches returns nothing", nothing.isEmpty)
}

// ---------------------------------------------------------------------------
// 4 - The bindings the owner asked for by name, and the ones already shipped.
// ---------------------------------------------------------------------------

@MainActor
func checkNamedBindings() {
    let cmd: NSEvent.ModifierFlags = [.command]
    let cmdShift: NSEvent.ModifierFlags = [.command, .shift]
    let opt: NSEvent.ModifierFlags = [.option]
    let none: NSEvent.ModifierFlags = []
    func m(_ c: String, _ f: NSEvent.ModifierFlags) -> EditorShortcut? {
        EditorShortcut.match(characters: c, modifiers: f, phase: .down)
    }

    // The three the owner named.
    check("S splits", m("s", none) == .splitClip)
    check("cmd-X cuts", m("x", cmd) == .cutClips)
    check("cmd-C copies", m("c", cmd) == .copyClips)

    // Split kept its old key as well as gaining S.
    check("cmd-T still splits", m("t", cmd) == .splitClip)
    check("cmd-E is still Export", m("e", cmd) == .export)
    check("cmd-shift-E is unbound", m("e", cmdShift) == nil)

    // Nothing that already worked moved.
    check("cmd-Z is undo", m("z", cmd) == .undo)
    check("cmd-shift-Z is redo", m("z", cmdShift) == .redo)
    check("space is play/pause", m(" ", none) == .playPause)
    check("cmd-0 fits", m("0", cmd) == .zoomToFit)
    check("cmd-= zooms in", m("=", cmd) == .zoomIn)
    check("cmd-shift-= zooms in too", m("=", cmdShift) == .zoomIn)
    check("cmd-minus zooms out", m("-", cmd) == .zoomOut)
    check("cmd-V pastes", m("v", cmd) == .pasteClips)
    check("cmd-A selects all", m("a", cmd) == .selectAllClips)
    check("cmd-shift-A deselects", m("a", cmdShift) == .deselectAll)
    check("cmd-D duplicates", m("d", cmd) == .duplicateClips)
    check("cmd-slash opens the sheet", m("/", cmd) == .shortcutSheet)
    for spelling in ["\u{8}", "\u{7F}", "\u{F728}"] {
        check("every Delete spelling deletes", m(spelling, none) == .deleteSelection)
    }

    // Arrows, with the function/numeric-pad bits macOS really sets on them.
    let arrowFlags: NSEvent.ModifierFlags = [.function, .numericPad]
    check("left nudges", m(EditorKey.left, arrowFlags) == .nudgeBack)
    check("right nudges", m(EditorKey.right, arrowFlags) == .nudgeForward)
    check("shift-left extends", m(EditorKey.left, arrowFlags.union(.shift)) == .extendSelectionBack)
    check("shift-right extends", m(EditorKey.right, arrowFlags.union(.shift)) == .extendSelectionForward)
    check("option-left goes to the previous edge", m(EditorKey.left, arrowFlags.union(.option)) == .previousEdge)
    check("option-right goes to the next edge", m(EditorKey.right, arrowFlags.union(.option)) == .nextEdge)
    check("up picks the track above", m(EditorKey.up, arrowFlags) == .selectTrackAbove)
    check("down picks the track below", m(EditorKey.down, arrowFlags) == .selectTrackBelow)
    check("home goes to the start", m(EditorKey.home, [.function]) == .jumpToStart)
    check("end goes to the end", m(EditorKey.end, [.function]) == .jumpToEnd)

    // The bare letters.
    check("B compares", m("b", none) == .bypassHold)
    check("L loops", m("l", none) == .toggleLoop)
    check("I sets the loop in", m("i", none) == .setLoopIn)
    check("O sets the loop out", m("o", none) == .setLoopOut)
    check("M marks", m("m", none) == .addMarker)
    check("option-M mutes", m("m", opt) == .toggleTrackMute)
    check("option-S solos", m("s", opt) == .toggleTrackSolo)

    // **The list of unmodified keys, asserted whole.** Every bare key is a key
    // somebody can no longer type when a text field is not focused, so the set
    // is spelled out here and a new one has to be added on purpose rather than
    // arriving as a side effect of somebody's convenient mnemonic.
    let bare = Set(
        EditorShortcut.chordOwners.keys
            .filter { $0.modifiers.isEmpty }
            .map(\.characters)
    )
    let expected: Set<String> = [
        " ", "\u{8}", "\u{7F}", "\u{F728}",
        EditorKey.up, EditorKey.down, EditorKey.left, EditorKey.right,
        EditorKey.home, EditorKey.end,
        "b", "s", "l", "i", "o", "m"
    ]
    check("the unmodified keys are exactly the ones this pass agreed to",
          bare == expected,
          "unexpected: \(bare.subtracting(expected).sorted()); "
          + "gone: \(expected.subtracting(bare).sorted())")

    // Letters that stay typeable.
    for letter in ["c", "v", "t", "x", "d", "a", "z", "e", "r", "0", "="] {
        check("plain \(letter) is not a shortcut", m(letter, none) == nil)
    }
}

// ---------------------------------------------------------------------------
// 5 - Key-up and key-repeat policy.
// ---------------------------------------------------------------------------

@MainActor
func checkPhases() {
    for shortcut in EditorShortcut.allCases {
        for stroke in shortcut.strokes {
            for spelling in stroke.spellings {
                let up = EditorShortcut.match(
                    characters: spelling,
                    modifiers: nsFlags(stroke.modifiers),
                    phase: .up
                )
                if shortcut == .bypassHold {
                    check("bypass answers the key coming back up", up == .bypassHold)
                } else {
                    check("\(shortcut.rawValue) ignores a key-up", up == nil, "got \(String(describing: up))")
                }
            }
        }
    }

    // A held key must never repeat a change to the document.
    let destructive: [EditorShortcut] = [
        .splitClip, .cutClips, .copyClips, .pasteClips, .duplicateClips,
        .deleteSelection, .undo, .redo, .addMarker, .playPause, .toggleLoop,
        .export, .openFile, .recordSystem, .pasteLink
    ]
    for shortcut in destructive {
        check("holding \(shortcut.rawValue) does not repeat it", !shortcut.repeatsAreMeaningful)
    }
    for shortcut in [EditorShortcut.nudgeBack, .nudgeForward, .zoomIn, .zoomOut] {
        check("holding \(shortcut.rawValue) repeats", shortcut.repeatsAreMeaningful)
    }
}

// ---------------------------------------------------------------------------
// 6 - What Delete removes.
// ---------------------------------------------------------------------------

@MainActor
func checkDeleteTarget() {
    let clipA = UUID(), clipB = UUID(), move = UUID()
    check("clips win over a selected move",
          EditorDeleteTarget.resolve(clipIDs: [clipA], moveID: move) == .clips([clipA]))
    check("with no clips selected, the move goes",
          EditorDeleteTarget.resolve(clipIDs: [], moveID: move) == .move(move))
    check("nothing selected removes nothing",
          EditorDeleteTarget.resolve(clipIDs: [], moveID: nil) == .nothing)
    if case .clips(let ids) = EditorDeleteTarget.resolve(clipIDs: [clipA, clipB], moveID: nil) {
        check("every selected clip goes, not just one", Set(ids) == Set([clipA, clipB]))
    } else {
        Probe.failures.append("two selected clips resolve to .clips")
    }
}

// ---------------------------------------------------------------------------
// 7 - Every entry is wired to something. Fired through the real router.
// ---------------------------------------------------------------------------

@MainActor
func seed(_ store: EditorStore) -> [Track] {
    var trackA = Track()
    trackA.clips = [
        Clip(start: 0, sourceIn: 0, sourceOut: 5),
        Clip(start: 6, sourceIn: 0, sourceOut: 4)
    ]
    let trackB = Track()
    let trackC = Track()
    let tracks = [trackA, trackB, trackC]
    store.document = EditorDocument(tracks: tracks)
    store.playhead = 3
    store.selection = 2...4
    store.selectedClipIDs = [trackA.clips[0].id]
    store.selectedTrackID = trackB.id
    store.selectedMoveID = nil
    store.calls = []
    EditorTimeline.shared.duration = 60
    EditorTimeline.shared.visible = 10
    EditorMarkers.shared.removeAll()
    return tracks
}

@MainActor
func fingerprint(_ store: EditorStore) -> String {
    let clips = store.selectedClipIDs.map(\.uuidString).sorted().joined(separator: ",")
    return [
        store.calls.joined(separator: "+"),
        "\(store.playhead)",
        String(describing: store.selection),
        clips,
        String(describing: store.selectedTrackID),
        "\(EditorMarkers.shared.markers.count)"
    ].joined(separator: "|")
}

@MainActor
func checkWiring() {
    let store = EditorStore()
    var windowCalls: [String] = []
    let router = EditorShortcutRouter(
        store: store,
        onExport: { windowCalls.append("export") },
        onOpenFile: { windowCalls.append("openFile") },
        onPasteLink: { windowCalls.append("pasteLink") },
        onRecord: { windowCalls.append("record") },
        onShowShortcuts: { windowCalls.append("shortcuts") }
    )

    for shortcut in EditorShortcut.allCases {
        _ = seed(store)
        windowCalls = []
        let before = fingerprint(store)
        let did = router.perform(shortcut, phase: .down)
        let after = fingerprint(store)
        check("\(shortcut.rawValue) reports it did something", did,
              "the key would be handed back to the responder chain and beep")
        check("\(shortcut.rawValue) actually reaches the store or the window",
              after != before || !windowCalls.isEmpty,
              "nothing observable changed - the arm matched and called nothing")
    }

    // A handful of arms, named, so a rewire to the wrong verb is caught rather
    // than merely a rewire to nothing.
    _ = seed(store)
    _ = router.perform(.cutClips, phase: .down)
    check("cut copies before it removes", store.calls == ["copyClips", "removeSelectedClips"],
          "\(store.calls)")

    _ = seed(store)
    _ = router.perform(.deleteSelection, phase: .down)
    check("delete takes the whole selection out in one step",
          store.calls == ["removeSelectedClips"],
          "\(store.calls) - one removeClip per id is one undo entry per clip")

    _ = seed(store)
    _ = router.perform(.duplicateClips, phase: .down)
    // Not copy-then-paste. That spelling worked and silently emptied the
    // clipboard, which no undo reaches and nothing on screen reports.
    check("duplicate leaves the clipboard alone", store.calls == ["duplicateClips"],
          "\(store.calls) - copyClips here means duplicating a clip destroys whatever was copied")

    _ = seed(store)
    _ = router.perform(.bypassHold, phase: .down)
    _ = router.perform(.bypassHold, phase: .up)
    check("bypass is told about both edges", store.calls == ["setBypassHeld", "setBypassHeld"],
          "\(store.calls)")

    var tracks = seed(store)
    _ = router.perform(.selectTrackAbove, phase: .down)
    check("up moves to the lane above", store.selectedTrackID == tracks[0].id)
    tracks = seed(store)
    _ = router.perform(.selectTrackBelow, phase: .down)
    check("down moves to the lane below", store.selectedTrackID == tracks[2].id)

    _ = seed(store)
    _ = router.perform(.nextEdge, phase: .down)
    check("the next edge from 3 is the end of the first clip at 5", store.playhead == 5,
          "landed on \(store.playhead)")
    _ = seed(store)
    _ = router.perform(.previousEdge, phase: .down)
    check("the previous edge from 3 is the head of the timeline", store.playhead == 0,
          "landed on \(store.playhead)")

    _ = seed(store)
    _ = router.perform(.setLoopIn, phase: .down)
    check("I moves the loop's start to the playhead", store.selection == 3...4,
          "\(String(describing: store.selection))")
    _ = seed(store)
    _ = router.perform(.setLoopOut, phase: .down)
    check("O moves the loop's end to the playhead", store.selection == 2...3,
          "\(String(describing: store.selection))")

    // The other half of the contract: an arm with nothing to do says so, so the
    // key goes back to the responder chain and beeps instead of dying quietly.
    _ = seed(store)
    store.selectedClipIDs = []
    check("copy with nothing selected gives the key back",
          router.perform(.copyClips, phase: .down) == false)
    check("cut with nothing selected gives the key back",
          router.perform(.cutClips, phase: .down) == false)
    check("duplicate with nothing selected gives the key back",
          router.perform(.duplicateClips, phase: .down) == false)
    store.selectedMoveID = nil
    check("delete with nothing selected gives the key back",
          router.perform(.deleteSelection, phase: .down) == false)
    store.document = nil
    check("the next edge with no document gives the key back",
          router.perform(.nextEdge, phase: .down) == false)
}

// ---------------------------------------------------------------------------
// 8 - The first-responder guard, run rather than read.
//
// This is the assertion the bare letters live or die by. S, B, L, I, O and M
// are all keys someone types into a track name, and the only thing between
// those two facts is `handle` refusing every event while the window's field
// editor holds first responder.
// ---------------------------------------------------------------------------

@MainActor
func checkFirstResponderGuard() {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)

    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
        styleMask: [.titled],
        backing: .buffered,
        defer: false
    )
    let field = NSTextField(frame: NSRect(x: 10, y: 100, width: 200, height: 24))
    field.isEditable = true
    field.isSelectable = true
    window.contentView?.addSubview(field)

    let commands = EditorKeyCommandView(frame: .zero)
    window.contentView?.addSubview(commands)
    window.orderFront(nil)

    var fired: [EditorShortcut] = []
    commands.perform = { shortcut, _ in
        fired.append(shortcut)
        return true
    }

    func press(_ characters: String, _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: flags,
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: 1
        )!
    }

    // Without this the rest of the section passes for the wrong reason: an
    // event whose window does not resolve is refused by the *first* guard in
    // `handle`, not by the field-editor one, and every assertion below would be
    // green with the thing under test never running.
    check("the probe's synthetic event resolves to the window under test",
          press("s").window === window,
          "event.window is \(String(describing: press("s").window)); "
          + "the guard assertions below would be vacuous")

    // Nothing focused: the editor takes the key.
    window.makeFirstResponder(window.contentView)
    fired = []
    let takenBack = commands.handle(press("s"))
    check("with no text field focused, S is the editor's",
          takenBack == nil && fired == [.splitClip],
          "returned \(takenBack == nil ? "nil" : "the event"), fired \(fired.map(\.rawValue))")

    // Focused: the field editor is first responder and the key is text.
    let became = window.makeFirstResponder(field)
    check("the probe could focus the text field", became)
    check("a focused NSTextField makes the window's field editor first responder",
          window.firstResponder is NSTextView,
          "firstResponder is \(String(describing: window.firstResponder)) - "
          + "the guard tests `is NSTextView`, so if this is the NSTextField "
          + "itself then every bare letter would be swallowed while typing")

    // Every bare key, plus the modified ones a field editor also wants.
    let typed: [(String, NSEvent.ModifierFlags, String)] = [
        ("s", [], "S while typing a track name would split a clip"),
        ("b", [], "B while typing would silence Melo's processing"),
        ("l", [], "L while typing would toggle looping"),
        ("i", [], "I while typing would move the loop's start"),
        ("o", [], "O while typing would move the loop's end"),
        ("m", [], "M while typing would drop a marker"),
        (" ", [], "Space while typing would start playback instead of a word break"),
        ("\u{7F}", [], "Delete while typing would remove a clip instead of a letter"),
        (EditorKey.left, [.function, .numericPad], "the left arrow would move the playhead, not the caret"),
        ("z", [.command], "cmd-Z while typing would undo a move instead of the sentence"),
        ("x", [.command], "cmd-X while typing would cut a clip instead of the text"),
        ("a", [.command], "cmd-A while typing would select clips instead of the text")
    ]
    for (characters, flags, consequence) in typed {
        fired = []
        let passedOn = commands.handle(press(characters, flags))
        check("while a text field is being edited the key goes to the field",
              passedOn != nil && fired.isEmpty,
              consequence)
    }

    // Clicking into a field while B is held has to end the comparison, or the
    // bypass is stuck with no key down and nothing on screen explaining it.
    window.makeFirstResponder(window.contentView)
    fired = []
    _ = commands.handle(press("b"))
    check("holding B starts the comparison", fired == [.bypassHold])
    fired = []
    window.makeFirstResponder(field)
    _ = commands.handle(press("s"))
    check("focusing a text field with B held releases the bypass",
          fired == [.bypassHold],
          "fired \(fired.map(\.rawValue)) - a stuck bypass is a wrong sound "
          + "with nothing on screen explaining it")

    // A key event belonging to another window is never this window's business.
    window.makeFirstResponder(window.contentView)
    fired = []
    let foreign = NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
        windowNumber: window.windowNumber + 9_999, context: nil,
        characters: "s", charactersIgnoringModifiers: "s", isARepeat: false, keyCode: 1
    )!
    check("a key in another window is passed straight through",
          commands.handle(foreign) != nil && fired.isEmpty)
}

@MainActor
func run() -> Int32 {
    checkReachability()
    checkCollisions()
    checkCheatSheet()
    checkNamedBindings()
    checkPhases()
    checkDeleteTarget()
    checkWiring()
    checkFirstResponderGuard()

    for failure in Probe.failures { print("FAIL \(failure)") }
    if Probe.failures.isEmpty { print("OK \(EditorShortcut.allCases.count) shortcuts") }
    return Probe.failures.isEmpty ? 0 : 1
}

exit(run())
"""


def run_swift_checks() -> None:
    if shutil.which("xcrun"):
        argv = ["xcrun", "swiftc"]
    elif shutil.which("swiftc"):
        argv = ["swiftc"]
    else:
        failures.append("no Swift compiler on PATH - these checks cannot be skipped silently")
        return

    units = [sources / name for name in UNITS]
    missing = [str(unit) for unit in units if not unit.is_file()]
    if missing:
        failures.append(f"keyboard checks: missing source unit(s) {missing}")
        return

    with tempfile.TemporaryDirectory(prefix="melo-verify-editor-keys-") as tmp:
        work = Path(tmp)
        (work / "main.swift").write_text(MAIN_SWIFT)
        (work / "stubs.swift").write_text(STUB_SWIFT)
        binary = work / "checks"
        compiled = subprocess.run(
            argv
            + [
                "-swift-version", SWIFT_VERSION,
                "-target", TARGET,
                "-o", str(binary),
                str(work / "main.swift"),
                str(work / "stubs.swift"),
            ]
            + [str(unit) for unit in units],
            capture_output=True,
            text=True,
        )
        if compiled.returncode != 0:
            errors = sorted({line for line in compiled.stderr.splitlines() if "error:" in line})[:12]
            failures.append(
                "the keyboard checks did not compile:\n        "
                + "\n        ".join(errors or compiled.stderr.splitlines()[:12])
            )
            return

        result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=600)
        reported = [
            line[len("FAIL "):] for line in result.stdout.splitlines() if line.startswith("FAIL ")
        ]
        failures.extend(reported)
        if result.returncode != 0 and not reported:
            failures.append(
                f"the keyboard checks exited {result.returncode} with no verdict: "
                f"{(result.stderr.strip() or result.stdout.strip())[:400]}"
            )


run_swift_checks()


# ---------------------------------------------------------------------------
# Structural: the one claim the executed half can make true and useless.
#
# "Every entry appears in the cheat sheet" is asserted above against
# `EditorShortcutSheet.groups(matching:)`. That assertion is worth nothing if
# `body` enumerates the table a second time and draws from that instead, which
# is the shape CLAUDE.md records under "Checks that prove a rule is correct and
# never prove it is connected". Nothing in this process can render a SwiftUI
# body, so the weak form is used here and only here: the sheet may name
# `EditorShortcut.allCases` once, inside the function under test, and `body`
# has to draw from what that function returns.
# ---------------------------------------------------------------------------

sheet = sources / "Editor/Window/EditorShortcutSheet.swift"
if sheet.is_file():
    text = sheet.read_text(errors="replace")
    live = [
        line for line in text.splitlines()
        if "EditorShortcut.allCases" in line and not line.strip().startswith("//")
    ]
    if len(live) != 1:
        failures.append(
            "EditorShortcutSheet names EditorShortcut.allCases "
            f"{len(live)} time(s), expected exactly 1 (inside groups(matching:)). "
            "A second enumeration is a second list, and the executed "
            "cheat-sheet assertion would stop describing what is drawn."
        )
    if "static func groups" not in text:
        failures.append(
            "EditorShortcutSheet.groups(matching:) is gone - the executed "
            "cheat-sheet assertion has nothing to run"
        )
    if not re.search(r"ForEach\(groups", text):
        failures.append(
            "EditorShortcutSheet's body no longer draws from groups(matching:), "
            "so what this script checks and what the sheet prints are two "
            "different lists"
        )
else:
    failures.append("Editor/Window/EditorShortcutSheet.swift is missing")


if failures:
    print(f"verify-editor-keys: {len(failures)} failure(s)")
    for failure in failures:
        print(f"  - {failure}")
    sys.exit(1)

print("verify-editor-keys: OK")
