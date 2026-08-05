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
# Up to three rockets can share the sky, each on its own cycle so they are not a
# formation, and each in its own vertical band so they never trace one line.
for needle in ("laneCount = 3", "laneTiming", "edgeLane(index:", "bandHeight"):
    if needle not in theme:
        failures.append(f"MeloVisualTheme.swift: multi-lane rockets missing {needle!r}")
if "CGSize(width: 46, height: 22)" not in theme or "CGSize(width: 43, height: 20)" not in theme:
    failures.append("MeloVisualTheme.swift: rockets are not 15% smaller (46x22 flying, 43x20 resting)")
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
project = require("Melo.xcodeproj/project.pbxproj", "ARCHS = arm64;", "EXCLUDED_ARCHS = x86_64;", "MARKETING_VERSION = 2.9.2;", "CURRENT_PROJECT_VERSION = 297;")
build = require("scripts/build-app.sh", "ARCHS=arm64", "EXCLUDED_ARCHS=x86_64", "Removed Intel slices", '[[ "$ARCHS" == "arm64" ]]')
if "ARCHS='arm64 x86_64'" in build or "ARCHS=arm64 x86_64" in build:
    failures.append("universal build flag remains in build script")
if '"$(inherited) @executable_path/../Frameworks"' in project:
    failures.append("malformed combined runtime search path remains")
with (root / "Config/Info.plist").open("rb") as file:
    info = plistlib.load(file)
if info.get("CFBundleShortVersionString") != "2.9.2": failures.append("wrong version")
if info.get("CFBundleVersion") != "297": failures.append("wrong build")

# Exactly one app icon source. Declaring both CFBundleIconFile and an asset
# catalog let macOS choose between two near-identical files, so the icon changed
# whenever Launch Services re-registered the bundle.
info_text = (root / "Config/Info.plist").read_text()
if "CFBundleIconFile" in info_text:
    failures.append("Config/Info.plist: CFBundleIconFile is back alongside the asset catalog")
if "Melo.icns" in project:
    failures.append("project.pbxproj: a second icon source (Melo.icns) is back in the bundle")
if "ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;" not in project:
    failures.append("project.pbxproj: app icon is not AppIcon")

# The Dock tile follows the system appearance. A .appiconset carries exactly one
# artwork, so the light/dark pair ships as image sets and is applied at runtime.
require("Sources/Melo/Coordination/DockIconAppearanceCoordinator.swift",
        "applicationIconImage", "AppleInterfaceThemeChangedNotification",
        "AppIconDark", "AppIconLight", "bestMatch(from: [.aqua, .darkAqua])")
if "DockIconAppearanceCoordinator.shared.start()" not in (root/"Sources/Melo/FineTuneApp.swift").read_text():
    failures.append("FineTuneApp.swift: the Dock icon coordinator is never started")
if "DockIconAppearanceCoordinator.shared.apply()" not in (root/"Sources/Melo/Coordination/AppSupportCoordinator.swift").read_text():
    failures.append("AppSupportCoordinator.swift: a newly shown Dock tile is not re-iconed")
for name in ("AppIconDark", "AppIconLight"):
    d = root / f"Resources/Assets.xcassets/{name}.imageset"
    for f in (f"{name}.png", f"{name}@2x.png", "Contents.json"):
        if not (d / f).is_file():
            failures.append(f"missing appearance icon {name}.imageset/{f}")

# macOS 26 boxes icons whose artwork carries its own rounded shape, shrinking
# them inside a grey container. Full-bleed (fully opaque) art avoids that.
try:
    from PIL import Image
    for rel in ("Resources/Assets.xcassets/AppIcon.appiconset/icon_512x512@2x.png",
                "Resources/Assets.xcassets/AppIconDark.imageset/AppIconDark@2x.png",
                "Resources/Assets.xcassets/AppIconLight.imageset/AppIconLight@2x.png"):
        alpha = Image.open(root / rel).convert("RGBA").split()[3]
        if alpha.getextrema()[0] != 255:
            failures.append(f"{rel}: artwork has transparent corners; macOS 26 will box it")
except ImportError:
    pass

if failures:
    print("Theme/architecture verification failed:")
    for failure in failures: print(f"  - {failure}")
    sys.exit(1)
print("Theme/architecture verification passed.")
