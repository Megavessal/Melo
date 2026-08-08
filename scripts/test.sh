#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

python3 scripts/verify-premium-pass.py Sources/Melo
python3 scripts/verify-everyday-features.py
python3 scripts/verify-consumer-foundations.py
python3 scripts/verify-apple-refinement.py
python3 scripts/verify-update-systems.py
python3 scripts/verify-recovery-support.py
python3 scripts/verify-theme-studio.py
python3 scripts/verify-2.8.3-refinement.py

if command -v xcrun >/dev/null 2>&1; then
    SWIFTC=(xcrun swiftc)
elif command -v swiftc >/dev/null 2>&1; then
    SWIFTC=(swiftc)
else
    echo "error: Swift compiler not found" >&2
    exit 1
fi
find Sources/Melo -name '*.swift' -print0 | xargs -0 "${SWIFTC[@]}" -frontend -parse

swift package dump-package >/dev/null
bash -n scripts/build-app.sh scripts/test.sh "Build Melo.command"

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "Source, project, package, and feature checks passed. Native Xcode build skipped outside macOS."
    exit 0
fi

xcodebuild -project Melo.xcodeproj -scheme Melo -list >/dev/null
./scripts/build-app.sh

APP="$ROOT/outputs/Melo.app"
[[ -d "$APP" ]]
[[ "$(defaults read "$APP/Contents/Info" CFBundleShortVersionString)" == "2.8.3" ]]
[[ "$(defaults read "$APP/Contents/Info" CFBundleVersion)" == "283" ]]
[[ "$(defaults read "$APP/Contents/Info" CFBundleIdentifier)" == "io.github.megavessal.Melo" ]]
find "$APP/Contents" -name 'Metadata.appintents' -print -quit | grep -q .

codesign --verify --deep --strict --verbose=2 "$APP"
ARCHS="$(lipo -archs "$APP/Contents/MacOS/Melo")"
[[ "$ARCHS" == "arm64" ]]
file "$APP/Contents/MacOS/Melo"

echo "All Melo build checks passed."
