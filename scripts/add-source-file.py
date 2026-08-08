#!/usr/bin/env python3
"""Add Swift files to Melo.xcodeproj's single target.

The project lists every source file explicitly, so a new .swift file compiles
under SwiftPM but is silently absent from the Xcode build that actually ships —
it fails as "cannot find X in scope" rather than as a missing file, which reads
like a code error and sends you looking in the wrong place.

Usage:  scripts/add-source-file.py Sources/Melo/Foo/Bar.swift [...]

Idempotent: a path already in the project is reported and left alone.
"""

import re
import sys
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PROJECT = ROOT / "Melo.xcodeproj/project.pbxproj"


def oid(seen):
    """24 uppercase hex chars, the shape Xcode uses for object ids."""
    while True:
        candidate = uuid.uuid4().hex[:24].upper()
        if candidate not in seen:
            seen.add(candidate)
            return candidate


def main(paths):
    if not paths:
        print(__doc__)
        return 2

    text = PROJECT.read_text()
    seen = set(re.findall(r"\b[0-9A-F]{24}\b", text))
    added = []

    for raw in paths:
        rel = Path(raw)
        if rel.is_absolute():
            rel = rel.relative_to(ROOT)
        rel = rel.as_posix()

        if not (ROOT / rel).exists():
            print(f"missing on disk: {rel}", file=sys.stderr)
            return 1
        if f"path = {rel};" in text:
            print(f"already in project: {rel}")
            continue

        name = Path(rel).name
        file_ref = oid(seen)
        build_ref = oid(seen)

        # 1. PBXBuildFile
        text = text.replace(
            "/* End PBXBuildFile section */",
            f"\t\t{build_ref} /* {name} in Sources */ = {{isa = PBXBuildFile; "
            f"fileRef = {file_ref} /* {name} */; }};\n"
            "/* End PBXBuildFile section */",
            1,
        )
        # 2. PBXFileReference
        text = text.replace(
            "/* End PBXFileReference section */",
            f"\t\t{file_ref} /* {name} */ = {{isa = PBXFileReference; "
            f"lastKnownFileType = sourcecode.swift; path = {rel}; "
            "sourceTree = SOURCE_ROOT; };\n"
            "/* End PBXFileReference section */",
            1,
        )
        # 3. Group membership — placed beside a sibling from the same directory
        #    so the navigator keeps matching the folder layout.
        parent = Path(rel).parent.as_posix()
        sibling = None
        for m in re.finditer(
            r"([0-9A-F]{24}) /\* ([^*]+?) \*/ = \{isa = PBXFileReference; "
            r"lastKnownFileType = sourcecode\.swift; path = ([^;]+); ",
            text,
        ):
            if Path(m.group(3)).parent.as_posix() == parent and m.group(1) != file_ref:
                sibling = (m.group(1), m.group(2))
                break

        if sibling:
            anchor = f"\t\t\t{sibling[0]} /* {sibling[1]} */,\n"
            text = text.replace(
                anchor, anchor + f"\t\t\t{file_ref} /* {name} */,\n", 1
            )
        else:
            print(
                f"no sibling group entry for {rel}; add it to a group manually",
                file=sys.stderr,
            )
            return 1

        # 4. Sources build phase
        sources = re.search(
            r"(isa = PBXSourcesBuildPhase;.*?files = \(\n)", text, re.S
        )
        if not sources:
            print("no PBXSourcesBuildPhase found", file=sys.stderr)
            return 1
        text = (
            text[: sources.end(1)]
            + f"\t\t\t{build_ref} /* {name} in Sources */,\n"
            + text[sources.end(1) :]
        )

        added.append(rel)

    PROJECT.write_text(text)
    for rel in added:
        print(f"added: {rel}")
    if not added:
        print("nothing to do")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
