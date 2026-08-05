#!/bin/bash
set -euo pipefail

# Builds the folder you upload for a Sparkle release: the app archive plus a
# signed appcast.xml. Run scripts/sparkle-setup.sh once first — generate_appcast
# reads the private key from your Keychain to sign each entry.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

fail() { printf 'error: %s\n' "$*" >&2; exit 1; }

# Track the build script rather than repeating the version here; the two drifted
# apart before, which produces an appcast advertising a version nobody built.
VERSION="$(sed -n 's/^VERSION="\(.*\)"$/\1/p' "$ROOT/scripts/build-app.sh" | head -1)"
[[ -n "$VERSION" ]] || fail "Could not read VERSION from scripts/build-app.sh"

ARCHIVE="$ROOT/outputs/Melo-macOS-$VERSION.zip"
RELEASE_DIR="${1:-$ROOT/outputs/sparkle-releases}"

if [[ ! -f "$ARCHIVE" ]]; then
    fail "Missing $ARCHIVE. Run ./Build\\ Melo.command --release first — a --dev build is not for distribution."
fi

FEED_URL="$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$ROOT/Config/Info.plist" 2>/dev/null || true)"
PUBLIC_KEY="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$ROOT/Config/Info.plist" 2>/dev/null || true)"
[[ -n "$FEED_URL" ]] || fail "SUFeedURL is empty in Config/Info.plist. Set it before publishing."
[[ -n "$PUBLIC_KEY" ]] || fail "SUPublicEDKey is empty in Config/Info.plist. Run scripts/sparkle-setup.sh first."

mkdir -p "$RELEASE_DIR"
cp -f "$ARCHIVE" "$RELEASE_DIR/"

GENERATE_APPCAST="$(find "$ROOT/.build-melo/DerivedData/SourcePackages" -path '*/Sparkle/bin/generate_appcast' -type f -print -quit 2>/dev/null || true)"
[[ -n "$GENERATE_APPCAST" ]] || fail "Sparkle's generate_appcast tool was not found. Build Melo once, then rerun."

"$GENERATE_APPCAST" "$RELEASE_DIR"

printf '\nSparkle release folder prepared:\n  %s\n\nUpload every file in that folder so appcast.xml is reachable at:\n  %s\n' \
    "$RELEASE_DIR" "$FEED_URL"
