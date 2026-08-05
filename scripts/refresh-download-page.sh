#!/bin/bash
set -euo pipefail

# Regenerates docs/index.html from the template and publishes it, without
# rebuilding or cutting a release. Use after editing the page's wording.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

fail() { printf 'error: %s\n' "$*" >&2; exit 1; }

VERSION="$(sed -n 's/^VERSION="\(.*\)"$/\1/p' scripts/build-app.sh | head -1)"
FEED_URL="$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' Config/Info.plist 2>/dev/null || true)"
[[ -n "$FEED_URL" ]] || fail "SUFeedURL is empty. Run scripts/setup-github-updates.sh first."

SLUG="$(printf '%s' "$FEED_URL" | sed -n 's|^https://\([^.]*\)\.github\.io/\([^/]*\)/.*$|\1/\2|p')"
[[ -n "$SLUG" ]] || fail "SUFeedURL is not a GitHub Pages address: $FEED_URL"
OWNER="${SLUG%%/*}"
REPO="${SLUG##*/}"

sed -e "s|__OWNER__|${OWNER}|g" \
    -e "s|__REPO__|${REPO}|g" \
    -e "s|__VERSION__|${VERSION}|g" \
    -e "s|__RELEASES_URL__|https://github.com/${SLUG}/releases|g" \
    -e "s|__DOWNLOAD_URL__|https://github.com/${SLUG}/releases/download/v${VERSION}/Melo-macOS-${VERSION}.zip|g" \
    scripts/templates/download-page.html > "$ROOT/docs/index.html"

git add docs/index.html
if git diff --cached --quiet; then
    printf 'Download page unchanged.\n'
else
    git -c user.email="${OWNER}@users.noreply.github.com" -c user.name="${OWNER}" \
        commit -q -m "Refresh download page"
    git push -q
    printf 'Published: https://%s.github.io/%s/\n' "$OWNER" "$REPO"
fi
