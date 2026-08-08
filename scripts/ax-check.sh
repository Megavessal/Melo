#!/bin/bash
# Drives scripts/ax-check.swift against the snapshot harness while it dwells.
#
#   scripts/ax-check.sh <snapshot-dir>
#
# Called by dev-verify-locked.sh, inside the lock, after the frames are on disk.
# Runnable on its own against a harness started by hand, which is how the
# assertions below were negative-tested.
#
# The handshake, both halves of it in `SnapshotHarness.dwellForAccessibilityCheck`:
# the harness writes `_ax_ready` containing its pid once the scene's window is
# up, then holds that window open until this script writes `_ax_done` or its own
# timeout expires. Nothing here may exit without writing `_ax_done` — the app is
# otherwise left running for three minutes with a window nobody can see.
#
# Why a whole separate process to check accessibility: the app cannot read its
# own accessibility tree. Both the in-process routes were measured and both are
# refused — see the header of ax-check.swift for the numbers.

set -uo pipefail

# The scenes this script knows how to assert against, in dwell order.
#
# `dev-verify-locked.sh` asks for this list with `--scenes` rather than keeping
# its own copy in the `open --env` line. Two copies can drift, and both
# directions of drift are silent: a scene dwelled with no assertion block is a
# window held open for nothing, and a scene asserted but never dwelled is a
# check that waits out its timeout and reports the harness broken. One list.
SCENES="popup-edit-priority autoeq-search-panel updates-available-light"
if [ "${1:-}" = "--scenes" ]; then
    echo "$SCENES" | tr ' ' ','
    exit 0
fi

OUT="${1:-}"
if [ -z "$OUT" ]; then
    echo "usage: scripts/ax-check.sh <snapshot-dir>" >&2
    exit 2
fi
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# A prebuilt checker, if the caller made one. `dev-verify-locked.sh` compiles it
# BEFORE launching the app, and that is not an optimisation.
#
# The compile used to happen here, which is after the render has finished and
# the harness is already holding its first window open. On a loaded machine
# swiftc took 16 seconds, the window was gone by the time the checker asked, and
# the gate reported the app's accessibility labels missing. Compiling off the
# critical path makes the interval between the harness signalling ready and the
# checker asking about it roughly nothing, which is the regime this has always
# worked in.
BIN="${MELO_AX_CHECK_BIN:-}"
OWNED_BIN=""
cleanup() {
    # The unsuffixed `_ax_done` releases whichever scene is currently waiting,
    # so no exit path here can strand the harness mid-list.
    [ -n "${OUT:-}" ] && : > "$OUT/_ax_done"
    [ -n "$OWNED_BIN" ] && rm -rf "$(dirname "$OWNED_BIN")"
}
trap cleanup EXIT

if [ -z "$BIN" ] || [ ! -x "$BIN" ]; then
    OWNED_BIN="$(mktemp -d "${TMPDIR:-/tmp}/melo-axcheck-XXXXXX")/ax-check"
    BIN="$OWNED_BIN"
    if ! swiftc -O "$ROOT/scripts/ax-check.swift" -o "$BIN" 2>&1; then
        echo "AX CHECK NOT RUN — scripts/ax-check.swift did not compile." >&2
        exit 2
    fi
fi

# Waits for one scene's window, asserts against it, then releases it so the
# harness can stage the next. Returns the checker's own exit code.
#
# `_ax_error` is polled alongside `_ax_ready_<scene>`: the harness writes it and
# dwells nothing at all when the list names a scene that does not exist, and
# without this the only symptom would be a 90-second wait ending in a timeout
# message that blamed the wrong thing.
run_scene() {
    local scene="$1"; shift
    local ready="$OUT/_ax_ready_$scene"
    for _ in $(seq 1 90); do
        [ -f "$ready" ] && break
        [ -f "$OUT/_ax_error" ] && break
        /bin/sleep 1
    done
    if [ -f "$OUT/_ax_error" ]; then
        echo "AX CHECK NOT RUN — the harness rejected the dwell list:" >&2
        sed 's/^/        /' "$OUT/_ax_error" >&2
        return 2
    fi
    if [ ! -f "$ready" ]; then
        echo "AX CHECK NOT RUN — the harness never signalled scene '$scene'." >&2
        return 2
    fi
    local pid; pid="$(tr -cd '0-9' < "$ready")"
    echo "  — $scene (pid $pid)"
    "$BIN" "$pid" --tree "$OUT/_ax_tree_$scene.log" "$@"
    local scene_status=$?
    : > "$OUT/_ax_done_$scene"
    return "$scene_status"
}

# What is asserted, and what each one catches when it is deleted or severed.
#
#   min-elements   an anti-vacuity floor. Without it, an accessibility tree that
#                  failed to materialise at all would satisfy every "nothing is
#                  named X" assertion below it and the run would go green on a
#                  check that inspected nothing.
#   adjustable     a device-priority row must expose AXIncrement AND the value
#                  it speaks must actually move when it runs. Deleting
#                  .accessibilityAdjustableAction from DeviceEditRow fails the
#                  first half; leaving the modifier and emptying moveBy(_:)
#                  fails the second. Only the second is the failure this project
#                  keeps shipping, and only this half of the check sees it.
#   button         an icon-only control that carries a real spoken name AND can
#                  be activated. With .accessibilityLabel gone, VoiceOver
#                  announces "button" and nothing else; with the label kept and
#                  no AXPress behind it, VoiceOver announces the name over
#                  something its user cannot press. The second half was missing
#                  from this check until "Expand device details" — a real defect
#                  this gate found and then failed to protect the fix of.
#   absent:Drag    the reorder grab handle is a pointer affordance and must not
#                  be a VoiceOver stop. Deleting its .accessibilityHidden(true)
#                  puts two AXImage "Drag" elements in this scene — measured,
#                  which is the only reason this assertion is phrased in terms
#                  of "Drag" rather than the symbol name: macOS resolves
#                  line.3.horizontal through its symbol catalogue long before
#                  anything reaches VoiceOver.
#   absent:Arrow…  the update banner's arrow.down.circle.fill, same rule and the
#                  same symbol-catalogue naming as absent:Drag — it announced
#                  itself as AXImage "Arrow Down Circle" between the banner's own
#                  spoken sentence and its buttons. Its assertion sits in this
#                  scene because the banner is only on screen here: the popup
#                  renders it from `updateReminder`, which SnapshotScenes leaves
#                  seeded from the updates frames above. A scene list that stops
#                  seeding it would make this check vacuous rather than fail it,
#                  which is what min-elements cannot catch on its own.
status=0
for scene in $SCENES; do
    scene_status=0
    case "$scene" in
        popup-edit-priority)
            run_scene popup-edit-priority \
                min-elements:40 \
                "adjustable:* priority" \
                "button:Change icon" \
                "button:Expand device details" \
                absent:Drag \
                "absent:Arrow Down Circle" || scene_status=$?
            ;;
        # The AutoEQ popover. An NSPopover is its own window and never appears
        # in a capture of the popup, so this surface had no coverage of any kind
        # until the dwell list grew a second entry.
        #
        #   button   `Import custom profile` is a real Button, and it is the
        #            anti-vacuity sentinel for the assertion under it: "nothing
        #            is named Search" is satisfied just as well by a tree that
        #            never materialised.
        #   absent   the magnifying glass beside the search field. It announced
        #            itself as AXImage "Search" next to a field already saying
        #            "Search headphones" — measured at 7 elements in this scene
        #            before it was hidden and 6 after.
        autoeq-search-panel)
            run_scene autoeq-search-panel \
                min-elements:5 \
                "button:Import custom profile" \
                absent:Search || scene_status=$?
            ;;
        # Settings → Updates, in the one state that draws the same
        # arrow.down.circle.fill the popup banner draws. The Settings window had
        # no accessibility coverage of any kind before this entry: every
        # assertion above is a popup or a popover, so `UpdatesTab`'s eight
        # decorative status symbols could have gone on announcing themselves
        # through any number of green runs.
        #
        # This scene and not `settings-updates`, which renders whatever activity
        # the frame before it left behind. This one's `prepare` sets
        # `.available(pending)` outright, and `dwellForAccessibilityCheck` runs
        # `prepare` before it stages the window — so the branch under assertion
        # is the branch that renders, rather than the branch that happened to.
        #
        #   button   `Update Now` is the primary action in this state and the
        #            anti-vacuity sentinel for the assertion under it.
        #   absent   the status symbol. Same glyph and therefore the same
        #            spoken name as the banner's, so deleting the shared
        #            .accessibilityHidden(true) at the `statusIcon` call site
        #            reddens this scene the way deleting the banner's reddens
        #            popup-edit-priority.
        updates-available-light)
            run_scene updates-available-light \
                min-elements:10 \
                "button:Update Now" \
                "absent:Arrow Down Circle" || scene_status=$?
            ;;
        *)
            echo "AX CHECK NOT RUN — no assertion block for scene '$scene'." >&2
            scene_status=2
            ;;
    esac
    # 3 is a property of the machine, not of this scene, so the remaining scenes
    # would only repeat it.
    if [ "$scene_status" -eq 3 ]; then status=3; break; fi
    [ "$scene_status" -ne 0 ] && status=1
done

case "$status" in
    0) echo "accessibility assertions passed on: $SCENES" ;;
    3) echo "AX CHECK SKIPPED — no Accessibility grant for this terminal; the "\
            "accessibility assertions did not run." >&2 ;;
    *) echo "ACCESSIBILITY CHECK FAILED — see the assertions above." >&2 ;;
esac
exit "$status"
