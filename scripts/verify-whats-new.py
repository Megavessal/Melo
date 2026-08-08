#!/usr/bin/env python3
"""Keeps the What's New flow honest.

The whole feature rests on one promise: after an update, Melo can tell you what
changed. That promise is only kept if every shipped build has release notes, so
this script fails the build when the version in Info.plist has no entry in
`MeloReleaseNotes.all`, when the entry disagrees with the build number, or when
any entry ships with nothing in it.
"""
from pathlib import Path
import plistlib
import re
import sys

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


notes_source = require(
    "Sources/Melo/Models/MeloReleaseNotes.swift",
    "struct MeloReleaseNote",
    "static let all: [MeloReleaseNote]",
    "let target: GuidedTourTarget?",
)

# The registry is Swift, not data, so it is parsed structurally rather than
# imported: each `MeloReleaseNote(` literal, its version/build, and how many
# `MeloReleaseNote.Item(` literals sit inside it before the next note begins.
note_starts = [m.start() for m in re.finditer(r"MeloReleaseNote\(\n", notes_source)]
notes: list[dict] = []
for index, start in enumerate(note_starts):
    end = note_starts[index + 1] if index + 1 < len(note_starts) else len(notes_source)
    body = notes_source[start:end]
    version = re.search(r'version:\s*"([^"]+)"', body)
    build = re.search(r"build:\s*(\d+)", body)
    if not version or not build:
        failures.append("MeloReleaseNotes.swift: a release note has no version or build")
        continue
    notes.append(
        {
            "version": version.group(1),
            "build": int(build.group(1)),
            "items": len(re.findall(r"MeloReleaseNote\.Item\(", body)),
            "headline": re.search(r'headline:\s*"([^"]+)"', body) is not None,
        }
    )

if not notes:
    failures.append("MeloReleaseNotes.swift: no release notes found in `all`")

for note in notes:
    if note["items"] == 0:
        failures.append(f"release note {note['version']} has no items")
    if not note["headline"]:
        failures.append(f"release note {note['version']} has no headline")

builds = [note["build"] for note in notes]
if builds != sorted(builds, reverse=True):
    failures.append("MeloReleaseNotes.all is not newest-first")
if len(set(builds)) != len(builds):
    failures.append("two release notes share a build number")

with (root / "Config/Info.plist").open("rb") as file:
    info = plistlib.load(file)
shipping_version = info.get("CFBundleShortVersionString")
shipping_build = info.get("CFBundleVersion")

matching = [note for note in notes if note["version"] == shipping_version]
if not matching:
    failures.append(
        f"Config/Info.plist ships {shipping_version} but MeloReleaseNotes.all has no entry for it — "
        "every release has to write its own notes"
    )
else:
    expected = str(matching[0]["build"])
    if expected != shipping_build:
        failures.append(
            f"release note {shipping_version} says build {expected}, Info.plist says {shipping_build}"
        )

# The flow itself: without these the notes exist but nobody is ever shown them.
require(
    "Sources/Melo/Coordination/WhatsNewCoordinator.swift",
    "lastSeenReleaseBuild",
    "suppressedByOnboarding",
    "MeloReleaseNotes.notes(after:",
    "guidedTour.begin(steps:",
)
require(
    "Sources/Melo/Settings/SettingsManager.swift",
    "var lastSeenReleaseBuild: Int = 0",
    "decodeIfPresent(Int.self, forKey: .lastSeenReleaseBuild)",
)
# The needle is the button, not the phrase. It was bare "Show Me", which this
# file's own doc comment above `hasTour` also contains — measured 2026-08-08:
# renaming the button and leaving the comment kept this green.
require(
    "Sources/Melo/Views/Onboarding/WhatsNewView.swift",
    'Button("Show Me")',
    "Version \\(note.version)",
)
require("Sources/Melo/Views/Settings/Tabs/AboutTab.swift", "What's New in Melo", "showWhatsNew()")
app = require("Sources/Melo/FineTuneApp.swift", "whatsNew.showIfNeeded(suppressedByOnboarding:")
# A fresh install must never see release notes, so the coordinator has to be
# handed the fact that setup is about to appear rather than guessing.
if "onboarding.isSetupPending" not in app:
    failures.append("FineTuneApp.swift: What's New does not stand down for first-run setup")

# The Bluetooth rules used to live here and have moved to
# scripts/verify-unasked-actions.py, which is their subject. Two of them were
# also wrong by the time they were removed.
#
# The engine check required `onboardingVersionCompleted >= …`, on the stated
# grounds that setup showed a page explaining Bluetooth first. That page was
# deleted, and `decodeSettings` stamps onboarding complete for every
# pre-existing install, so the guard passed at launch on exactly the machines it
# was supposed to protect. Launch no longer touches IOBluetooth at all, which is
# checked there by reading the startup block.
#
# The monitor check counted `guard isStarted` and wanted at least four. One of
# the four is `start()`'s own idempotence guard, which is not an IOBluetooth
# entry point — so the count could stay at four while `connect()` lost its gate.
# The replacement reads each entry point's body individually.

# The tour is data-driven now, and MenuBarPopupView's row-expansion mapping keys
# off SpotlightStep ids. Renaming an id without updating the popup still
# compiles — it just silently stops expanding the right row before a step — so
# the two files are tied together here.
popup = (root / "Sources/Melo/Views/MenuBarPopupView.swift").read_text(errors="replace")
coordinator = (root / "Sources/Melo/Coordination/GuidedTourCoordinator.swift").read_text(errors="replace")
if "GuidedTourCoordinator.Step" in popup or "guidedTour.step)" in popup:
    failures.append("MenuBarPopupView.swift: still references the removed Step enum")
for needle in ('id: "devices"', 'id: "autoEQ"', 'id: "equalizer"'):
    if needle not in coordinator:
        failures.append(f"GuidedTourCoordinator.swift: first-run tour lost {needle!r}, which MenuBarPopupView matches on")
for needle in ('case "devices", "autoEQ":', 'case "equalizer":'):
    if needle not in popup:
        failures.append(f"MenuBarPopupView.swift: row-expansion mapping lost {needle!r}")

if failures:
    print("What's New verification failed:")
    for failure in failures:
        print(f"  - {failure}")
    sys.exit(1)
print("What's New verification passed.")
