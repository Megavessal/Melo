#!/usr/bin/env python3
from pathlib import Path
import math
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
failures: list[str] = []

def require(relative: str, *needles: str) -> str:
    path = root / relative
    if not path.is_file():
        failures.append(f"missing {relative}")
        return ""
    text = path.read_text(errors="replace")
    for needle in needles:
        if needle not in text:
            failures.append(f"{relative}: missing {needle!r}")
    return text

require("Sources/Melo/Updates/SparkleUpdateController.swift",
        "SPUStandardUpdaterController", "startUpdater", "checkForUpdates",
        "automaticallyChecksForUpdates", "automaticallyDownloadsUpdates")
# Melo is LSUIElement. Sparkle's standard UI assumes an app that can come to the
# front on its own, and an accessory app's alert opens behind everything — a
# scheduled update the user can never see is the same as no updater at all.
require("Sources/Melo/Updates/SparkleUpdateController.swift",
        "supportsGentleScheduledUpdateReminders",
        "standardUserDriverWillShowModalAlert",
        "activate(ignoringOtherApps",
        # A menu-bar app is almost never quit, so an automatically downloaded
        # update must be finishable from the UI rather than only on quit.
        "installDownloadedUpdateNow",
        # Every user-visible state has to be a state, not an inference.
        "case checking", "case upToDate", "case available", "case downloading",
        "case readyToInstall", "case failed", "lastCheckDate")

# Sparkle's delegate methods are optional: a Swift name that does not map to the
# selector Sparkle sends compiles fine and is simply never called, which would
# silently disable everything above.
sparkle_source = (root / "Sources/Melo/Updates/SparkleUpdateController.swift").read_text(errors="replace")
for selector in (
    "@objc(updater:didFindValidUpdate:)",
    "@objc(updaterDidNotFindUpdate:error:)",
    "@objc(updater:didAbortWithError:)",
    "@objc(updater:willInstallUpdateOnQuit:immediateInstallationBlock:)",
    "@objc(standardUserDriverShouldHandleShowingScheduledUpdate:andInImmediateFocus:)",
):
    if selector not in sparkle_source:
        failures.append(f"SparkleUpdateController.swift: {selector} is not pinned to its selector")

with (root / "Config/Info.plist").open("rb") as file:
    info = plistlib.load(file)

# --- Behaviour, not presence. Everything below can fail on a regression that
# --- leaves all the names above in place.

# 1. An update found in the background must survive a relaunch, and the mark
#    that announces it must have a real reader. `hasUnseenUpdate` was published
#    and consumed by nobody, so the only channel was a one-shot notification.
if "Keys.pendingUpdate" not in sparkle_source or "restorePendingUpdate" not in sparkle_source:
    failures.append("SparkleUpdateController.swift: the pending update is not persisted across launches")
readers = [
    path for path in sorted((root / "Sources/Melo").rglob("*.swift"))
    if "pendingUpdate" in path.read_text(errors="replace")
    and path.name != "SparkleUpdateController.swift"
]
if not readers:
    failures.append("SparkleUpdateController.swift: pendingUpdate has no reader outside its own file — nothing shows it")
# Melo must never insert a menu bar extra of its own accord. HIG, "The menu bar":
# "Let people — not your app — decide whether to put your menu bar extra in the
# menu bar", and "avoid relying on the presence of menu bar extras", because the
# system hides them when the bar is crowded. Melo announced a waiting update by
# adding a *second* status item and then depending on it. The one status item
# Melo has comes from FluidMenuBarExtra; nothing in Melo's own sources may create
# another.
def code_of(path) -> str:
    """The file with `//` comment lines removed, so a rule can be explained in a
    comment that names the very call the rule forbids."""
    return "\n".join(
        line for line in path.read_text(errors="replace").splitlines()
        if not line.lstrip().startswith("//")
    )

own_status_items = [
    path for path in sorted((root / "Sources/Melo").rglob("*.swift"))
    if "NSStatusBar.system.statusItem(" in code_of(path)
]
if own_status_items:
    joined = ", ".join(str(path.relative_to(root)) for path in own_status_items)
    failures.append(f"Melo creates a menu bar extra of its own: {joined}")

# The waiting update has to be visible on the surfaces the user *did* choose:
# a badge on Melo's own menu bar icon, its context menu, and the popup.
for relative, needles in (
    ("Sources/Melo/Views/MenuBar/MenuBarIconCoordinator.swift",
     ("updateReminder", "Self.badged(", "Update Now", "Remind Me Later", "Skip This Version")),
    ("Sources/Melo/Views/MenuBarPopupView.swift", ("PendingUpdateBanner(",)),
    ("Sources/Melo/Updates/PendingUpdateBanner.swift", ("Update Now", "Later")),
):
    # Comment-stripped: every one of these surfaces is explained in a comment
    # that names it, so a substring match on the raw file would pass on prose.
    code = code_of(root / relative)
    for needle in needles:
        if needle not in code:
            failures.append(f"{relative}: the waiting update is not surfaced — missing {needle!r}")

# Deferring must not be the same act as refusing. Before this the only thing
# that cleared the reminder was a permanent skip.
for needle in ("func remindLater()", "Keys.remindAfter", "updateReminder"):
    if needle not in sparkle_source:
        failures.append(f"SparkleUpdateController.swift: missing {needle!r} — a reminder cannot be deferred without skipping the version for good")
if "func skipPendingUpdate" in sparkle_source and "Skip This Version" not in (root / "Sources/Melo/Views/Settings/Tabs/UpdatesTab.swift").read_text(errors="replace"):
    failures.append("UpdatesTab.swift: skipping a version is not offered on the one screen that is about updates")

# Skip has to be one decision, not two lists that disagree. Melo writes and reads
# Sparkle's own key, or a version dismissed in Melo's UI returns as Sparkle's
# alert on the next scheduled check.
if "SUSkippedVersion" not in sparkle_source:
    failures.append("SparkleUpdateController.swift: skipping does not write Sparkle's own skip list, so Sparkle will re-offer the version")
if "updates.skippedBuild" in sparkle_source:
    failures.append("SparkleUpdateController.swift: a second skip list is back beside Sparkle's")

# A restored record is yesterday's claim about a feed. A pulled release must stop
# being advertised without waiting for the next scheduled check.
if "checkForUpdateInformation()" not in code_of(root / "Sources/Melo/Updates/SparkleUpdateController.swift"):
    failures.append("SparkleUpdateController.swift: a restored pending update is asserted, never re-verified against the feed")

# 2. A failed check must never be rewritten as "up to date": that borrows an
#    older check's timestamp to make a false all-clear.
def body_of(source: str, signature: str) -> str:
    start = source.index(signature)
    depth = 0
    for index in range(start, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[start:index]
    return source[start:]

def body_or_none(source: str, signature: str):
    """`body_of`, but `None` when the declaration is gone — so a check whose
    whole point is that a function exists can report that, instead of raising."""
    return body_of(source, signature) if signature in source else None

sparkle_code = code_of(root / "Sources/Melo/Updates/SparkleUpdateController.swift")

for function in ("func dismissFailure()", "fileprivate func sessionFinished()", "private var restingActivity"):
    if ".upToDate" in body_of(sparkle_source, function):
        failures.append(f"SparkleUpdateController.swift: {function} still claims 'up to date' without a check that said so")

# --- A skip has to survive the day it was made -------------------------------
#
# The decision was durable in UserDefaults and nowhere else: `.skipped` lived
# only in memory, `pendingUpdate = nil` deleted the disk record, and the next
# background check reported "nothing newer" — because Sparkle filters the
# skipped item out of its *not-found* appcast too (`SUAppcastDriver.m`: "This
# excludes newer backgrounded updates that fail because they are skipped"),
# yielding SPUNoUpdateFoundReasonOnLatestVersion. So within a day, the one
# screen that is entirely about updates drew a green check under "Nothing newer
# is published for this Mac" about a version Melo was itself suppressing. A
# relaunch got there sooner, at `.idle`.
skip_record_body = body_or_none(sparkle_code, "private func restoredSkippedUpdate()")
if skip_record_body is None:
    failures.append("SparkleUpdateController.swift: a skip has no durable representation — nothing can name the refused version after a relaunch")
# The record is a caption for Sparkle's decision, never a decision of its own.
# Gated on isSkipped, it cannot outlive the keys; ungated it is the second skip
# list this file already removed once.
elif "isSkipped(" not in skip_record_body:
    failures.append(
        "SparkleUpdateController.swift: the durable skip record is not re-checked against Sparkle's keys, "
        "so it is a second skip list that can contradict them"
    )
for function, what in (
    ("fileprivate func foundNoUpdate(", "a scheduled check reports 'nothing newer' about the version it is suppressing"),
    ("private func restorePendingUpdate()", "a relaunch forgets the skip and opens at idle"),
):
    if ".skipped(" not in (body_or_none(sparkle_code, function) or ""):
        failures.append(f"SparkleUpdateController.swift: {function.strip()} does not surface a durable skip — {what}")
# Clearing the keys without clearing the caption leaves the tab naming a version
# nothing is suppressing; clearing the caption without the keys leaves a skip
# nothing can undo. One function does both, and the check the user asked for
# must call it.
clear_body = body_or_none(sparkle_code, "private func clearSkip()") or ""
for needle, what in (
    ("sparkleSkipKeys", "Sparkle's own keys"),
    ("Keys.skippedUpdate", "the durable record that names the refused version"),
):
    if needle not in clear_body:
        failures.append(f"SparkleUpdateController.swift: clearSkip does not clear {what}")

# Skip is one act, so it has one name. It was "Skip This Version" in Settings
# and "Skip Melo 2.9.5" in the status-item menu.
if re.search(r'title: "Skip Melo', code_of(root / "Sources/Melo/Views/MenuBar/MenuBarIconCoordinator.swift")):
    failures.append("MenuBarIconCoordinator.swift: the status-item menu gives Skip a second name")

# `Show Progress…` must not be offered when there is no window to show.
# SPUAutomaticUpdateDriver.showingUpdate returns NO and never opens anything, and
# SPUUpdater.checkForUpdates returns immediately while sessionInProgress — so
# with automatic downloads on the button activated Melo and did nothing.
# Scoped to the button's own declaration, not the file: the token also appears
# in the card's copy nearby, and a file-wide match passed while the button
# itself had been put back behind `if true`.
tab_primary = body_or_none(code_of(root / "Sources/Melo/Views/Settings/Tabs/UpdatesTab.swift"),
                           "private var primaryButton") or ""
if "Show Progress" in tab_primary and "canRevealUpdateWindow" not in tab_primary:
    failures.append("UpdatesTab.swift: Show Progress is offered unconditionally, but the automatic-download session has no window to show")
if "canRevealUpdateWindow" not in body_of(sparkle_code, "fileprivate func sessionFinished()"):
    failures.append("SparkleUpdateController.swift: canRevealUpdateWindow outlives the session that set it, so Show Progress returns as an inert button")

# A record for a version the user already skipped must be deleted, not merely
# ignored: it was re-read and re-discarded on every launch, forever.
restore_body = body_of(sparkle_source, "private func restorePendingUpdate()")
if restore_body.count("removeObject(forKey: Keys.pendingUpdate)") < 2:
    failures.append("SparkleUpdateController.swift: restorePendingUpdate leaves the stale record on disk when the version is skipped")

# A decision the user just made has to change what the card says. Skip left
# `activity` untouched from every state but `.available`, so the card went on
# advertising the refused version with a live Install button beside it; and from
# `.available` it claimed `.upToDate`, which renders as "nothing newer is
# published" about a version the user had just been offered.
# Comment-stripped: each of these rules is explained in a comment that names the
# very token the rule forbids.
skip_body = body_of(sparkle_code, "func skipPendingUpdate()")
if "activity = .skipped(" not in skip_body:
    failures.append("SparkleUpdateController.swift: skipPendingUpdate leaves `activity` advertising the version it just refused")
if ".upToDate" in skip_body:
    failures.append("SparkleUpdateController.swift: skipPendingUpdate claims 'up to date' about a version that is still published")
if "if case .available = activity" in skip_body:
    failures.append("SparkleUpdateController.swift: skipPendingUpdate only updates the card from one state, so every other state keeps offering the refused version")
later_body = body_of(sparkle_code, "func remindLater()")
if "activity = .deferred(" not in later_body:
    failures.append("SparkleUpdateController.swift: remindLater silences the badge and the banner but leaves the tab unchanged, so the surfaces disagree")

# --- The deferral, run rather than read --------------------------------------
#
# `remindLater()` moved both surfaces together, and nothing moved them back. The
# lapse had no path at all — `refreshReminder()` restored `updateReminder` and
# never touched `activity`, so the badge and the banner returned while the tab
# went on saying they were off for the next eight hours — and the launch restore
# had the mirror of it, asserting `.available` without ever reading
# `Keys.remindAfter`, so relaunching inside a live deferral offered a version
# whose ambient surfaces were correctly silent.
#
# Neither is visible to a source check. `activity` was assigned the right case
# from the right function in both directions; the defect was in which *facts*
# were consulted, and a substring test cannot see a missing read. So this
# compiles the shipped controller and drives the real object: writes a pending
# record and a deferral into a throwaway defaults suite, constructs it, and
# watches the states it reaches — including the one that only arrives when the
# real `Timer` fires on the real run loop.
#
# It needs a bundle. `init` registers the notification category, and
# `UNUserNotificationCenter.current()` raises `bundleProxyForCurrentProcess is
# nil` in a bare executable — so the checks are built into a minimal .app.

STATE_CHECKS_SWIFT = r"""
import Foundation

var failures: [String] = []
func check(_ label: String, _ ok: Bool) { if !ok { failures.append(label) } }

let suiteName = "melo.verify.updatestate"
let sample = SparkleUpdateController.PendingUpdate(
    version: "2.9.5", build: "200", notes: nil, notesAreHTML: false,
    notesURL: nil, downloadBytes: 1_000_000, published: nil, isCritical: false
)
let blob = try! JSONEncoder().encode(sample)

/// A defaults store holding exactly what a previous launch would have left.
func store(deferredFor seconds: TimeInterval?) -> UserDefaults {
    let store = UserDefaults(suiteName: suiteName)!
    store.removePersistentDomain(forName: suiteName)
    store.set(blob, forKey: "__PENDING_KEY__")
    if let seconds { store.set(Date().addingTimeInterval(seconds), forKey: "__REMIND_KEY__") }
    return store
}

MainActor.assumeIsolated {
    // Nothing deferred: the version is offered and the ambient surfaces show it.
    // Here so a fix that simply defers everything cannot pass.
    let plain = SparkleUpdateController(defaults: store(deferredFor: nil))
    check("a restored update with no deferral does not open at .available", plain.activity == .available(sample))
    check("a restored update with no deferral does not reach the badge and the banner", plain.updateReminder == sample)

    // Relaunching inside a live deferral. The tab must not offer what the badge
    // and the banner are deliberately not showing.
    let deferred = SparkleUpdateController(defaults: store(deferredFor: 3600))
    check(
        "relaunching inside a live deferral opens the Updates tab at .available while the badge and banner stay silent",
        deferred.activity == .deferred(sample)
    )
    check("relaunching inside a live deferral wakes the ambient surfaces", deferred.updateReminder == nil)

    // The button itself, not a state handed to it.
    let pressed = SparkleUpdateController(defaults: store(deferredFor: nil))
    pressed.remindLater()
    check("Remind Me Later leaves the Updates tab where it was", pressed.activity == .deferred(sample))
    check("Remind Me Later leaves the badge and the banner showing", pressed.updateReminder == nil)
}

// The lapse, on the real run loop, through the timer the controller schedules.
let lapsing = MainActor.assumeIsolated { SparkleUpdateController(defaults: store(deferredFor: 0.6)) }
MainActor.assumeIsolated {
    check("the lapse check did not begin deferred, so it proves nothing", lapsing.activity == .deferred(sample))
    check("the lapse check did not begin silent, so it proves nothing", lapsing.updateReminder == nil)
}
RunLoop.main.run(until: Date().addingTimeInterval(2.5))
MainActor.assumeIsolated {
    check("a lapsed deferral never brings the badge and the banner back", lapsing.updateReminder == sample)
    check(
        "a lapsed deferral brings the badge and the banner back but leaves the Updates tab saying they are off for eight hours",
        lapsing.activity == .available(sample)
    )
}

if failures.isEmpty {
    print("ok")
} else {
    for failure in failures { print("FAIL \(failure)") }
    exit(1)
}
"""

STATE_CHECKS_PLIST = """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>io.github.megavessal.Melo.verify-update-state</string>
<key>CFBundleExecutable</key><string>Check</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>100</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>LSUIElement</key><true/>
</dict></plist>
"""


def defaults_key(name):
    """The literal a `Keys` member is declared with. Scraped rather than
    repeated, so renaming the key cannot leave these checks writing a record the
    controller no longer reads — which would pass by never restoring anything."""
    match = re.search(rf'static let {name} = "([^"]+)"', sparkle_source)
    if match is None:
        failures.append(f"SparkleUpdateController.swift: Keys.{name} is gone; the deferral checks cannot run")
        return None
    return match.group(1)


def run_update_state_checks() -> None:
    pending_key, remind_key = defaults_key("pendingUpdate"), defaults_key("remindAfter")
    if pending_key is None or remind_key is None:
        return

    if shutil.which("xcrun"):
        argv = ["xcrun", "swiftc"]
    elif shutil.which("swiftc"):
        argv = ["swiftc"]
    else:
        failures.append("no Swift compiler on PATH — the deferral checks cannot be skipped silently")
        return

    # Sparkle is a binary dependency, so this needs the framework a build has
    # already produced. `build-app.sh` deletes .build-melo and outputs/Melo.app
    # at the start of every build, so all three of these are empty *during* one —
    # which is fine, because `dev-verify-locked.sh` runs the verify scripts
    # inside the lock, after its own build. Run standalone while another agent
    # holds the lock, this reports the window rather than a defect.
    framework_dir = next(
        (
            candidate for candidate in (
                root / ".build-melo/DerivedData/Build/Products/Release",
                root / "outputs/Melo.app/Contents/Frameworks",
                root / ".build-melo/DerivedData/SourcePackages/artifacts/sparkle/Sparkle"
                     / "Sparkle.xcframework/macos-arm64_x86_64",
            )
            if (candidate / "Sparkle.framework").is_dir()
        ),
        None,
    )
    if framework_dir is None:
        failures.append(
            "no built Sparkle.framework to link the deferral checks against. Run ./scripts/dev-verify.sh, "
            "which builds before it runs these scripts; a build in flight elsewhere has deleted every copy "
            "for the moment. Deliberately not skipped — these are the only assertions that observe the "
            "deferral rather than read it."
        )
        return

    controller = root / "Sources/Melo/Updates/SparkleUpdateController.swift"
    with tempfile.TemporaryDirectory(prefix="melo-verify-deferral-") as tmp:
        work = Path(tmp)
        macos = work / "Check.app/Contents/MacOS"
        macos.mkdir(parents=True)
        (work / "Check.app/Contents/Info.plist").write_text(STATE_CHECKS_PLIST)
        (work / "main.swift").write_text(
            STATE_CHECKS_SWIFT
            .replace("__PENDING_KEY__", pending_key)
            .replace("__REMIND_KEY__", remind_key)
        )
        binary = macos / "Check"
        # MELO_DEV for nothing in particular here — the checks drive the real
        # `init` and the real `remindLater()` — but the shipped file must build
        # in the configuration the harness uses, or a snapshot seam that stopped
        # compiling would only be found four minutes later in the app build.
        compiled = subprocess.run(
            argv + ["-D", "MELO_DEV", "-F", str(framework_dir),
                    "-Xlinker", "-rpath", "-Xlinker", str(framework_dir),
                    "-o", str(binary), str(work / "main.swift"), str(controller)],
            capture_output=True,
            text=True,
        )
        if compiled.returncode != 0:
            errors = [line for line in compiled.stderr.splitlines() if "error:" in line][:12]
            failures.append(
                "the deferral checks did not compile:\n        "
                + "\n        ".join(errors or compiled.stderr.splitlines()[:12])
            )
            return

        try:
            result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=120)
        except subprocess.TimeoutExpired:
            failures.append("the deferral checks never finished — the lapse timer did not fire")
            return
        finally:
            subprocess.run(["defaults", "delete", "melo.verify.updatestate"], capture_output=True)

        if result.returncode != 0:
            reported = [line[len("FAIL "):] for line in result.stdout.splitlines() if line.startswith("FAIL ")]
            failures.extend(f"SparkleUpdateController.swift: {line}" for line in reported)
            if not reported:
                failures.append(
                    f"the deferral checks exited {result.returncode} with no verdict: "
                    f"{(result.stderr or result.stdout).strip()[:300]}"
                )


run_update_state_checks()

# And the bypass must stay absent. `.available` may only be produced by
# `waitingState(for:)`, the one function that reads the deferral, plus
# `refreshReminder`, which promotes a lapsed `.deferred` and is what the timer
# is for. Producing the case anywhere else is how all four of the original paths
# went wrong.
#
# Matched on the case, not on `activity = .available(`, which is what this check
# tested first: `restingActivity` *returns* the state rather than assigning it,
# so the assignment form let the single largest fallback path — every session
# that ends, and every dismissed failure — go back to bypassing the deferral
# with this check still green. Negative-tested in both forms.
producers = [
    body_or_none(sparkle_code, signature) or ""
    for signature in ("private func refreshReminder()", "private func waitingState(")
]
elsewhere = sparkle_code
for body in producers:
    if body:
        elsewhere = elsewhere.replace(body, "")
for bypass in (".available(", "Activity.available"):
    if bypass in elsewhere:
        failures.append(
            f"SparkleUpdateController.swift: {bypass!r} outside waitingState/refreshReminder — a waiting "
            "update is announced without reading the deferral, so the Updates tab can offer a version "
            "whose badge and banner the user has silenced"
        )

# Once Sparkle has staged an update, its own delegate header states it "will
# always attempt to install the update when the app terminates" and there is no
# public way to unstage it. A Skip button there refuses nothing.
tab_code = code_of(root / "Sources/Melo/Views/Settings/Tabs/UpdatesTab.swift")
if ".readyToInstall" in body_of(tab_code, "private var offersSkip: Bool"):
    failures.append("UpdatesTab.swift: Skip is offered for a staged update it cannot stop installing at the next quit")
if "guard pendingUpdate != nil" not in body_of(sparkle_code, "func installDownloadedUpdateNow()"):
    failures.append("SparkleUpdateController.swift: installDownloadedUpdateNow still installs after the record was cleared")

# The states a decision produces must be rendered, or the next button that does
# nothing survives every check again.
#
# Set states are not enough, and this assertion used to accept them. Both
# `skipPendingUpdate()` and `remindLater()` guard on `pendingUpdate`, so a frame
# built by handing `.skipped(pending)` to `setActivityForSnapshot` shows what the
# state looks like while proving nothing about whether the button reaches it.
# That is exactly how a dead Skip button survived an earlier run's entire suite:
# ten verify scripts and forty-odd frames, both of which this project has since
# outgrown. Those are the numbers that run measured, not a count of today's —
# and the growth is the point, because a larger suite of the same kind of
# assertion would have missed it just as completely.
# `setPendingUpdateForSnapshot(_:)` exists so the real buttons
# can be pressed; an assertion that only proves the seam *exists* is the dead
# pattern CLAUDE.md names, and it passed while the seam had no caller at all.
scenes_code = code_of(root / "Sources/Melo/Utilities/SnapshotScenes.swift")
if "setPendingUpdateForSnapshot" not in scenes_code:
    failures.append(
        "SnapshotScenes.swift: setPendingUpdateForSnapshot has no caller — the Skip and Remind Me Later "
        "seam is unused, so those two buttons are still source-traced only. Both decisions must be driven "
        "from a SnapshotHarness.transition whose prepare puts a real pending update in place."
    )
# The scene has to be named exactly that, and the method has to be run *by that
# scene*. Both halves were bare substring tests over the whole file, and both
# were satisfiable without the behaviour: `updates-skippedX` contains
# "updates-skipped", and `skipPendingUpdate()` anywhere in a 700-line file
# satisfied the second — including from the other decision's scene, so one
# method could have driven both frames and this stayed green. Reading the two
# out of the same call expression is what ties them together.
def calls_naming(source: str, literal: str) -> list[str]:
    """Every parenthesised call expression containing `literal`, so a scene's
    name and the act it runs are read as one thing rather than as two
    independent substrings of the file."""
    calls: list[str] = []
    cursor = 0
    while (found := source.find(literal, cursor)) >= 0:
        cursor = found + len(literal)
        depth = 0
        start = None
        for index in range(found, -1, -1):
            if source[index] == ")":
                depth += 1
            elif source[index] == "(":
                if depth == 0:
                    start = index
                    break
                depth -= 1
        if start is None:
            continue
        depth = 0
        for index in range(start, len(source)):
            if source[index] == "(":
                depth += 1
            elif source[index] == ")":
                depth -= 1
                if depth == 0:
                    calls.append(source[start:index + 1])
                    break
    return calls

for scene, method in (("updates-skipped", "skipPendingUpdate()"), ("updates-deferred", "remindLater()")):
    calls = calls_naming(scenes_code, f'"{scene}"')
    if not calls:
        failures.append(f"SnapshotScenes.swift: no frame renders the card after the decision ({scene})")
    elif any(method not in call for call in calls):
        failures.append(
            f"SnapshotScenes.swift: the {scene} frame does not run {method} — it shows what the state "
            "looks like, not that the button produces it"
        )
# And the exact dead shape must not come back. Deliberately matched on the
# literal tuple rather than on the state name, because `.skipped(` legitimately
# appears wherever the card is described.
for dead in ('("updates-skipped", .skipped(', '("updates-deferred", .deferred('):
    failing_scene = dead.split('"')[1]
    if dead in scenes_code:
        failures.append(
            f"SnapshotScenes.swift: {failing_scene} is a set state again — the frame is handed the state "
            "directly instead of pressing the button that reaches it"
        )

# The notification is the announcement that needs permission. Asking and posting
# in the same breath races: the post is resolved against the authorization state
# at the time of the call, so the first notification is the one that is lost.
notify_body = body_of(sparkle_source, "private func postUpdateNotification(")
if "getNotificationSettings" not in notify_body or "requestAuthorization" not in notify_body:
    failures.append("SparkleUpdateController.swift: postUpdateNotification does not wait for an authorization answer before posting")

# --- The notification has to be answerable -----------------------------------
#
# Melo posted a notification with no category, so it had no buttons, and
# implemented `willPresent` but not `didReceive response`, so the system's
# default action just activated an LSUIElement app with no Dock tile and no
# window. Tapping the one thing that announces a new version opened nothing.
# HIG, Notifications: "Avoid sending a notification that tells people to perform
# specific tasks within your app… Otherwise, avoid telling people what to do
# because it's hard for people to remember such instructions after they dismiss
# the notification." — which is precisely what the body then had to say.
app_source = (root / "Sources/Melo/FineTuneApp.swift").read_text(errors="replace")
if "didReceive response" not in app_source or "handleNotificationResponse" not in app_source:
    failures.append(
        "FineTuneApp.swift: no didReceive-response handler — tapping the update "
        "notification activates an app with no window and opens nothing"
    )
if "categoryIdentifier" not in notify_body:
    failures.append("SparkleUpdateController.swift: the update notification carries no category, so it has no buttons")

# Every button the category declares must be routed. A category with an action
# nobody handles is the same dead end in a new place: the button is drawn, it is
# pressed, and the completion handler fires having done nothing.
category_body = body_of(sparkle_code, "static var updateNotificationCategory")
handler_body = body_of(sparkle_code, "func handleNotificationResponse(")
declared_actions = re.findall(r"identifier:\s*(?:Self\.)?(\w*ActionIdentifier)", category_body)
if not declared_actions:
    failures.append("SparkleUpdateController.swift: updateNotificationCategory declares no actions, so the notification is still only an instruction")
for action in declared_actions:
    if action not in handler_body:
        failures.append(f"SparkleUpdateController.swift: notification action {action} is offered but never handled")
# Tapping the notification itself must do something. This is the case that was
# broken, and it is not covered by the loop above.
if "UNNotificationDefaultActionIdentifier" not in handler_body:
    failures.append("SparkleUpdateController.swift: tapping the update notification is not handled — the default action still opens nothing")
# And the body must state a fact, not issue an instruction the user has to
# remember after the banner is gone.
body_builder = body_of(sparkle_code, "private static func notificationBody(")
for instruction in ("Open Melo", "from the menu bar", "install it"):
    if instruction in body_builder:
        failures.append(
            f"SparkleUpdateController.swift: the notification body tells the user what to do ({instruction!r}) "
            "instead of offering an action"
        )

# --- The badge must sit beside the mark, not replace part of it --------------
#
# `badged(_:)` punches a transparent disc through the icon before drawing the
# dot, so the dot reads as a separate mark instead of merging into the artwork.
# At its shipped size that disc had a 4.5pt radius on an 18pt-tall canvas and
# swallowed the pixel mark's entire right-hand peak plus five cells of its
# baseline bar. No name-based check could see that; this one recomputes the
# geometry from both files and fails if the cleared disc touches a single filled
# cell of the mark.
icon_code = code_of(root / "Sources/Melo/Views/MenuBar/MenuBarIconCoordinator.swift")
badge_body = body_of(icon_code, "private static func badged(")
image_source = (root / "Sources/Melo/Views/MenuBar/MenuBarIconImage+NSImage.swift").read_text(errors="replace")

# The model below assumes these exact expressions. If the drawing changes shape,
# fail loudly here rather than keep checking a formula the code no longer uses.
for expression in (
    "size.width - diameter / 2 - gap",
    "size.height - diameter / 2 - gap",
    "center.x - diameter / 2 - gap",
    "width: diameter + gap * 2",
):
    if expression not in badge_body:
        failures.append(
            f"MenuBarIconCoordinator.swift: badged() no longer places the badge with {expression!r}; "
            "the geometry check below is modelling code that is gone"
        )

def scalar(source: str, name: str, pattern: str):
    match = re.search(pattern, source)
    if match is None:
        failures.append(f"verify-update-systems.py: could not read {name} — the badge geometry is unchecked")
        return None
    return float(match.group(1))

diameter = scalar(badge_body, "badge diameter", r"let diameter:\s*CGFloat\s*=\s*([\d.]+)")
gap = scalar(badge_body, "badge gap", r"let gap:\s*CGFloat\s*=\s*([\d.]+)")
canvas_w = scalar(image_source, "canvas width", r"canvasSize\s*=\s*NSSize\(width:\s*([\d.]+)")
canvas_h = scalar(image_source, "canvas height", r"canvasSize\s*=\s*NSSize\(width:\s*[\d.]+,\s*height:\s*([\d.]+)")
mark_rows = re.findall(r'"([01]{4,})"', image_source)

if None not in (diameter, gap, canvas_w, canvas_h) and mark_rows:
    columns, row_count = len(mark_rows[0]), len(mark_rows)
    # Transcribed from makePixelMeloMark: whole-point cells, centred, rounded.
    cell = math.floor(min(canvas_w / columns, canvas_h / row_count))
    origin_x = math.floor((canvas_w - cell * columns) / 2 + 0.5)
    origin_y = math.floor((canvas_h - cell * row_count) / 2 + 0.5)
    centre_x, centre_y = canvas_w - diameter / 2 - gap, canvas_h - diameter / 2 - gap
    radius = diameter / 2 + gap

    # The settled constraint: the status item's width must not change when an
    # update arrives, so nothing may be drawn outside the existing canvas.
    if centre_x + radius > canvas_w + 1e-9 or centre_y + radius > canvas_h + 1e-9 \
       or centre_x - radius < -1e-9 or centre_y - radius < -1e-9:
        failures.append(
            "MenuBarIconCoordinator.swift: the badge is drawn outside the "
            f"{canvas_w:g}×{canvas_h:g}pt canvas, so the menu bar item changes width when an update arrives"
        )

    eaten = []
    for row_index, row in enumerate(mark_rows):
        for column_index, character in enumerate(row):
            if character != "1":
                continue
            x0 = origin_x + column_index * cell
            y0 = origin_y + (row_count - 1 - row_index) * cell
            # Closest point of the cell to the disc's centre.
            nearest_x = min(max(centre_x, x0), x0 + cell)
            nearest_y = min(max(centre_y, y0), y0 + cell)
            if math.hypot(nearest_x - centre_x, nearest_y - centre_y) < radius:
                eaten.append((row_index, column_index))
    if eaten:
        where = ", ".join(f"r{r}c{c}" for r, c in eaten[:8])
        more = f" (+{len(eaten) - 8} more)" if len(eaten) > 8 else ""
        failures.append(
            f"MenuBarIconCoordinator.swift: the update badge erases {len(eaten)} cell(s) of the "
            f"menu bar mark — {where}{more}. It has to sit beside the glyph, not replace part of it."
        )

# The headline of the one item in the popup that expires must not be the
# quietest text on it. It was drawn in `textSecondary`, a full step below the
# device rows underneath.
banner_code = code_of(root / "Sources/Melo/Updates/PendingUpdateBanner.swift")
if "textSecondary" in banner_code:
    failures.append("PendingUpdateBanner.swift: the headline of the expiring item is drawn below the rows beneath it")

# --- Skip must mean what Sparkle means by it ---------------------------------
#
# Melo writes and reads Sparkle's own keys precisely so the two cannot disagree,
# which only works if it also uses Sparkle's own *rules*. `isSkipped` compared
# with `==` where SUAppcastDriver skips anything at or below the skipped version,
# and `recordSkip` always wrote the minor key where SPUSkippedUpdate writes the
# major pair for a majorUpgrade — so Skip in Melo's Settings and Skip in
# Sparkle's own alert left the app in different states.
skipped_body = body_of(sparkle_code, "private func isSkipped(")
record_body = body_of(sparkle_code, "private func recordSkip(")
if "compareVersion" not in skipped_body:
    failures.append("SparkleUpdateController.swift: isSkipped does not compare versions with Sparkle's comparator at all")
# The original defect exactly: `defaults.string(forKey:) == update.build`. A
# comparator somewhere else in the function does not redeem an equality test on
# the version itself, which is why this looks at the operator and not the
# vocabulary.
if re.search(r"==\s*update\.(build|version)\b", skipped_body):
    failures.append(
        "SparkleUpdateController.swift: isSkipped tests a version for equality, so it misses "
        "everything Sparkle skips at or below the skipped version"
    )
if "sparkleSkippedMajorVersion" not in skipped_body:
    failures.append("SparkleUpdateController.swift: isSkipped never reads SUSkippedMajorVersion, so a skipped major line comes back as a badge on the next launch")
if "sparkleSkippedMajorVersion" not in record_body:
    failures.append("SparkleUpdateController.swift: recordSkip writes the minor key for a major upgrade, so the next release in that line returns after the user refused it")
# A skip that a user-initiated check cannot clear is permanent by accident.
found_body = body_of(sparkle_code, "fileprivate func foundUpdate(")
if "clearSkip()" not in found_body:
    failures.append("SparkleUpdateController.swift: a user-initiated check does not clear the skip, so the check the user asked for stays filtered")

# The harness cannot press Skip or Remind Me Later without this: both guard on
# `pendingUpdate`, which is private(set). Without the seam, `updates-skipped`
# and `updates-deferred` are set states that prove nothing about the buttons.
#
# Checked as a behaviour, not a name: the seam has to live inside the MELO_DEV
# block — it must never exist in a shipping build — and it has to assign the
# `pendingUpdate` *property*, so `didSet` runs and the harness exercises the
# same state machine a real find produces. A seam that wrote the storage
# directly, or set something else, would let the buttons pass against a state
# the app can never be in.
dev_region = re.search(r"#if MELO_DEV(.*?)#endif", sparkle_code, re.S)
dev_block = dev_region.group(1) if dev_region else ""
if "func setPendingUpdateForSnapshot(" not in dev_block:
    failures.append(
        "SparkleUpdateController.swift: no MELO_DEV snapshot seam for pendingUpdate — Skip and "
        "Remind Me Later cannot be driven through their real buttons"
    )
elif "pendingUpdate = " not in body_of(dev_block, "func setPendingUpdateForSnapshot("):
    failures.append(
        "SparkleUpdateController.swift: setPendingUpdateForSnapshot does not assign the pendingUpdate "
        "property, so the harness drives a state the app cannot reach"
    )

# 3. What the tab says about cadence has to be what the app is configured to do.
if info.get("SUEnableAutomaticChecks") is not True:
    failures.append("Info.plist: SUEnableAutomaticChecks is not true — a user who skips onboarding never gets a background check")
if info.get("SUScheduledCheckInterval") != 86400:
    failures.append("Info.plist: SUScheduledCheckInterval is not the daily interval the Updates tab describes")

# A rollback ends with the previous build running again. Without a record the
# user sees the app quit, reopen, and still report the old version.
require("Sources/Melo/Updates/UpdateInstallationCoordinator.swift",
        "report rolled-back", "consumeInstallOutcome")
require("Sources/Melo/Updates/DeveloperUpdateManager.swift", "consumeInstallOutcome")
require("Sources/Melo/Views/Settings/Tabs/UpdatesTab.swift",
        "Check for Updates", "Install and Relaunch", "Try Again", "Show Release Notes",
        "rolledBack")

require("Sources/Melo/Updates/DeveloperUpdateManifest.swift",
        "schemaVersion", "packageType", "minimumMacOS", "sourceSubdirectory")
developer = require("Sources/Melo/Updates/DeveloperUpdateManager.swift",
        "chooseUpdateFile", "chooseFolderToCheck",
        "checkRememberedFolder", "scanFolder", "buildAndInstallReadyUpdate",
        # Folder scanning must not extract whole archives, and a superseded task
        # must not be able to overwrite a newer operation's status.
        "peekManifest", "generation")
require("Sources/Melo/Updates/UpdateFolderBookmark.swift", "withSecurityScope")
require("Sources/Melo/Updates/UpdatePackageValidator.swift",
        "validateArchivePaths", "bundle identifier", "codesign", "notNewer",
        "peekManifest")
require("Sources/Melo/Updates/UpdateBuildCoordinator.swift",
        "Build Melo.command", "separate process", "--dev")
install = require("Sources/Melo/Updates/UpdateInstallationCoordinator.swift",
        "Melo.previous.app", "Melo.incoming.app", "rolling back",
        # The four reliability invariants of the swap.
        "preflightArgument", "lsregister", "EXPECTED", "aborting with nothing changed")
updates_tab = require("Sources/Melo/Views/Settings/Tabs/UpdatesTab.swift",
        "Choose Update File", "Choose Folder to Check", "#if MELO_DEV")

# Installing from a pasted URL is gone on purpose: a local folder is what makes
# the developer loop fast, while an arbitrary remote link only added a way to be
# talked into running someone else's build script.
for label, text in (("DeveloperUpdateManager.swift", developer), ("UpdatesTab.swift", updates_tab)):
    if "installFromLink" in text or "secure link" in text:
        failures.append(f"{label}: the remote-link install path is back")

# The developer-update machinery must be compiled out of shipping builds, not
# merely hidden. Source packages execute build scripts from the archive.
for relative, needle in (
    ("Sources/Melo/Updates/UpdateBuildCoordinator.swift", "#if !MELO_DEV"),
    ("Sources/Melo/Updates/DeveloperUpdateManager.swift", "#if MELO_DEV"),
):
    text = (root / relative).read_text(errors="replace")
    if needle not in text:
        failures.append(f"{relative}: developer updates are not gated behind {needle}")

# A running bundle must never be moved, and the new build must prove it launches.
if "kill -0" not in install or "exit 3" not in install:
    failures.append("UpdateInstallationCoordinator.swift: swap does not abort when the old process is still running")
if "handlePreflightAndExitIfNeeded" not in (root / "Sources/Melo/FineTuneApp.swift").read_text(errors="replace"):
    failures.append("FineTuneApp.swift: preflight handler is not installed at startup")
require("scripts/build-app.sh", "--melo-preflight", "--dev")
require("Package.swift", 'Sparkle.git', 'exact: "2.9.5"')
require("Melo.xcodeproj/project.pbxproj", 'Sparkle in Frameworks', 'version = 2.9.5')
require("scripts/build-app.sh", 'Sparkle.framework', 'Melo.local.entitlements')
require("scripts/make-developer-update.sh", 'manifest.json', 'sourceSubdirectory')

# Free update hosting: Pages serves the feed, Releases carry the archives.
require("scripts/setup-github-updates.sh", "SUFeedURL", "github.io", "/docs")
require("scripts/sparkle-setup.sh", "generate_keys", "SUPublicEDKey")
release = require("scripts/release.sh", "generate_appcast", "--download-url-prefix", "gh release create")
# A distributed build must never carry the developer-update machinery.
if "--release" not in release:
    failures.append("release.sh: publishes without forcing a --release build")
require("scripts/templates/download-page.html", "Open Anyway", "__RELEASES_URL__", "__VERSION__")
# The one-command path must create the repo and enable Pages over the API rather
# than sending the user into a browser to click through settings.
require("scripts/publish-setup.sh", "gh repo create", "repos/${SLUG}/pages", "generate_keys", "release.sh")

# Homebrew must not be a hard prerequisite: gh ships a standalone binary and many
# Macs do not have brew installed.
gh_lib = require("scripts/lib/gh.sh", "melo_ensure_gh", "cli/cli/releases")
# The tool must not live under .build-melo — build-app.sh wipes that folder at
# the start of every build, which deleted gh mid-release once already. Comments
# are stripped first, since the explanation of this rule names the folder.
gh_code = "\n".join(
    line for line in gh_lib.splitlines() if not line.lstrip().startswith("#")
)
if ".build-melo" in gh_code:
    failures.append("lib/gh.sh: installs into the folder build-app.sh wipes")
if ".tools" not in gh_code:
    failures.append("lib/gh.sh: does not install into a build-safe .tools folder")
# release.sh runs standalone for every future release, so it has to find gh
# itself rather than inheriting a PATH from publish-setup.sh.
for script in ("scripts/publish-setup.sh", "scripts/release.sh"):
    text = (root / script).read_text(errors="replace")
    if "melo_ensure_gh" not in text:
        failures.append(f"{script}: does not resolve the GitHub CLI itself")
require("Documentation/MELO-2.7-UPDATES.md", "Sparkle 2.9.5", "three sources")

if "SUFeedURL" not in info or "SUPublicEDKey" not in info:
    failures.append("Sparkle configuration keys missing")

project = require("Melo.xcodeproj/project.pbxproj")
for source in sorted((root / "Sources/Melo").rglob("*.swift")):
    relative = str(source.relative_to(root))
    if relative not in project:
        failures.append(f"Xcode target missing {relative}")

if failures:
    print("Update-system verification failed:")
    for failure in failures:
        print(f"  - {failure}")
    sys.exit(1)
print("Update-system verification passed.")
