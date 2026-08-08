#!/usr/bin/env python3
from __future__ import annotations
from pathlib import Path
import math
import os
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

def swift_body(source: str, signature: str) -> str:
    """The braces of one declaration, so a rule about how a thing is drawn is
    read against the declaration that draws it rather than against the whole
    file, where a stroke belonging to some other view satisfies it."""
    if signature not in source:
        return ""
    start = source.index(signature)
    depth = 0
    for index in range(start, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[start:index + 1]
    return source[start:]

# The tour is data now, so a walkthrough is a list of `SpotlightStep`s the
# overlay renders rather than an enum it switches on. The copy moved with the
# data into the coordinator; the overlay is still checked for what marks the
# target and for the quiet-app question never coming back.
tour = require(
    "Sources/Melo/Views/Onboarding/GuidedTourOverlay.swift",
    "coordinator.currentStep",
)
# Two marks say which control a step is about: the ring struck on the spotlight
# cutout, and the dot on the control itself. Each is checked for its
# dark-under-light pair rather than merely for being drawn — the cutout shows
# the real control, so a white-only mark vanished on a highlighted light row,
# which is precisely where the tour has to be legible. Since the drawn arrow
# cursor was removed the ring carries this alone.
ring = swift_body(tour, "private func spotlightRing(")
for shade in ("black", "white"):
    if f"ring.stroke(.{shade}" not in ring:
        failures.append(
            f"guided tour: the spotlight ring lost its {shade} stroke, so it disappears "
            "against the row it is outlining"
        )
# Read only from the part of the dot that is drawn unconditionally. The
# expanding ripple repeats the same two strokes inside `if !reduceMotion`, so a
# check over the whole declaration is satisfied by the copy Reduce Motion
# removes — measured: deleting the always-drawn pair left this assertion green.
ripple = swift_body(tour, "private var pressRipple: some View")
always_drawn = ripple.split("if !reduceMotion")[0]
for shade in ("black", "white"):
    if f".strokeBorder(.{shade}" not in always_drawn:
        failures.append(
            f"guided tour: the dot on the control lost its {shade} stroke, so the point "
            "a step names is unmarked on a light row or with motion switched off"
        )
# Scoped to the declaration that draws the mark: an `Image` elsewhere in this
# file is somebody's icon, an image here is a second pointer beside the one the
# user is holding — which is the thing that shipped broken.
marker = swift_body(tour, "private var pointer: some View")
if "pressRipple" not in marker:
    failures.append("guided tour: nothing marks the control the step's sentence names")
if "Image(" in marker or "NSCursor" in marker:
    failures.append("guided tour: a drawn pointer is back beside the one the user is holding")
if "Keep quiet apps visible?" in tour or "quietAppsCard" in tour:
    failures.append("quiet-app setup question remains in guided tour")

# Everything above reads the declarations that draw the tour's marks. None of it
# reads whether `body` still calls them. Measured 2026-08-07: the mark, the ring,
# and the scrim's cutout were each cut out of `body` one at a time and all twelve
# verify scripts that existed that day stayed green, because a needle like
# "SpotlightRing(cutout: rect" lives inside `spotlightRing(_:)`'s own body and
# survives its call site being deleted. These read the call.
overlay_body = swift_body(tour, "var body: some View")
if not overlay_body:
    failures.append("guided tour: GuidedTourOverlay has no `var body`")
for drawn, call, consequence in (
    ("dimmingLayer", r"\bdimmingLayer\b", "nothing dims the popup, so no step is about anything in particular"),
    ("spotlightRing", r"spotlightRing\(", "the cutout loses its ring, which is the whole mark under Reduce Motion"),
    ("pointer", r"\bpointer\b", "nothing marks the exact control the step's sentence names"),
    ("calloutCard", r"\bcalloutCard\b", "the step's own copy is never drawn"),
):
    if not re.search(call, overlay_body):
        failures.append(
            f"guided tour: GuidedTourOverlay's body no longer draws `{drawn}` — {consequence}"
        )
# The cutout is the geometry the scrim, the ring and the mark all read from:
# `spotlightRect` nil means no hole, no ring and no mark at once, and the tour
# becomes a card floating over a window dimmed end to end.
scrim = swift_body(tour, "private var dimmingLayer: some View")
if "cutout: spotlightRect" not in scrim:
    failures.append(
        "guided tour: the scrim is no longer built from spotlightRect, so it dims the "
        "control the step is about along with everything else"
    )
# Where the mark goes and how big it is are both read from `markedControlFrame`,
# so the chain is checked link by link: a needle on the end declaration alone
# survives the middle one being cut out.
if "markedControlFrame" not in swift_body(tour, "private var pointerPosition: CGPoint"):
    failures.append(
        "guided tour: pointerPosition ignores the step's pointerTarget, so a step whose "
        "spotlight is a whole region marks whatever control sits at its centre — for the "
        "device list that is the mute button, not the row you are told to click"
    )
if "resolved?.pointerFrame" not in swift_body(tour, "private var markedControlFrame: CGRect?"):
    failures.append(
        "guided tour: markedControlFrame no longer reads the step's pointerTarget, so both "
        "the mark's position and its size fall back to the whole highlighted region"
    )
if "markedControlFrame" not in swift_body(tour, "private var markDiameter: CGFloat"):
    failures.append(
        "guided tour: the mark's diameter ignores the control it is marking, so it is a "
        "fixed ring again — which on the 28pt device badge is drawn across the glyph"
    )

# --- The Settings Guide's "Show Me" is one spotlight, not a tour.
#
# It builds a one-element step list and drives this same overlay, so it wore the
# tour's chrome: "1 OF 1", a "Skip Tour" button with the help text "End the tour
# (esc)", and a primary button reading "Finish". None of those three is true
# about being shown where one control is. Source-level, because no frame renders
# the Guide's spotlight yet — see the scene proposed in the run report.
for declaration, needle, consequence in (
    ("private var isSingleSpotlight: Bool", "coordinator.steps.count",
     "the one-step case is decided by something other than how many steps there are"),
    ("private var stepCounter: String", "isSingleSpotlight",
     'a single spotlight is labelled "1 OF 1" again'),
    ("private func calloutBody(", "isSingleSpotlight",
     'a single spotlight offers "Skip Tour" for a tour that does not exist'),
    ("private var advanceTitle: String", "isSingleSpotlight",
     'a single spotlight\'s only button reads "Finish", which is a word about a sequence'),
    # Escape rides on Skip Tour during a tour. A single spotlight draws no such
    # button, and the tour's own history records Escape falling through to the
    # popup and closing the whole window when nothing catches it.
    ("private var advanceButton: some View", "cancelAction",
     "Escape has nothing to dismiss a single spotlight with, so it closes the popup instead"),
):
    if needle not in swift_body(tour, declaration):
        failures.append(f"guided tour: {declaration.strip()} lost {needle!r} — {consequence}")

guide_controller = require(
    "Sources/Melo/Coordination/OnboardingWindowController.swift",
    "GuideSpotlightRequest",
)
show_in_popup = swift_body(guide_controller, "private func showInPopup(")
for needle, consequence in (
    (
        "regionPointer",
        "a Guide entry that names a control inside a region marks whatever sits at that "
        "region's centre — thirteen of them target .devices, whose centre is the mute button",
    ),
    (
        "absenceFallback",
        "a Guide entry whose control is not on screen draws a centred card describing it "
        "anyway, which is the shape of a tutorial that is fluff",
    ),
):
    if needle not in show_in_popup:
        failures.append(f"settings guide: showInPopup no longer supplies {needle} — {consequence}")


def swift_list(source: str, signature: str) -> str:
    """The brackets of one array literal, so the tour's targets are read from the
    tour rather than from every `.` in the file."""
    if signature not in source:
        return ""
    start = source.index("[", source.index("=", source.index(signature)))
    depth = 0
    for index in range(start, len(source)):
        if source[index] == "[":
            depth += 1
        elif source[index] == "]":
            depth -= 1
            if depth == 0:
                return source[start:index + 1]
    return source[start:]


coordinator = require(
    "Sources/Melo/Coordination/GuidedTourCoordinator.swift",
    # The first-run tour still covers every one of these, under the old case
    # names, which are now the step ids.
    'id: "autoEQ"',
    'id: "smartAudio"',
    'id: "equalizer"',
    'id: "search"',
    'id: "settings"',
    "AutoEQ corrects supported headphones",
    "Smart Sound adapts automatically",
    "EQ changes the tone of one app",
    "Search finds actions, not only labels",
    "func finish()",
)
if "finish(quietMoveDelay" in coordinator:
    failures.append("guided tour still changes quiet-app behavior")

# --- Every control a first-run step names is still anchored to that control.
#
# A severed anchor does not crash and does not look broken. The step falls
# through to `absenceFallback`, so the tour shows the user an alternate that is a
# true sentence about an absence that is not real: delete
# `.guidedTourTarget(.appVolume)` and step one tells someone with music playing
# that nothing is making sound. Four of the ten targets were name-checked and six
# — appVolume, equalizer, appDisclosure, smartSoundLevel, deviceSelection — were
# not, each deletable with the whole suite green.
#
# Derived from the tour rather than listed beside it, so a step that starts
# naming a new control brings its own requirement with it instead of quietly
# joining the unchecked six.
tour_steps = swift_list(coordinator, "static let firstRunTour")
named_targets = set(re.findall(r"(?:target|pointerTarget):\s*\.([A-Za-z]\w*)", tour_steps))
if len(named_targets) < 8:
    failures.append(
        "could not read the first-run tour's targets out of GuidedTourCoordinator "
        f"(found {sorted(named_targets)}) — the anchor check is reading nothing"
    )
anchored: set[str] = set()
for source_file in (root / "Sources/Melo").rglob("*.swift"):
    # Skipped deliberately: this file *declares* `guidedTourTarget(_:)`, and a
    # target satisfied by its own definition is the check testing itself.
    if source_file.name == "GuidedTourOverlay.swift":
        continue
    anchored |= set(
        re.findall(
            r"\.guidedTourTarget\(\s*\.([A-Za-z]\w*)",
            source_file.read_text(errors="replace"),
        )
    )
for target in sorted(named_targets - anchored):
    failures.append(
        f"guided tour: a step names .{target} but nothing applies "
        f".guidedTourTarget(.{target}) — that step silently shows its absence copy"
    )

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

# ---------------------------------------------------------------------------
# Rendered assertions: read the tour frame dev-verify.sh just produced.
#
# Everything above proves the tour's rules and, now, that `body` still calls
# them. These prove *arrival* — that the scrim really has a hole in it, that the
# hole really carries a ring, that the mark really lands on the badge the step
# tells you to click rather than on the mute button beside it, and that on an
# icon-sized anchor the tour is not drawing over the control it describes. Five
# wiring points were severed one at a time with the whole suite green before the
# first three existed; the fourth is a defect no source-level check can see,
# because every piece of it is individually correct.
#
# `tour-light` is the devices step in Light Mode, which is the frame that can
# carry the first three: the scrim takes a near-white popup down to a flat grey,
# so the cutout, its ring and the mark all read as large numeric differences
# rather than as judgement calls about a dark frame.
# ---------------------------------------------------------------------------

# Chosen because the check is about what these files draw. The snapshot
# directory is not passed down to verify scripts, so the frames are found by
# their completion sentinel; under dev-verify.sh the render and this script run
# inside one lock, so the newest sentinel on the machine is this run's. Standalone
# that stops being true, and this guard is what catches the common case.
FRAME_INPUTS = [
    "Sources/Melo/Views/Onboarding/GuidedTourOverlay.swift",
    "Sources/Melo/Coordination/GuidedTourCoordinator.swift",
    "Sources/Melo/Views/Rows/DeviceRow.swift",
    "Sources/Melo/Utilities/SnapshotScenes.swift",
]
TOUR_FRAME = "tour-light.png"
# The same popup, same appearance, no tour over it. Both occlusion checks are
# differences against an untoured render of the same control, because "the tour
# drew on this" is not a property one frame has on its own.
BADGE_PLAIN_FRAME = "popup-light.png"
ICON_STEP_FRAME = "tour-autoeq-seeded.png"
ICON_PLAIN_FRAME = "popup-devices-seeded.png"
measurements: list[str] = []

# ---------------------------------------------------------------------------
# --- A search result marks the setting it took you to.
#
# The chain is: a result row hands `SettingsRootView.navigate` the entry's
# destination *and its location*; `sectionTitle(inLocation:)` reads a section
# out of that location; the tab is handed the resulting `SettingsSectionTarget`;
# `settingsSectionAnchor` draws the mark on the section whose title matches.
#
# `settings-audio-guide-smartsound` proves the last link and only the last link:
# it hands `AudioTab` a target directly, so it renders a blue mark whatever the
# rest of the chain does. Measured 2026-08-08 by running the shipping derivation
# over the shipping catalog: **45 of 102 entries could produce a mark at all**.
# Nine General entries — Launch at Login, Show Melo in the Dock, Appearance,
# Theme, Theme Studio, accent colour, disconnect alerts, Bluetooth, Move Quiet
# Apps — carried the location "Settings › General", which names a tab and no
# section, so `sectionTitle` returned nil, `navigate` set `sectionTarget` to nil,
# and the tab opened at its top with nothing marked. The frame was green, every
# verify script was green, and the feature did not work. That is the whole
# defect: the rule was correct and never connected to its input.
#
# Fixing those nine locations took it to 54. The last nine were stranded a level
# up: Effects, Updates and About declared no anchors at all and were handed no
# target, so their entries had nothing to name even with a three-part location.
# Anchoring those three tabs and pointing their entries at real headings took it
# to 63 — every catalog entry that names a Settings tab.
#
# So this reads the input. For every catalog entry that names a Settings tab the
# window can mark, the location must resolve to a section that tab actually
# anchors. It is not a substring test — it re-implements `sectionTitle`'s split
# and compares against the anchor titles parsed out of the tabs, so renaming a
# section heading, dropping an anchor, or writing a location one level short all
# come back red.

SECTION_TARGET_TABS = {
    "everyday": "Sources/Melo/Views/Settings/Tabs/EverydayTab.swift",
    "general": "Sources/Melo/Views/Settings/Tabs/GeneralTab.swift",
    "audio": "Sources/Melo/Views/Settings/Tabs/AudioTab.swift",
    "shortcuts": "Sources/Melo/Views/Settings/Tabs/ShortcutsTab.swift",
    # Added 2026-08-08. These three held no anchors and were handed no target,
    # so the nine catalog entries naming them — the three update topics, the
    # licence, and all five Audio Unit topics — opened a tab and marked nothing.
    "effects": "Sources/Melo/Views/Settings/Tabs/AudioUnitsTab.swift",
    "updates": "Sources/Melo/Views/Settings/Tabs/UpdatesTab.swift",
    "about": "Sources/Melo/Views/Settings/Tabs/AboutTab.swift",
}

# The Guide is not a settings tab and has no sections to scroll to; a result
# routed there opens on its own topic instead (`explainInGuide`). Named rather
# than skipped silently, so a catalog entry that starts pointing at a tab nobody
# has anchored is still caught below rather than quietly counted out.
UNMARKABLE_DESTINATIONS = {"guide"}


def section_in_location(location: str | None) -> str | None:
    """`SettingsGuideEntry.sectionTitle(inLocation:)`, in Python. Kept in step
    by the assertion below, which fails if the Swift stops splitting on › or
    stops requiring three parts."""
    if location is None:
        return None
    parts = [part.strip() for part in location.split("›")]
    if len(parts) < 3 or parts[0] != "Settings":
        return None
    return parts[2]


guide_model = require(
    "Sources/Melo/Models/SettingsGuide.swift",
    "static func sectionTitle(inLocation location: String?) -> String?",
)
section_title_body = swift_body(
    guide_model, "static func sectionTitle(inLocation location: String?) -> String?"
)
for needle, consequence in (
    ('split(separator: "›")', "the location is no longer split on the separator the "
     "location lines are written with, so this check is now reading a different rule than "
     "the app runs"),
    ("parts.count >= 3", "a location that names a tab and no section would be accepted, and "
     "the section it returns is whatever happens to sit at index 2"),
):
    if needle not in section_title_body:
        failures.append(f"settings search: sectionTitle(inLocation:) lost {needle!r} — {consequence}")

# The wire, read at the call site rather than at the declaration. `activate` is
# the shipping action behind a result row; handing `onSelect` anything other
# than the entry's own location compiles, still travels to the right tab, and
# silently stops marking.
settings_root = require(
    "Sources/Melo/Views/Settings/SettingsRootView.swift",
    "SettingsSearchField(",
)
activate_body = swift_body(settings_root, "private func activate(_ entry: SettingsGuideEntry)")
if "onSelect(destination, entry.location)" not in activate_body:
    failures.append(
        "settings search: a result row no longer hands `entry.location` to onSelect, so "
        "navigate has nothing to derive a section from and every result opens a tab at its "
        "top with nothing marked"
    )
navigate_body = swift_body(settings_root, "private func navigate(to destination: SettingsDestination")
for needle, consequence in (
    ("SettingsGuideEntry.sectionTitle(inLocation: location)", "the location the result row "
     "passed is no longer read, so no target is ever built"),
    ("sectionTarget = target", "the derived target is never stored, so no tab receives it"),
):
    if needle not in navigate_body:
        failures.append(f"settings search: navigate lost {needle!r} — {consequence}")

# Each tab that owns anchors must actually be handed the target. Dropping the
# argument at one call site is a one-line change that leaves the other three
# working, which is exactly the shape that hides.
anchors_by_tab: dict[str, set[str]] = {}
for destination, relative in SECTION_TARGET_TABS.items():
    source = require(relative, ".settingsSectionAnchor(")
    # The descent is only owed by a tab that scrolls. Effects and About are one
    # screenful each — Effects pins its header and footer and scrolls the chain
    # inside its own List, About is centred and does not scroll at all — so
    # demanding the modifier of them would demand a `scrollPosition` binding
    # with no scroll view to bind to: a modifier that satisfies this line and
    # moves nothing. Read from the tab's own `body` rather than the file, so a
    # ScrollView inside some private helper further down cannot answer for it.
    tab_body = swift_body(source, "var body: some View")
    if "ScrollView" in tab_body and "guidedSectionScroll(target: sectionTarget)" not in source:
        failures.append(
            f"settings search: {relative} scrolls but never calls "
            "guidedSectionScroll(target: sectionTarget), so a section it marks can stay below "
            "the fold and the reader is sent to a page that looks unchanged"
        )
    anchors_by_tab[destination] = set(re.findall(r'\.settingsSectionAnchor\(\s*"([^"]+)"', source))
    if not anchors_by_tab[destination]:
        failures.append(f"settings search: {relative} declares no section anchors, so nothing in it can be marked")

# One page property per markable tab, each passing the target on. Counted rather
# than matched by name so a tab losing its argument cannot hide behind the other
# three still having theirs.
passed_targets = settings_root.count("sectionTarget: sectionTarget")
if passed_targets < len(SECTION_TARGET_TABS):
    failures.append(
        f"settings search: only {passed_targets} of {len(SECTION_TARGET_TABS)} markable tabs are "
        "handed sectionTarget in SettingsRootView — the ones that are not open at their top "
        "with nothing marked, and every other check here still passes"
    )

# The catalog itself, run through the shipping derivation.
entry_pattern = re.compile(
    r'\.init\(\s*"(?P<id>[^"]+)"(?P<body>.*?)\n        \)', re.DOTALL
)
catalog = (root / "Sources/Melo/Models/SettingsGuide.swift").read_text(errors="replace")
markable = 0
stranded: list[str] = []
for match in entry_pattern.finditer(catalog):
    entry_id = match.group("id")
    body = match.group("body")
    destination_match = re.search(r"destination: \.(\w+)", body)
    if not destination_match:
        continue
    destination = destination_match.group(1)
    if destination in UNMARKABLE_DESTINATIONS:
        stranded.append(f"{entry_id}→{destination}")
        continue
    if destination not in SECTION_TARGET_TABS:
        failures.append(
            f"settings search: guide entry {entry_id!r} points at the {destination!r} tab, which "
            "is neither known to hold anchors nor listed as unmarkable — a result for it opens a "
            "tab and marks nothing"
        )
        continue
    location_match = re.search(r'location: "([^"]*)"', body)
    location = location_match.group(1) if location_match else None
    section = section_in_location(location)
    if section is None:
        failures.append(
            f"settings search: guide entry {entry_id!r} sends the reader to the {destination} tab "
            f"but its location {location!r} names no section, so sectionTitle(inLocation:) returns "
            "nil, navigate stores no target, and the result highlights nothing. Write the section "
            f'it lives in: "Settings › {destination.capitalize()} › <section heading>"'
        )
        continue
    if section not in anchors_by_tab[destination]:
        failures.append(
            f"settings search: guide entry {entry_id!r} asks for section {section!r} in the "
            f"{destination} tab, which anchors {sorted(anchors_by_tab[destination])}. Nothing "
            "matches, so the tab scrolls nowhere and marks nothing"
        )
        continue
    markable += 1

# Exact rather than slack. Every entry that names a Settings tab now resolves,
# so any number below this one means an entry was deleted or its destination
# quietly dropped — both of which make every check above pass.
if markable < 63:
    failures.append(
        f"settings search: only {markable} catalog entries can produce a highlight, down from 63. "
        "This floor exists because deleting entries is a way to make every check above pass"
    )
else:
    stranded_note = (
        f"; {len(stranded)} are stranded on tabs that hold no anchors ({', '.join(stranded)})"
        if stranded
        else "; none are stranded on a tab that holds no anchors"
    )
    measurements.append(
        f"settings search: {markable} guide entries resolve to a section their destination tab "
        f"anchors{stranded_note}"
    )


def locate_frames() -> Path | None:
    candidates: list[tuple[float, Path]] = []
    for base in {Path("/tmp"), Path(os.environ.get("TMPDIR", "/tmp"))}:
        try:
            entries = list(base.iterdir())
        except OSError:
            continue
        for entry in entries:
            sentinel = entry / "_complete"
            try:
                if entry.is_dir() and sentinel.is_file():
                    candidates.append((sentinel.stat().st_mtime, entry))
            except OSError:
                continue
    return max(candidates)[1] if candidates else None


def run_frame_checks() -> None:
    try:
        from PIL import Image
    except ImportError:
        failures.append("Pillow is not installed; the rendered tour assertions cannot run")
        return

    frames = locate_frames()
    if frames is None or not (frames / TOUR_FRAME).is_file():
        failures.append(
            f"no rendered {TOUR_FRAME} found — run ./scripts/dev-verify.sh <dir> first; "
            "whether the tour's marks reach the screen is a claim about pixels"
        )
        return
    rendered = (frames / TOUR_FRAME).stat().st_mtime
    newest_input = max(
        ((root / rel).stat().st_mtime for rel in FRAME_INPUTS if (root / rel).is_file()),
        default=0.0,
    )
    if newest_input > rendered:
        failures.append(
            f"{frames / TOUR_FRAME} is older than the source it is evidence about — "
            "re-render before trusting it"
        )
        return

    image = Image.open(frames / TOUR_FRAME)
    rgb = image.convert("RGB").load()
    luminance = image.convert("L").load()
    width, height = image.size

    # --- 1. The scrim has a hole in it.
    #
    # The device badge is the only saturated blue in this frame and it sits
    # inside the highlighted row. Under the scrim it would come back at 42% —
    # far below this threshold — so "no cutout" and "cutout" differ by thousands
    # of pixels rather than by a shade.
    lit: list[tuple[int, int]] = []
    for y in range(height):
        for x in range(width):
            red, _, blue = rgb[x, y]
            if blue >= 200 and blue - red >= 90:
                lit.append((x, y))
    if len(lit) < 800:
        failures.append(
            f"{TOUR_FRAME}: the highlighted device row is dimmed like everything else "
            f"({len(lit)} undimmed pixels on its badge) — the scrim has no cutout, so the "
            "step spotlights nothing"
        )
        return

    leading = min(x for x, _ in lit)
    disc = [(x, y) for x, y in lit if x <= leading + 60]
    centre = (
        (min(x for x, _ in disc) + max(x for x, _ in disc)) / 2,
        (min(y for _, y in disc) + max(y for _, y in disc)) / 2,
    )

    # --- 2. The cutout carries its ring.
    #
    # Read across the badge's own scanline, which crosses the cutout's leading
    # edge. Melo's rows are flat at rest, so with no ring the scrim runs straight
    # into the undimmed row: grey, then white. The ring puts its black stroke
    # between them, and black-over-scrim is the one thing on that line darker
    # than the scrim itself.
    row = int(round(centre[1]))
    popup_left = next((x for x in range(width) if luminance[x, row] < 200), None)
    if popup_left is None:
        failures.append(f"{TOUR_FRAME}: no dimmed region at all on the highlighted row's scanline")
        return
    scrim = luminance[popup_left, row]
    edge = next((x for x in range(popup_left, width) if luminance[x, row] >= 230), None)
    if edge is None:
        failures.append(f"{TOUR_FRAME}: the scanline through the highlighted row is dimmed end to end")
        return
    darkest = min(luminance[x, row] for x in range(max(popup_left, edge - 8), edge))
    if darkest > scrim * 0.75:
        failures.append(
            f"{TOUR_FRAME}: the cutout's edge goes straight from scrim ({scrim}) to row without "
            f"a ring (darkest approach {darkest}) — under Reduce Motion the ring is the whole "
            "mark, and nothing outlines the control the step is about"
        )

    # --- 3. The mark is *around* the device badge: on it, and not over it.
    #
    # Read as a difference against `popup-light`, the same popup with no tour
    # over it, because that is what "the tour drew this" means. Two claims, both
    # measured from the badge's own geometry so neither depends on how big the
    # mark happens to be:
    #
    #   inside the badge — the two frames must agree. A 15pt ring dropped on the
    #   28pt badge's centre composited with the device glyph into a struck-through
    #   disc, under a card reading "click a row to make that device the main
    #   output". `cutoutIsAtItsFloor`, which suppresses the mark on the AutoEQ
    #   wand, cannot see this: the anchor is a 28pt badge inside a row-sized
    #   cutout, so the cutout is nowhere near its floor.
    #
    #   around the badge — they must differ. That is the mark, present, and
    #   concentric with the badge. Drop it, or let the `pointerTarget:
    #   .deviceSelection` correction lapse so it slides to the centre of the row
    #   — which is the mute button — and this annulus goes back to matching.
    #
    # Together they are the same rule the icon step is held to, on the case the
    # floor test structurally cannot reach.
    plain_badge = frames / BADGE_PLAIN_FRAME
    if not plain_badge.is_file():
        failures.append(
            f"frames in {frames} are missing {BADGE_PLAIN_FRAME} — whether the tour draws over "
            "the device badge is read against the same popup with no tour on it"
        )
        return
    plain_image = Image.open(plain_badge)
    # Width only: the two frames carry provenance bands of different heights, and
    # the popup is drawn from the top down, so the badge is at the same
    # coordinates in both while the images are not the same shape.
    if plain_image.width != width:
        failures.append(
            f"{TOUR_FRAME} and {BADGE_PLAIN_FRAME} are different widths, so the same "
            "coordinates are not the same control in both"
        )
        return
    plain = plain_image.convert("L").load()
    readable_height = min(height, plain_image.height)
    badge_radius = min(
        max(x for x, _ in disc) - min(x for x, _ in disc),
        max(y for _, y in disc) - min(y for _, y in disc),
    ) / 2
    if badge_radius < 8:
        failures.append(
            f"{TOUR_FRAME}: the device badge measures {2 * badge_radius:.0f}px across, which is "
            "not a badge — the mark checks below would be reading noise"
        )
        return

    def differing_share(inner: float, outer: float) -> tuple[float, int]:
        total = changed = 0
        for y in range(int(centre[1] - outer) - 1, int(centre[1] + outer) + 2):
            for x in range(int(centre[0] - outer) - 1, int(centre[0] + outer) + 2):
                if not (0 <= x < width and 0 <= y < readable_height):
                    continue
                distance = math.hypot(x - centre[0], y - centre[1])
                if not inner <= distance <= outer:
                    continue
                total += 1
                if abs(luminance[x, y] - plain[x, y]) > 12:
                    changed += 1
        return 100 * changed / max(1, total), total

    # Inset past the badge's own antialiased rim, which is a boundary and is
    # allowed to differ by a level or two.
    over_badge, _ = differing_share(0, badge_radius - 3)
    if over_badge > 1.0:
        failures.append(
            f"{TOUR_FRAME}: {over_badge:.1f}% of the device badge differs from {BADGE_PLAIN_FRAME}, "
            "where the same badge is drawn with no tour over it. The step is drawing on top of "
            "the control its own sentence tells you to click"
        )
    else:
        measurements.append(f"device-badge defacement {over_badge:.2f}% (ceiling 1.00%)")

    around_badge, _ = differing_share(badge_radius + 3, badge_radius + 18)
    if around_badge < 5.0:
        failures.append(
            f"{TOUR_FRAME}: the ring of popup around the device badge at {centre} is "
            f"{around_badge:.1f}% different from {BADGE_PLAIN_FRAME} — nothing marks the control "
            "this step names, or the mark slid to the centre of the row, which is its mute button"
        )
    else:
        measurements.append(f"device-badge mark coverage {around_badge:.1f}% (floor 5.0%)")

    check_icon_step_is_not_defaced(Image)


def check_icon_step_is_not_defaced(Image) -> None:
    """The tour must not draw over the control it is pointing at.

    `spotlightRect` floors the cutout at 52 × 38 while
    `DesignTokens.Dimensions.minTouchTarget` is 28, so every icon-only anchor —
    the AutoEQ wand, the disclosure chevron, ⌘K, the Settings gear — gets a
    cutout larger than its control with the glyph dead centre. The mark landed
    dead centre too. Measured 2026-08-07 on the AutoEQ step: the 15pt ring and
    `wand.and.sparkles`'s diagonal shaft together drew a **no-entry sign** over
    the wand, on a card reading "This wand searches measured headphone
    profiles." No source-level check can see that — every piece is individually
    correct — and the drawn ring is not animated, so it is what a real user
    sees, and under Reduce Motion it is the only thing drawn.

    The two frames share a `prepare`; the only difference is whether the tour is
    running. So inside the cutout, where there is no scrim, they have to agree.
    """
    frames = locate_frames()
    if frames is None:
        return
    missing = [n for n in (ICON_STEP_FRAME, ICON_PLAIN_FRAME) if not (frames / n).is_file()]
    if missing:
        failures.append(
            f"frames in {frames} are missing {missing} — the icon-step occlusion check "
            "needs the toured and untoured renders of the same seeded device list"
        )
        return

    toured_image = Image.open(frames / ICON_STEP_FRAME)
    plain_image = Image.open(frames / ICON_PLAIN_FRAME)
    width, height = toured_image.size
    if plain_image.width != width:
        failures.append(
            f"{ICON_STEP_FRAME} and {ICON_PLAIN_FRAME} are different widths, so the same "
            "coordinates are not the same control in both"
        )
        return
    toured = toured_image.convert("L").load()
    plain = plain_image.convert("L").load()

    # Stop above the provenance band. Its bold caption is bright enough to be
    # mistaken for the ring, and it says nothing about the app.
    content_bottom = height
    band = toured_image.convert("RGB").load()
    for y in range(height):
        red, green, blue = band[10, y]
        if red > 100 and green < 60 and blue < 60:
            content_bottom = y
            break

    # The cutout's ring is the only thing in the popup bright enough to run 40
    # pixels straight, so its top and bottom edges locate the hole.
    edges = []
    for y in range(content_bottom):
        run = 0
        for x in range(width):
            run = run + 1 if toured[x, y] >= 200 else 0
            if run >= 40:
                edges.append(y)
                break
    mid_row = None
    if edges:
        top, bottom = min(edges), max(edges)
        if 60 <= bottom - top <= 200:
            mid_row = (top + bottom) // 2
    if mid_row is None:
        failures.append(
            f"{ICON_STEP_FRAME}: could not find the spotlight cutout's ring, so whether the "
            "tour draws over the wand it is describing cannot be read"
        )
        return
    columns = [x for x in range(width) if toured[x, mid_row] >= 200]
    left, right = min(columns), max(columns)
    if not 80 <= right - left <= 400:
        failures.append(f"{ICON_STEP_FRAME}: the cutout measures {right - left}px wide, which is not a cutout")
        return

    # Inset past the ring's own strokes, which are drawn on the boundary and are
    # supposed to differ.
    inset = 10
    box = (left + inset, right - inset, top + inset, bottom - inset)
    total = (box[1] - box[0]) * (box[3] - box[2])
    changed = sum(
        1
        for y in range(box[2], box[3])
        for x in range(box[0], box[1])
        if abs(toured[x, y] - plain[x, y]) > 12
    )
    share = 100 * changed / max(1, total)
    if share > 1.0:
        failures.append(
            f"{ICON_STEP_FRAME}: {share:.1f}% of the pixels inside the spotlight differ from "
            f"{ICON_PLAIN_FRAME}, where the same control is drawn with no tour over it. The "
            "step is drawing on top of the control its own sentence describes"
        )
    else:
        measurements.append(f"icon-step cutout defacement {share:.2f}% (ceiling 1.00%)")

    check_press_mark_only_where_there_is_a_press(Image)


def annulus_dark_share(luminance, size, centre, radius, samples=32) -> float:
    """How much of the circle at `radius` around `centre` is darker than the
    surface it is drawn on. A ring reads ~1.0; a line of text never does,
    because the arc above it is blank."""
    width, height = size
    dark = total = 0
    for step in range(samples):
        angle = 2 * math.pi * step / samples
        x = int(round(centre[0] + radius * math.cos(angle)))
        y = int(round(centre[1] + radius * math.sin(angle)))
        if 0 <= x < width and 0 <= y < height:
            total += 1
            if luminance[x, y] < 200:
                dark += 1
    return dark / total if total else 0.0


def find_press_mark(image, centres_x, centres_y) -> tuple[int, int, int] | None:
    """The tour's press mark, if it is drawn anywhere in the given band.

    The mark is the only *hollow* dark circle the overlay draws: a continuous
    stroke with the control, or the empty card, still showing through the
    middle. Hollowness is what separates it from everything else in a cutout —
    the device badge is a filled disc and fails the interior test, and a line of
    text is not continuous around a full circle and fails the outer one. Both
    sizes the mark can take are covered: the 15pt point-mark and the ring that
    encloses a control up to `maxEnclosingMark`.
    """
    luminance = image.convert("L").load()
    size = image.size
    for centre_y in centres_y:
        for centre_x in centres_x:
            for radius in range(8, 46, 2):
                centre = (centre_x, centre_y)
                if annulus_dark_share(luminance, size, centre, radius) < 0.85:
                    continue
                if annulus_dark_share(luminance, size, centre, max(3, radius - 7)) > 0.35:
                    continue
                return (centre_x, centre_y, radius)
    return None


def locate_cutout(image) -> tuple[int, int, int, int] | None:
    """The spotlight's hole, as (left, right, top, bottom).

    Light Mode only, and for the same reason the three checks above are: the
    scrim takes a near-white popup down to a flat grey, so the unscrimmed hole
    is the one thing in the frame that runs bright for most of the popup's
    width. The callout card is bright too and is excluded by width — it is
    316pt against a popup of 600.
    """
    luminance = image.convert("L").load()
    width, height = image.size
    # Stop above the provenance band, whose bold caption is bright enough to
    # read as content and says nothing about the app.
    rgb = image.convert("RGB").load()
    content_bottom = height
    for y in range(height):
        red, green, blue = rgb[10, y]
        if red > 100 and green < 60 and blue < 60:
            content_bottom = y
            break

    rows: list[int] = []
    for y in range(content_bottom):
        run = longest = 0
        for x in range(width):
            run = run + 1 if luminance[x, y] >= 200 else 0
            longest = max(longest, run)
        if longest >= 800:
            rows.append(y)
    if not rows:
        return None
    top, bottom = min(rows), max(rows)
    # Outermost bright columns on the hole's own middle row, not the longest
    # unbroken run: a device row's interior is interrupted by its badge and its
    # label, so the longest run there is the gap between two controls rather
    # than the hole.
    mid = (top + bottom) // 2
    columns = [x for x in range(width) if luminance[x, mid] >= 200]
    if not columns or max(columns) - min(columns) < 400:
        return None
    return (min(columns), max(columns), top, bottom)


# ---------------------------------------------------------------------------
# A press mark is only drawn where there is something to press.
#
# The mark is a ring with a click ripple coming out of it: it says "put your
# pointer here and press". Twice already it has said that by drawing on top of
# the thing it was naming — the device badge, then the AutoEQ wand — and both
# fixes were rules about *size* and *floors*, each blind to the next surface.
# The third was not about size at all. A step whose control is absent falls back
# to `.emptyApps`, a large placeholder with no control in it: the cutout is
# nowhere near its floor, no substitute control is named, so the flat 15pt mark
# landed at the centre of the cutout, which is the sentence "No user apps are
# open". It struck the words through in six frames and nothing went red.
#
# So this check is written about the category rather than about a surface, and
# it reads its own expectations out of the tour instead of listing frames:
#
#   * an alternate that names a `pointerTarget:` is sending you to a real
#     control, so its frame must still carry a mark — this is the half that
#     stops the defect being "fixed" by deleting the mark everywhere;
#   * an alternate that names none is a sentence about an absence, so its frame
#     must carry no mark anywhere inside the cutout.
#
# Add an empty-state scene and it is covered. Give an alternate a pointer target
# and the expectation flips with it.
# ---------------------------------------------------------------------------
EMPTY_FRAME_PATTERNS = (
    re.compile(r"^tour-empty-light-\d\d-(?P<step>\w+)\.png$"),
    re.compile(r"^whatsnew-tour-empty-(?P<step>\w+)\.png$"),
)


def alternates_naming_a_control() -> dict[str, bool] | None:
    """Per first-run step id, whether its `unavailable:` alternate names a
    control to press. Read from the tour so this cannot drift from it."""
    steps = swift_list(coordinator, "static let firstRunTour")
    if not steps:
        return None
    out: dict[str, bool] = {}
    for chunk in steps.split("SpotlightStep(")[1:]:
        identifier = re.search(r'id:\s*"(\w+)"', chunk)
        alternate = chunk.find("unavailable:")
        if identifier is None or alternate < 0:
            continue
        out[identifier.group(1)] = "pointerTarget:" in chunk[alternate:]
    return out or None


def fallbacks_naming_a_control() -> dict[str, bool] | None:
    """Per `GuidedTourTarget`, whether `absenceFallback` sends a step to a
    control it can point at. The tuple's second element is that pointer, so
    `nil` there is the model saying in as many words that there is nothing to
    press where this step is being sent."""
    body = swift_body(
        require("Sources/Melo/Views/Onboarding/GuidedTourOverlay.swift"),
        "var absenceFallback:",
    )
    if not body:
        return None
    out: dict[str, bool] = {}
    for arm in body.split("case ")[1:]:
        label, _, tail = arm.partition(":")
        returned = re.search(r"return\s*\(([^)]*)\)", tail, re.S)
        if returned is None:
            continue
        parts = [part.strip() for part in returned.group(1).split(",")]
        if len(parts) < 2:
            continue
        for target in re.findall(r"\.(\w+)", label):
            out[target] = parts[1] != "nil"
    return out or None


def check_press_mark_only_where_there_is_a_press(Image) -> None:
    frames = locate_frames()
    if frames is None:
        return
    expectations = alternates_naming_a_control()
    if expectations is None:
        failures.append(
            "could not read the first-run tour's alternates out of GuidedTourCoordinator — "
            "the press-mark check has no expectations and would pass on anything"
        )
        return
    # A data-built walkthrough — What's New — has no hand-written alternate. Its
    # frame is named for the *target* the note claimed, and the alternate comes
    # from `GuidedTourTarget.absenceFallback`, so its expectation is read from
    # there instead.
    fallbacks = fallbacks_naming_a_control()
    if fallbacks is None:
        failures.append(
            "could not read absenceFallback out of GuidedTourOverlay — the press-mark check "
            "has no expectation for the data-built walkthrough"
        )
        return

    checked = 0
    for frame in sorted(frames.glob("*.png")):
        step = None
        for pattern in EMPTY_FRAME_PATTERNS:
            match = pattern.match(frame.name)
            if match:
                step = match.group("step")
                break
        if step is None:
            continue
        if step in expectations:
            expects_mark = expectations[step]
        elif step in fallbacks:
            expects_mark = fallbacks[step]
        else:
            failures.append(
                f"{frame.name}: no first-run step and no absenceFallback arm names .{step}, "
                "so there is nothing to say whether this frame should carry a mark"
            )
            continue

        image = Image.open(frame)
        box = locate_cutout(image)
        if box is None:
            failures.append(
                f"{frame.name}: could not find the spotlight cutout, so whether the tour "
                "marks a press on a placeholder cannot be read"
            )
            continue
        left, right, top, bottom = box
        middle = (top + bottom) // 2
        rows = [middle - 4, middle, middle + 4]
        # The cutout's exact centre first and by name, because that is where a
        # mark with no control to sit on lands — `pointerPosition` falls through
        # to `rect.mid`. A swept grid is not enough on its own: at a stride of 6
        # the sweep stepped straight over the centre column and read the struck
        # -through placeholder as clean, which is this check's own near miss.
        # The sweep is still here for the enclosing ring, which sits on whatever
        # control it circles, anywhere across the hole.
        centres = [(left + right) // 2] + list(range(left + 40, right - 40, 6))
        mark = find_press_mark(image, centres, rows)
        checked += 1

        if expects_mark and mark is None:
            failures.append(
                f"{frame.name}: this step's alternate names a control to press and nothing "
                "marks it — the tour sends the user somewhere and then points at nothing"
            )
        elif not expects_mark and mark is not None:
            failures.append(
                f"{frame.name}: a press mark is drawn at {mark[0]},{mark[1]} (r={mark[2]}px) "
                "inside a cutout whose step has no control to press. This step's copy is a "
                "sentence about a control that is absent, and the mark is drawn through it"
            )
        else:
            measurements.append(
                f"{frame.name}: press mark {'present' if expects_mark else 'absent'}, as its "
                "alternate says it should be"
            )

    if checked < 4:
        failures.append(
            f"only {checked} empty-state tour frames were read — the press-mark check is "
            "matching frame names that are no longer being rendered"
        )


run_frame_checks()

if failures:
    print("Melo 2.8.3 refinement verification failed:")
    for failure in failures:
        print(f"  - {failure}")
    sys.exit(1)
print("Melo 2.8.3 refinement verification passed.")
for measurement in measurements:
    print(f"  measured: {measurement}")
