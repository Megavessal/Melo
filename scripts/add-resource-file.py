#!/usr/bin/env python3
"""Add or remove bundled resources in Melo.xcodeproj's single target.

The companion to `add-source-file.py`, and it exists for the same reason: the
project lists every file explicitly, so a resource dropped into `Resources/`
without a project entry is simply absent from the built app. Unlike a missing
source file, that failure is *silent* — `Bundle.main.url(forResource:)` returns
nil, the caller's `guard` takes the early return, and the feature does nothing
at all with no error anywhere. A tutorial that plays no sound looks like a bug
in the audio code.

Usage:
    scripts/add-resource-file.py Resources/Foo.m4a [...]
    scripts/add-resource-file.py --remove Resources/Old.wav [...]

Idempotent: adding a path already present reports and leaves it alone.
"""

import re
import sys
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PROJECT = ROOT / "Melo.xcodeproj/project.pbxproj"

# Xcode infers most types, but being explicit keeps the diff readable and stops
# it rewriting the entry the first time the project is opened.
FILE_TYPES = {
    ".m4a": "audio.m4a", ".wav": "audio.wav", ".aiff": "audio.aiff",
    ".caf": "file", ".mp3": "audio.mp3", ".txt": "text",
    ".md": "net.daringfireball.markdown", ".json": "text.json",
    ".png": "image.png", ".pdf": "image.pdf",
}


def oid(seen):
    while True:
        candidate = uuid.uuid4().hex[:24].upper()
        if candidate not in seen:
            seen.add(candidate)
            return candidate


def add(text, seen, rel):
    name = Path(rel).name
    if f"path = {rel};" in text:
        print(f"  already present: {rel}")
        return text
    if not (ROOT / rel).exists():
        sys.exit(f"error: {rel} does not exist on disk")

    ref, build = oid(seen), oid(seen)
    ftype = FILE_TYPES.get(Path(rel).suffix.lower(), "file")

    text = text.replace(
        "/* End PBXBuildFile section */",
        f"\t\t{build} /* {name} in Resources */ = {{isa = PBXBuildFile; "
        f"fileRef = {ref} /* {name} */; }};\n/* End PBXBuildFile section */", 1)
    text = text.replace(
        "/* End PBXFileReference section */",
        f"\t\t{ref} /* {name} */ = {{isa = PBXFileReference; "
        f"lastKnownFileType = {ftype}; path = {rel}; sourceTree = SOURCE_ROOT; }};\n"
        "/* End PBXFileReference section */", 1)

    # Into the Resources build phase, or it is never copied into the bundle.
    text = re.sub(
        r"(isa = PBXResourcesBuildPhase;[^)]*?files = \()",
        rf"\1\n\t\t\t{build} /* {name} in Resources */,",
        text, count=1, flags=re.S)

    # And into the same group the other resources live in, so it is visible in
    # Xcode's navigator rather than only in the build.
    #
    # Anchored on any of several long-lived resources rather than one filename:
    # the first version of this named a single .wav, which was deleted two
    # commits later, and a group anchor that silently misses just drops the file
    # out of the navigator while the build keeps working — the kind of failure
    # nobody notices for months.
    anchor = None
    for known in ("NOTICE.md", "LICENSE.txt", "README.md", "Assets.xcassets"):
        anchor = re.search(rf"([0-9A-F]{{24}}) /\* {re.escape(known)} \*/,", text)
        if anchor:
            break
    if anchor:
        text = text.replace(anchor.group(0), anchor.group(0) + f"\n\t\t\t{ref} /* {name} */,", 1)
    else:
        print(f"  warning: {name} added to the build but not to any group; "
              f"it will not appear in Xcode's navigator")

    print(f"  added: {rel}")
    return text


def remove(text, rel):
    name = Path(rel).name
    if f"path = {rel};" not in text:
        print(f"  not in project: {rel}")
        return text
    ref = re.search(rf"([0-9A-F]{{24}}) /\* {re.escape(name)} \*/ = \{{isa = PBXFileReference", text)
    build = re.search(rf"([0-9A-F]{{24}}) /\* {re.escape(name)} in Resources \*/ = \{{isa = PBXBuildFile", text)
    ids = [m.group(1) for m in (ref, build) if m]
    kept = [ln for ln in text.splitlines(keepends=True)
            if not any(i in ln for i in ids)]
    print(f"  removed: {rel}")
    return "".join(kept)


def main(argv):
    if not argv:
        sys.exit(__doc__)
    removing = argv[0] == "--remove"
    paths = argv[1:] if removing else argv

    text = PROJECT.read_text()
    seen = set(re.findall(r"\b[0-9A-F]{24}\b", text))
    for rel in paths:
        rel = str(Path(rel))
        text = remove(text, rel) if removing else add(text, seen, rel)
    PROJECT.write_text(text)


if __name__ == "__main__":
    main(sys.argv[1:])
