#!/bin/bash
# Locates the GitHub CLI, installing a local copy if the system has none.
#
# Shared by publish-setup.sh and release.sh. release.sh needs its own copy of
# this logic because it is run on its own for every release afterwards, long
# after publish-setup.sh set PATH for one shell that has since exited.
#
# The install location is deliberately NOT under .build-melo: build-app.sh
# begins every build with `rm -rf "$BUILD_ROOT"`, which deleted the binary out
# from under a release that was already using it.

# Pinned fallback for when GitHub's /latest redirect can't be reached.
MELO_GH_FALLBACK_TAG="v2.97.0"

melo_tools_dir() {
    printf '%s/.tools' "$1"
}

# melo_ensure_gh <project-root>
# On success, `gh` is on PATH for the calling shell.
melo_ensure_gh() {
    local root="$1"
    local tools
    tools="$(melo_tools_dir "$root")"

    command -v gh >/dev/null && return 0

    # A previous run may already have fetched one.
    local existing
    existing="$(find "$tools" -type f -name gh -perm -u+x -print -quit 2>/dev/null || true)"
    if [[ -n "$existing" ]]; then
        PATH="$(dirname "$existing"):$PATH"
        export PATH
        command -v gh >/dev/null && return 0
    fi

    if command -v brew >/dev/null; then
        brew install gh >/dev/null 2>&1 || true
        command -v gh >/dev/null && return 0
    fi

    local arch
    case "$(uname -m)" in
        arm64)  arch="arm64" ;;
        x86_64) arch="amd64" ;;
        *)      printf 'error: unsupported architecture %s\n' "$(uname -m)" >&2; return 1 ;;
    esac

    local tag version asset url
    tag="$(curl -fsSL -o /dev/null -w '%{url_effective}' \
            https://github.com/cli/cli/releases/latest 2>/dev/null \
          | sed -n 's|.*/tag/\(v[0-9][0-9.]*\)$|\1|p')"
    [[ -n "$tag" ]] || tag="$MELO_GH_FALLBACK_TAG"
    version="${tag#v}"
    asset="gh_${version}_macOS_${arch}.zip"
    url="https://github.com/cli/cli/releases/download/${tag}/${asset}"

    mkdir -p "$tools"
    printf '  Downloading GitHub CLI %s…\n' "$version"
    if ! curl -fsSL -o "$tools/gh.zip" "$url"; then
        printf 'error: could not download %s\n' "$url" >&2
        printf '       Install gh from https://cli.github.com and run this again.\n' >&2
        return 1
    fi

    rm -rf "${tools:?}/gh_${version}_macOS_${arch}"
    if ! /usr/bin/ditto -x -k "$tools/gh.zip" "$tools"; then
        printf 'error: could not unpack the GitHub CLI download\n' >&2
        return 1
    fi
    rm -f "$tools/gh.zip"

    local binary="$tools/gh_${version}_macOS_${arch}/bin/gh"
    if [[ ! -x "$binary" ]]; then
        printf 'error: the GitHub CLI download contained no executable at %s\n' "$binary" >&2
        return 1
    fi

    PATH="$(dirname "$binary"):$PATH"
    export PATH
    command -v gh >/dev/null
}
