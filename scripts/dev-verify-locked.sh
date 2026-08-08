#!/bin/bash
# The exclusive section of scripts/dev-verify.sh: build, then render.
#
# A separate file rather than an inline `bash -c '...'` string. It was inline,
# and a single quote added inside that string silently terminated it — the shell
# then ran fragments of the script as commands, printed "Build: command not
# found", and exited 0. A verification wrapper that reports success after
# running none of its own body is the worst possible failure for this script.
#
# Not intended to be called directly; dev-verify.sh holds the lock around it.

set -euo pipefail

ROOT="$1"
OUT="$2"
cd "$ROOT"

echo "=== building ==="
if ! ./"Build Melo.command" --dev > "$OUT/build.log" 2>&1; then
    echo "BUILD FAILED — errors:" >&2
    grep -E "error:" "$OUT/build.log" | head -40 >&2 || tail -40 "$OUT/build.log" >&2
    exit 1
fi
grep -q "Launch test passed" "$OUT/build.log" || {
    echo "LAUNCH TEST FAILED" >&2
    tail -20 "$OUT/build.log" >&2
    exit 1
}
echo "build ok"

echo "=== rendering snapshots ==="
# Render from a private copy. `outputs/Melo.app` is deleted and rebuilt by the
# next caller's build, and a harness whose executable is removed mid-run dies
# without generating a crash report — indistinguishable, from outside, from a
# render that simply finished early.
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/melo-render-XXXXXX")"
# `_ax_done` releases the harness's accessibility dwell (see AX CHECK below).
# It is written here as well as by ax-check.sh because every early exit in this
# script — a failed sentinel, a frame-count mismatch — would otherwise leave a
# Melo process holding a window open for the full dwell timeout.
trap 'touch "$OUT/_ax_done" 2>/dev/null; rm -rf "$STAGE"' EXIT
cp -R "$ROOT/outputs/Melo.app" "$STAGE/Melo.app"

rm -f "$OUT/_complete" "$OUT/_ax_error"
rm -f "$OUT"/_ax_ready* "$OUT"/_ax_done* 2>/dev/null || true
# MELO_SNAPSHOT_FAIL_AFTER is fault injection, forwarded only when the caller
# set it. It makes the harness exit after N frames without writing the
# completion sentinel — the same thing a crash halfway through a render looks
# like from out here. Without a way to produce that state on demand, the
# rejection below is a branch nobody has ever seen taken.
#
# MELO_AX_DWELL names the scenes the harness holds open after its last frame,
# so scripts/ax-check.sh has live accessibility trees to interrogate. The list
# comes from ax-check.sh itself — it owns the assertions, so it owns which
# scenes have to be staged for them.
AX_SCENES="$("$ROOT/scripts/ax-check.sh" --scenes)"
if [ -n "${MELO_SNAPSHOT_FAIL_AFTER:-}" ]; then
    open -n --env MELO_SNAPSHOT_DIR="$OUT" \
        --env MELO_SNAPSHOT_FAIL_AFTER="$MELO_SNAPSHOT_FAIL_AFTER" "$STAGE/Melo.app"
else
    open -n --env MELO_SNAPSHOT_DIR="$OUT" \
        --env MELO_AX_DWELL="$AX_SCENES" "$STAGE/Melo.app"
fi

# Wait for the sentinel the harness writes after its last frame. Watching the
# file count stop changing cannot distinguish a finished run from a crashed one:
# a render that died at 12 frames of 41 was reported as a success, and the
# frames were used.
for _ in $(seq 1 150); do
    [ -f "$OUT/_complete" ] && break
    /bin/sleep 2
done

n=$(ls "$OUT"/*.png 2>/dev/null | wc -l | tr -d " ")
if [ ! -f "$OUT/_complete" ]; then
    echo "RENDER DID NOT COMPLETE — $n frame(s) written, no completion sentinel." >&2
    echo "The harness died partway. Treat these frames as unusable." >&2
    [ -f "$OUT/_failures.log" ] && sed 's/^/        /' "$OUT/_failures.log" >&2
    exit 1
fi

# The sentinel says "<ok>/<total>", and this used to print it and move on — so
# a scene that failed to render, or a transition whose "after" frame came out
# pixel-identical to its "before" (a control that changed nothing), was
# reported in passing while the script exited 0. The harness's own verdict has
# to be able to fail the run, or it is decoration.
ok=$(tr -d '\n' < "$OUT/_complete")
if [ "${ok%%/*}" != "${ok##*/}" ]; then
    echo "RENDER REPORTED FAILURES — $ok scenes ok:" >&2
    [ -f "$OUT/_failures.log" ] && sed 's/^/        /' "$OUT/_failures.log" >&2
    exit 1
fi

# The header of dev-verify.sh has always claimed it fails when "no snapshots
# were produced", and no such check existed. The sentinel comparison above is
# satisfied by "0/0", so an empty scene list — or one silently filtered down to
# a handful — was green. MIN_SCENES is a floor, not an exact count, so adding
# and removing frames stays cheap while a collapse cannot pass.
MIN_SCENES=60
total=${ok##*/}
if [ "$total" -lt "$MIN_SCENES" ]; then
    echo "TOO FEW SCENES — the harness offered $total, floor is $MIN_SCENES." >&2
    echo "A scene list that collapses is a silent loss of coverage." >&2
    exit 1
fi
if [ "$n" -ne "$total" ]; then
    echo "FRAME COUNT MISMATCH — $total scenes reported ok, $n PNG(s) on disk." >&2
    exit 1
fi
echo "rendered $n snapshots to $OUT ($ok scenes ok)"
[ -f "$OUT/_transitions.log" ] && {
    echo "=== transition measurements ==="
    sed 's/^/  /' "$OUT/_transitions.log"
}

# Every accessibility modifier in this app was covered only by greps of the
# source, which stay green when the modifier is present and connected to
# nothing. This performs the action against the live tree and asserts the value
# it speaks actually moves. It needs a running app, so it cannot be one of the
# verify-*.py scripts below.
#
# It runs here, before the verify scripts, because it is the only check in this
# file that needs a live process: the harness is holding a window open right now
# and every second it waits is a second of a shared lock. It does NOT exit here.
#
# It used to, and that was wrong on a lock six agents queue for. One red
# accessibility assertion aborted the run before `=== verify scripts ===` ever
# printed, so a builder whose real question was "did my fourteen scripts pass"
# got no answer at all and had to re-run them by hand, outside the lock, against
# build products they had to hope were still there. A gate that costs everyone
# else their results is a gate people route around. Both failures are collected
# and reported, and the run exits non-zero at the end if either of them failed —
# see the result block.
echo "=== accessibility check ==="
ax_status=0
"$ROOT/scripts/ax-check.sh" "$OUT" || ax_status=$?
case "$ax_status" in
    # 3 is "this terminal has no Accessibility grant", a property of the machine
    # rather than of the tree. Failing on it would train everyone to ignore red.
    # It is still named in the result block, because a gate that can go quiet
    # without saying so is a gate that has already stopped working.
    0) ax_verdict="passed" ;;
    3) ax_verdict="NOT RUN — no Accessibility grant on this machine" ;;
    *) ax_verdict="FAILED — see the assertions above" ;;
esac
# The harness exits once the dwell is released. Waiting for it keeps the trap's
# `rm -rf "$STAGE"` from pulling the executable out from under a live process.
for _ in $(seq 1 20); do
    pgrep -f "$STAGE/Melo.app" > /dev/null || break
    /bin/sleep 0.5
done

# Inside the lock: see the header of dev-verify.sh.
echo "=== verify scripts ==="
fails=0
total_scripts=0
for f in scripts/verify-*.py; do
    name=$(basename "$f")
    total_scripts=$((total_scripts + 1))
    if out=$(python3 "$f" 2>&1); then
        printf "  PASS  %s\n" "$name"
    else
        printf "  FAIL  %s\n" "$name"
        echo "$out" | tail -6 | sed 's/^/        /'
        fails=$((fails + 1))
    fi
done

# Every verdict in one place, printed on a green run as well as a red one. The
# accessibility gate is named here whatever it did, including when it did
# nothing — the failure this guards against is not a gate that fails, it is a
# gate that stops running and nobody notices for a release.
echo "=== result ==="
echo "  verify scripts: $((total_scripts - fails))/$total_scripts passing"
echo "  accessibility gate: $ax_verdict"
if [ "$fails" -ne 0 ] || { [ "$ax_status" -ne 0 ] && [ "$ax_status" -ne 3 ]; }; then
    exit 1
fi
