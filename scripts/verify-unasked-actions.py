#!/usr/bin/env python3
"""Guards the things Melo used to do without being asked.

1. **Duck every other app because Slack made a noise.** One poll above -42 dBFS
   from anything on the communication list engaged ducking and a flat 1.5 s hold
   kept it there, so a message chime cost 1.7 s of everything else at 20%. The
   rule now lives in `CallActivityDetector`, which is pure, so this file
   compiles the shipped source and runs chime-shaped and call-shaped level
   sequences through the real implementation.

2. **Reach raw.githubusercontent.com at launch.** `AutoEQProfileManager.init`
   kicked off a catalog fetch on every launch, before the user had touched
   AutoEQ and with nothing anywhere in the app saying so. The fetch now happens
   when the AutoEQ panel opens, under a line of copy that says it is happening.

3. **Touch IOBluetooth at launch, raising the macOS Bluetooth prompt.** The
   startup task called `startBluetoothMonitoringIfEnabled()`, which guarded on
   `bluetoothFeaturesEnabled && onboardingVersionCompleted >= …`. Both guards
   pass on every pre-existing install — `decodeSettings` migrates the flag to
   true and stamps onboarding complete — so the gate only ever protected new
   installs, and everyone else got a permission dialog for opening an app.
   Nothing may now reach IOBluetooth as a consequence of launch.

The structural half of this file is deliberately written as *absence* checks —
"no raw threshold survives in the manager", "nothing but the picker calls
`prepareCatalog`". CLAUDE.md records four wiring points being severed at once
while every assertion stayed green, because each one tested a pure function
nothing proved was called. A check that a symbol is present survives its subject
being bypassed; a check that the bypass is absent does not.

What this file does **not** prove: that ducking gain actually moves on real call
audio, or that a real request is issued when the panel opens. Neither is
reachable without audio and a network, and the snapshot harness has neither.
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


def read(relative: str) -> str:
    path = root / relative
    if not path.is_file():
        failures.append(f"missing {relative}")
        return ""
    return path.read_text(errors="replace")


def body_of(text: str, opening: str) -> str:
    """Returns the brace-balanced body that follows `opening`, or ""."""
    start = text.find(opening)
    if start < 0:
        return ""
    brace = text.find("{", start)
    if brace < 0:
        return ""
    depth = 0
    for i in range(brace, len(text)):
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0:
                return text[brace + 1:i]
    return ""


# ---------------------------------------------------------------------------
# Executed: the real trigger rule, against the sequences that motivated it.
# ---------------------------------------------------------------------------

SWIFT_UNITS = ["Audio/Types/CallActivityDetector.swift"]

MAIN_SWIFT = r"""
import Foundation

var failures: [String] = []

func check(_ label: String, _ condition: Bool) {
    if !condition { failures.append(label) }
}

/// Runs a sequence of per-poll peak levels through one detector and returns the
/// engaged state after each poll.
func run(_ peaks: [Float]) -> [Bool] {
    var detector = CallActivityDetector()
    return peaks.map { detector.update(peak: $0) }
}

// The finding, exactly. A Slack message chime is one short loud burst: at the
// manager's 250 ms poll it covers one or two polls and then stops.
check(
    "a two-poll (500 ms) chime engages ducking",
    run([0.15, 0.15, 0.0, 0.0]).allSatisfy { $0 == false }
)

// The old rule's threshold, on its own, must no longer be enough to engage.
check(
    "a poll at the old 0.008 threshold still engages on its own",
    run([0.008, 0.008, 0.008, 0.008]).allSatisfy { $0 == false }
)

// A call is continuous. Speech must engage, and promptly.
let call = run([0.1, 0.1, 0.1, 0.1])
check("sustained speech never engages ducking", call[3])
check("ducking engages before three polls of sustained sound", call[0] == false && call[1] == false)
check("ducking does not engage on the third poll of sustained sound", call[2])

// Hysteresis. Once engaged, a dip between sustain and onset must hold — a
// consonant gap that released the duck would be audible as pumping.
var held = CallActivityDetector()
for peak: Float in [0.1, 0.1, 0.1] { _ = held.update(peak: peak) }
check("engaged ducking drops out on a dip below the onset level", held.update(peak: 0.01))
check("engaged ducking drops out on a second dip", held.update(peak: 0.009))
check("ducking stays engaged after the sound falls below the sustain level",
      held.update(peak: 0.001) == false)

// Constants, asserted as relationships rather than as numbers, so the values
// stay tunable and the shape does not.
check("sustain level is not below the onset level — no hysteresis",
      CallActivityDetector.sustainLevel < CallActivityDetector.onsetLevel)
check("release hold is no longer than the 1.5 s it replaced",
      CallActivityDetector.releaseMilliseconds > 1_500)

if failures.isEmpty {
    print("ok")
} else {
    for failure in failures { print("FAIL \(failure)") }
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
        failures.append(f"swift checks: missing source unit(s) {missing}")
        return

    with tempfile.TemporaryDirectory(prefix="melo-verify-unasked-") as tmp:
        work = Path(tmp)
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
                "call-ducking checks did not compile:\n        "
                + "\n        ".join(errors or compiled.stderr.splitlines()[:12])
            )
            return

        result = subprocess.run([str(binary)], capture_output=True, text=True)
        if result.returncode != 0:
            reported = [ln[len("FAIL "):] for ln in result.stdout.splitlines() if ln.startswith("FAIL ")]
            failures.extend(reported)
            if not reported:
                failures.append(
                    f"call-ducking checks exited {result.returncode} with no verdict: "
                    f"{result.stderr.strip()[:200]}"
                )


run_swift_checks()

# ---------------------------------------------------------------------------
# Connected: the manager must have no way to decide this for itself.
# ---------------------------------------------------------------------------

manager = read("Sources/Melo/Coordination/CallDuckingManager.swift")

level_reads = manager.count("audioEngine.getAudioLevel(")
delegated = manager.count("update(peak: audioEngine.getAudioLevel(")
if level_reads == 0:
    failures.append("CallDuckingManager: reads no audio level at all")
elif delegated != level_reads:
    failures.append(
        f"CallDuckingManager: {level_reads} audio-level read(s), only {delegated} fed to "
        "CallActivityDetector — a level compared anywhere else is the old rule back"
    )

inline_threshold = re.search(r"getAudioLevel\([^)]*\)\s*[<>]=?", manager)
if inline_threshold:
    failures.append("CallDuckingManager: an audio level is compared inline; the rule belongs to CallActivityDetector")

if "CallActivityDetector.releaseMilliseconds" not in manager:
    failures.append("CallDuckingManager: the restore hold must come from CallActivityDetector")
for literal in re.findall(r"\.milliseconds\((\d[\d_]*)\)", manager):
    if int(literal.replace("_", "")) >= 1_000:
        failures.append(
            f"CallDuckingManager: a literal {literal} ms sleep is back — the hold is "
            "CallActivityDetector.releaseMilliseconds"
        )

# ---------------------------------------------------------------------------
# The network call: not at launch, and not from anywhere undisclosed.
# ---------------------------------------------------------------------------

fetcher = read("Sources/Melo/Audio/AutoEQ/AutoEQFetcher.swift")
if "private func refreshCatalogFromGitHub" not in fetcher:
    failures.append(
        "AutoEQFetcher: refreshCatalogFromGitHub must stay private, or a caller can "
        "reach the network without going through refreshCatalogIfNeeded"
    )
if "func refreshCatalogIfNeeded" not in fetcher:
    failures.append("AutoEQFetcher: refreshCatalogIfNeeded is the only sanctioned network entrance")
if "func loadCachedCatalog" not in fetcher:
    failures.append("AutoEQFetcher: launch needs a cache-only load")

profile_manager = read("Sources/Melo/Audio/AutoEQ/AutoEQProfileManager.swift")
init_body = body_of(profile_manager, "init(loader:")
if not init_body:
    failures.append("AutoEQProfileManager: could not read the init body")
else:
    for banned in ("refreshCatalog", "prepareCatalog", "Task {"):
        if banned in init_body:
            failures.append(
                f"AutoEQProfileManager.init contains `{banned}` — launch must not put a "
                "request on the wire"
            )
    if "loadCachedCatalog()" not in init_body:
        failures.append("AutoEQProfileManager.init must load the cached catalog")

callers = sorted(
    path.relative_to(root).as_posix()
    for path in sources.rglob("*.swift")
    if "prepareCatalog()" in path.read_text(errors="replace")
    and path.name != "AutoEQProfileManager.swift"
)
if callers != ["Sources/Melo/Views/Components/AutoEQPicker.swift"]:
    failures.append(
        "prepareCatalog() is called from " + (", ".join(callers) or "nowhere")
        + " — the disclosed surface is AutoEQPicker, and only AutoEQPicker may cause the fetch"
    )

picker = read("Sources/Melo/Views/Components/AutoEQPicker.swift")
disclosure = re.search(r"static let networkDisclosure\s*=\s*(.+?)\n\n", picker, re.S)
if not disclosure:
    failures.append("AutoEQPicker: no networkDisclosure string")
else:
    text = " ".join(re.findall(r'"([^"]*)"', disclosure.group(1)))
    if "GitHub" not in text:
        failures.append("AutoEQPicker: the disclosure must name where the profiles come from")
    if len(text) < 40:
        failures.append("AutoEQPicker: the disclosure is too short to disclose anything")
if "Text(Self.networkDisclosure)" not in picker:
    failures.append("AutoEQPicker: the disclosure string exists but is never rendered")

# ---------------------------------------------------------------------------
# Bluetooth: launch must not touch it, and only a user reaching for the
# feature may.
# ---------------------------------------------------------------------------

engine = read("Sources/Melo/Audio/Engine/AudioEngine.swift")

# The precise claim: the startup task cannot reach IOBluetooth. Checked by
# reading the block rather than by grepping the file, because the file legitimately
# still mentions Bluetooth elsewhere — in the sanctioned wrapper and in the Core
# Audio device callbacks, both of which are inert until someone starts the monitor.
startup = body_of(engine, "if startMonitorsAutomatically {")
# Comments stripped first: a comment saying why Bluetooth is absent is not a
# call, and the check has to be able to tell those apart.
startup_code = re.sub(r"//[^\n]*", "", startup)
if not startup:
    failures.append("AudioEngine: could not read the startMonitorsAutomatically block")
elif re.search(r"[Bb]luetooth", startup_code):
    failures.append(
        "AudioEngine's startup block reaches Bluetooth again — launching Melo is not "
        "reaching for a Bluetooth feature, and the first touch is what raises the "
        "macOS permission prompt"
    )

# Inventory equality, the same shape verify-launch-responsiveness.py uses. Any new
# file that can raise the prompt fails; so does one quietly dropping out.
#
# FirstRunOnboardingView was pinned here while it still called this on setup
# close — a prompt with no Bluetooth reason on screen. That call is gone:
# finishing setup is not reaching for the feature, it is the same unexplained
# dialog thirty seconds later.
#
# MenuBarPopupView replaced it because entering device-priority edit mode on the
# output tab is the only surface in the app that renders paired devices at all,
# so it is the first moment a user has asked for something Bluetooth does. With
# onboarding removed and the launch call gone, it is also the only initiator a
# pre-existing install can ever reach — the settings switch is already on for
# them, so its onChange never fires. Drop it and the feature is dead.
ALLOWED_BLUETOOTH_INITIATORS = {
    "Sources/Melo/Audio/Engine/AudioEngine.swift",          # the wrapper itself
    "Sources/Melo/Views/Settings/Tabs/GeneralTab.swift",    # the feature's own switch
    "Sources/Melo/Views/MenuBarPopupView.swift",            # the only surface that shows paired devices
}
initiator = re.compile(r"\.startBluetoothMonitoringIfEnabled\(|bluetoothDeviceMonitor\.start\(\)")
actual_initiators = {
    path.relative_to(root).as_posix()
    for path in sources.rglob("*.swift")
    if initiator.search(path.read_text(errors="replace"))
}
if actual_initiators != ALLOWED_BLUETOOTH_INITIATORS:
    added = sorted(actual_initiators - ALLOWED_BLUETOOTH_INITIATORS)
    gone = sorted(ALLOWED_BLUETOOTH_INITIATORS - actual_initiators)
    if added:
        failures.append(
            "new Bluetooth initiator(s): " + ", ".join(added)
            + " — the first call raises the macOS prompt, so only a surface where the "
            "user asked for something Bluetooth does may make it"
        )
    if gone:
        failures.append(
            "Bluetooth is no longer started from " + ", ".join(gone)
            + " — update ALLOWED_BLUETOOTH_INITIATORS, and check the feature can still "
            "be reached at all"
        )

# The off switch. Without this guard, a user who turned the feature off is still asked.
wrapper = body_of(engine, "func startBluetoothMonitoringIfEnabled()")
if not wrapper:
    failures.append("AudioEngine: could not read startBluetoothMonitoringIfEnabled()")
elif "bluetoothFeaturesEnabled" not in wrapper:
    failures.append("startBluetoothMonitoringIfEnabled must honour bluetoothFeaturesEnabled")

# One gate covers every IOBluetooth path, which is what keeps the Core Audio
# device callbacks — they fire while devices enumerate at launch — inert.
bt_monitor = read("Sources/Melo/Audio/Monitors/BluetoothDeviceMonitor.swift")
for method in ("func refresh()", "func connect(device:", "func notifyDeviceAppearedInCoreAudio()"):
    gated = body_of(bt_monitor, method)
    if not gated:
        failures.append(f"BluetoothDeviceMonitor: could not read {method}")
    elif "guard isStarted" not in gated:
        failures.append(
            f"BluetoothDeviceMonitor.{method} no longer guards on isStarted — it can now "
            "reach IOBluetooth before any user asked for it"
        )

# ---------------------------------------------------------------------------
# Shortcuts: a device named in a shortcut must survive a reconnect.
# ---------------------------------------------------------------------------

intents = read("Sources/Melo/Shortcuts/MeloAppIntents.swift")
if "struct SetMeloOutputDeviceIntent" not in intents:
    failures.append("MeloAppIntents: no intent can name an output device")
if "MeloAudioDeviceEntity(id: $0.uid" not in intents:
    failures.append(
        "MeloAppIntents: the device entity must be keyed by UID — CoreAudio reassigns "
        "AudioDeviceID across reconnects, so a saved shortcut would point elsewhere"
    )

# ---------------------------------------------------------------------------

if failures:
    print("Unasked-action verification failed:")
    for failure in failures:
        print(f"  - {failure}")
    sys.exit(1)

print("Unasked-action verification passed.")
