#!/bin/bash
set -euo pipefail

# One-time Sparkle setup.
#
# Creates the EdDSA key pair Sparkle uses to prove an update really came from you.
# The private half is stored in your login Keychain and never touches this repo —
# if you lose it, every existing install stops accepting updates permanently, so
# back it up somewhere you trust.
#
# Run this once, paste the printed public key into Config/Info.plist, and Sparkle
# turns itself on.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

fail() { printf 'error: %s\n' "$*" >&2; exit 1; }

[[ "$(uname -s)" == "Darwin" ]] || fail "Sparkle's tools only run on macOS."

# Sparkle ships its tools inside the resolved Swift package checkout, which only
# exists after a build has fetched dependencies.
find_tool() {
    find "$ROOT/.build-melo/DerivedData/SourcePackages" \
        -path "*/Sparkle/bin/$1" -type f -print -quit 2>/dev/null || true
}

GENERATE_KEYS="$(find_tool generate_keys)"
if [[ -z "$GENERATE_KEYS" ]]; then
    fail "Sparkle's generate_keys tool was not found. Run ./Build\\ Melo.command once, then rerun this script."
fi

printf 'Creating a Sparkle signing key for Melo…\n\n'
"$GENERATE_KEYS"

cat <<'EOF'

────────────────────────────────────────────────────────────────────────
Next steps

1. Copy the public key printed above (the SUPublicEDKey line).
2. Paste it into Config/Info.plist as the value of SUPublicEDKey.
3. Put the address of your appcast.xml into SUFeedURL in the same file.
   It must be https. Example:
     https://example.com/melo/appcast.xml
4. Rebuild. The Updates tab stops reporting a missing configuration and
   Sparkle begins checking on its own.

The private key now lives in your login Keychain under "Private key for
signing Sparkle updates". Back it up. Losing it means no existing install
will ever accept another update from you.
────────────────────────────────────────────────────────────────────────
EOF
