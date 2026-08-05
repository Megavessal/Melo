#!/bin/bash
set -euo pipefail

# One-time setup for hosting Melo's updates on GitHub.
#
#   scripts/setup-github-updates.sh <owner/repo>
#
# Writes the Sparkle feed URL into Config/Info.plist and builds the download page
# under docs/. Commit the result — from then on your clone is the source of truth
# and these settings survive every rebuild.
#
# Layout this produces:
#   docs/appcast.xml   the Sparkle feed, served by GitHub Pages
#   docs/index.html    a download page for people you send the app to
#   Releases           the actual .zip archives
#
# Pages and Releases are split deliberately. The feed URL then never changes no
# matter how you tag releases, and the archives do not count against the Pages
# size limit.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

fail() { printf 'error: %s\n' "$*" >&2; exit 1; }

SLUG="${1:-}"
[[ -n "$SLUG" ]] || fail "Usage: scripts/setup-github-updates.sh <owner/repo>   (for example: jengram/Melo)"
[[ "$SLUG" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || fail "Expected owner/repo, got: $SLUG"

OWNER="${SLUG%%/*}"
REPO="${SLUG##*/}"

# GitHub Pages URLs are case-sensitive in the repo segment but the owner segment
# is lowercased by github.io. Getting this wrong yields a 404 that looks like a
# broken updater, so normalise it here rather than letting it fail silently.
OWNER_LOWER="$(printf '%s' "$OWNER" | tr '[:upper:]' '[:lower:]')"
FEED_URL="https://${OWNER_LOWER}.github.io/${REPO}/appcast.xml"
PAGE_URL="https://${OWNER_LOWER}.github.io/${REPO}/"
RELEASES_URL="https://github.com/${OWNER}/${REPO}/releases"

/usr/libexec/PlistBuddy -c "Set :SUFeedURL ${FEED_URL}" "$ROOT/Config/Info.plist" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Add :SUFeedURL string ${FEED_URL}" "$ROOT/Config/Info.plist"

mkdir -p "$ROOT/docs"

# GitHub Pages runs Jekyll by default, which skips files beginning with an
# underscore and can rewrite things unexpectedly. The feed must be served byte
# for byte.
touch "$ROOT/docs/.nojekyll"

TEMPLATE="$ROOT/scripts/templates/download-page.html"
[[ -f "$TEMPLATE" ]] || fail "Missing $TEMPLATE"

VERSION="$(sed -n 's/^VERSION="\(.*\)"$/\1/p' "$ROOT/scripts/build-app.sh" | head -1)"

sed -e "s|__OWNER__|${OWNER}|g" \
    -e "s|__REPO__|${REPO}|g" \
    -e "s|__VERSION__|${VERSION}|g" \
    -e "s|__RELEASES_URL__|${RELEASES_URL}|g" \
    -e "s|__DOWNLOAD_URL__|https://github.com/${OWNER}/${REPO}/releases/download/v${VERSION}/Melo-macOS-${VERSION}.zip|g" \
    "$TEMPLATE" > "$ROOT/docs/index.html"

PUBLIC_KEY="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$ROOT/Config/Info.plist" 2>/dev/null || true)"

cat <<EOF

Configured Melo to publish updates from ${OWNER}/${REPO}.

  Feed      ${FEED_URL}
  Page      ${PAGE_URL}
  Releases  ${RELEASES_URL}

Remaining steps
───────────────
1. Create the repository at https://github.com/new
     Name: ${REPO}     Visibility: Public
   Public is required for free Pages, and Melo is GPL-3.0 — anyone you give a
   binary to is already entitled to the source.

2. Push this project to it:
     git init && git add -A && git commit -m "Melo ${VERSION}"
     git branch -M main
     git remote add origin https://github.com/${OWNER}/${REPO}.git
     git push -u origin main

3. Turn on Pages: repository Settings → Pages →
     Source: Deploy from a branch    Branch: main    Folder: /docs

EOF

if [[ -z "$PUBLIC_KEY" ]]; then
cat <<'EOF'
4. Create your update signing key, which is still missing:
     ./scripts/sparkle-setup.sh
   Paste the printed public key into SUPublicEDKey in Config/Info.plist.

5. Publish:
     ./scripts/release.sh
EOF
else
cat <<'EOF'
4. Publish:
     ./scripts/release.sh
EOF
fi

printf '\n'
