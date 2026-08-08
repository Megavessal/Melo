#!/usr/bin/env python3
"""Guards the main actor against synchronous cross-process calls.

`DeviceVolumeMonitor.start()` called `NSAppleScript.executeAndReturnError`
in-process, on the main actor, during launch. Measured with `sample` against a
real launch on 2026-08-07: **218 ms** of main-thread time, **133 ms** of it
inside `AEDefaultActiveProc` — the Apple event blocking wait. That wait has no
bound Melo controls. When macOS decides the Automation consent
dialog is needed, the main thread stays parked inside `AESendMessage` behind it,
which is a spinning beachball at launch. Ad-hoc signing makes that reachable on
*every* rebuild, because the cdhash is the TCC identity.

Two numbers, one measurement, so the provenance is written down rather than
re-derived. This header and `DeviceVolumeMonitor` both used to read "141 ms
inside AEDefaultActiveProc" while `MenuBarPopupView` read 133 ms for the same
profile. 133 is the one commit 85be898 records in its own summary of the run
that produced it, so 133 is what the tree now says everywhere. The 141 ms is
believed to be the whole execute phase, of which AEDefaultActiveProc is a part —
believed, not established: the raw `sample` output is not in the tree, so the
compile-phase figure that used to sit beside it is **unverified** and has been
dropped rather than restated. Nothing in the fix turns on it; the argument is
that the wait has no upper bound, not that it is long.

The fix was not to make the Apple event faster. It was to stop the main actor
waiting for it — the same move `setAlertVolume` had already made for the write,
one function away, with a comment explaining why.

The inventory check below is the load-bearing one. It pins the exact set of
files allowed to construct `NSAppleScript`, so a new synchronous call site
anywhere in the app fails rather than being noticed by whoever next profiles a
launch. It is written as an equality, not a ceiling: removing the remaining one
is also a change worth being told about.
"""
from __future__ import annotations

import re
import sys
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
# Inventory: who is allowed to construct NSAppleScript at all.
# ---------------------------------------------------------------------------
#
# Empty, and that is the point. `MenuBarPopupView.activateApp` was the last one
# and now spawns osascript like the other two. Nothing in Melo may send an Apple
# event from inside its own process any more, so any file that reappears here is
# a regression rather than an entry to be added.
ALLOWED_APPLESCRIPT_FILES: set[str] = set()

actual = {
    path.relative_to(root).as_posix()
    for path in sources.rglob("*.swift")
    if re.search(r"NSAppleScript\s*\(", path.read_text(errors="replace"))
}
if actual != ALLOWED_APPLESCRIPT_FILES:
    added = sorted(actual - ALLOWED_APPLESCRIPT_FILES)
    removed = sorted(ALLOWED_APPLESCRIPT_FILES - actual)
    if added:
        failures.append(
            "new in-process NSAppleScript call site(s): " + ", ".join(added)
            + " — a synchronous Apple event blocks whichever thread sends it; "
            "spawn osascript instead, as DeviceVolumeMonitor does"
        )
    if removed:
        failures.append(
            "NSAppleScript is gone from " + ", ".join(removed)
            + " — good, but update ALLOWED_APPLESCRIPT_FILES so this check keeps meaning something"
        )

# An absence check alone would also pass if the Apple event were deleted rather
# than moved off the main actor, and then "click an app row to restore its
# minimized window" would silently stop working with every check still green.
# So assert the replacement is present, and that it does not wait.
popup = read("Sources/Melo/Views/MenuBarPopupView.swift")
activate = body_of(popup, "private func activateApp(")
if not activate:
    failures.append("MenuBarPopupView: could not read activateApp()")
else:
    if "/usr/bin/osascript" not in activate:
        failures.append(
            "MenuBarPopupView.activateApp no longer spawns osascript — the Apple event that "
            "restores a minimized window is gone, not merely moved off the main actor"
        )
    # Comments stripped first. The function's own comment explains why the pipe
    # must be drained before `waitUntilExit()` rather than after, and a check
    # that reads prose would fail on the explanation of the rule it enforces.
    activate_code = re.sub(r"//[^\n]*", "", activate)
    if "waitUntilExit" in activate_code:
        failures.append(
            "MenuBarPopupView.activateApp waits on osascript — that reintroduces on the main "
            "actor exactly the block spawning a child process was meant to remove"
        )

# ---------------------------------------------------------------------------
# The alert-volume read specifically.
# ---------------------------------------------------------------------------

monitor = read("Sources/Melo/Audio/Monitors/DeviceVolumeMonitor.swift")

refresh = body_of(monitor, "func refreshAlertVolume()")
if not refresh:
    failures.append("DeviceVolumeMonitor: could not read refreshAlertVolume()")
else:
    if "executeAndReturnError" in refresh:
        failures.append(
            "refreshAlertVolume executes an Apple event in-process again — this is "
            "the 218 ms main-thread block, back"
        )
    if "readAlertVolumePercent()" not in refresh:
        failures.append("refreshAlertVolume must delegate the read to readAlertVolumePercent()")
    if "alertVolumeDebounceTask == nil" not in refresh:
        failures.append(
            "refreshAlertVolume must not apply a read while a write is pending — the "
            "read is older and would undo the user's drag"
        )

reader = body_of(monitor, "static func readAlertVolumePercent()")
if not reader:
    failures.append("DeviceVolumeMonitor: no readAlertVolumePercent()")
else:
    if "/usr/bin/osascript" not in reader:
        failures.append("readAlertVolumePercent must run osascript as a child process")
    drain = reader.find("readDataToEndOfFile")
    wait = reader.find("waitUntilExit")
    if drain < 0 or wait < 0:
        failures.append("readAlertVolumePercent must both drain stdout and reap the child")
    elif drain > wait:
        failures.append(
            "readAlertVolumePercent waits for the child before draining its stdout — "
            "that deadlocks as soon as the reply outgrows the pipe buffer"
        )

# The launch path must reach the read through the non-blocking wrapper only.
start_body = body_of(monitor, "func start()")
if start_body and "executeAndReturnError" in start_body:
    failures.append("DeviceVolumeMonitor.start executes an Apple event inline")

# ---------------------------------------------------------------------------

if failures:
    print("Launch responsiveness verification failed:")
    for failure in failures:
        print(f"  - {failure}")
    sys.exit(1)

print("Launch responsiveness verification passed.")
