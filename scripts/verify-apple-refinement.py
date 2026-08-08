#!/usr/bin/env python3
from pathlib import Path
import re, sys

root = Path(__file__).resolve().parents[1]
failures = []

def require(path, *needles):
    p = root / path
    if not p.is_file():
        failures.append(f"missing {path}")
        return ""
    text = p.read_text(errors="replace")
    for needle in needles:
        if needle not in text:
            failures.append(f"{path}: missing {needle!r}")
    return text

# One overlay, one label. The end of setup, What's New's footer and the Guide's
# popup chip all call `guidedTour.begin` and then `popupController.toggle()`
# across the same 0.35s handoff, so all three read "Show Me". "Show Me Around"
# was true of this entry point alone: What's New builds its steps from the
# release notes and the Guide builds exactly one, and "Around" promised those
# two a tour neither runs.
#
# `Button("…")`, not the bare phrase — "Show Me" is a substring of "Show Me
# Around" and of every doc comment that discusses either, so a bare needle
# cannot tell the rename from the thing it renamed.
require("Sources/Melo/Views/Onboarding/FirstRunOnboardingView.swift",
        'title: "Melo"', 'short sound', 'Button("Show Me")')
require("Sources/Melo/Coordination/FirstRunAudioPrimer.swift", "runFirstRunAudioPrimer")
require("Sources/Melo/Audio/Engine/ProcessTapController.swift", "startAudioDeviceOffMainThread")
# Tour copy now lives beside the data in the coordinator; the overlay only
# renders whichever step list it is handed.
require("Sources/Melo/Coordination/GuidedTourCoordinator.swift",
        "AutoEQ corrects supported headphones", "Search finds actions")
# What marks a step's target is the ring struck on the spotlight cutout, built
# from the resolved rect. The tour also drew a copy of the system arrow cursor
# there: a second pointer, in the user's own pointer's artwork, that the user
# cannot move and that is never where their hand is. The absence is asserted
# beside the presence, because removing the arrow and leaving no ring is a step
# that points at nothing.
#
# The needle is the *call*, not the shape. It was "SpotlightRing(cutout: rect",
# which lives inside `spotlightRing(_:)`'s own body — measured 2026-08-07:
# deleting the call from `body`, so no ring is ever drawn, left this green.
tour = require("Sources/Melo/Views/Onboarding/GuidedTourOverlay.swift",
        "GuidedTourTargetPreferenceKey",
        "coordinator.currentStep")
if "NSCursor" in tour or "Image(nsImage:" in tour:
    failures.append("GuidedTourOverlay.swift: the tour draws a pointer of its own beside the one the user is holding")
if "Keep quiet apps visible?" in tour:
    failures.append("quiet-app setup question must not appear in onboarding or the guided tour")
# The Guide draws two chips that do unrelated things: one opens the popup and
# spotlights a control through the tour overlay, the other switches the Settings
# tab and scrolls to a heading. They read "Show me in Melo" and "Show me" — a
# single capital apart — so the reader learned nothing from the label and found
# out which was which by pressing it. The pair is pinned together, because
# either one drifting back re-opens the collision.
guide = require("Sources/Melo/Views/Settings/Guide/SettingsGuideView.swift",
        "categoryButton", "searchScore",
        'title: "Show Me"', 'title: "Take Me There"')
if 'title: "Show me' in guide:
    failures.append(
        'SettingsGuideView.swift: a chip is spelled "Show me…" again — sentence case, and '
        "a near-copy of the overlay label it is not the overlay"
    )
require("Sources/Melo/Utilities/IntentSearch.swift", "synonymGroups", "editDistance")
require("Sources/Melo/Views/MenuBarPopupView.swift",
        "GuidedTourOverlay", "ConsumerCommandPalette", ".guidedTourTarget(.apps)")
require("Sources/Melo/Updates/SparkleUpdateController.swift",
        "SPUStandardUpdaterController", "automaticallyChecksForUpdates", "automaticallyDownloadsUpdates")
require("Sources/Melo/Updates/DeveloperUpdateManager.swift",
        "chooseUpdateFile", "chooseFolderToCheck", "scanFolder")
require("Sources/Melo/Updates/UpdateInstallationCoordinator.swift",
        "confirmCurrentBuild", "rolling back", "Melo.previous.app", "preflightArgument")
require("Documentation/MELO-2.7-UPDATES.md", "Sparkle 2.9.5", "replay onboarding")
require("Resources/MeloFirstRunIntro.wav")

project = (root / "Melo.xcodeproj/project.pbxproj").read_text()
for source in (root / "Sources/Melo").rglob("*.swift"):
    rel = str(source.relative_to(root))
    if rel not in project:
        failures.append(f"Xcode target missing {rel}")
if "MeloFirstRunIntro.wav in Resources" not in project:
    failures.append("intro sound is not in the Xcode resources phase")

icon_dir = root / "Resources/Assets.xcassets/AppIcon.appiconset"
for name in ["icon_16x16.png", "icon_128x128@2x.png", "icon_512x512@2x.png"]:
    if not (icon_dir / name).is_file(): failures.append(f"missing restored icon {name}")

if failures:
    print("Apple refinement verification failed:")
    for failure in failures: print(f"  - {failure}")
    sys.exit(1)
print("Apple refinement verification passed.")
