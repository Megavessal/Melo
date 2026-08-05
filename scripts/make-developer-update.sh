#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:-}"
BUILD="${2:-}"
SOURCE_DIR="${3:-}"
NOTES="${4:-Developer build}"

if [[ -z "$VERSION" || -z "$BUILD" || -z "$SOURCE_DIR" ]]; then
  echo "Usage: $0 <version> <build> <source-folder> [release-notes]" >&2
  exit 1
fi

SOURCE_DIR="$(cd "$SOURCE_DIR" && pwd)"
STAGE="$ROOT/.build-melo/developer-update-$BUILD"
PACKAGE_NAME="Melo-Developer-$VERSION-$BUILD"
OUTPUT="$ROOT/outputs/$PACKAGE_NAME.zip"
SOURCE_NAME="Melo-macOS-$VERSION"

rm -rf "$STAGE" "$OUTPUT"
mkdir -p "$STAGE/$SOURCE_NAME" "$ROOT/outputs"

python3 - "$STAGE/manifest.json" "$VERSION" "$BUILD" "$SOURCE_NAME" "$NOTES" <<'PY'
import json
import sys
from pathlib import Path

output, version, build, source_name, notes = sys.argv[1:]
manifest = {
    "schemaVersion": 1,
    "version": version,
    "build": int(build),
    "bundleIdentifier": "dev.local.Melo",
    "packageType": "source",
    "minimumMacOS": "15.4",
    "sourceSubdirectory": source_name,
    "releaseNotes": notes,
}
Path(output).write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
PY

/usr/bin/rsync -a \
  --exclude '.build-melo' \
  --exclude 'outputs' \
  --exclude '.DS_Store' \
  "$SOURCE_DIR/" "$STAGE/$SOURCE_NAME/"

xattr -cr "$STAGE" 2>/dev/null || true
/usr/bin/ditto -c -k --sequesterRsrc "$STAGE" "$OUTPUT"

printf 'Created developer update:\n  %s\n' "$OUTPUT"
