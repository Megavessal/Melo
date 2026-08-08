#!/usr/bin/env python3
"""One arrow in the interface path Melo prints, everywhere it prints one.

Melo writes a path through its own interface as `Settings › General`, and
`SettingsGuide` alone does it a hundred times. Four user-facing strings wrote
`Settings → General` instead, and the divergence was visible in the rendered
`whats-new.png` frame: one sentence of release-note copy using a different glyph
from every location line in the Guide behind it.

Copy is the rare case where a static check earns its place. There is nothing to
execute and no rendered pixel that distinguishes the two glyphs at a glance, so
"a reviewer will notice" is the only thing that was guarding this, and a
reviewer did not notice for four releases.

Scoped deliberately, in three ways, because a check that fires on the wrong
thing gets weakened until it fires on nothing:

  1. **String literals only.** `→` is the codebase's arrow for "maps to" and
     "then" in comments — `bundleID → deviceUID`, `armed→ramping`, `Light→System`
     — and roughly a dozen comments name a Settings path in passing. None of that
     reaches a user. The scanner below strips comments rather than grepping.

  2. **`Settings →` only, not every `→` in a literal.** About twenty `logger`
     strings use `→` for a state transition. Logs are not interface copy.

  3. **Shipping files only.** A file whose first line is `#if MELO_DEV` is not
     in a release build at all, and `SnapshotScenes.swift` uses `→` in a `note:`
     that only ever reaches an agent reading a provenance band.

The last assertion is an anti-vacuity guard. Without it this file passes
perfectly on a tree where every interface path has been deleted, which is the
failure mode of every check written only as a prohibition.
"""
from __future__ import annotations

import sys
from pathlib import Path

root = Path(__file__).resolve().parents[1]
sources = root / "Sources/Melo"
failures: list[str] = []

WRONG = "Settings →"
RIGHT = "Settings ›"


def string_literals(text: str) -> list[tuple[int, str]]:
    """Every Swift string literal in `text`, as (line number, contents).

    A scanner rather than a regex because the thing being excluded — comments —
    is exactly what a regex over lines cannot distinguish from code, and getting
    that backwards is how this check would end up reporting a dozen comments and
    being switched off.
    """
    out: list[tuple[int, str]] = []
    i, line, n = 0, 1, len(text)
    while i < n:
        ch = text[i]
        if ch == "\n":
            line += 1
            i += 1
        elif text.startswith("//", i):
            while i < n and text[i] != "\n":
                i += 1
        elif text.startswith("/*", i):
            depth, i = 1, i + 2  # Swift block comments nest.
            while i < n and depth:
                if text.startswith("/*", i):
                    depth, i = depth + 1, i + 2
                elif text.startswith("*/", i):
                    depth, i = depth - 1, i + 2
                else:
                    if text[i] == "\n":
                        line += 1
                    i += 1
        elif text.startswith('"""', i):
            start, i = line, i + 3
            buf: list[str] = []
            while i < n and not text.startswith('"""', i):
                if text[i] == "\n":
                    line += 1
                buf.append(text[i])
                i += 1
            i += 3
            out.append((start, "".join(buf)))
        elif ch == '"':
            start, i = line, i + 1
            buf = []
            while i < n and text[i] != '"':
                if text[i] == "\\":
                    buf.append(text[i:i + 2])
                    i += 2
                    continue
                if text[i] == "\n":  # Unterminated; don't run away with the file.
                    break
                buf.append(text[i])
                i += 1
            i += 1
            out.append((start, "".join(buf)))
        else:
            i += 1
    return out


def is_dev_only(path: Path, text: str) -> bool:
    return text.lstrip().startswith("#if MELO_DEV")


swift = sorted(sources.rglob("*.swift"))
if len(swift) < 100:
    failures.append(f"only {len(swift)} Swift files found under {sources} — the scan did not run")

scanned = 0
for path in swift:
    text = path.read_text(errors="replace")
    if is_dev_only(path, text):
        continue
    scanned += 1
    for line_number, literal in string_literals(text):
        if WRONG in literal:
            failures.append(
                f"{path.relative_to(root)}:{line_number}: user-facing string writes "
                f"{WRONG!r}. Melo prints an interface path as {RIGHT!r} everywhere else, "
                "and the two forms sitting in one window is what this exists to stop."
            )

# Anti-vacuity: the prohibition above is satisfied by a tree with no interface
# paths in it at all. These two files are where Melo names its own paths — the
# Guide's location lines and the release notes' prose — so if neither writes one,
# the convention did not become consistent, it disappeared.
for relative in ("Sources/Melo/Models/SettingsGuide.swift", "Sources/Melo/Models/MeloReleaseNotes.swift"):
    path = root / relative
    if not path.is_file():
        failures.append(f"missing {relative}")
        continue
    if not any(RIGHT in literal for _, literal in string_literals(path.read_text(errors="replace"))):
        failures.append(
            f"{relative}: no string writes {RIGHT!r}. The arrow check above now proves nothing, "
            "because there is no interface path left for it to be wrong about."
        )

if failures:
    print("Copy consistency verification failed:")
    for failure in failures:
        print(f"  - {failure}")
    sys.exit(1)

print(f"Copy consistency verification passed ({scanned} shipping Swift files scanned).")
