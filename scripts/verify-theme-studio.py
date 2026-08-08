#!/usr/bin/env python3
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

require("Sources/Melo/Settings/Types/SettingsUITypes.swift", "case aurora", "case aiGenerated", "struct GeneratedMeloTheme", "starDensity", "sparkleStrength", "showsRocket", "min(max(starDensity, 0), 48)", "min(max(sparkleStrength, 0.04), 0.28)")
require("Sources/Melo/Settings/SettingsManager.swift", "generatedTheme: GeneratedMeloTheme? = nil", "decodeIfPresent(GeneratedMeloTheme.self", "visualTheme == .aiGenerated")
theme = require("Sources/Melo/Views/DesignSystem/MeloVisualTheme.swift", "AnimatedStarField", "density: 21", "sparkleStrength: 0.22", "AuroraNightBackdrop", "AuroraRibbons", "RocketFlight", "PixelRocketGlyph", "edgeLane", "GeneratedThemeBackdrop")
# Theme decoration is drawn per-theme in a `switch theme` inside
# `MeloThemeBackdrop`, and a branch quietly gaining — or losing — a decoration is
# invisible in review. That is exactly how rockets came to be flying on Aurora.
#
# The assertion that used to stand here counted `RocketFlight(` call sites and
# passed on any four of them. It could not tell Space from Aurora, so it could
# not have caught that defect, and it pinned the wrong answer besides: it
# required the rocket on Aurora, which is the theme the owner asked to clear.
#
# This walks the composition instead. It takes each `case .theme:` branch of the
# switch, follows every `View` struct that branch constructs — `.aurora` reaches
# its cabin through `AuroraNightBackdrop` rather than directly — and asserts the
# set of *visitors* reachable from each theme is exactly the expected one.
# Both directions: the themes that should have a rocket do, and the themes that
# should not, do not. Only the second half could have caught the original bug.

def strip_swift_comments(src: str) -> str:
    """Comments name the very symbols being counted (`// The rocket belongs to
    Space and Galaxy`), so a textual search over raw source finds decorations in
    prose. Handles `//`, nested `/* */` and plain string literals; this file has
    no multiline `\"\"\"` strings."""
    out, i, n, in_string = [], 0, len(src), False
    while i < n:
        char = src[i]
        if in_string:
            if char == "\\" and i + 1 < n:
                out.append(src[i:i + 2]); i += 2; continue
            if char == '"': in_string = False
            out.append(char); i += 1; continue
        if char == '"':
            in_string = True; out.append(char); i += 1; continue
        if src.startswith("//", i):
            while i < n and src[i] != "\n": i += 1
            continue
        if src.startswith("/*", i):
            depth, i = 1, i + 2
            while i < n and depth:
                if src.startswith("/*", i): depth, i = depth + 1, i + 2
                elif src.startswith("*/", i): depth, i = depth - 1, i + 2
                else: i += 1
            continue
        out.append(char); i += 1
    return "".join(out)

def braced_block(text: str, open_index: int) -> str:
    """Body between the brace at `open_index` and its match."""
    depth = 0
    for i in range(open_index, len(text)):
        if text[i] == "{": depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0: return text[open_index + 1:i]
    return ""

# The four easter eggs. Membership in this set is what is pinned per theme; the
# ambient decoration below is only required to be present, so adding a new
# gradient or glow to a theme does not fail the run.
VISITORS = {"RocketFlight", "DeskMacPeek", "CabinWindowLight", "PaintBrushStroke"}
EXPECTED_VISITORS = {
    "systemAccent": {"DeskMacPeek"},
    "space": {"RocketFlight"},
    "galaxy": {"RocketFlight"},
    "aurora": {"CabinWindowLight"},
    "custom": {"PaintBrushStroke"},
}
REQUIRED_AMBIENT = {
    "space": {"AnimatedStarField"},
    "galaxy": {"AnimatedStarField"},
    "aurora": {"AnimatedStarField", "AuroraRibbons", "NightMountainSilhouette"},
}

clean = strip_swift_comments(theme)
view_bodies = {}
for match in re.finditer(r"\bstruct\s+(\w+)\s*:\s*View\s*\{", clean):
    view_bodies[match.group(1)] = braced_block(clean, match.end() - 1)

def constructed_views(snippet, seen=None):
    """Every `View` struct this snippet constructs, transitively."""
    seen = set() if seen is None else seen
    direct = {name for name in view_bodies if re.search(rf"\b{name}\s*\(", snippet)}
    found = set(direct)
    for name in direct - seen:
        seen.add(name)
        found |= constructed_views(view_bodies[name], seen)
    return found

backdrop = view_bodies.get("MeloThemeBackdrop", "")
switch_match = re.search(r"switch\s+theme\s*\{", backdrop)
if not switch_match:
    failures.append("MeloVisualTheme.swift: MeloThemeBackdrop no longer switches on theme; per-theme decoration cannot be verified")
else:
    switch_body = braced_block(backdrop, switch_match.end() - 1)
    case_marks = list(re.finditer(r"case\s+\.(\w+)\s*:", switch_body))
    branches = {
        mark.group(1): switch_body[mark.end():(case_marks[i + 1].start() if i + 1 < len(case_marks) else len(switch_body))]
        for i, mark in enumerate(case_marks)
    }
    for case_name, expected in EXPECTED_VISITORS.items():
        if case_name not in branches:
            failures.append(f"MeloVisualTheme.swift: no `case .{case_name}` branch in the theme switch")
            continue
        reachable = constructed_views(branches[case_name])
        actual = reachable & VISITORS
        for extra in sorted(actual - expected):
            failures.append(f"MeloVisualTheme.swift: `.{case_name}` draws {extra} and must not — that decoration belongs to another theme")
        for missing in sorted(expected - actual):
            failures.append(f"MeloVisualTheme.swift: `.{case_name}` no longer draws {missing}")
        for missing in sorted(REQUIRED_AMBIENT.get(case_name, set()) - reachable):
            failures.append(f"MeloVisualTheme.swift: `.{case_name}` lost its {missing}")

# `.aiGenerated` is the owner's to review, so its decoration set is not pinned.
# What is pinned is that its rocket stays behind the theme's own opt-in field
# rather than becoming unconditional.
generated = view_bodies.get("GeneratedThemeBackdrop", "")
if not re.search(r"if\s+theme\.showsRocket\s*\{[^{}]*RocketFlight\s*\(", generated, re.S):
    failures.append("MeloVisualTheme.swift: the generated theme's rocket is no longer gated on its own showsRocket opt-in")

# Every animated decoration must stop when the popup closes. One TimelineView in
# this file shipped with no `paused:` argument at all, so a closed menu-bar popup
# drove a 24 fps redraw loop behind it. Assert the gate on all of them, not that
# the symbol exists somewhere.
timelines = len(re.findall(r"TimelineView\s*\(", clean))
gated = len(re.findall(r"TimelineView\s*\(\s*\.animation\([^)]*paused:\s*isStatic", clean))
if timelines != gated:
    failures.append(f"MeloVisualTheme.swift: {timelines - gated} of {timelines} TimelineViews are not paused by isStatic; a closed popup will keep redrawing")
for egg in ("DeskMacPeek", "CabinWindowLight", "PaintBrushStroke", "RocketFlight"):
    body = view_bodies.get(egg, "")
    if "reduceMotion || !isVisible" not in body:
        failures.append(f"MeloVisualTheme.swift: {egg} no longer rests for Reduce Motion and a closed popup")

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
project = require("Melo.xcodeproj/project.pbxproj", "ARCHS = arm64;", "EXCLUDED_ARCHS = x86_64;", "MARKETING_VERSION = 2.9.4;", "CURRENT_PROJECT_VERSION = 299;")
build = require("scripts/build-app.sh", "ARCHS=arm64", "EXCLUDED_ARCHS=x86_64", "Removed Intel slices", '[[ "$ARCHS" == "arm64" ]]')
if "ARCHS='arm64 x86_64'" in build or "ARCHS=arm64 x86_64" in build:
    failures.append("universal build flag remains in build script")
if '"$(inherited) @executable_path/../Frameworks"' in project:
    failures.append("malformed combined runtime search path remains")
with (root / "Config/Info.plist").open("rb") as file:
    info = plistlib.load(file)
if info.get("CFBundleShortVersionString") != "2.9.4": failures.append("wrong version")
if info.get("CFBundleVersion") != "299": failures.append("wrong build")

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

# macOS does not mask app icons: the artwork has to carry its own rounded shape
# with transparent margin around it. A full-bleed opaque square renders as a hard
# square tile in a Dock of rounded ones — it reads as a cropped screenshot. Apple
# sizes the body at 824/1024 of the canvas; Melo uses 52/64 cells, which is the
# same proportion on a whole number of pixel-art cells.
try:
    from PIL import Image
    for rel in ("Resources/Assets.xcassets/AppIcon.appiconset/icon_512x512@2x.png",
                "Resources/Assets.xcassets/AppIconDark.imageset/AppIconDark@2x.png",
                "Resources/Assets.xcassets/AppIconLight.imageset/AppIconLight@2x.png"):
        alpha = Image.open(root / rel).convert("RGBA").split()[3]
        width, height = alpha.size
        if alpha.getpixel((0, 0)) != 0:
            failures.append(f"{rel}: corners are opaque; the Dock tile will be a hard square")
        if alpha.getpixel((width // 2, height // 2)) != 255:
            failures.append(f"{rel}: the icon body is not opaque")
        covered = sum(1 for value in alpha.getdata() if value > 0) / (width * height)
        if not 0.55 <= covered <= 0.72:
            failures.append(f"{rel}: body covers {covered:.0%} of the canvas; Apple's proportion is about 63%")
except ImportError:
    pass

if failures:
    print("Theme/architecture verification failed:")
    for failure in failures: print(f"  - {failure}")
    sys.exit(1)
print("Theme/architecture verification passed.")
