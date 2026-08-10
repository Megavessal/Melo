#!/usr/bin/env python3
"""Proves the beachball detector detects, and stays quiet when there is nothing.

`MainThreadStall.startWatchdog` is the only thing in Melo that can see a
main-thread freeze nobody predicted, and a detector that has never been watched
detecting anything reports silence whether the app is healthy or wedged. Greps
cannot tell those apart — the modifier is present in both.

So this compiles the real file and runs it twice against the same driver:

  * block the main thread for 600ms, and require the watchdog to notice
  * do not block it at all, and require the watchdog to stay at zero

The second half is the negative control, and it is the half that makes the
first half mean something. A watchdog with its threshold set to zero would pass
the first check on its own.
"""
import pathlib
import re
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCE = ROOT / "Sources/Melo/Utilities/MainThreadStall.swift"

DRIVER = r"""
import Foundation

// The driver blocks the main *thread*, not a Task: a `Task.sleep` yields and the
// main queue keeps draining, which is a freeze the user would never see and a
// freeze this detector should never report.
let shouldBlock = CommandLine.arguments.contains("--block")

MainThreadStall.startWatchdog()

// Let the watchdog take at least one healthy reading first, so a detector that
// simply reports on its first pass regardless is caught by the control below.
let settleUntil = Date().addingTimeInterval(0.5)
while Date() < settleUntil {
    RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
}

if shouldBlock {
    // A busy wait, deliberately. `sleep` would also block the thread, but a
    // spin is what a real stall looks like — an expensive synchronous call —
    // and it cannot be optimised into a yield.
    let until = Date().addingTimeInterval(0.6)
    var spin = 0
    while Date() < until { spin &+= 1 }
    if spin == -1 { print("unreachable") }
}

// Give the watchdog room to notice the thread came back and to write its number.
let drainUntil = Date().addingTimeInterval(0.8)
while Date() < drainUntil {
    RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
}

print("longestStallMilliseconds=\(MainThreadStall.longestStallMilliseconds)")
"""


def fail(lines):
    print("Stall watchdog checks failed:")
    for line in lines:
        print(f"  - {line}")
    return 1


def main():
    problems = []

    if not SOURCE.exists():
        return fail([f"{SOURCE.relative_to(ROOT)} is missing"])

    with tempfile.TemporaryDirectory() as tmp:
        tmp = pathlib.Path(tmp)
        # Must be `main.swift`: Swift only allows top-level statements in a
        # file with that name, and the driver is nothing but top-level
        # statements.
        driver = tmp / "main.swift"
        driver.write_text(DRIVER)
        binary = tmp / "watchdog-probe"

        build = subprocess.run(
            ["xcrun", "swiftc", "-O", "-swift-version", "6",
             str(SOURCE), str(driver), "-o", str(binary)],
            capture_output=True, text=True,
        )
        if build.returncode != 0:
            errors = [ln for ln in build.stderr.splitlines() if "error:" in ln]
            return fail([
                "MainThreadStall.swift did not compile on its own",
                *(errors[:3] or ["swiftc failed with no error line"]),
            ])

        def run(*args):
            out = subprocess.run([str(binary), *args], capture_output=True, text=True, timeout=60)
            match = re.search(r"longestStallMilliseconds=(\d+)", out.stdout)
            if not match:
                return None
            return int(match.group(1))

        blocked = run("--block")
        quiet = run()

    if blocked is None or quiet is None:
        return fail(["the probe did not report a number; the watchdog may not have run at all"])

    # 400ms against a 600ms block. Loose enough that a busy machine does not
    # make this flaky, tight enough that a watchdog reporting its poll interval
    # rather than the stall (150ms) fails.
    if blocked < 400:
        problems.append(
            f"a deliberate 600ms freeze was reported as {blocked}ms — the watchdog "
            "is not measuring the length of the stall"
        )
    # The negative control. Anything above zero here means it reports freezes
    # that did not happen, and every number it has ever produced is noise.
    if quiet != 0:
        problems.append(
            f"a run that never blocked the main thread reported a {quiet}ms freeze"
        )

    if problems:
        return fail(problems)

    print(f"Stall watchdog OK — 600ms freeze seen as {blocked}ms, quiet run seen as {quiet}ms")
    return 0


if __name__ == "__main__":
    sys.exit(main())
