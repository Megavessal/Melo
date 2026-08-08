#!/usr/bin/env python3
"""Pins Melo's bundle identifier, and executes the migration that protects it.

Melo shipped through build 299 under `dev.local.Melo`, a placeholder that was
never a domain anyone controlled. It is now `io.github.megavessal.Melo`, which is
the reverse-DNS form of `megavessal.github.io` — the host the Sparkle appcast is
already served from, and therefore the one domain this project demonstrably owns.

Two failures this exists to catch.

**The identifier drifting back, or drifting apart.** Forty occurrences across
thirty-four files had to change at once, and three of them decide the app's
actual identity: `CFBundleIdentifier`, `CFBundleURLName`, and
`PRODUCT_BUNDLE_IDENTIFIER` in both build configurations. A single one left
behind, or a fourth added later by copy-paste, is a silent split — the built app
reads one domain and something else claims another. The inventory check below is
an equality rather than a ceiling, so re-introducing the old string anywhere
fails, and so does removing it from the one file whose subject it is.

**The migration coming loose.** `UserDefaults` is keyed by bundle identifier and
by nothing else, so the rename orphans every preference Melo has ever written:
Sparkle's check settings and skipped version, the deferred install-location
prompt, and the saved audio-unit profiles. `LegacyDefaultsMigration` copies them
across on first launch. A check that the type merely *exists* would survive the
call site being deleted, which is the pattern this project's anchor names as
dead — so this compiles the real source file and runs it against throwaway
preference domains, asserting what it copies, what it refuses to overwrite, and
that a second run does nothing at all.
"""
from __future__ import annotations

import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import uuid
from pathlib import Path

root = Path(__file__).resolve().parents[1]
failures: list[str] = []

BUNDLE_ID = "io.github.megavessal.Melo"
LEGACY_ID = "dev.local.Melo"

# ---------------------------------------------------------------------------
# Inventory: who may name the old identifier at all.
# ---------------------------------------------------------------------------
#
# Exactly one file, and only because the old domain is the thing it reads from.
# Everything else that named it — thirty-three files of logger subsystems,
# notification names, a dispatch queue label, two build configurations, the
# Info.plist and two scripts — was swept. A file reappearing here is a
# regression; the file disappearing means the migration has lost the domain it
# copies out of.
#
# `Documentation/` is excluded on purpose: it holds checked-in diffs and dated
# audit reports of releases that really did ship under the old identifier, and
# rewriting a historical record to make a check pass is not a fix.
ALLOWED_LEGACY_ID_FILES = {
    "Sources/Melo/Coordination/LegacyDefaultsMigration.swift",
}

SEARCH_ROOTS = ["Sources", "Config", "scripts"]
SEARCH_FILES = ["Melo.xcodeproj/project.pbxproj"]


# This file, which has to spell the retired identifier out in order to look for
# it. Skipped by path so the exemption cannot be widened by accident.
SELF = Path(__file__).resolve()


def scan_paths():
    for name in SEARCH_ROOTS:
        for path in (root / name).rglob("*"):
            if path.is_file() and not path.name.startswith(".") and path.resolve() != SELF:
                yield path
    for name in SEARCH_FILES:
        path = root / name
        if path.is_file():
            yield path


actual_legacy = set()
for path in scan_paths():
    try:
        text = path.read_text(errors="replace")
    except (OSError, UnicodeError):
        continue
    if LEGACY_ID in text:
        actual_legacy.add(path.relative_to(root).as_posix())

if actual_legacy != ALLOWED_LEGACY_ID_FILES:
    added = sorted(actual_legacy - ALLOWED_LEGACY_ID_FILES)
    removed = sorted(ALLOWED_LEGACY_ID_FILES - actual_legacy)
    if added:
        failures.append(
            f"the retired identifier {LEGACY_ID} is back in: " + ", ".join(added)
            + f" — the shipping identifier is {BUNDLE_ID}, and a logger subsystem or "
            "notification name that disagrees with the bundle splits the app's identity"
        )
    if removed:
        failures.append(
            f"{LEGACY_ID} is gone from " + ", ".join(removed)
            + " — that file is the one place allowed to name it, because it is the "
            "domain the migration reads from. Losing the string loses the migration"
        )

# ---------------------------------------------------------------------------
# The three places that actually decide the identity, and their agreement.
# ---------------------------------------------------------------------------

info_path = root / "Config/Info.plist"
info: dict = {}
if not info_path.is_file():
    failures.append("missing Config/Info.plist")
else:
    info = plistlib.loads(info_path.read_bytes())
    if info.get("CFBundleIdentifier") != BUNDLE_ID:
        failures.append(
            f"Config/Info.plist CFBundleIdentifier is {info.get('CFBundleIdentifier')!r}, "
            f"expected {BUNDLE_ID!r}"
        )
    url_names = [entry.get("CFBundleURLName") for entry in info.get("CFBundleURLTypes", [])]
    if url_names != [BUNDLE_ID]:
        failures.append(
            f"Config/Info.plist CFBundleURLName(s) are {url_names!r}, expected [{BUNDLE_ID!r}] — "
            "the melo:// URL type is registered under the bundle identifier and has to move with it"
        )

pbx_path = root / "Melo.xcodeproj/project.pbxproj"
if not pbx_path.is_file():
    failures.append("missing Melo.xcodeproj/project.pbxproj")
else:
    found = re.findall(r"PRODUCT_BUNDLE_IDENTIFIER\s*=\s*([^;]+);", pbx_path.read_text())
    values = [value.strip().strip('"') for value in found]
    # Two build configurations, Debug and Release. Both, or the identity depends
    # on which one someone happens to build.
    if values != [BUNDLE_ID, BUNDLE_ID]:
        failures.append(
            f"PRODUCT_BUNDLE_IDENTIFIER settings are {values!r}, expected exactly two "
            f"entries both {BUNDLE_ID!r}"
        )

# ---------------------------------------------------------------------------
# Why *this* identifier: it is the update feed's host, reversed.
# ---------------------------------------------------------------------------
#
# The identifier is not a free choice. It has to be a domain the project
# controls, and the only evidence of control is that Sparkle already serves the
# appcast from it. Tying the two together means moving the feed to a host this
# identifier does not derive from fails here rather than shipping as an
# identifier nobody owns.

feed = info.get("SUFeedURL", "")
match = re.match(r"https://([^/]+)/", feed)
if not match:
    failures.append(f"Config/Info.plist SUFeedURL is not an https URL with a host: {feed!r}")
else:
    reversed_host = ".".join(reversed(match.group(1).split(".")))
    if not BUNDLE_ID.startswith(reversed_host + "."):
        failures.append(
            f"the bundle identifier {BUNDLE_ID} does not derive from the update feed host "
            f"{match.group(1)} (reversed: {reversed_host}) — the feed host is the only "
            "evidence that this domain belongs to the project"
        )

# ---------------------------------------------------------------------------
# The migration has to be reached, and reached first.
# ---------------------------------------------------------------------------
#
# Ordering, not presence. The two update controllers read UserDefaults in their
# own initialisers; a migration that runs after them hands them the empty domain
# it exists to prevent, and every other check here still passes.

app_path = root / "Sources/Melo/FineTuneApp.swift"
if not app_path.is_file():
    failures.append("missing Sources/Melo/FineTuneApp.swift")
else:
    app_src = re.sub(r"//[^\n]*", "", app_path.read_text())
    call = app_src.find("LegacyDefaultsMigration.runIfNeeded(")
    if call < 0:
        failures.append(
            "MeloApp.init never calls LegacyDefaultsMigration.runIfNeeded — the migration "
            "compiles and is never run, so the first launch after the rename reads an empty domain"
        )
    else:
        for reader in ("SparkleUpdateController()", "DeveloperUpdateManager()"):
            at = app_src.find(reader)
            if at < 0:
                failures.append(f"MeloApp.init no longer constructs {reader}")
            elif at < call:
                failures.append(
                    f"{reader} is constructed before LegacyDefaultsMigration.runIfNeeded — it reads "
                    "UserDefaults in its initialiser, so it would see the empty post-rename domain"
                )

erase_path = root / "Sources/Melo/Coordination/AppSupportCoordinator.swift"
if not erase_path.is_file():
    failures.append("missing Sources/Melo/Coordination/AppSupportCoordinator.swift")
else:
    erase_src = erase_path.read_text()
    if "LegacyDefaultsMigration.legacyDomain" not in erase_src:
        failures.append(
            "eraseAllDataAndRestart does not delete the pre-rename preferences domain — the "
            "migration would copy the erased values straight back on the restart it performs"
        )

# ---------------------------------------------------------------------------
# Run the migration. Not "does the symbol exist" — what does it actually do.
# ---------------------------------------------------------------------------

MIGRATION_SOURCE = root / "Sources/Melo/Coordination/LegacyDefaultsMigration.swift"

DRIVER = r"""
import Foundation

// Throwaway domains, unique per run, deleted below. Real preferences are never
// read or written by this driver.
let legacyDomain = "melo.identitycheck.legacy.__RUN__"
let newDomain = "melo.identitycheck.new.__RUN__"
let emptyLegacyDomain = "melo.identitycheck.emptylegacy.__RUN__"
let freshDomain = "melo.identitycheck.fresh.__RUN__"

var problems: [String] = []
// Top-level code is main-actor isolated under Swift 6; a bare global function is
// not, and cannot touch `problems`.
@MainActor
func expect(_ condition: Bool, _ message: String) {
    if !condition { problems.append(message) }
}

let defaults = UserDefaults.standard
for domain in [legacyDomain, newDomain, emptyLegacyDomain, freshDomain] {
    defaults.removePersistentDomain(forName: domain)
}

let profileBlob = Data("{\"profiles\":[]}".utf8)
defaults.setPersistentDomain([
    "SUEnableAutomaticChecks": true,
    "SUAutomaticallyUpdate": true,
    "SUSkippedVersion": "300",
    "melo.audio-unit-profiles.v1": profileBlob,
    "installLocation.deferredForBuild": 294,
], forName: legacyDomain)
// Already answered under the new identifier. The old value is older and must lose.
defaults.setPersistentDomain(["SUSkippedVersion": "kept-by-new"], forName: newDomain)

guard let destination = UserDefaults(suiteName: newDomain) else {
    print("FAIL: could not open suite \(newDomain)")
    exit(1)
}

let first = LegacyDefaultsMigration.runIfNeeded(
    into: destination,
    destinationDomain: newDomain,
    legacyDomain: legacyDomain,
    logger: nil
)

guard case .copied(let copied) = first else {
    print("FAIL: first run returned \(first), expected .copied")
    exit(1)
}
expect(
    copied == ["SUAutomaticallyUpdate", "SUEnableAutomaticChecks",
               "installLocation.deferredForBuild", "melo.audio-unit-profiles.v1"],
    "copied the wrong set of keys: \(copied)"
)

let afterFirst = defaults.persistentDomain(forName: newDomain) ?? [:]
expect(afterFirst["SUEnableAutomaticChecks"] as? Bool == true,
       "SUEnableAutomaticChecks did not arrive in the new domain")
expect(afterFirst["SUAutomaticallyUpdate"] as? Bool == true,
       "SUAutomaticallyUpdate did not arrive in the new domain")
expect(afterFirst["melo.audio-unit-profiles.v1"] as? Data == profileBlob,
       "the audio-unit profile blob did not survive the copy intact")
expect(afterFirst["installLocation.deferredForBuild"] as? Int == 294,
       "installLocation.deferredForBuild did not arrive in the new domain")
expect(afterFirst["SUSkippedVersion"] as? String == "kept-by-new",
       "a key the new domain already held was overwritten by the older one")
expect(afterFirst[LegacyDefaultsMigration.completionKey] as? Bool == true,
       "the completion flag was not written, so this would run again every launch")

// Copy, not move.
let legacyAfter = defaults.persistentDomain(forName: legacyDomain) ?? [:]
expect(legacyAfter.count == 5, "the legacy domain was modified: \(legacyAfter.keys.sorted())")

// Idempotency. The user turns automatic checking off after upgrading; a second
// run must not hand them the old answer back.
destination.set(false, forKey: "SUEnableAutomaticChecks")
let second = LegacyDefaultsMigration.runIfNeeded(
    into: destination,
    destinationDomain: newDomain,
    legacyDomain: legacyDomain,
    logger: nil
)
expect(second == .alreadyDone, "second run returned \(second), expected .alreadyDone")
expect((defaults.persistentDomain(forName: newDomain) ?? [:])["SUEnableAutomaticChecks"] as? Bool == false,
       "a second run restored a value the user had changed — the migration is not idempotent")

// Fresh install: no legacy domain at all. Still records that it ran, so the
// lookup is not repeated on every launch forever.
guard let fresh = UserDefaults(suiteName: freshDomain) else {
    print("FAIL: could not open suite \(freshDomain)")
    exit(1)
}
let third = LegacyDefaultsMigration.runIfNeeded(
    into: fresh,
    destinationDomain: freshDomain,
    legacyDomain: emptyLegacyDomain,
    logger: nil
)
expect(third == .nothingToCopy, "fresh-install run returned \(third), expected .nothingToCopy")
expect((defaults.persistentDomain(forName: freshDomain) ?? [:])[LegacyDefaultsMigration.completionKey] as? Bool == true,
       "a fresh install did not record that the migration ran")

for domain in [legacyDomain, newDomain, emptyLegacyDomain, freshDomain] {
    defaults.removePersistentDomain(forName: domain)
}

if problems.isEmpty {
    print("OK")
} else {
    for problem in problems { print("FAIL: \(problem)") }
    exit(1)
}
"""


def run_migration_behaviour() -> None:
    if not MIGRATION_SOURCE.is_file():
        failures.append(f"missing {MIGRATION_SOURCE.relative_to(root).as_posix()}")
        return

    swiftc = shutil.which("swiftc")
    if swiftc:
        compile_cmd = [swiftc]
    elif shutil.which("xcrun"):
        compile_cmd = ["xcrun", "swiftc"]
    else:
        failures.append(
            "no Swift compiler, so the migration's behaviour was not executed — this check "
            "must not pass without running it"
        )
        return

    run_id = uuid.uuid4().hex[:12]
    with tempfile.TemporaryDirectory(prefix="melo-identity-") as tmp:
        tmpdir = Path(tmp)
        (tmpdir / "main.swift").write_text(DRIVER.replace("__RUN__", run_id))
        binary = tmpdir / "identitycheck"
        compiled = subprocess.run(
            compile_cmd + [
                "-Onone", "-swift-version", "6",
                str(MIGRATION_SOURCE), str(tmpdir / "main.swift"),
                "-o", str(binary),
            ],
            capture_output=True, text=True,
        )
        if compiled.returncode != 0:
            failures.append(
                "LegacyDefaultsMigration.swift did not compile standalone:\n"
                + "\n".join(compiled.stderr.strip().splitlines()[-12:])
            )
            return
        result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=120)
        # The driver empties these domains, and `defaults delete` empties them
        # again if it crashed first — but neither removes the plist file, so a
        # 42-byte husk is left in ~/Library/Preferences per run. This script runs
        # on every build; a few hundred of those is litter in the user's home.
        for suffix in ("legacy", "new", "emptylegacy", "fresh"):
            domain = f"melo.identitycheck.{suffix}.{run_id}"
            subprocess.run(["defaults", "delete", domain], capture_output=True)
            husk = Path.home() / "Library/Preferences" / f"{domain}.plist"
            # Guarded by the run id, which this process generated: nothing else
            # can own this path.
            if husk.is_file() and husk.stat().st_size < 4096:
                husk.unlink(missing_ok=True)
        if result.returncode != 0 or "OK" not in result.stdout:
            detail = (result.stdout + result.stderr).strip() or "(no output)"
            failures.append("the defaults migration misbehaved when run:\n" + detail)


run_migration_behaviour()

# ---------------------------------------------------------------------------

if failures:
    print("Bundle identity verification failed:")
    for failure in failures:
        print(f"  - {failure}")
    sys.exit(1)

print("Bundle identity verification passed.")
