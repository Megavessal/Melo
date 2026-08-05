#!/bin/bash
set -euo pipefail

# Sets up free update hosting for Melo, end to end, in one command.
#
#   ./scripts/publish-setup.sh
#
# Creates the GitHub repository, pushes this project, turns on Pages, generates
# the Sparkle signing key, writes both settings into Config/Info.plist, and
# publishes the first release.
#
# Everything that can be automated is. The only things left to you are the two
# that must be: signing in to GitHub, and letting the Keychain store your key.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

BOLD=$'\033[1m'; DIM=$'\033[2m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; RESET=$'\033[0m'
step()  { printf '\n%s▸ %s%s\n' "$BOLD" "$*" "$RESET"; }
ok()    { printf '  %s✓%s %s\n' "$GREEN" "$RESET" "$*"; }
note()  { printf '  %s%s%s\n' "$DIM" "$*" "$RESET"; }
warn()  { printf '  %s!%s %s\n' "$YELLOW" "$RESET" "$*"; }
fail()  { printf '\nerror: %s\n' "$*" >&2; exit 1; }

REPO_NAME="${1:-Melo}"

[[ "$(uname -s)" == "Darwin" ]] || fail "Run this on your Mac."

# ---------------------------------------------------------------- prerequisites

step "Checking prerequisites"

command -v git >/dev/null || fail "git is missing. Install Xcode command line tools: xcode-select --install"
ok "git"

# gh ships a self-contained binary, so Homebrew is not a prerequisite for it.
# Installing into the project's own tools folder needs no administrator rights
# and leaves nothing behind on the system.
TOOLS_DIR="$ROOT/.build-melo/tools"

install_gh_locally() {
    local arch asset tag version url
    case "$(uname -m)" in
        arm64)  arch="arm64" ;;
        x86_64) arch="amd64" ;;
        *)      fail "Unsupported architecture: $(uname -m)" ;;
    esac

    # Resolve the newest release by following GitHub's /latest redirect. If that
    # is unreachable, fall back to a version known to exist rather than failing.
    tag="$(curl -fsSL -o /dev/null -w '%{url_effective}' \
            https://github.com/cli/cli/releases/latest 2>/dev/null \
          | sed -n 's|.*/tag/\(v[0-9][0-9.]*\)$|\1|p')"
    [[ -n "$tag" ]] || tag="v2.97.0"
    version="${tag#v}"
    asset="gh_${version}_macOS_${arch}.zip"
    url="https://github.com/cli/cli/releases/download/${tag}/${asset}"

    mkdir -p "$TOOLS_DIR"
    note "Downloading GitHub CLI ${version}…"
    curl -fsSL -o "$TOOLS_DIR/gh.zip" "$url" \
        || fail "Could not download $url — check your connection, or install gh from https://cli.github.com and rerun."
    rm -rf "$TOOLS_DIR/gh_${version}_macOS_${arch}"
    /usr/bin/ditto -x -k "$TOOLS_DIR/gh.zip" "$TOOLS_DIR" \
        || fail "Could not unpack the GitHub CLI download."
    rm -f "$TOOLS_DIR/gh.zip"

    local binary="$TOOLS_DIR/gh_${version}_macOS_${arch}/bin/gh"
    [[ -x "$binary" ]] || fail "The GitHub CLI download did not contain an executable at $binary"
    export PATH="$(dirname "$binary"):$PATH"
}

if ! command -v gh >/dev/null; then
    # A previous run may already have put it in the tools folder.
    EXISTING_GH="$(find "$TOOLS_DIR" -type f -name gh -perm -u+x -print -quit 2>/dev/null || true)"
    if [[ -n "$EXISTING_GH" ]]; then
        export PATH="$(dirname "$EXISTING_GH"):$PATH"
    elif command -v brew >/dev/null; then
        note "Installing the GitHub CLI with Homebrew…"
        brew install gh
    else
        warn "GitHub CLI is not installed — fetching a local copy."
        install_gh_locally
    fi
fi
command -v gh >/dev/null || fail "GitHub CLI is still unavailable."
ok "gh $(gh --version | head -1 | awk '{print $3}')"

# ------------------------------------------------------------------ github auth

step "Signing in to GitHub"

if gh auth status >/dev/null 2>&1; then
    ok "already signed in"
else
    note "A browser window will open. Sign in, then come back here."
    gh auth login --hostname github.com --git-protocol https --web
    gh auth status >/dev/null 2>&1 || fail "GitHub sign-in did not complete."
fi

OWNER="$(gh api user --jq .login)"
[[ -n "$OWNER" ]] || fail "Could not read your GitHub username."
SLUG="${OWNER}/${REPO_NAME}"
ok "signed in as ${OWNER}"

# ------------------------------------------------------------------- repository

step "Preparing the repository"

if [[ ! -d .git ]]; then
    git init -q
    git branch -M main
    ok "initialised a git repository"
fi

# .gitignore keeps build products and the local Sparkle staging folder out.
[[ -f .gitignore ]] || fail "Missing .gitignore — extract the full project archive."

git add -A
if git diff --cached --quiet; then
    note "nothing new to commit"
else
    VERSION="$(sed -n 's/^VERSION="\(.*\)"$/\1/p' scripts/build-app.sh | head -1)"
    git -c user.email="${OWNER}@users.noreply.github.com" \
        -c user.name="${OWNER}" \
        commit -q -m "Melo ${VERSION}"
    ok "committed"
fi

if gh repo view "$SLUG" >/dev/null 2>&1; then
    ok "repository ${SLUG} already exists"
    git remote get-url origin >/dev/null 2>&1 || git remote add origin "https://github.com/${SLUG}.git"
    git push -u origin main
else
    note "Creating ${SLUG} as a public repository."
    note "Public is required for free Pages, and Melo is GPL-3.0 — anyone you"
    note "give a build to is already entitled to the source."
    gh repo create "$SLUG" --public --source=. --remote=origin --push \
        --description "Per-app volume, output routing, and sound shaping for macOS."
    ok "created and pushed"
fi

# ------------------------------------------------------------------------ pages

step "Turning on GitHub Pages"

if gh api "repos/${SLUG}/pages" >/dev/null 2>&1; then
    ok "Pages is already enabled"
else
    # 409 means it raced into existence; anything else is a real failure.
    if gh api --method POST "repos/${SLUG}/pages" \
        -f "source[branch]=main" -f "source[path]=/docs" >/dev/null 2>&1; then
        ok "Pages enabled from main /docs"
    else
        warn "Could not enable Pages automatically."
        note "Turn it on by hand: https://github.com/${SLUG}/settings/pages"
        note "Source: Deploy from a branch · Branch: main · Folder: /docs"
    fi
fi

# ------------------------------------------------------------------- feed + key

step "Configuring the updater"

./scripts/setup-github-updates.sh "$SLUG" >/dev/null
FEED_URL="$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' Config/Info.plist)"
ok "feed set to ${FEED_URL}"

PUBLIC_KEY="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' Config/Info.plist 2>/dev/null || true)"
if [[ -n "$PUBLIC_KEY" ]]; then
    ok "signing key already configured"
else
    GENERATE_KEYS="$(find "$ROOT/.build-melo/DerivedData/SourcePackages" -path '*/Sparkle/bin/generate_keys' -type f -print -quit 2>/dev/null || true)"
    if [[ -z "$GENERATE_KEYS" ]]; then
        note "Fetching Sparkle so its key tool is available (one-time)…"
        xcodebuild -resolvePackageDependencies -project Melo.xcodeproj -scheme Melo \
            -derivedDataPath "$ROOT/.build-melo/DerivedData" >/dev/null
        GENERATE_KEYS="$(find "$ROOT/.build-melo/DerivedData/SourcePackages" -path '*/Sparkle/bin/generate_keys' -type f -print -quit 2>/dev/null || true)"
    fi
    [[ -n "$GENERATE_KEYS" ]] || fail "Sparkle's generate_keys tool was not found."

    note "macOS will ask permission to store the key in your Keychain — allow it."
    KEY_OUTPUT="$("$GENERATE_KEYS" 2>&1 || true)"

    # generate_keys prints the public key inside a plist snippet on first run and
    # supports -p for reading it back afterwards. Try both rather than depending
    # on one output format.
    PUBLIC_KEY="$(printf '%s' "$KEY_OUTPUT" | sed -n 's|.*<string>\(.*\)</string>.*|\1|p' | head -1)"
    if [[ -z "$PUBLIC_KEY" ]]; then
        PUBLIC_KEY="$("$GENERATE_KEYS" -p 2>/dev/null | tr -d '[:space:]' || true)"
    fi

    if [[ -n "$PUBLIC_KEY" ]]; then
        /usr/libexec/PlistBuddy -c "Set :SUPublicEDKey ${PUBLIC_KEY}" Config/Info.plist 2>/dev/null \
            || /usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string ${PUBLIC_KEY}" Config/Info.plist
        ok "signing key created and saved"
    else
        printf '\n%s\n\n' "$KEY_OUTPUT"
        fail "Could not read the public key automatically. Copy the SUPublicEDKey value printed above into Config/Info.plist, then rerun."
    fi

    warn "Back up that private key. It lives in your login Keychain as"
    warn "\"Private key for signing Sparkle updates\". If you lose it, no existing"
    warn "install will ever accept another update from you."
fi

# ---------------------------------------------------------------------- release

step "Publishing the first release"

git add -A
git diff --cached --quiet || {
    git -c user.email="${OWNER}@users.noreply.github.com" -c user.name="${OWNER}" \
        commit -q -m "Configure updates"
    git push -q
}

./scripts/release.sh

cat <<EOF

${BOLD}Done.${RESET}

  Download page  https://$(printf '%s' "$OWNER" | tr '[:upper:]' '[:lower:]').github.io/${REPO_NAME}/
  Update feed    ${FEED_URL}
  Repository     https://github.com/${SLUG}

Pages can take a minute or two to go live the first time.

From now on, releasing is: bump VERSION and BUILD_NUMBER in scripts/build-app.sh,
then run ./scripts/release.sh
EOF
