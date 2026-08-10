#!/usr/bin/env python3
"""Proves that bypass and the compare lane describe two genuinely different sounds.

Every visual check this feature has can pass while the feature does nothing.

A bypass whose filter matched no move would render the identical buffer, splice
it at the identical sample, light the identical control, and change no pixel
anywhere. A compare lane whose "processed" picture came back equal to the raw
one would draw two waveforms, in two weights, over one span of the ruler, and
look exactly like a working comparison. Both failures are silent, and both are
the shape `CLAUDE.md:138` records — a rule that is correct, tested, and not
connected to anything.

So this **executes the shipping split**. `EditorChain.arrangementOnly` is the
one definition of what bypass plays; it used to be a private static on
`EditorPlayback`, which holds an `AVAudioEngine` and cannot be reached from a
headless process, which is precisely why it had never been asserted. It is in
`Editor/Core` now, and this opens a real WAV through the real `EditorStore`,
puts a real chain on it, renders both sides through the real `RenderEngine`, and
compares samples.

Six things are asserted and each names the user-facing consequence of its
failure:

  1. Bypass changes the samples at all.
  2. The difference is not merely a level change — the two are still different
     after being matched for RMS. A bypass that only turned the volume down
     would satisfy (1) and would not be a bypass.
  3. Bypass does not change the LENGTH. `EditorPlayback.restart(at:)` splices
     the two renders at the same sample position; a different length is a jump
     rather than a comparison.
  4. A move that shapes TIME survives the filter. Without this, (1) passes for
     a filter that strips everything, which would move the audio under the
     playhead.
  5. A chain made only of time-shaping moves is bit-for-bit unchanged by the
     filter — the complement of (4), and what stops "strip everything" from
     passing (1) through (4).
  6. The compare lane's invariant: one source through the tone-and-level chain
     produces a waveform of the SAME duration and DIFFERENT buckets from the
     same source through nothing. Same duration is what lets the strip be drawn
     against the clip's own span of the ruler; different buckets is the whole
     feature. This is the claim no rendered frame can make, because the snapshot
     harness has no file to decode and seeds the processed picture by hand.

Plus one structural check, which is the weak form and is used only where the
strong form cannot reach: that `EditorPlayback` still calls
`EditorChain.arrangementOnly`. Nothing headless can drive an `AVAudioPlayerNode`,
so whether the *player* swaps buffers stays unverified here.

Standalone `python3`, no arguments. Exits non-zero and prints every failure.
"""
from __future__ import annotations

import glob
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

root = Path(__file__).resolve().parents[1]
sources = root / "Sources/Melo"
failures: list[str] = []


def unit_paths() -> list[str]:
    """Everything the store and the render actor drag in, minus the UI layer.

    Deliberately the same set `verify-editor-wiring.py` compiles. Two verify
    scripts that build the editor from two different file lists would drift, and
    the first symptom would be one of them silently not covering a file.
    """
    listed = sorted(glob.glob(str(sources / "Editor/Core/*.swift")))
    listed += sorted(glob.glob(str(sources / "Editor/DSP/*.swift")))
    listed += [
        str(sources / name)
        for name in [
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
# one drags the whole root view in behind it. Nothing here calls that function.
STUB_SWIFT = """
import AppKit

@MainActor
final class EditorWindowController {
    static let shared = EditorWindowController()
    func show() {}
}
"""

MAIN_SWIFT = r"""
import Foundation

@MainActor
func run() async -> Int32 {
    var failures: [String] = []
    func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
        if !ok {
            let extra = detail()
            failures.append(extra.isEmpty ? name : "\(name) - \(extra)")
        }
    }

    // Six seconds of something a chain can visibly change: a 100 Hz tone under a
    // 1 kHz tone, with a louder burst every second.
    //
    // The two frequencies are what makes assertion 2 mean anything. A high-pass
    // at 400 Hz removes the low tone and leaves the high one, so the two renders
    // differ in SHAPE and not only in level — which a chain of nothing but
    // `gain` could not demonstrate, and which is the difference between a bypass
    // and a volume control. The bursts give the limiter something to do.
    let rate = 48_000.0
    let frames = Int(rate * 6)
    var samples = [Float](repeating: 0, count: frames * 2)
    for frame in 0..<frames {
        let time = Double(frame) / rate
        let burst = (frame / Int(rate)) % 2 == 0 ? 1.0 : 2.6
        let low = pow(10.0, -14.0 / 20.0) * sin(2 * Double.pi * 100 * time)
        let high = pow(10.0, -20.0 / 20.0) * sin(2 * Double.pi * 1000 * time)
        let value = Float(min(max((low + high) * burst, -1), 1))
        samples[frame * 2] = value
        samples[frame * 2 + 1] = value
    }
    let block = PCMBlock(samples: samples, sampleRate: rate, channelCount: 2)

    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("melo-compare-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("tone.wav")

    do {
        try AudioFileIO.encodeNatively(
            block,
            settings: ExportSettings(format: .wav, destinationURL: url)
        )
    } catch {
        print("FAIL could not write the test file - \(error)")
        return 1
    }

    let store = EditorStore.shared
    await store.open(url)
    guard let opened = store.document else {
        print("FAIL the document did not open - \(store.lastError ?? "no error reported")")
        return 1
    }
    let engine = store.renderEngine

    // MARK: The chain
    //
    // One move of each kind that matters, and one that must survive the filter.
    // `trim` is the survivor: it moves where every later sample sits, so if the
    // filter drops it the bypass buffer is a different length and the splice
    // becomes a jump.
    let toneAndLevel: [Move] = [
        Move(kind: .gain(dB: 7), rationale: nil),
        Move(kind: .highPass(frequency: 400), rationale: nil),
        Move(kind: .limiter(ceilingDBTP: -1, releaseMS: 60), rationale: nil)
    ]
    let shapesTime: [Move] = [Move(kind: .trim(start: 0.5, end: 5.0), rationale: nil)]

    var edited = opened
    edited.master = shapesTime + toneAndLevel
    let bypassed = EditorChain.arrangementOnly(edited)

    func render(_ document: EditorDocument, _ label: String) async -> PCMBlock? {
        do {
            return try await engine.render(document, range: nil, progress: { _ in })
        } catch {
            failures.append("\(label) would not render - \(error)")
            return nil
        }
    }

    guard let wet = await render(edited, "the edited chain"),
          let dry = await render(bypassed, "the bypassed chain") else {
        for failure in failures { print("FAIL \(failure)") }
        return 1
    }

    func rms(_ block: PCMBlock) -> Double {
        guard !block.samples.isEmpty else { return 0 }
        var total = 0.0
        for sample in block.samples { total += Double(sample) * Double(sample) }
        return (total / Double(block.samples.count)).squareRoot()
    }

    // MARK: 1 — bypass changes the samples

    check("the bypass render is the same LENGTH as the edited one",
          wet.frameCount == dry.frameCount,
          "\(wet.frameCount) frames edited against \(dry.frameCount) bypassed. "
          + "EditorPlayback splices the two at the same sample position, so a "
          + "length difference means holding B jumps the playhead instead of "
          + "swapping the sound under it")

    let compared = min(wet.samples.count, dry.samples.count)
    var largest = 0.0
    for index in 0..<compared {
        largest = max(largest, abs(Double(wet.samples[index]) - Double(dry.samples[index])))
    }
    check("bypass produces DIFFERENT samples from the edited chain",
          largest > 1e-4,
          "the largest difference across \(compared) samples is \(largest). A bypass "
          + "that renders the identical buffer plays the identical sound, lights "
          + "the identical control, greys the identical clips, and tells the user "
          + "their edit did nothing — or that it did something, when it did not. "
          + "Nothing else in this project can catch that")

    // MARK: 2 — and the difference is not merely level

    let wetRMS = rms(wet)
    let dryRMS = rms(dry)
    check("both renders carry signal", wetRMS > 1e-5 && dryRMS > 1e-5,
          "edited RMS \(wetRMS), bypassed RMS \(dryRMS)")

    if wetRMS > 1e-5 && dryRMS > 1e-5 {
        // Match the two for level, then look again. A chain of nothing but gain
        // would collapse to zero here; this one carries a high-pass, so what is
        // left is the 100 Hz tone the filter removed.
        let matchScale = wetRMS / dryRMS
        var shape = 0.0
        for index in 0..<compared {
            shape = max(
                shape,
                abs(Double(wet.samples[index]) - Double(dry.samples[index]) * matchScale)
            )
        }
        check("the difference is a change of SHAPE and not only of level",
              shape > 1e-3,
              "after matching the two for RMS the largest remaining difference is "
              + "\(shape). A bypass that only changed the volume would satisfy the "
              + "check above and would not be a bypass — the tone moves in the "
              + "chain are what the user is judging")
    }

    // MARK: 3 and 4 — the time-shaping move survived

    let trimmed = 5.0 - 0.5
    check("the bypass render keeps the TRIM",
          abs(dry.duration - trimmed) < 0.05,
          "the bypassed render is \(dry.duration)s and the trim asks for \(trimmed)s. "
          + "A filter that stripped the trim as well would satisfy every difference "
          + "check above by moving the audio in time, which is the one thing bypass "
          + "must never do")

    // MARK: 5 — a time-only chain is untouched

    var timeOnly = opened
    timeOnly.master = shapesTime
    let timeOnlyBypassed = EditorChain.arrangementOnly(timeOnly)
    check("a chain of only time-shaping moves is unchanged by the filter",
          timeOnlyBypassed == timeOnly,
          "arrangementOnly removed something from a stack that contains nothing it "
          + "should remove. The complement of the checks above: without this, "
          + "'strip every move' passes all of them")

    // MARK: 6 — the compare lane draws two different pictures

    let source = opened.source
    let original = EditorChain.isolated(source, through: [])
    let processed = EditorChain.isolated(source, through: EditorChain.toneAndLevel(toneAndLevel))
    do {
        let originalWave = try await engine.waveform(original, range: nil, bucketCount: 2_048)
        let processedWave = try await engine.waveform(processed, range: nil, bucketCount: 2_048)

        check("the compare lane's two pictures cover the SAME span of time",
              abs(originalWave.duration - processedWave.duration) < 0.001,
              "\(originalWave.duration)s raw against \(processedWave.duration)s processed. "
              + "The strip is drawn under the clip against the clip's own span of the "
              + "ruler, so two pictures of different lengths are two pictures of "
              + "different moments stacked on each other — a comparison that is wrong "
              + "everywhere except the first sample")

        check("the compare lane's two pictures have the same number of buckets",
              originalWave.buckets.count == processedWave.buckets.count,
              "\(originalWave.buckets.count) against \(processedWave.buckets.count)")

        var moved = 0
        var widest = 0.0
        let pairs = min(originalWave.buckets.count, processedWave.buckets.count)
        for index in 0..<pairs {
            let before = originalWave.buckets[index]
            let after = processedWave.buckets[index]
            let delta = max(
                abs(Double(before.maximum) - Double(after.maximum)),
                abs(Double(before.rms) - Double(after.rms))
            )
            widest = max(widest, delta)
            if delta > 1e-4 { moved += 1 }
        }
        check("the compare lane draws two DIFFERENT waveforms",
              pairs > 0 && moved > pairs / 2 && widest > 1e-3,
              "\(moved) of \(pairs) buckets moved, widest \(widest). The lane exists to "
              + "show what the chain did; two identical pictures drawn in two weights "
              + "under one clip look exactly like a working comparison and are not one. "
              + "No rendered frame can catch this — the snapshot harness has no file to "
              + "decode and seeds the processed picture by hand")
    } catch {
        failures.append("the compare lane's waveforms would not render - \(error)")
    }

    // MARK: The staleness stamp

    // A stamp that never changed would freeze every compare picture at whatever
    // the chain was when it was first drawn: the user would edit a move, watch
    // the clip stay exactly as it was, and conclude the move does nothing.
    var stampA = opened
    stampA.master = [Move(kind: .gain(dB: 3), rationale: nil)]
    var stampB = opened
    stampB.master = [Move(kind: .gain(dB: 9), rationale: nil)]
    check("the chain stamp notices a move's VALUE changing",
          EditorChain.stamp(stampA) != EditorChain.stamp(stampB),
          "+3 dB and +9 dB stamp identically, so a processed picture would never be "
          + "re-rendered when the user drags a slider")
    check("the chain stamp is stable for the same chain",
          EditorChain.stamp(stampA) == EditorChain.stamp(stampA),
          "the same document stamps two different ways, so every drawing pass would "
          + "throw the compare pictures away and re-render them")

    var disabled = stampA
    disabled.master[0].isEnabled = false
    check("the chain stamp notices a move being switched off",
          EditorChain.stamp(stampA) != EditorChain.stamp(disabled),
          "switching a move off leaves the compare picture showing it")

    check("every job was retired", store.jobs.isEmpty, "\(store.jobs.count) left running")

    // The debounced write leaves a sidecar for this temporary file.
    try? await Task.sleep(for: .milliseconds(400))
    try? FileManager.default.removeItem(at: EditorSession.fileURL(for: url))

    for failure in failures { print("FAIL \(failure)") }
    if failures.isEmpty { print("OK") }
    return failures.isEmpty ? 0 : 1
}

exit(await run())
"""


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
        failures.append(f"compare/bypass checks: missing source unit(s) {missing}")
        return

    with tempfile.TemporaryDirectory(prefix="melo-verify-compare-bypass-") as tmp:
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
                "the compare/bypass checks did not compile:\n        "
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
                f"the compare/bypass checks exited {result.returncode} with no verdict: "
                f"{(result.stderr.strip() or result.stdout.strip())[:400]}"
            )


run_swift_checks()


# ---------------------------------------------------------------------------
# Structural: the two wires the executed check cannot reach from in here.
#
# Both are caller-existence checks, which this project's anchor names as the
# weak form. They are used only where the strong form cannot go: driving an
# `AVAudioPlayerNode` and a SwiftUI `Canvas` both need a UI process, and neither
# is reachable from a compiled-in-a-temp-directory binary. What each one buys is
# narrow and is written down so nobody reads it as more.
# ---------------------------------------------------------------------------

def live_lines(path: Path) -> list[str]:
    """Non-comment lines, so a mention in prose does not satisfy a check."""
    out: list[str] = []
    for line in path.read_text(errors="replace").splitlines():
        stripped = line.strip()
        if stripped.startswith("//"):
            continue
        out.append(line)
    return out


playback = sources / "Editor/Views/Waveform/EditorPlayback.swift"
if not playback.is_file():
    failures.append(f"missing {playback.relative_to(root)}")
else:
    text = "\n".join(live_lines(playback))
    if not re.search(r"EditorChain\.arrangementOnly\(", text):
        failures.append(
            "EditorPlayback no longer calls EditorChain.arrangementOnly — so what "
            "hold-to-bypass plays is no longer the thing this script proved is "
            "different, and the compare lane and the ear would be describing two "
            "different edits"
        )
    if not re.search(r"\bdry\s*=\s*buffer\b", text):
        failures.append(
            "EditorPlayback never adopts the bypass buffer it renders. The render "
            "would run, the control would light, and the sound would not change"
        )

lanes = sources / "Editor/Views/Waveform/EditorTimelineLanes.swift"
if not lanes.is_file():
    failures.append(f"missing {lanes.relative_to(root)}")
else:
    text = "\n".join(live_lines(lanes))
    if "clip.original" not in text:
        failures.append(
            "the lanes canvas never reads a clip's `original` columns, so the compare "
            "strip is drawing nothing or drawing the clip's own picture twice"
        )
    if "isOriginal: !isBypassed" not in text:
        failures.append(
            "the compare strip's ink no longer inverts with bypass. The two pictures "
            "would draw at the same weight in both states, and a still frame could no "
            "longer say which of them the user is hearing — which is the only marker "
            "this feature has"
        )

store = sources / "Editor/Core/EditorStore.swift"
if store.is_file():
    text = "\n".join(live_lines(store))
    if "showsCompareLane = false" not in text:
        failures.append(
            "EditorStore.setForSnapshot no longer clears showsCompareLane, so every "
            "timeline frame in the render suite depends on the preference of whoever "
            "ran it — lanes at one height on one machine and another height on the next"
        )


if failures:
    print(f"verify-compare-bypass: {len(failures)} failure(s)")
    for failure in failures:
        print(f"  - {failure}")
    sys.exit(1)

print("verify-compare-bypass: OK")
