#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"
# Defaults to a developer build, because this script is what the in-app updater
# invokes when it installs a source package — and older Melo builds invoke it with
# no arguments at all. If the default were a shipping build, the first update
# installed this way would compile out the developer-update tools and there would
# be no way to install the next one. Pass --release for a distributable build.
if [[ $# -eq 0 ]]; then
  set -- --dev
fi
./scripts/build-app.sh "$@"
if [[ -t 0 ]]; then
  printf '\nPress Return to close.\n'
  read -r
fi
