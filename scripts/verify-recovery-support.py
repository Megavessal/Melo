#!/usr/bin/env python3
from pathlib import Path
import plistlib
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

require(
    "Sources/Melo/Coordination/AppSupportCoordinator.swift",
    "eraseAllDataAndRestart",
    "replayTutorial",
    "createDiagnosticReport",
    "MeloDiagnosticReport",
    "setDockVisible",
)
require(
    "Sources/Melo/Views/MenuBar/MenuBarIconCoordinator.swift",
    "addLocalMonitorForEvents",
    "Replay Tutorial",
    "Show Melo in Dock",
    "Report a Problem",
    "Quit Melo",
)
require(
    "Sources/Melo/Views/Settings/Tabs/GeneralTab.swift",
    "Getting Started",
    "Replay Tutorial",
    "Show Melo in Dock",
    "Erase All Melo Data",
    "Help and Diagnostics",
)
require(
    "Sources/Melo/Settings/SettingsManager.swift",
    "showInDock",
    "prepareForFullErase",
    "makeDiagnosticsSnapshot",
    "persistenceDisabledForErase",
)
require(
    "Sources/Melo/Coordination/OnboardingWindowController.swift",
    "func replay()",
)
project = require(
    "Melo.xcodeproj/project.pbxproj",
    "AppSupportCoordinator.swift in Sources",
    '"@executable_path/../Frameworks"',
)
if '"$(inherited) @executable_path/../Frameworks"' in project:
    failures.append("malformed combined runtime search path remains")

with (root / "Config/Info.plist").open("rb") as file:
    info = plistlib.load(file)
if "MeloDiagnosticsEndpoint" not in info:
    failures.append("future diagnostics endpoint key missing")

build_command = require("Build Melo.command", "[[ -t 0 ]]")

if failures:
    print("Recovery/support verification failed:")
    for failure in failures:
        print(f"  - {failure}")
    sys.exit(1)
print("Recovery/support verification passed.")
