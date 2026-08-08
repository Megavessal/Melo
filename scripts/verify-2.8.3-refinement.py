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
# verify scripts stayed green, because a needle like "SpotlightRing(cutout: rect"
# lives inside `spotlightRing(_:)`'s own body and survives its call site being
# deleted. These read the call.
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
if "resolved?.pointerFrame" not in swift_body(tour, "private var pointerPosition: CGPoint"):
    failures.append(
        "guided tour: pointerPosition ignores the step's pointerTarget, so a step whose "
        "spotlight is a whole region marks whatever control sits at its centre — for the "
        "device list that is the mute button, not the row you are told to click"
    )


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
ICON_STEP_FRAME = "tour-autoeq-seeded.png"
ICON_PLAIN_FRAME = "popup-devices-seeded.png"
measurements: list[str] = []


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


def ring_mean(luminance, centre: tuple[float, float], radius: float, size: tuple[int, int]) -> float:
    """Mean brightness around one circle. The mark is two concentric strokes, so
    it is a trough at one radius and a peak at the next — a shape no background
    happens to have, and one that does not care what colour the badge is."""
    samples = max(12, int(2 * math.pi * radius))
    width, height = size
    total = 0
    for index in range(samples):
        angle = 2 * math.pi * index / samples
        x = min(width - 1, max(0, int(round(centre[0] + radius * math.cos(angle)))))
        y = min(height - 1, max(0, int(round(centre[1] + radius * math.sin(angle)))))
        total += luminance[x, y]
    return total / samples


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

    # --- 3. The mark is on the badge, not on the middle of the row.
    #
    # `.deviceSelection` anchors the badge exactly, so the mark's centre and the
    # badge's centre are the same point. Two concentric strokes 7.5pt out: the
    # black one reads as roughly half the badge under it, the white one as near
    # white whatever is under it. Drop the mark, or let the pointerTarget
    # correction lapse so it slides to the centre of the row — which is the mute
    # button — and both features vanish from here together.
    trough = min(ring_mean(luminance, centre, radius / 2, image.size) for radius in range(18, 24))
    peak = max(ring_mean(luminance, centre, radius / 2, image.size) for radius in range(25, 30))
    if peak < 190 or trough > 130 or peak - trough < 90:
        failures.append(
            f"{TOUR_FRAME}: no mark on the device badge at {centre} (inner {trough:.0f}, "
            f"outer {peak:.0f}) — either nothing marks the control this step names, or the "
            "mark slid to the centre of the row, which is its mute button"
        )
    else:
        measurements.append(f"device-badge mark contrast {peak - trough:.0f} (floor 90)")

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


run_frame_checks()

if failures:
    print("Melo 2.8.3 refinement verification failed:")
    for failure in failures:
        print(f"  - {failure}")
    sys.exit(1)
print("Melo 2.8.3 refinement verification passed.")
for measurement in measurements:
    print(f"  measured: {measurement}")
