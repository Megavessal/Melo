#!/usr/bin/env python3
"""Guards that Melo Edit's expensive machinery is actually reached.

Every check in this file exists because something in the editor was correct,
tested, and **never called**. That is this project's signature defect —
CLAUDE.md:138 records four wiring points severed at once while the tree built,
83 frames rendered, and all eleven verify scripts passed, because each
assertion tested a pure function nothing proved was called.

It happened again on the run that built this feature. `MoveProposer` had 45
executed assertions behind it. `LoudnessMeter` measured a −20 dBFS tone at
−20.0 LUFS. `EditorStore.setAnalysis` had **zero callers**, so
`document.analysis` was nil for the life of every document in a shipping build,
and therefore: "Fix it for me" was permanently disabled, "What I found" said
"Still listening." forever, Normalize and Fix DC offset were unavailable, and
the export before/after never rendered. Every frame showing a measurement came
from `#if MELO_DEV` seeding. Nothing was broken. Nothing was connected.

So the check here is not "does `setAnalysis` appear somewhere". A grep for a
caller passes the moment the symbol is named in dead code, which is a worse
failure than no check at all because it reads as coverage. This **opens a real
WAV through the real store, through the real render actor, and looks at what
`document.analysis` holds afterwards.** Watched fail: deleting the `measure()`
call from `openSource`, and separately deleting the `setAnalysis(report)` line
inside `measure()`, both turn it red with the exact user-facing consequence
named in the failure text.

The structural half covers the one thing an executed check in this process
cannot reach: whether the window layer releases the decoded source when the
window closes. Nothing frees it otherwise, the store is a singleton with no
deinit, and a two-hour file is about 1.4 GB held for the rest of the session.
Written as caller-existence checks because "the call is absent" is the defect;
they are the weak form of assertion and they are used only where the strong
form cannot go.

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
    """Everything the store drags in, minus the UI layer."""
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


# `MeloThemeRemix.openInEditor()` reaches the window controller, and the
# real one drags DockPresence, SettingsManager and the whole root view in
# behind it. Nothing here calls that function; this is the smallest shape that
# satisfies the reference.
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

    // Six seconds of a -20 dBFS 1 kHz tone, written as a real file so the
    // store's real decode path runs.
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
        .appendingPathComponent("melo-wiring-\(UUID().uuidString)", isDirectory: true)
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

    check("the document opened", store.document != nil, store.lastError ?? "no error reported")
    check("the waveform rendered", store.waveform != nil)

    // The assertion this whole file exists for.
    check("opening a file leaves a measurement on the document",
          store.document?.analysis != nil,
          "analysis is nil, so in a shipping build 'Fix it for me' is disabled, "
          + "'What I found' says 'Still listening.' forever, Normalize and Fix DC "
          + "offset are unavailable, and the export before/after cannot render")

    if let report = store.document?.analysis {
        // Not just non-nil: a measurement OF THIS FILE. A hard-coded or stale
        // report would satisfy the check above.
        check("the measurement is of this file, not a placeholder",
              abs(report.integratedLUFS - (-20.0)) < 0.5,
              "measured \(report.integratedLUFS) LUFS for a -20 dBFS tone")
        check("true peak was measured too",
              report.truePeakDBTP.isFinite && report.truePeakDBTP > -30,
              "\(report.truePeakDBTP) dBTP")
        check("the report is dated",
              abs(report.measuredAt.timeIntervalSinceNow) < 300,
              "\(report.measuredAt)")
    }

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
        failures.append(f"editor wiring checks: missing source unit(s) {missing}")
        return

    with tempfile.TemporaryDirectory(prefix="melo-verify-editor-wiring-") as tmp:
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
                "the editor wiring checks did not compile:\n        "
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
                f"the editor wiring checks exited {result.returncode} with no verdict: "
                f"{(result.stderr.strip() or result.stdout.strip())[:400]}"
            )


run_swift_checks()


# ---------------------------------------------------------------------------
# Structural: the release the executed check cannot observe from in here.
# ---------------------------------------------------------------------------

def calls_outside(pattern: re.Pattern[str], defining_file: str) -> list[str]:
    """Files other than `defining_file` with a live (non-comment) line matching."""
    found: list[str] = []
    for path in sorted(sources.rglob("*.swift")):
        relative = str(path.relative_to(sources))
        if relative == defining_file:
            continue
        text = path.read_text(errors="replace")
        for line in text.splitlines():
            stripped = line.strip()
            if stripped.startswith("//") or stripped.startswith("///"):
                continue
            if pattern.search(line):
                found.append(relative)
                break
    return found


# A bare `close(` would match `window.close()` and `pipe.close()` all over the
# tree and pass forever — it did, on the first run of this file. The receiver
# has to be named. These are the spellings the store is reached by; a new one
# means updating this line, which is the correct amount of friction for a check
# whose whole job is to notice a call disappearing.
STORE_CLOSE = re.compile(r"(EditorStore\.shared|\bstore|\bcuttingRoom)\.close\(\)")
FORGET_CACHE = re.compile(r"\.forgetCachedSource\(\)")

if not calls_outside(FORGET_CACHE, "Editor/DSP/RenderEngine.swift"):
    failures.append(
        "nothing calls RenderEngine.forgetCachedSource() — a decoded two-hour "
        "source is about 1.4 GB and nothing else frees it"
    )

if not calls_outside(STORE_CLOSE, "Editor/Core/EditorStore.swift"):
    failures.append(
        "nothing calls EditorStore.close() — so closing Melo Edit "
        "window never writes the session sidecar and never releases the decoded "
        "source (about 1.4 GB for a two-hour file, held for the rest of the "
        "session). The window's root view is the caller this needs."
    )


if failures:
    print(f"verify-editor-wiring: {len(failures)} failure(s)")
    for failure in failures:
        print(f"  - {failure}")
    sys.exit(1)

print("verify-editor-wiring: OK")
