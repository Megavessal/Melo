#!/bin/bash
set -euo pipefail

# Publishes a Melo release: builds, signs the appcast, creates the GitHub
# release, and updates the download page. One command, start to finish.
#
#   ./scripts/release.sh
#
# Requires: scripts/setup-github-updates.sh run once, scripts/sparkle-setup.sh
# run once, and the GitHub CLI (`gh auth login`).

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

fail() { printf 'error: %s\n' "$*" >&2; exit 1; }
step() { printf '\n\033[1m▸ %s\033[0m\n' "$*"; }

VERSION="$(sed -n 's/^VERSION="\(.*\)"$/\1/p' scripts/build-app.sh | head -1)"
BUILD="$(sed -n 's/^BUILD_NUMBER="\(.*\)"$/\1/p' scripts/build-app.sh | head -1)"
[[ -n "$VERSION" && -n "$BUILD" ]] || fail "Could not read VERSION/BUILD_NUMBER from scripts/build-app.sh"

TAG="v${VERSION}"
ARCHIVE="$ROOT/outputs/Melo-macOS-${VERSION}.zip"
# Kept between releases on purpose: generate_appcast builds the feed from the
# archives it finds here, so deleting this folder drops older versions out of the
# appcast.
RELEASE_DIR="$ROOT/outputs/sparkle-releases"

# ---- Preconditions ---------------------------------------------------------

# shellcheck source=scripts/lib/gh.sh
source "$ROOT/scripts/lib/gh.sh"

# Resolved here rather than inherited: this script is run on its own for every
# release, in a shell that never saw publish-setup.sh.
melo_ensure_gh "$ROOT" || fail "The GitHub CLI is required. Install it from https://cli.github.com and rerun."
gh auth status >/dev/null 2>&1 || fail "Not signed in to GitHub. Run: gh auth login"

FEED_URL="$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' Config/Info.plist 2>/dev/null || true)"
PUBLIC_KEY="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' Config/Info.plist 2>/dev/null || true)"
[[ -n "$FEED_URL" ]] || fail "SUFeedURL is empty. Run: scripts/setup-github-updates.sh <owner/repo>"
[[ -n "$PUBLIC_KEY" ]] || fail "SUPublicEDKey is empty. Run: scripts/sparkle-setup.sh"

# Derive the repo from the feed rather than storing it twice, so the two can
# never disagree.
SLUG="$(printf '%s' "$FEED_URL" | sed -n 's|^https://\([^.]*\)\.github\.io/\([^/]*\)/.*$|\1/\2|p')"
[[ -n "$SLUG" ]] || fail "SUFeedURL is not a GitHub Pages address: $FEED_URL"

if gh release view "$TAG" >/dev/null 2>&1; then
    fail "Release $TAG already exists. Bump VERSION/BUILD_NUMBER in scripts/build-app.sh first."
fi

# ---- Build -----------------------------------------------------------------

step "Building Melo $VERSION ($BUILD) for distribution"
# --release, not --dev: a shipping build has no developer-update machinery in it.
./scripts/build-app.sh --release
[[ -f "$ARCHIVE" ]] || fail "Build did not produce $ARCHIVE"

# ---- Appcast ---------------------------------------------------------------

step "Signing the appcast"
mkdir -p "$RELEASE_DIR"
cp -f "$ARCHIVE" "$RELEASE_DIR/"

GENERATE_APPCAST="$(find "$ROOT/.build-melo/DerivedData/SourcePackages" -path '*/Sparkle/bin/generate_appcast' -type f -print -quit 2>/dev/null || true)"
[[ -n "$GENERATE_APPCAST" ]] || fail "Sparkle's generate_appcast was not found. Build once, then rerun."

# Every archive the feed references is uploaded to *this* release, so the prefix
# is this tag. Older entries stay valid because their archives are re-uploaded
# alongside the new one.
"$GENERATE_APPCAST" \
    --download-url-prefix "https://github.com/${SLUG}/releases/download/${TAG}/" \
    --link "https://github.com/${SLUG}" \
    --maximum-versions 5 \
    -o "$ROOT/docs/appcast.xml" \
    "$RELEASE_DIR"

[[ -s "$ROOT/docs/appcast.xml" ]] || fail "generate_appcast produced no feed"

# ---- Download page ---------------------------------------------------------

step "Updating the download page"
OWNER="${SLUG%%/*}"
REPO="${SLUG##*/}"
sed -e "s|__OWNER__|${OWNER}|g" \
    -e "s|__REPO__|${REPO}|g" \
    -e "s|__VERSION__|${VERSION}|g" \
    -e "s|__RELEASES_URL__|https://github.com/${SLUG}/releases|g" \
    -e "s|__DOWNLOAD_URL__|https://github.com/${SLUG}/releases/download/v${VERSION}/Melo-macOS-${VERSION}.zip|g" \
    scripts/templates/download-page.html > "$ROOT/docs/index.html"

# ---- Publish ---------------------------------------------------------------

step "Creating GitHub release $TAG"
UPLOADS=()
while IFS= read -r -d '' file; do
    UPLOADS+=("$file")
done < <(find "$RELEASE_DIR" -type f \( -name '*.zip' -o -name '*.delta' \) -print0)
[[ ${#UPLOADS[@]} -gt 0 ]] || fail "Nothing to upload from $RELEASE_DIR"

gh release create "$TAG" \
    --repo "$SLUG" \
    --title "Melo $VERSION" \
    --notes "Melo $VERSION (build $BUILD)" \
    "${UPLOADS[@]}"

step "Publishing the feed"
git add docs/appcast.xml docs/index.html docs/.nojekyll 2>/dev/null || true
if git diff --cached --quiet; then
    printf 'Feed unchanged.\n'
else
    # Identity passed explicitly so this works on a machine where git has no
    # global user configured — failing at the very last step of a release is a
    # miserable place to discover that.
    git -c user.email="${OWNER}@users.noreply.github.com" \
        -c user.name="${OWNER}" \
        commit -q -m "Publish Melo $VERSION"
    git push -q
fi

cat <<EOF

Melo $VERSION is published.

  Download page  https://${OWNER}.github.io/${REPO}/
  Update feed    $FEED_URL

Existing installs pick it up on their next check. Give the download page to
anyone new — it includes the first-launch step macOS requires for apps that
are not notarized.
EOF
