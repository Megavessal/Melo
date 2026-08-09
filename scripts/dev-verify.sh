#!/bin/bash
# Build Melo (dev) and render UI snapshots, one caller at a time.
#
#   scripts/dev-verify.sh <output-dir>
#
# Two things this exists for.
#
# 1. Serialization. Several agents editing this repo at once would otherwise
#    run concurrent xcodebuilds against the same DerivedData and the same
#    outputs/ directory, which produces corrupt bundles and build failures that
#    look like code errors. The flock makes builds queue instead.
#
# 2. Launching the harness correctly. Executing the binary directly gets the
#    process SIGKILLed (exit 137) before it reaches any of Melo's own code —
#    the app's CoreAudio taps need the TCC identity that only a LaunchServices
#    launch establishes. `open -n --env` is the path that works; a direct
#    ./Melo.app/Contents/MacOS/Melo is not.
#
# Exits non-zero if the build fails, the launch test fails, too few snapshots
# were produced, the harness reported a bad scene, or a verify script fails.
#
# Everything that reads or writes the repo — build, render AND the verify
# scripts — runs inside the lock. The verify loop used to run after the lock
# was released, which meant the exact concurrency the lock exists for still
# corrupted the second half of every run: `verify-premium-pass.py` was seen
# dying on `FileNotFoundError` mid-`rglob` while another agent's
# `build-app.sh` did `rm -rf .build-melo` underneath it.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:-}"

if [ -z "$OUT" ]; then
    echo "usage: scripts/dev-verify.sh <output-dir>" >&2
    exit 2
fi

mkdir -p "$OUT"
# Absolute, always. `mkdir -p` above resolves a relative path against this
# script's working directory, but the harness is started by LaunchServices via
# `open`, whose working directory is `/` — so a relative MELO_SNAPSHOT_DIR sent
# every frame to a path that does not exist and the run produced zero PNGs.
# Measured 2026-08-09 against `outputs/baseline-editor`: build ok, render
# started, nothing written, and the only complaint was on stderr, which is easy
# to lose behind a pipe. Absolutizing here rather than documenting the
# convention, because the convention was already "use /tmp/melo-<topic>" and it
# is one character of difference to get wrong.
OUT="$(cd "$OUT" && pwd)"
# _failures.log too: a stale one from a previous run reads as this run's.
rm -f "$OUT"/*.png "$OUT/_failures.log" 2>/dev/null || true

# NOT under .build-melo: scripts/build-app.sh starts with `rm -rf .build-melo`,
# so a lock kept there is deleted by the very build it is serializing. Each new
# caller then created a fresh lock file, every holder was waiting on an inode
# nobody could see, and concurrent xcodebuilds wiped each other's DerivedData
# mid-resolve — which surfaces as "Could not resolve package dependencies",
# a network-looking error with no network cause.
LOCK="${TMPDIR:-/tmp}/melo-dev-verify.lock"

echo "waiting for build lock..."
# No flock(1) on macOS; shlock/mkdir are racy. Perl's flock is available on
# every macOS and blocks properly.
# `system`, not `exec`. Perl sets close-on-exec on descriptors above 2, so
# `exec` closed the lock file the instant the build started — the flock was
# released before xcodebuild had done anything, every caller sailed straight
# through, and concurrent builds corrupted each other's build.db. That failure
# surfaced as "database is locked", "disk I/O error", or "Could not resolve
# package dependencies", none of which point at a lock. `system` keeps this
# perl process alive holding the descriptor for as long as the build runs.
# `system` returns a raw wait status, not an exit code. `>> 8` alone reads the
# exit byte and throws the signal byte away, so a locked section killed by a
# signal — SIGKILL, SIGSEGV, an OOM kill — came back as status 0 and this
# script exited 0 with zero frames produced. Proved end-to-end against a
# locked-script stub that SIGKILLs itself: EXIT was 0. `set -e` cannot help,
# because perl itself succeeded. The low seven bits carry the signal; shells
# report that as 128 + signal, and so does this.
status=0
perl -e 'open(F, ">>", $ARGV[0]) or die; flock(F, 2) or die;
         my $rc = system(@ARGV[1..$#ARGV]);
         exit($rc & 127 ? 128 + ($rc & 127) : $rc >> 8);' \
    "$LOCK" "$ROOT/scripts/dev-verify-locked.sh" "$ROOT" "$OUT" || status=$?

echo
echo "snapshots: $OUT"
exit "$status"
