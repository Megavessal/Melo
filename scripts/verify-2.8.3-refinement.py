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

settings = require(
    "Sources/Melo/Settings/SettingsManager.swift",
    "static let guidedTour = 2",
    "quietMoveDelay = try c.decodeIfPresent",
    # Directive: quiet-app handling defaults to Never and is never asked about.
    # Matched loosely so renaming the local decode variable cannot silently drop it.
    "appSettings.quietMoveDelay = .never",
)
if "?? (onboardingVersionCompleted == 0 ? .never : .fifteenSeconds)" in settings:
    failures.append("legacy fifteen-second quiet-app migration remains")

tour = require(
    "Sources/Melo/Views/Onboarding/GuidedTourOverlay.swift",
    "NSCursor.arrow.image",
    "AutoEQ corrects supported headphones",
    "Smart Sound adapts automatically",
    "EQ changes the tone of one app",
    "Search finds actions, not only labels",
)
if "Keep quiet apps visible?" in tour or "quietAppsCard" in tour:
    failures.append("quiet-app setup question remains in guided tour")

coordinator = require(
    "Sources/Melo/Coordination/GuidedTourCoordinator.swift",
    "case autoEQ",
    "case smartAudio",
    "case equalizer",
    "case search",
    "case settings",
    "func finish()",
)
if "finish(quietMoveDelay" in coordinator:
    failures.append("guided tour still changes quiet-app behavior")

theme = require(
    "Sources/Melo/Views/DesignSystem/MeloVisualTheme.swift",
    "PixelRocketGlyph",
    "edgeLane(index: cycleIndex - 1",
    # Direction still alternates per cycle; the lane offset staggers the three
    # tracks so they do not all cross the same way at once.
    "(cycleIndex &+ lane).isMultiple(of: 2)",
    "max(-15, min(15, visualAngle))",
    "three-to-five-second rhythm",
    "different rates",
    "sparkleStrength: 0.22",
)

popup = require(
    "Sources/Melo/Shortcuts/MenuBarPopupController.swift",
    "enum MenuBarPopupPositioner",
    "buttonRectOnScreen.minY - popupSize.height",
)
menu = require(
    "Sources/Melo/Views/MenuBar/MenuBarIconCoordinator.swift",
    "lastLocalRightClickTime",
    "observedAt - self.lastLocalRightClickTime > 0.75",
)
main = require(
    "Sources/Melo/Views/MenuBarPopupView.swift",
    "popupContentLayer",
    "popupAppearanceLayer",
    "popupDeviceObservationLayer",
    "popupApplicationObservationLayer",
    "popupPeripheralObservationLayer",
    "popupWindowObservationLayer",
    "popupKeyboardLayer",
    "handlePopupAppear",
    "handlePopupWindowBecameKey",
    "MenuBarPopupPositioner.anchor",
    ".guidedTourTarget(.search)",
    ".guidedTourTarget(.settings)",
    ".guidedTourTarget(.smartAudio)",
)
if "var body: some View {\n        ZStack" in main:
    failures.append("MenuBarPopupView body was not split into smaller view layers")

with (root / "Config/Info.plist").open("rb") as file:
    info = plistlib.load(file)
if info.get("CFBundleShortVersionString") != "2.9.2":
    failures.append("wrong version")
if info.get("CFBundleVersion") != "297":
    failures.append("wrong build")

if failures:
    print("Melo 2.8.3 refinement verification failed:")
    for failure in failures:
        print(f"  - {failure}")
    sys.exit(1)
print("Melo 2.8.3 refinement verification passed.")
