#!/usr/bin/env python3
from pathlib import Path
import plistlib, re, sys

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

require("Sources/Melo/Views/Onboarding/FirstRunOnboardingView.swift",
        'title: "Melo"', 'short sound', 'Show Me Around')
require("Sources/Melo/Coordination/FirstRunAudioPrimer.swift", "runFirstRunAudioPrimer")
require("Sources/Melo/Audio/Engine/ProcessTapController.swift", "startAudioDeviceOffMainThread")
tour = require("Sources/Melo/Views/Onboarding/GuidedTourOverlay.swift",
        "GuidedTourTargetPreferenceKey", "NSCursor.arrow.image",
        "AutoEQ corrects supported headphones", "Search finds actions")
if "Keep quiet apps visible?" in tour:
    failures.append("quiet-app setup question must not appear in onboarding or the guided tour")
require("Sources/Melo/Views/Settings/Guide/SettingsGuideView.swift",
        "categoryButton", "searchScore")
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

with (root / "Config/Info.plist").open("rb") as f:
    info = plistlib.load(f)
if info.get("CFBundleShortVersionString") != "2.9.2": failures.append("wrong version")
if info.get("CFBundleVersion") != "297": failures.append("wrong build")

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
