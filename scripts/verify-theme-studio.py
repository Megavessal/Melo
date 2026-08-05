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

require("Sources/Melo/Settings/Types/SettingsUITypes.swift", "case aurora", "case aiGenerated", "struct GeneratedMeloTheme", "starDensity", "sparkleStrength", "showsRocket", "min(max(starDensity, 0), 48)", "min(max(sparkleStrength, 0.04), 0.28)")
require("Sources/Melo/Settings/SettingsManager.swift", "generatedTheme: GeneratedMeloTheme? = nil", "decodeIfPresent(GeneratedMeloTheme.self", "visualTheme == .aiGenerated")
theme = require("Sources/Melo/Views/DesignSystem/MeloVisualTheme.swift", "AnimatedStarField", "density: 21", "sparkleStrength: 0.22", "AuroraNightBackdrop", "AuroraRibbons", "RocketFlight", "PixelRocketGlyph", "edgeLane", "GeneratedThemeBackdrop")
# Backdrops now take an isVisible flag so they stop animating when the popup
# is closed, so match the call rather than the exact empty argument list.
if theme.count("RocketFlight(") < 4:
    failures.append("rocket is not available across Space, Galaxy, Aurora, and generated themes")
require("Sources/Melo/Views/Settings/Components/ThemeTilePicker.swift", "case .aurora", "case .aiGenerated")
general = require("Sources/Melo/Views/Settings/Tabs/GeneralTab.swift", "Theme Studio", "AIThemeStudioView", "ChatGPT Theme Bridge", "Copy Prompt & Open ChatGPT", "https://chatgpt.com/", "Return JSON only", "No API key", "Create…")
for forbidden in ("api.openai.com", "OpenAIThemeKeychain", "OpenAIThemeService", "gpt-5.6-luna"):
    if forbidden in general:
        failures.append(f"unsafe or unsupported direct-AI integration remains: {forbidden}")
require("Sources/Melo/Views/MenuBar/MenuBarIconCoordinator.swift", "@preconcurrency import AppKit", "addLocalMonitorForEvents", "addGlobalMonitorForEvents", "presentContextMenu")
# Source updates now delegate entirely to the project's own build script, which is
# what enforces arm64-only output, embeds Sparkle, and signs the result. A bare
# xcodebuild invocation did none of those and produced bundles that would not launch.
build_coordinator = require("Sources/Melo/Updates/UpdateBuildCoordinator.swift", "Build Melo.command", "scripts/build-app.sh")
if "/usr/bin/xcodebuild" in build_coordinator and "xcodebuild\"," in build_coordinator:
    failures.append("UpdateBuildCoordinator.swift: builds must go through build-app.sh, not a direct xcodebuild invocation")
project = require("Melo.xcodeproj/project.pbxproj", "ARCHS = arm64;", "EXCLUDED_ARCHS = x86_64;", "MARKETING_VERSION = 2.9.0;", "CURRENT_PROJECT_VERSION = 294;")
build = require("scripts/build-app.sh", "ARCHS=arm64", "EXCLUDED_ARCHS=x86_64", "Removed Intel slices", '[[ "$ARCHS" == "arm64" ]]')
if "ARCHS='arm64 x86_64'" in build or "ARCHS=arm64 x86_64" in build:
    failures.append("universal build flag remains in build script")
if '"$(inherited) @executable_path/../Frameworks"' in project:
    failures.append("malformed combined runtime search path remains")
with (root / "Config/Info.plist").open("rb") as file:
    info = plistlib.load(file)
if info.get("CFBundleShortVersionString") != "2.9.0": failures.append("wrong version")
if info.get("CFBundleVersion") != "294": failures.append("wrong build")
if failures:
    print("Theme/architecture verification failed:")
    for failure in failures: print(f"  - {failure}")
    sys.exit(1)
print("Theme/architecture verification passed.")
