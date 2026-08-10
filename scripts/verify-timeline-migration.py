#!/usr/bin/env python3
"""Guards that a 3.1.x session sidecar still becomes a working 3.2 timeline.

Melo Edit was rebuilt from a single-clip editor into a multitrack timeline. Every
sidecar already on a user's disk was written by the single-clip build: a flat
`moves` list, one source, and no mention of tracks or clips. The migration is
not a conversion pass — it is `EditorSession.restore(into:)` leaving the default
document alone (one track, one clip covering the whole source) and putting the
saved `moves` on the master, which is what those moves always meant.

The failure this guards is silent by construction. A migration that drops the
stack does not crash, does not log, and does not render differently: the user
opens yesterday's file, sees no moves, and assumes they misremembered. Nothing
the compiler, a rendered frame, or a symbol-existence grep can see. CLAUDE.md
records the same shape twice — four wiring points severed while all eleven
verify scripts passed, and a `Codable` fingerprint that was never equal to
itself and would have shipped session restore dead and silent.

So this does not check that a migration function exists. It **writes a real WAV,
hand-writes a 3.1.x-shaped sidecar as raw JSON** — the text the old build wrote,
not something produced by today's encoder, so a decoder change that breaks it is
caught here rather than on a user's machine — **places it where
`EditorSession.fileURL(for:)` looks, and opens the file through the real
`EditorStore`.** Then it reads what actually came back.

What it asserts:

  * the migrated shape — one track, one clip, `start 0`, `sourceIn 0`,
    `sourceOut == source.duration`, one source in the pool
  * the master moves surviving with their ids, enablement and rationales, so
    undo and the stack still refer to the same things
  * the restored destination
  * the restored **saved** analysis rather than a fresh measurement (the saved
    figure is -20.1 LUFS and a re-measure of the tone reads -20.0, so the two
    are distinguishable)
  * that opening a migrated file rewrites nothing on its own, and that the
    first real edit writes back a sidecar still carrying a flat `moves` key —
    downgrade to 3.1.x is a path people take
  * a lossless 3.2 round trip, tracks and master both
  * undo coalescing on a clip drag: twenty ticks are one step, observed through
    where a single undo lands rather than through the private history array
  * split sharing one decoded source, and copy/paste moving clips not samples
  * solo behaving as a render filter — `audibleTrackIDs` changes, the other
    tracks' gain and mute do not
  * `EditorRecents` touching no disk on the main thread

Mutations watched go red
------------------------

Recorded because CLAUDE.md's claim standard asks for the break, not the pass: an
assertion nobody has seen fail is an assumption with a test's formatting.

1. **Dropped `document.master = moves` from `EditorSession.restore(into:)`**
   (`Sources/Melo/Editor/Core/EditorSession.swift:181`) — five failures naming
   the lost stack:

       the saved moves are on the master — 0 master moves
       the first move survived intact — nil
       a disabled move stayed disabled
       move ids survived, so undo and the stack still refer to the same things
       the rewritten sidecar still carries a flat `moves` key, so a downgrade
         to 3.1.x does not lose the stack — Optional(<__NSArray0 …>(

   The fifth is the one worth reading: with the master empty, the next save
   writes an empty `moves` array, so the mutation does not only lose the stack
   in memory — it overwrites the sidecar that held it. The run that first
   watched this mutation recorded four failures; this is the same mutation
   re-run against the promoted script and it reports five. Take the five.

2. **Un-floored the fingerprint mtime** — removed the `.rounded(.down)` in
   `Fingerprint.of`, so an APFS timestamp of `…147.1700807` is compared against
   the whole seconds `.iso8601` wrote. "a 3.1.x sidecar still decodes" fails
   with "load(for:) returned nil, so every saved 3.1.x move stack is discarded
   on upgrade", and the restore assertions fall with it. This one guards a real
   bug fixed 2026-08-09 — see CLAUDE.md, "A `Codable` fingerprint that mixes
   `.iso8601` with a filesystem timestamp is always unequal to itself".

3. **Made the default clip cover half the source** — the coverage and duration
   checks: "the clip covers the whole source" and "the document is as long as
   the file".

4. **Made `EditorSession.sources` / `tracks` non-optional** — the schema trap
   the `load(for:)` comment describes, sprung from the other end. A 3.1.x
   sidecar has neither key, so the decode fails and every legacy sidecar on the
   machine dies on the first open after the update.

Mutations 2, 3 and 4 were watched red in the scratchpad the checks were written
in, before promotion; their transcripts are recorded above rather than re-run
here. Mutation 1 was re-run 2026-08-09 against **this** file, on a copy of the
tree in a scratch directory (nothing under `Sources/` was edited to do it), and
produced the five failures quoted above — so the promotion carried the proving
with it, not just the passing.

Registration is the filename. `scripts/dev-verify-locked.sh:182` runs
`for f in scripts/verify-*.py` — verified by reading it, not assumed.

Standalone `python3`, no arguments. Exits non-zero and prints every failure.
"""
from __future__ import annotations

import glob
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

root = Path(__file__).resolve().parents[1]
sources = root / "Sources/Melo"
failures: list[str] = []


def unit_paths() -> list[str]:
    """Everything the store drags in, minus the UI layer.

    `Window/EditorRecents.swift` is the one Window unit here: the recents list
    owns the main-thread-disk assertion at the end, and it pulls in nothing from
    the view layer beyond `EditorWindowController`, which STUB_SWIFT satisfies.
    """
    listed = sorted(glob.glob(str(sources / "Editor/Core/*.swift")))
    listed += sorted(glob.glob(str(sources / "Editor/DSP/*.swift")))
    listed += [
        str(sources / name)
        for name in [
            "Editor/Window/EditorRecents.swift",
            "Editor/Analysis/DestinationCatalogue.swift",
            "Editor/Analysis/MoveProposer.swift",
            "Editor/Sources/ToolProcessRunner.swift",
            "Editor/Sources/ExternalToolLocator.swift",
            "Editor/Theme/MeloThemeRemix.swift",
            "Audio/Loudness/KWeightingFilter.swift",
            "Audio/Loudness/LoudnessEqualizerMath.swift",
            "Audio/EQ/BiquadMath.swift",
            "Audio/Engine/SoftLimiter.swift",
            "Models/EQSettings.swift",
            "Models/EQPreset.swift",
            "Models/AutoEQProfile.swift",
        ]
    ]
    return listed


# `MeloThemeRemix.openInEditor()` reaches the window controller, and the real
# one drags DockPresence, SettingsManager and the whole root view in behind it.
# Nothing here calls that function; this is the smallest shape that satisfies
# the reference.
STUB_SWIFT = """
import AppKit

@MainActor
final class EditorWindowController {
    static let shared = EditorWindowController()
    func show() {}
}
"""

# Delimited with triple single quotes, not the triple double quotes the sibling
# verify scripts use: the Swift below contains a Swift multiline string literal
# for the hand-written 3.1.x sidecar, and that literal's own delimiter is three
# double quotes. Still raw, so `\(…)` interpolation reaches swiftc intact.
MAIN_SWIFT = r'''
import Foundation

// A 3.1.x sidecar, written by hand in the old shape: one source, a flat move
// list, and no mention of tracks or clips. Nothing in this file constructs an
// `EditorSession` to produce it — the JSON below is the text a 3.1.x build
// wrote, so a decoder change that breaks it is caught here rather than on a
// user's machine.

@MainActor
func run() async -> Int32 {
    var failures: [String] = []
    func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
        if !ok {
            let extra = detail()
            failures.append(extra.isEmpty ? name : "\(name) — \(extra)")
        }
    }

    // MARK: A real file on disk, so the fingerprint is a real fingerprint.

    let rate = 48_000.0
    let frames = Int(rate * 6)
    var samples = [Float](repeating: 0, count: frames * 2)
    let amplitude = Float(pow(10.0, -20.0 / 20.0))
    for frame in 0..<frames {
        let value = amplitude * Float(sin(2 * Double.pi * 1000 * Double(frame) / rate))
        samples[frame * 2] = value
        samples[frame * 2 + 1] = value
    }
    let block = PCMBlock(samples: samples, sampleRate: rate, channelCount: 2)

    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("melo-migration-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("tone.wav")

    do {
        try AudioFileIO.encodeNatively(block, settings: ExportSettings(format: .wav, destinationURL: url))
    } catch {
        print("FAIL could not write the test file — \(error)")
        return 1
    }

    // MARK: The hand-written 3.1.x sidecar.

    let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
    let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
        .contentModificationDate ?? Date()
    let formatter = ISO8601DateFormatter()
    // Whole seconds, the way `.iso8601` encodes and the way `Fingerprint.of`
    // floors. A 3.1.x build wrote exactly this.
    let flooredMTime = formatter.string(
        from: Date(timeIntervalSince1970: modified.timeIntervalSince1970.rounded(.down))
    )
    let savedAt = formatter.string(from: Date())
    let measuredAt = formatter.string(from: Date())

    let legacyJSON = """
    {
      "analysis" : {
        "clippedSampleCount" : 0,
        "dcOffset" : 0.0001,
        "integratedLUFS" : -20.1,
        "interiorSilences" : [],
        "isEffectivelyMono" : true,
        "leadingSilence" : 0,
        "loudnessRangeLU" : 0.5,
        "measuredAt" : "\(measuredAt)",
        "noiseFloorDBFS" : -90,
        "peakDBFS" : -20,
        "spectralTiltDBPerOctave" : -1.5,
        "trailingSilence" : 0,
        "truePeakDBTP" : -19.9
      },
      "destinationID" : "podcast",
      "fingerprint" : {
        "byteCount" : \(size),
        "modifiedAt" : "\(flooredMTime)"
      },
      "moves" : [
        {
          "id" : "11111111-1111-1111-1111-111111111111",
          "isEnabled" : true,
          "kind" : { "gain" : { "dB" : -3 } },
          "rationale" : "Three quieter, to leave the limiter something to do."
        },
        {
          "id" : "22222222-2222-2222-2222-222222222222",
          "isEnabled" : false,
          "kind" : { "highPass" : { "frequency" : 80 } }
        }
      ],
      "savedAt" : "\(savedAt)"
    }
    """

    let sidecar = EditorSession.fileURL(for: url)
    try? FileManager.default.createDirectory(
        at: EditorSession.directory, withIntermediateDirectories: true)
    do {
        try Data(legacyJSON.utf8).write(to: sidecar, options: .atomic)
    } catch {
        print("FAIL could not place the legacy sidecar — \(error)")
        return 1
    }
    defer { try? FileManager.default.removeItem(at: sidecar) }

    // The sidecar has to decode at all. If this is red, every 3.1.x stack on
    // every machine is being thrown away silently on the first open after the
    // update — which is the failure this whole exercise is about.
    let decoded = EditorSession.load(for: url)
    check("a 3.1.x sidecar still decodes", decoded != nil,
          "load(for:) returned nil, so every saved 3.1.x move stack is discarded on upgrade")
    check("its moves survived the decode", decoded?.moves.count == 2,
          "\(decoded?.moves.count ?? -1) moves")
    check("it carries no timeline, as a 3.1.x sidecar cannot",
          decoded?.tracks == nil && decoded?.sources == nil)

    // MARK: Open the file through the real store.

    let store = EditorStore.shared
    await store.open(url)

    guard let document = store.document else {
        print("FAIL the document did not open — \(store.lastError ?? "no error reported")")
        return 1
    }

    check("it loads as exactly one track", document.tracks.count == 1,
          "\(document.tracks.count) tracks")
    check("that track holds exactly one clip", document.tracks.first?.clips.count == 1,
          "\(document.tracks.first?.clips.count ?? -1) clips")
    check("one source in the pool", document.sources.count == 1,
          "\(document.sources.count) sources")

    if let clip = document.tracks.first?.clips.first, let source = document.sources.first {
        check("the clip covers the whole source",
              clip.start == 0 && clip.sourceIn == 0
                  && abs(clip.sourceOut - source.duration) < 1e-9,
              "start \(clip.start), in \(clip.sourceIn), out \(clip.sourceOut), source \(source.duration)")
        check("the clip points at the source in the pool", clip.sourceID == source.id)
        check("the document is as long as the file",
              abs(document.duration - source.duration) < 1e-9,
              "\(document.duration) vs \(source.duration)")
        check("nothing was put on the clip", clip.moves.isEmpty && clip.gainDB == 0)
    }

    check("the saved moves are on the master", document.master.count == 2,
          "\(document.master.count) master moves")
    check("nothing was put on the track", document.tracks.first?.moves.isEmpty == true)
    check("the first move survived intact",
          document.master.first?.kind == .gain(dB: -3)
              && document.master.first?.isEnabled == true
              && document.master.first?.rationale?.hasPrefix("Three quieter") == true,
          "\(String(describing: document.master.first))")
    check("a disabled move stayed disabled",
          document.master.last?.kind == .highPass(frequency: 80)
              && document.master.last?.isEnabled == false)
    check("move ids survived, so undo and the stack still refer to the same things",
          document.master.first?.id == UUID(uuidString: "11111111-1111-1111-1111-111111111111"))

    check("the destination came back", document.destination?.id == "podcast",
          "\(String(describing: document.destination?.id))")
    check("the saved measurement came back and was not re-measured",
          document.analysis.map { abs($0.integratedLUFS - (-20.1)) < 1e-9 } == true,
          "\(String(describing: document.analysis?.integratedLUFS)) — "
          + "-20.1 is the saved figure, -20.0 means the file was measured again")

    // The transitional single-track spelling has to agree with the new model,
    // because forty call sites still use it.
    check("document.moves still reads the master", document.moves == document.master)
    check("document.source still reads the pool's first",
          document.source.id == document.sources.first?.id)

    // MARK: What the migrated document writes back.

    // Opening a migrated file writes nothing back on its own — `measure()` is
    // satisfied by the restored report, so no mutation happens and the 3.1.x
    // sidecar is left exactly as it was. It is the first real edit that
    // rewrites it. Make one, then let the debounced write land.
    check("opening a migrated file rewrites nothing on its own",
          (try? Data(contentsOf: sidecar)) == Data(legacyJSON.utf8))
    store.renameTrack(document.tracks[0].id, to: "Voice")
    try? await Task.sleep(for: .milliseconds(500))
    guard let written = try? Data(contentsOf: sidecar),
          let object = try? JSONSerialization.jsonObject(with: written) as? [String: Any] else {
        print("FAIL the migrated document did not write a sidecar back")
        return 1
    }
    check("the rewritten sidecar still carries a flat `moves` key, so a downgrade "
          + "to 3.1.x does not lose the stack",
          (object["moves"] as? [Any])?.count == 2,
          "\(String(describing: object["moves"]))")
    check("it now carries the timeline too", object["tracks"] != nil && object["sources"] != nil)
    check("`savedAt` is still written", object["savedAt"] != nil)

    // MARK: Duplicating a clip must not empty the clipboard.
    //
    // ⌘D was built as copyClips-then-pasteClips. It produced the right clip and
    // took the user's clipboard with it — and a clipboard is not in the
    // document, so undo cannot bring it back and nothing on screen reports it.
    // The stub-store probe in verify-editor-keys.py can only see which method
    // was called; this drives the real store and looks at what came out.
    //
    // **The two clips must be different.** A first version copied clip A and
    // duplicated clip A, so a duplicate that overwrote the clipboard overwrote
    // it with an identical clip and the assertion could not see the defect: the
    // mutation that puts `copyClips(ids)` back at the top of `duplicateClips`
    // ran green. B is trimmed to a length A does not have, and the paste is
    // identified by that length.
    if let trackID = store.document?.tracks.first?.id,
       let sourceID = store.document?.sources.first?.id,
       let clipA = store.document?.tracks.first?.clips.first {

        let clipB = store.addClip(sourceID: sourceID, to: trackID, at: 12.0)
        store.trimClip(clipB, sourceIn: 0.25, sourceOut: 0.75)
        let lengthB = 0.5
        let lengthA = clipA.duration
        check("the fixture's two clips are distinguishable by length",
              abs(lengthA - lengthB) > 0.01,
              "A is \(lengthA)s, B is \(lengthB)s — an assertion that cannot tell them "
              + "apart cannot see a clipboard being overwritten")

        store.copyClips([clipB])
        let countBefore = store.document?.tracks.first?.clips.count ?? 0
        let made = store.duplicateClips([clipA.id])
        check("duplicate adds a clip", made.count == 1, "made \(made.count)")
        check("the duplicate does not land on top of its original",
              store.document?.tracks.first?.clips.first(where: { $0.id == made.first })
                  .map { $0.start >= clipA.end - 1e-9 } == true,
              "a duplicate under its original looks like nothing happened")

        // Paste far to the right, where nothing else is, and read back what
        // arrived. If duplicating overwrote the clipboard this is A's length.
        store.pasteClips(at: 40, track: trackID)
        let pasted = (store.document?.tracks.first?.clips ?? [])
            .filter { $0.start >= 39.5 }
        check("a paste after a duplicate still pastes something", pasted.count == 1,
              "\(pasted.count) clips landed at 40s")
        check("the clipboard still holds what was copied, not what was duplicated",
              pasted.first.map { abs($0.duration - lengthB) < 1e-6 } == true,
              "pasted \(String(describing: pasted.first?.duration))s, copied B at "
              + "\(lengthB)s, duplicated A at \(lengthA)s — A's length here means "
              + "duplicating emptied the clipboard")
        check("the duplicate and the paste are two separate clips",
              (store.document?.tracks.first?.clips.count ?? 0) == countBefore + 2,
              "\(countBefore) -> \(String(describing: store.document?.tracks.first?.clips.count))")

        // Put the track back the way the round-trip section below expects it.
        let extras = (store.document?.tracks.first?.clips ?? [])
            .filter { $0.id != clipA.id }
            .map(\.id)
        for id in extras { store.removeClip(id) }
        check("the fixture is restored for the sections below",
              store.document?.tracks.first?.clips.count == 1,
              "\(String(describing: store.document?.tracks.first?.clips.count))")
    }

    // MARK: A 3.2 document round-trips.

    let secondTrack = store.addTrack()
    if let sourceID = store.document?.sources.first?.id {
        _ = store.addClip(sourceID: sourceID, to: secondTrack, at: 2.5)
    }
    store.setTrackGain(secondTrack, dB: -6)
    store.renameTrack(secondTrack, to: "Bed")
    if let clipID = store.document?.tracks.first?.clips.first?.id {
        store.trimClip(clipID, sourceIn: 1.0, sourceOut: 5.0)
    }
    let before = store.document

    // The panel set is a parameter rather than a field on the document — it
    // describes the pane, not the sound, and undo copies documents. Two panels,
    // not one, because a set of one survives a bug that flattens the set to its
    // first element and a set of two does not.
    EditorSession.save(store.document!, openPanels: [.chain, .analysis])
    if let session = EditorSession.load(for: url) {
        var fresh = EditorDocument(source: store.document!.sources[0])
        session.restore(into: &fresh)
        check("a two-track document comes back as two tracks", fresh.tracks.count == 2,
              "\(fresh.tracks.count)")
        check("the second track kept its name and gain",
              fresh.tracks.last?.name == "Bed" && fresh.tracks.last?.gainDB == -6,
              "\(String(describing: fresh.tracks.last?.name)) / \(String(describing: fresh.tracks.last?.gainDB))")
        check("the trim came back exactly",
              fresh.tracks.first?.clips.first.map {
                  abs($0.sourceIn - 1.0) < 1e-9 && abs($0.sourceOut - 5.0) < 1e-9
              } == true,
              "\(String(describing: fresh.tracks.first?.clips.first))")
        check("every clip still points at a source in the pool",
              fresh.tracks.allSatisfy { track in
                  track.clips.allSatisfy { clip in fresh.source(clip.sourceID) != nil }
              })
        check("the round trip is lossless",
              fresh.tracks == before?.tracks && fresh.master == before?.master)
        // Which panels were open is the one thing in the sidecar that is not in
        // the document, so `restore(into:)` cannot carry it and nothing above
        // would notice it going missing. A dropped `openPanels` key reopens
        // every file on the destination picker with no error and no clue.
        check("the open panels came back",
              session.openPanels.map(EditorPanel.migrating) == Set<EditorPanel>([.chain, .analysis]),
              "\(String(describing: session.openPanels))")
        // The pre-rename spelling, which every sidecar written before 3.3
        // carries. Dropping it is silent: the Chain was open yesterday and is
        // shut today.
        check("a pre-3.3 sidecar's \"stack\" still opens the Chain",
              EditorPanel.migrating(["stack", "analysis"]) == Set<EditorPanel>([.chain, .analysis]))
    } else {
        failures.append("a 3.2 sidecar did not load back")
    }

    // MARK: Trim is reversible, which is the other thing the model promises.

    if let clipID = store.document?.tracks.first?.clips.first?.id,
       let sourceDuration = store.document?.sources.first?.duration {
        store.trimClip(clipID, sourceIn: 0, sourceOut: sourceDuration)
        let restored = store.document?.tracks.first?.clips.first
        check("dragging a trimmed edge back out restores the whole source",
              restored.map { $0.sourceIn == 0 && abs($0.sourceOut - sourceDuration) < 1e-9 } == true,
              "\(String(describing: restored))")
    }

    // MARK: Undo coalescing — a clip drag is one step, not one per tick.

    // Observed through behaviour rather than through the history array, which
    // is private: if the twenty ticks each pushed an entry, one undo lands on
    // tick nineteen instead of on the state before the drag.
    if let clipID = store.document?.tracks.first?.clips.first?.id,
       let trackID = store.document?.tracks.first?.id {
        let startBefore = store.document?.tracks.first?.clips.first?.start ?? -1
        for tick in 1...20 {
            store.moveClip(clipID, toTrack: trackID, start: Double(tick) * 0.01)
        }
        check("the drag moved the clip",
              store.document?.tracks.first?.clips.first?.start == 0.20,
              "\(String(describing: store.document?.tracks.first?.clips.first?.start))")
        store.undo()
        check("a clip drag is one undo step, landing before the drag rather than "
              + "on its previous tick",
              store.document?.tracks.first?.clips.first?.start == startBefore,
              "\(String(describing: store.document?.tracks.first?.clips.first?.start)) "
              + "— expected \(startBefore)")
    }

    // MARK: Split shares one source; copy and paste move clips, not samples.

    if let clipID = store.document?.tracks.first?.clips.first?.id,
       let clip = store.document?.clip(clipID) {
        let sourceCountBefore = store.document?.sources.count ?? 0
        let right = store.splitClip(clipID, at: clip.start + clip.duration / 2)
        check("split returns the right-hand clip", right != nil)
        check("split does not add a source",
              store.document?.sources.count == sourceCountBefore,
              "\(store.document?.sources.count ?? -1) vs \(sourceCountBefore)")
        if let right, let left = store.document?.clip(clipID),
           let rightClip = store.document?.clip(right) {
            check("both halves share the one decoded source",
                  left.sourceID == rightClip.sourceID)
            check("the halves meet where the cut was",
                  abs(left.end - rightClip.start) < 1e-9
                      && abs(left.sourceOut - rightClip.sourceIn) < 1e-9,
                  "\(left.end) / \(rightClip.start)")
            check("nothing was thrown away",
                  abs((left.duration + rightClip.duration) - clip.duration) < 1e-9)
        }
    }

    if let ids = store.document?.tracks.first?.clips.map(\.id) {
        let countBefore = store.document?.tracks.first?.clips.count ?? 0
        let sourcesBefore = store.document?.sources.count ?? 0
        store.copyClips(ids)
        store.pasteClips(at: 30, track: store.document?.tracks.first?.id)
        check("paste adds clips", store.document?.tracks.first?.clips.count == countBefore * 2,
              "\(store.document?.tracks.first?.clips.count ?? -1)")
        check("paste decodes nothing", store.document?.sources.count == sourcesBefore)
        check("pasted clips got new ids",
              Set(store.document?.tracks.first?.clips.map(\.id) ?? []).count == countBefore * 2)
        check("the paste is the selection", store.selectedClipIDs.count == countBefore)
    }

    // MARK: Solo is a filter, not a state change.

    if let first = store.document?.tracks.first?.id, let second = store.document?.tracks.last?.id {
        let gainsBefore = store.document?.tracks.map(\.gainDB)
        let mutesBefore = store.document?.tracks.map(\.isMuted)
        store.toggleSolo(first)
        check("solo silences the others at render time",
              store.document?.audibleTrackIDs == [first],
              "\(String(describing: store.document?.audibleTrackIDs))")
        check("nothing was written to the other track",
              store.document?.tracks.map(\.gainDB) == gainsBefore
                  && store.document?.tracks.map(\.isMuted) == mutesBefore)
        store.toggleSolo(first)
        check("un-soloing restores exactly what was there",
              store.document?.audibleTrackIDs == Set([first, second]))
    }

    // MARK: The last track cannot be removed.

    while (store.document?.tracks.count ?? 0) > 1 {
        store.removeTrack(store.document!.tracks.last!.id)
    }
    store.removeTrack(store.document!.tracks[0].id)
    check("removing the last track is refused", store.document?.tracks.count == 1)

    try? FileManager.default.removeItem(at: EditorSession.fileURL(for: url))

    // MARK: - The recents list does its disk work off the main thread.

    do {
        let scratch = directory.appendingPathComponent("recents", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)

        let present = directory.appendingPathComponent("tone.wav")
        let absent = directory.appendingPathComponent("unplugged-drive.wav")
        func entry(_ at: URL, _ name: String) -> EditorRecent {
            EditorRecent(url: at, displayName: name, formatDescription: "WAV",
                         duration: 6, openedAt: Date(), kind: .file)
        }
        let stored = [entry(present, "tone"), entry(absent, "gone")]
        try? JSONEncoder().encode(stored)
            .write(to: scratch.appendingPathComponent("cutting-room-recents.json"))

        let recents = EditorRecents(directory: scratch)

        // `init` no longer reads the file synchronously, so nothing is known yet.
        check("constructing the list touches no disk on the main thread",
              recents.all.isEmpty && recents.visible.isEmpty,
              "\(recents.all.count) remembered, \(recents.visible.count) visible before any await")

        // Let the load and the availability pass land.
        for _ in 0..<40 where recents.visible.isEmpty {
            try? await Task.sleep(for: .milliseconds(25))
        }

        check("the stored list arrives", recents.all.count == 2, "\(recents.all.count)")
        check("the list shows exactly what it showed before — the remembered "
              + "entries whose files are on disk",
              recents.visible.map(\.url) == [present],
              "\(recents.visible.map(\.displayName))")

        // The synchronous half of the old behaviour that must survive: a
        // forgotten row leaves under the user's hand, not a disk round trip
        // later.
        recents.forget(stored[0])
        check("forgetting a row removes it immediately",
              recents.visible.isEmpty && recents.all.count == 1,
              "\(recents.visible.count) visible, \(recents.all.count) remembered")

        let kept = await EditorRecents.keptSourcesExist()
        check("the kept-sources question answers without blocking a caller",
              kept == !((try? FileManager.default.contentsOfDirectory(
                  at: EditorSourceStore.directory,
                  includingPropertiesForKeys: nil,
                  options: [.skipsHiddenFiles])) ?? []).isEmpty)
    }

    for failure in failures { print("FAIL \(failure)") }
    if failures.isEmpty { print("OK") }
    return failures.isEmpty ? 0 : 1
}

exit(await run())
'''


def run_swift_checks() -> None:
    if shutil.which("xcrun"):
        argv = ["xcrun", "swiftc"]
    elif shutil.which("swiftc"):
        argv = ["swiftc"]
    else:
        failures.append("no Swift compiler on PATH — these checks cannot be skipped silently")
        return

    units = unit_paths()
    missing = [unit for unit in units if not Path(unit).is_file()]
    if missing:
        failures.append(f"timeline migration checks: missing source unit(s) {missing}")
        return

    with tempfile.TemporaryDirectory(prefix="melo-verify-timeline-migration-") as tmp:
        work = Path(tmp)
        (work / "main.swift").write_text(MAIN_SWIFT)
        (work / "stub.swift").write_text(STUB_SWIFT)
        binary = work / "checks"
        compiled = subprocess.run(
            argv
            + [
                "-swift-version", "6",
                "-O",
                "-o", str(binary),
                str(work / "main.swift"),
                str(work / "stub.swift"),
            ]
            + units,
            capture_output=True,
            text=True,
        )
        if compiled.returncode != 0:
            errors = sorted({line for line in compiled.stderr.splitlines() if "error:" in line})[:12]
            failures.append(
                "the timeline migration checks did not compile:\n        "
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
                f"the timeline migration checks exited {result.returncode} with no verdict: "
                f"{(result.stderr.strip() or result.stdout.strip())[:400]}"
            )


run_swift_checks()


if failures:
    print(f"verify-timeline-migration: {len(failures)} failure(s)")
    for failure in failures:
        print(f"  - {failure}")
    sys.exit(1)

print("verify-timeline-migration: OK")
