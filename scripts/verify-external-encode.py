#!/usr/bin/env python3
"""Guards MP3 and Opus export, which goes out through an `ffmpeg` nobody here has.

`ffmpeg` is not installed on the build machine and will not be. So the only way
to prove argument construction, progress parsing, error reporting and
cancellation is to substitute the binary and keep everything else real: this
file writes small shell scripts that speak ffmpeg's command line and emit
ffmpeg's `-progress` format, then drives `AudioFileIO.encode` through the
**real** `SystemToolProcessRunner` with the **real** `Process`, the real pipes
and real signals. Only the executable is a stand-in.

That matters more than it sounds. CLAUDE.md records four wiring points being
severed at once while every assertion stayed green, because each one tested a
pure function nothing proved was called. So the argument check here does not
just compare `ffmpegArguments(input:settings:)` against an expected array — it
compares the argv a spawned process **actually received** against what that
function returns, which is the only version that fails when the two stop being
connected.

Five things are pinned, in descending order of what they would cost if wrong.

1. **Cancellation intent is checked before the exit code.** A tool killed by a
   signal can still report exit 0 — `bash` with `trap 'exit 0' TERM` does
   exactly that, and the `ffmpeg-trap0` stand-in is that case on purpose. If the
   order in `encodeThroughFFmpeg` is ever flipped, a user pressing Stop gets a
   cheerful "exported" for a file that was never written.
2. **A refusal from the progress sink really kills the child.** Not "sets a flag
   and waits": the elapsed-time bound fails if the 30-second stand-in is allowed
   to run to completion.
3. **`out_time_ms` carries microseconds.** This is a misnomer in ffmpeg itself,
   not a units bug here, and it is the single most likely thing for a future
   contributor to "correct". Pinned twice — once on the parser, once end to end
   through a stand-in that emits it — so a well-meaning divide by 1000 fails.
4. **A non-zero exit surfaces ffmpeg's own last stderr line.** "Unknown encoder
   'libmp3lame'" is actionable; "the export failed" sends someone to the wrong
   place.
5. **The staged intermediate is real, and it is gone afterwards.** The stand-in
   measures the WAV it was handed, so an empty file fails; and no
   `MeloEncode-*` directory may survive any path, including the throwing ones.

Standalone `python3`, no arguments. Exits non-zero and prints every failure.
"""
from __future__ import annotations

import os
import shutil
import stat
import subprocess
import sys
import tempfile
from pathlib import Path

root = Path(__file__).resolve().parents[1]
sources = root / "Sources/Melo"
failures: list[str] = []

# Listed rather than globbed, so a new dependency creeping into the encode path
# arrives as a compile error naming it rather than as a silently narrower check.
SWIFT_UNITS = [
    "Editor/Core/EditorTypes.swift",
    "Editor/Core/MoveKindDisplay.swift",
    "Editor/Core/AudioFileIO.swift",
    "Editor/Sources/ToolProcessRunner.swift",
    "Editor/Sources/ExternalToolLocator.swift",
    "Models/EQSettings.swift",
    "Models/AutoEQProfile.swift",
    "Audio/EQ/BiquadMath.swift",
]

# --------------------------------------------------------------------------
# The stand-ins. Each speaks ffmpeg's command line; none of them is ffmpeg.
# --------------------------------------------------------------------------

STAND_INS = {
    # Succeeds, records what it was given, and measures the WAV it was handed.
    # Emits `out_time_us=N/A` first, which is what real ffmpeg does before the
    # first frame, then a deliberate mix of `_us` and `_ms` keys.
    "ffmpeg-ok": r"""#!/bin/bash
here="$(cd "$(dirname "$0")" && pwd)"
printf '%s\n' "$@" > "$here/argv-ok.txt"
prev=""; input=""
for a in "$@"; do
  if [ "$prev" = "-i" ]; then input="$a"; fi
  prev="$a"
done
if [ -n "$input" ] && [ -f "$input" ]; then
  wc -c < "$input" | tr -d ' ' > "$here/input-size.txt"
else
  echo 0 > "$here/input-size.txt"
fi
echo "out_time_us=N/A"
echo "out_time_us=0"
echo "out_time_ms=1000000"
echo "out_time_us=2000000"
echo "progress=end"
out="${@: -1}"
: > "$out"
exit 0
""",
    # Fails the way a build without libmp3lame fails.
    "ffmpeg-fail": r"""#!/bin/bash
echo "ffmpeg version 7.1.1 Copyright (c) 2000-2025 the FFmpeg developers" >&2
echo "Unknown encoder 'libmp3lame'" >&2
exit 1
""",
    # Emits one progress line then hangs. `exec` so the signal reaches the
    # sleep itself and the pipe closes with it — otherwise an orphaned child
    # holds stdout open and the runner waits for EOF that is not coming.
    "ffmpeg-slow": r"""#!/bin/bash
echo "out_time_us=1000000"
exec sleep 30
""",
    # Hangs, and exits 0 when told to stop. This is the case where the exit code
    # lies: `didSucceed` is true for a process the user cancelled.
    "ffmpeg-trap0": r"""#!/bin/bash
trap 'exit 0' TERM
echo "out_time_us=1000000"
sleep 20 >/dev/null 2>&1 &
wait
exit 0
""",
}

MAIN_SWIFT = r"""
import Foundation

var failures: [String] = []

func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    if !ok {
        let extra = detail()
        failures.append(extra.isEmpty ? name : "\(name) - \(extra)")
    }
}

func near(_ actual: Double, _ expected: Double, _ tolerance: Double) -> Bool {
    actual.isFinite && abs(actual - expected) <= tolerance
}

/// Collects the fractions the sink is handed, from whatever thread hands them over.
///
/// **Refuses exactly once**, which is not a detail. A sink that keeps saying no
/// also refuses the final `report(progress, 1)` at the end of a *successful*
/// encode, and that throws `CancellationError` all on its own — so the
/// exit-code-0 assertion below passed for the wrong reason and stayed green
/// through a mutation that deleted the very check it claims to pin. Found by
/// mutating, not by reading. One refusal is also what a user pressing Stop
/// actually does.
final class Fractions: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Double] = []
    private var refused = false
    /// Refuse once the bar passes this, so the refusal lands during ffmpeg
    /// rather than during the staging write.
    let refuseAbove: Double
    init(refuseAbove: Double = 2) { self.refuseAbove = refuseAbove }

    func accept(_ fraction: Double) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        values.append(fraction)
        guard fraction > refuseAbove, !refused else { return true }
        refused = true
        return false
    }

    var all: [Double] {
        lock.lock(); defer { lock.unlock() }
        return values
    }
}

let work = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let temporaryRoot = FileManager.default.temporaryDirectory

func scratchDirectoryCount() -> Int {
    let contents = (try? FileManager.default.contentsOfDirectory(atPath: temporaryRoot.path)) ?? []
    return contents.filter { $0.hasPrefix("MeloEncode-") }.count
}

let scratchBefore = scratchDirectoryCount()

let rate = 48_000.0
let seconds = 2.0
func tone() -> PCMBlock {
    let frames = Int(seconds * rate)
    var samples = [Float](repeating: 0, count: frames * 2)
    for frame in 0..<frames {
        let value = Float(0.25 * sin(2 * Double.pi * 440 * Double(frame) / rate))
        samples[frame * 2] = value
        samples[frame * 2 + 1] = value
    }
    return PCMBlock(samples: samples, sampleRate: rate, channelCount: 2)
}
let block = tone()

func standIn(_ name: String) -> URL { work.appendingPathComponent(name) }

func settings(_ format: AudioFormatKind, bitRate: Int?, name: String) -> ExportSettings {
    ExportSettings(
        format: format,
        destinationURL: work.appendingPathComponent(name),
        bitRateKbps: bitRate,
        channels: .keep
    )
}

// ---------------------------------------------------------------------------
// A. The command line, as a pure function.
// ---------------------------------------------------------------------------

let mp3Default = AudioFileIO.ffmpegArguments(
    input: URL(fileURLWithPath: "/tmp/staged.wav"),
    settings: settings(.mp3, bitRate: nil, name: "a.mp3")
)
check("MP3 asks for libmp3lame",
      mp3Default.contains("libmp3lame"), "\(mp3Default)")
check("MP3 defaults to 320k",
      mp3Default.contains("320k"), "\(mp3Default)")
check("the output path is the last argument",
      mp3Default.last == work.appendingPathComponent("a.mp3").path, "\(mp3Default.last ?? "nil")")
check("progress is machine-readable on stdout",
      mp3Default.contains("-progress") && mp3Default.contains("pipe:1"), "\(mp3Default)")
check("the input is passed after -i",
      zip(mp3Default, mp3Default.dropFirst()).contains { $0 == "-i" && $1 == "/tmp/staged.wav" },
      "\(mp3Default)")
check("nothing is passed as a shell string",
      !mp3Default.contains { $0.contains(" -") }, "\(mp3Default)")

let opusDefault = AudioFileIO.ffmpegArguments(
    input: URL(fileURLWithPath: "/tmp/staged.wav"),
    settings: settings(.opus, bitRate: nil, name: "a.opus")
)
check("Opus asks for libopus", opusDefault.contains("libopus"), "\(opusDefault)")
check("Opus defaults to 160k", opusDefault.contains("160k"), "\(opusDefault)")

let overridden = AudioFileIO.ffmpegArguments(
    input: URL(fileURLWithPath: "/tmp/staged.wav"),
    settings: settings(.mp3, bitRate: 192, name: "a.mp3")
)
check("an explicit bit rate overrides the default",
      overridden.contains("192k") && !overridden.contains("320k"), "\(overridden)")

// ---------------------------------------------------------------------------
// B. The progress parser, including ffmpeg's own misnomer.
// ---------------------------------------------------------------------------

check("out_time_us is microseconds",
      AudioFileIO.ffmpegProgressMicroseconds("out_time_us=1500000") == 1_500_000)
check("out_time_ms is ALSO microseconds - ffmpeg's misnomer, not ours",
      AudioFileIO.ffmpegProgressMicroseconds("out_time_ms=1500000") == 1_500_000,
      "if this went red because someone divided by 1000, they were fixing a bug that is not here")
check("N/A before the first frame is ignored",
      AudioFileIO.ffmpegProgressMicroseconds("out_time_us=N/A") == nil)
check("other progress keys are ignored",
      AudioFileIO.ffmpegProgressMicroseconds("bitrate=128.0kbits/s") == nil
        && AudioFileIO.ffmpegProgressMicroseconds("progress=continue") == nil)
check("a line with no separator is ignored",
      AudioFileIO.ffmpegProgressMicroseconds("frame= 12") == nil)

// ---------------------------------------------------------------------------
// C. A whole successful encode, through a real child process.
// ---------------------------------------------------------------------------

let okSettings = settings(.mp3, bitRate: 192, name: "out.mp3")
let okFractions = Fractions()
do {
    try await AudioFileIO.encode(
        block,
        settings: okSettings,
        runner: SystemToolProcessRunner(),
        locate: { _ in standIn("ffmpeg-ok") },
        progress: { okFractions.accept($0) }
    )
    check("a successful external encode returns without throwing", true)
} catch {
    check("a successful external encode returns without throwing", false, "\(error)")
}

let recordedArgv = ((try? String(contentsOf: work.appendingPathComponent("argv-ok.txt"), encoding: .utf8)) ?? "")
    .split(separator: "\n", omittingEmptySubsequences: true)
    .map(String.init)
check("the child was actually spawned", !recordedArgv.isEmpty)

// The wiring assertion: what the process received is what the function builds.
// A check that only compared the function against a literal would survive
// `encode` being changed to pass something else entirely.
if let inputIndex = recordedArgv.firstIndex(of: "-i"), inputIndex + 1 < recordedArgv.count {
    let stagedPath = recordedArgv[inputIndex + 1]
    let expected = AudioFileIO.ffmpegArguments(
        input: URL(fileURLWithPath: stagedPath),
        settings: okSettings
    )
    check("the argv the process received is exactly ffmpegArguments(input:settings:)",
          recordedArgv == expected,
          "received \(recordedArgv)\n          expected \(expected)")
    check("the staged intermediate is a .wav",
          stagedPath.hasSuffix(".wav"), stagedPath)
} else {
    check("the child was given an -i argument", false, "\(recordedArgv)")
}

let stagedSize = Int((((try? String(contentsOf: work.appendingPathComponent("input-size.txt"), encoding: .utf8)) ?? "0")
    .trimmingCharacters(in: .whitespacesAndNewlines))) ?? 0
// 2 s of 48 kHz stereo Float32 is 768,000 bytes of samples plus a header.
check("the staged WAV really held the audio",
      stagedSize > 700_000, "\(stagedSize) bytes")

let observed = okFractions.all
check("progress was reported", !observed.isEmpty)
check("progress never goes backwards",
      zip(observed, observed.dropFirst()).allSatisfy { $0 <= $1 + 1e-9 }, "\(observed)")
check("progress ends at 1", observed.last.map { near($0, 1, 1e-9) } ?? false, "\(observed)")
// out_time_ms=1000000 is one second of a two-second block: 0.2 staging plus
// 0.8 x 0.5. Read as milliseconds it would be 1000 seconds and clamp to 1.0,
// so this value existing is the end-to-end proof of the microsecond reading.
check("out_time_ms=1000000 landed at the halfway mark, not the end",
      observed.contains { near($0, 0.6, 0.01) },
      "\(observed) - a value of 0.6 is what one second of two looks like")

// ---------------------------------------------------------------------------
// D. A non-zero exit says what ffmpeg said.
// ---------------------------------------------------------------------------

do {
    try await AudioFileIO.encode(
        block,
        settings: settings(.mp3, bitRate: nil, name: "fail.mp3"),
        runner: SystemToolProcessRunner(),
        locate: { _ in standIn("ffmpeg-fail") },
        progress: nil
    )
    check("a failing ffmpeg throws", false, "it returned normally")
} catch let failure as AudioFileIO.Failure {
    if case let .encodeFailed(message) = failure {
        check("the failure carries ffmpeg's own last stderr line",
              message == "Unknown encoder 'libmp3lame'", message)
    } else {
        check("a failing ffmpeg throws encodeFailed", false, "\(failure)")
    }
} catch {
    check("a failing ffmpeg throws AudioFileIO.Failure", false, "\(error)")
}

// ---------------------------------------------------------------------------
// E. A refusal from the sink kills the child.
// ---------------------------------------------------------------------------

let slowStart = Date()
let slowFractions = Fractions(refuseAbove: 0.2)
do {
    try await AudioFileIO.encode(
        block,
        settings: settings(.mp3, bitRate: nil, name: "slow.mp3"),
        runner: SystemToolProcessRunner(),
        locate: { _ in standIn("ffmpeg-slow") },
        progress: { slowFractions.accept($0) }
    )
    check("refusing mid-encode throws", false, "it returned normally")
} catch is CancellationError {
    check("refusing mid-encode throws CancellationError", true)
} catch {
    check("refusing mid-encode throws CancellationError", false, "\(error)")
}
let slowElapsed = Date().timeIntervalSince(slowStart)
// The stand-in sleeps for 30 s. Anything near that means the refusal set a flag
// and waited rather than reaching the process.
check("the child was killed rather than waited out",
      slowElapsed < 10, "took \(String(format: "%.1f", slowElapsed))s of a 30s sleep")

// ---------------------------------------------------------------------------
// F. Exit code 0 does not overrule a cancellation the user asked for.
// ---------------------------------------------------------------------------

let trapStart = Date()
let trapFractions = Fractions(refuseAbove: 0.2)
do {
    try await AudioFileIO.encode(
        block,
        settings: settings(.mp3, bitRate: nil, name: "trap.mp3"),
        runner: SystemToolProcessRunner(),
        locate: { _ in standIn("ffmpeg-trap0") },
        progress: { trapFractions.accept($0) }
    )
    check("a cancelled encode whose tool exits 0 is still a cancellation", false,
          "it reported success for a file the user stopped")
} catch is CancellationError {
    check("a cancelled encode whose tool exits 0 is still a cancellation", true)
} catch {
    check("a cancelled encode whose tool exits 0 is still a cancellation", false, "\(error)")
}
check("the trap stand-in did not run to completion",
      Date().timeIntervalSince(trapStart) < 10)

// ---------------------------------------------------------------------------
// G. No tool, and no lies about it.
// ---------------------------------------------------------------------------

do {
    try await AudioFileIO.encode(
        block,
        settings: settings(.mp3, bitRate: nil, name: "missing.mp3"),
        runner: SystemToolProcessRunner(),
        locate: { _ in nil },
        progress: nil
    )
    check("MP3 without ffmpeg throws", false, "it returned normally")
} catch let failure as AudioFileIO.Failure {
    check("MP3 without ffmpeg names the tool it needs",
          failure == .toolMissing(.ffmpeg), "\(failure)")
    check("and says how to get it",
          failure.recoverySuggestion == "brew install ffmpeg",
          failure.recoverySuggestion ?? "nil")
} catch {
    check("MP3 without ffmpeg throws AudioFileIO.Failure", false, "\(error)")
}

// A native format must not consult the locator at all.
do {
    try await AudioFileIO.encode(
        block,
        settings: settings(.wav, bitRate: nil, name: "native.wav"),
        runner: SystemToolProcessRunner(),
        locate: { _ in nil },
        progress: nil
    )
    let written = (try? work.appendingPathComponent("native.wav")
        .resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    check("WAV still writes with no external tool anywhere", written > 700_000, "\(written) bytes")
} catch {
    check("WAV still writes with no external tool anywhere", false, "\(error)")
}

// ---------------------------------------------------------------------------
// H. Nothing was left behind, on any path — including the two that threw.
// ---------------------------------------------------------------------------

check("no MeloEncode scratch directory survived",
      scratchDirectoryCount() == scratchBefore,
      "\(scratchBefore) before, \(scratchDirectoryCount()) after")

// ---------------------------------------------------------------------------

for failure in failures { print("FAIL \(failure)") }
if failures.isEmpty {
    print("OK")
} else {
    exit(1)
}
"""


def run_swift_checks() -> None:
    if shutil.which("xcrun"):
        argv = ["xcrun", "swiftc"]
    elif shutil.which("swiftc"):
        argv = ["swiftc"]
    else:
        failures.append("no Swift compiler on PATH — these checks cannot be skipped silently")
        return

    missing = [unit for unit in SWIFT_UNITS if not (sources / unit).is_file()]
    if missing:
        failures.append(f"external encode checks: missing source unit(s) {missing}")
        return

    with tempfile.TemporaryDirectory(prefix="melo-verify-external-encode-") as tmp:
        work = Path(tmp)
        for name, body in STAND_INS.items():
            path = work / name
            path.write_text(body)
            path.chmod(path.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)

        (work / "main.swift").write_text(MAIN_SWIFT)
        binary = work / "checks"
        compiled = subprocess.run(
            argv + ["-O", "-o", str(binary), str(work / "main.swift")]
            + [str(sources / unit) for unit in SWIFT_UNITS],
            capture_output=True,
            text=True,
        )
        if compiled.returncode != 0:
            errors = [line for line in compiled.stderr.splitlines() if "error:" in line][:12]
            failures.append(
                "the external encode checks did not compile:\n        "
                + "\n        ".join(errors or compiled.stderr.splitlines()[:12])
            )
            return

        result = subprocess.run(
            [str(binary), str(work)], capture_output=True, text=True, timeout=300
        )
        reported = [
            line[len("FAIL "):] for line in result.stdout.splitlines() if line.startswith("FAIL ")
        ]
        failures.extend(reported)
        if result.returncode != 0 and not reported:
            failures.append(
                f"the external encode checks exited {result.returncode} with no verdict: "
                f"{(result.stderr.strip() or result.stdout.strip())[:400]}"
            )


run_swift_checks()


# ---------------------------------------------------------------------------
# Structural: the absence checks the executed ones cannot make.
# ---------------------------------------------------------------------------

encode_source = (sources / "Editor/Core/AudioFileIO.swift").read_text(errors="replace")

# Written as an absence check on purpose. A check that `ToolProcessRunning` is
# *present* survives someone adding a second, unproved path beside it.
if "Process(" in encode_source or "posix_spawn" in encode_source:
    failures.append(
        "AudioFileIO constructs a process directly — every child process in the "
        "editor goes through ToolProcessRunning, which is the only version that "
        "can be exercised without the binary"
    )

if 'stagingShare' not in encode_source:
    failures.append("the staged-WAV progress split is gone; progress will jump")


if failures:
    print(f"verify-external-encode: {len(failures)} failure(s)")
    for failure in failures:
        print(f"  - {failure}")
    sys.exit(1)

print("verify-external-encode: OK")
