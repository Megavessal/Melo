#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP_NAME="Melo"
VERSION="3.1.2"
BUILD_NUMBER="312"
BUILD_ROOT="$ROOT/.build-melo"
DERIVED_DATA="$BUILD_ROOT/DerivedData"
OUTPUT_ROOT="$ROOT/outputs"
APP_BUNDLE="$OUTPUT_ROOT/$APP_NAME.app"
ZIP_PATH="$OUTPUT_ROOT/$APP_NAME-macOS-$VERSION.zip"
PROJECT="$ROOT/Melo.xcodeproj"
SCHEME="Melo"

# Developer builds keep the in-app developer-update tools (build from a folder,
# build from a link, build log). A normal build compiles them out entirely rather
# than merely hiding their UI, so a shipping Melo has no code that downloads and
# runs a build script.
DEV_BUILD=0
COMPILATION_CONDITIONS=""
for arg in "$@"; do
    case "$arg" in
        --dev) DEV_BUILD=1 ;;
        --release) DEV_BUILD=0 ;;
        *) printf 'error: unknown option %s\n' "$arg" >&2; exit 1 ;;
    esac
done
if (( DEV_BUILD )); then
    COMPILATION_CONDITIONS="MELO_DEV"
    ZIP_PATH="$OUTPUT_ROOT/$APP_NAME-macOS-$VERSION-dev.zip"
fi

fail() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

[[ "$(uname -s)" == "Darwin" ]] || fail "Melo must be built on macOS."
[[ -d "$PROJECT" ]] || fail "Melo.xcodeproj is missing. Re-extract the complete project archive."

if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

command -v xcodebuild >/dev/null || fail "Install full Xcode, then run: sudo xcode-select -s /Applications/Xcode.app"
command -v xcrun >/dev/null || fail "Xcode command-line tools are unavailable."
command -v codesign >/dev/null || fail "codesign is unavailable. Install Xcode command-line tools."
command -v lipo >/dev/null || fail "lipo is unavailable. Install Xcode command-line tools."

SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"
SDK_MAJOR="${SDK_VERSION%%.*}"
if (( SDK_MAJOR < 26 )); then
    fail "Xcode with the macOS 26 SDK is required because Melo uses macOS 26 interface APIs. Found SDK $SDK_VERSION."
fi

if (( DEV_BUILD )); then
    printf 'Building Melo %s (%s) — developer build — with macOS SDK %s\n' "$VERSION" "$BUILD_NUMBER" "$SDK_VERSION"
else
    printf 'Building Melo %s (%s) with Xcode and macOS SDK %s\n' "$VERSION" "$BUILD_NUMBER" "$SDK_VERSION"
fi

rm -rf "$BUILD_ROOT" "$APP_BUNDLE" "$ZIP_PATH"
mkdir -p "$BUILD_ROOT" "$OUTPUT_ROOT"

xcodebuild \
    -resolvePackageDependencies \
    -project "$PROJECT" \
    -scheme "$SCHEME"

xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -derivedDataPath "$DERIVED_DATA" \
    -destination 'generic/platform=macOS' \
    ARCHS=arm64 \
    EXCLUDED_ARCHS=x86_64 \
    ONLY_ACTIVE_ARCH=NO \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    SWIFT_ACTIVE_COMPILATION_CONDITIONS="\$(inherited) $COMPILATION_CONDITIONS" \
    build

BUILT_APP="$DERIVED_DATA/Build/Products/Release/$APP_NAME.app"
[[ -d "$BUILT_APP" ]] || fail "Xcode did not produce $BUILT_APP"

/usr/bin/ditto "$BUILT_APP" "$APP_BUNDLE"

# Finder and archive tools can attach extended attributes that codesign rejects.
xattr -cr "$APP_BUNDLE" 2>/dev/null || true
find "$APP_BUNDLE" \( -name ".DS_Store" -o -name "._*" \) -delete


# The bundled encoder. MP3 and Opus have no encoder on macOS, so Melo Edit
# shells out for those two formats and only those two. Built from upstream
# source by scripts/build-ffmpeg.sh — 1.7 MB, audio-only, statically linked,
# LGPL-2.1 (no --enable-gpl, which would pull it to GPL-2 and conflict with
# Melo's GPL-3).
#
# Contents/Helpers, not Contents/Resources: a Mach-O in Resources is signable
# but is not where Apple puts helper executables, and the distinction matters
# to `--deep` and to anyone auditing the bundle. It goes in before the thinning
# loop on purpose, so a future universal build of it gets thinned like anything
# else rather than smuggling an Intel slice past the check below.
FFMPEG_SOURCE="$ROOT/Vendor/ffmpeg/ffmpeg"
if [[ -x "$FFMPEG_SOURCE" ]]; then
    mkdir -p "$APP_BUNDLE/Contents/Helpers"
    /usr/bin/ditto "$FFMPEG_SOURCE" "$APP_BUNDLE/Contents/Helpers/ffmpeg"
    chmod 755 "$APP_BUNDLE/Contents/Helpers/ffmpeg"
    printf 'Bundled ffmpeg (%s bytes).\n' "$(stat -f '%z' "$APP_BUNDLE/Contents/Helpers/ffmpeg")"
else
    # Not fatal: the app runs without it and Melo Edit falls back to looking for
    # a user-installed ffmpeg, which is exactly what it did before 3.1.2. But it
    # is a silent loss of a shipped capability, so say so loudly here.
    printf 'WARNING: %s missing — MP3 and Opus export will need a user-installed ffmpeg.\n' \
        "$FFMPEG_SOURCE" >&2
fi

# Swift package binary frameworks can arrive as universal artifacts. Thin every
# Mach-O payload before signing so the final bundle is genuinely Apple-silicon
# only, including Sparkle's nested helper tools.
thinned_count=0
while IFS= read -r -d '' candidate; do
    description="$(/usr/bin/file -b "$candidate" 2>/dev/null || true)"
    [[ "$description" == *"Mach-O"* ]] || continue
    candidate_archs="$(lipo -archs "$candidate" 2>/dev/null || true)"
    if [[ "$candidate_archs" == *x86_64* ]]; then
        [[ "$candidate_archs" == *arm64* ]] || fail "Embedded binary is Intel-only: $candidate"
        mode="$(stat -f '%Lp' "$candidate")"
        temp="$candidate.melo-arm64"
        lipo "$candidate" -thin arm64 -output "$temp"
        chmod "$mode" "$temp"
        mv -f "$temp" "$candidate"
        thinned_count=$((thinned_count + 1))
    fi
done < <(find "$APP_BUNDLE" -type f -print0)
printf 'Removed Intel slices from %s embedded binaries.\n' "$thinned_count"

# Ad-hoc signing is appropriate for a local build. Use Developer ID signing and
# notarization before distributing the app outside your own Mac.
codesign --force --deep --sign - \
    --entitlements "$ROOT/Config/Melo.local.entitlements" \
    "$APP_BUNDLE"

codesign --verify --strict --verbose=2 "$APP_BUNDLE"
plutil -lint "$APP_BUNDLE/Contents/Info.plist"
[[ -d "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework" ]] || fail "Sparkle.framework was not embedded in the app bundle."

# Launch test. A bundle that cannot link — a framework that was not embedded, a
# thinned binary that lost its only slice — fails here rather than at the moment
# a user double-clicks it or an update swaps it in. This is the same check the
# in-app updater runs before replacing a running copy.
PREFLIGHT_LOG="$BUILD_ROOT/preflight.log"
"$APP_BUNDLE/Contents/MacOS/$APP_NAME" --melo-preflight >"$PREFLIGHT_LOG" 2>&1 &
PREFLIGHT_PID=$!

# Bounded wait. macOS has no coreutils `timeout`, and this build can be launched
# by the in-app updater in the background, where a hung child would look like a
# silently stalled update rather than a failure.
preflight_status=""
for _ in $(seq 1 60); do
    if ! kill -0 "$PREFLIGHT_PID" 2>/dev/null; then
        wait "$PREFLIGHT_PID"
        preflight_status=$?
        break
    fi
    sleep 0.5
done

if [[ -z "$preflight_status" ]]; then
    kill -9 "$PREFLIGHT_PID" 2>/dev/null || true
    printf 'error: the built app did not finish starting up within 30s.\n' >&2
    exit 1
fi
if (( preflight_status != 0 )); then
    printf 'error: the built app could not start (exit %s).\n' "$preflight_status" >&2
    sed -n '1,20p' "$PREFLIGHT_LOG" >&2
    exit 1
fi
printf 'Launch test passed.\n'

[[ "$(defaults read "$APP_BUNDLE/Contents/Info" CFBundleShortVersionString)" == "$VERSION" ]] \
    || fail "Built app version does not match $VERSION."
[[ "$(defaults read "$APP_BUNDLE/Contents/Info" CFBundleVersion)" == "$BUILD_NUMBER" ]] \
    || fail "Built app build number does not match $BUILD_NUMBER."

ARCHS="$(lipo -archs "$APP_BUNDLE/Contents/MacOS/$APP_NAME")"
[[ "$ARCHS" == "arm64" ]] || fail "Apple-silicon-only binary check failed: $ARCHS"

while IFS= read -r -d '' candidate; do
    description="$(/usr/bin/file -b "$candidate" 2>/dev/null || true)"
    [[ "$description" == *"Mach-O"* ]] || continue
    candidate_archs="$(lipo -archs "$candidate" 2>/dev/null || true)"
    [[ "$candidate_archs" != *x86_64* ]] || fail "Intel slice remains in: $candidate"
done < <(find "$APP_BUNDLE" -type f -print0)

APP_INTENTS_METADATA="$(find "$APP_BUNDLE/Contents" -name 'Metadata.appintents' -print -quit)"
[[ -n "$APP_INTENTS_METADATA" ]] || fail "Shortcuts metadata was not generated. Build with full Xcode 26 and the Melo Xcode scheme."

/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$ZIP_PATH"

APP_SIZE="$(du -sh "$APP_BUNDLE" | awk '{print $1}')"
printf '\nBuilt successfully:\n  %s\n  %s\nArchitectures: %s\nApp size: %s\nShortcuts metadata: %s\n' \
    "$APP_BUNDLE" "$ZIP_PATH" "$ARCHS" "$APP_SIZE" "$APP_INTENTS_METADATA"
