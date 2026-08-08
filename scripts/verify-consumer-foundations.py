#!/usr/bin/env python3
"""Release guard for Melo 2.5 consumer-foundation features."""
from pathlib import Path
import re
import sys

root = Path(__file__).resolve().parents[1]
failures: list[str] = []

def require_file(relative: str) -> str:
    path = root / relative
    if not path.is_file():
        failures.append(f"missing {relative}")
        return ""
    return path.read_text(errors="replace")

def require(relative: str, *needles: str) -> str:
    text = require_file(relative)
    for needle in needles:
        if needle not in text:
            failures.append(f"{relative}: missing marker {needle!r}")
    return text

# 1. Onboarding
require("Sources/Melo/Views/Onboarding/FirstRunOnboardingView.swift",
        'title: "Melo"', 'title: audioAccessTitle',
        'title: "Try It Once"', 'Button("Skip")')
require("Sources/Melo/Coordination/OnboardingWindowController.swift", "showIfNeeded()")
require("Sources/Melo/FineTuneApp.swift", "onboarding.showIfNeeded()")

# 2. Searchable guide
catalog = require("Sources/Melo/Models/SettingsGuide.swift", "static let all", 'title: "Always Show"')
require("Sources/Melo/Views/Settings/Guide/SettingsGuideView.swift", 'Try “keep Spotify visible” or “quieter calls”', "selectedCategory")
if catalog.count(".init(") < 68:
    failures.append("Settings guide should contain at least 68 plain-language entries")

# 3. Quiet move + Always show. The policy must retain its privacy boundary.
policy = require("Sources/Melo/Models/AppActivityPresentationPolicy.swift",
                 "case off", "case fifteenSeconds", "case thirtySeconds", "case oneMinute", "case never",
                 "presentation-only", '"Always show" keeps a row visible; it never means "keep audio captured."')
require("Sources/Melo/Views/Settings/Tabs/GeneralTab.swift", 'SettingsRow("Move Quiet Apps"')
popup = require("Sources/Melo/Views/MenuBarPopupView.swift", "scheduleQuietMove", "rescheduleQuietAppMoves")
if "quietMoveDelaySeconds" in popup or ".seconds(15)" in popup:
    failures.append("MenuBarPopupView still contains the old hardcoded quiet delay")
require("Sources/Melo/Views/Rows/AppEditRow.swift", 'Always show this app', 'accessibilityLabel')

# 4. Call lowering.
#
# This used to pin the markers `activeLevelThreshold` and `1_500`. Both were
# satisfied by a constant merely existing — the shape CLAUDE.md lists as a dead
# pattern — and neither could tell a working duck from one that never comes back
# up. The trigger rule now lives in `CallActivityDetector` and is *executed*
# against chime-shaped and call-shaped level sequences by
# scripts/verify-unasked-actions.py; what is checked here is the wiring around
# it, which that file does not look at.
ducking = require_file("Sources/Melo/Coordination/CallDuckingManager.swift")
if "setCallDuckingMonitoringPIDs" not in ducking:
    failures.append("CallDuckingManager: no longer tells the engine which PIDs to meter")
if "CallActivityDetector" not in ducking:
    failures.append("CallDuckingManager: the call-versus-notification distinction must stay in CallActivityDetector")
ramps = [
    (float(target), deactivate == "true")
    for target, deactivate in re.findall(
        r"rampGain\(to: ([0-9.]+), milliseconds: \d+, deactivateAfter: (true|false)\)",
        ducking,
    )
]
if not any(target < 1.0 and not deactivate for target, deactivate in ramps):
    failures.append("CallDuckingManager: nothing ramps the other apps down when a call starts")
if not any(target == 1.0 and deactivate for target, deactivate in ramps):
    failures.append("CallDuckingManager: nothing ramps the other apps back up and clears the ducking flag — a duck with no release is silent audio")
engine = require("Sources/Melo/Audio/Engine/AudioEngine.swift",
                 "callDuckingGain", "setCallDuckingMonitoringPIDs", "communicationAppPIDs")
require("Sources/Melo/Views/Settings/Tabs/AudioTab.swift", '"Lower Other Apps During Calls"', '"Choose Call Apps"')

# 5. App Intents and Xcode metadata path
require("Sources/Melo/Shortcuts/MeloAppIntents.swift",
        "UseMeloSceneIntent", "SetMeloAppVolumeIntent", "SetMeloAppMuteIntent",
        "StartMeloSleepTimerIntent", "FixMeloAudioIntent", "MeloAppShortcuts")
project = require("Melo.xcodeproj/project.pbxproj",
                  "ENABLE_APP_INTENTS_METADATA_EXTRACTION = YES", "MeloAppIntents.swift", "AppIntents")
for source_path in sorted((root / "Sources/Melo").rglob("*.swift")):
    relative = str(source_path.relative_to(root))
    if relative not in project:
        failures.append(f"Xcode project does not include {relative}")
require("Melo.xcodeproj/xcshareddata/xcschemes/Melo.xcscheme", 'BlueprintName="Melo"')
require("scripts/build-app.sh", "xcodebuild", "Metadata.appintents")

# 6. Lower-priority items
require("Sources/Melo/Views/Settings/Tabs/EverydayTab.swift",
        '"Match a Scene to a Focus"', '"Sleep Timer"')
require("Sources/Melo/Audio/Loudness/AdaptiveAudioSettings.swift", "dialogueBoostEnabled")
require("Sources/Melo/Audio/Loudness/AdaptiveAudioProcessor.swift", "dialogueBoostEnabled")
require("Sources/Melo/Audio/Engine/ProcessTapController.swift", "monoAudioEnabled")
require("Sources/Melo/Coordination/SleepTimerManager.swift", "fadeOutAndMute")
require("Sources/Melo/Settings/SettingsManager.swift", "PortableSettingsBackup", "exportSettings", "importSettings")
require("Sources/Melo/Audio/Keys/PlaybackPauseService.swift", "sendPlayPause")
require("Sources/Melo/Coordination/PowerSourceMonitor.swift", "IOPSCopyPowerSourcesInfo")
require("Sources/Melo/Audio/Engine/CrossfadeOrchestrator.swift", "equal-power", "static var duration")

# Migration defaults and release metadata
settings = require("Sources/Melo/Settings/SettingsManager.swift",
                   "onboardingVersionCompleted", "quietMoveDelay", "lowerOtherAppsDuringCalls",
                   "monoAudioEnabled", "pauseOnHeadphoneDisconnect", "reduceProcessingOnBattery")

if failures:
    print("Consumer foundation verification failed:")
    for failure in failures:
        print(f"  - {failure}")
    sys.exit(1)
print("Consumer foundation verification passed.")
