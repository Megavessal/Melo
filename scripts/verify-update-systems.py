#!/usr/bin/env python3
from pathlib import Path
import plistlib
import sys

root = Path(__file__).resolve().parents[1]
failures: list[str] = []

def require(relative: str, *needles: str) -> str:
    path = root / relative
    if not path.is_file():
        failures.append(f"missing {relative}")
        return ""
    text = path.read_text(errors="replace")
    for needle in needles:
        if needle not in text:
            failures.append(f"{relative}: missing {needle!r}")
    return text

require("Sources/Melo/Updates/SparkleUpdateController.swift",
        "SPUStandardUpdaterController", "startUpdater", "checkForUpdates",
        "automaticallyChecksForUpdates", "automaticallyDownloadsUpdates")
require("Sources/Melo/Updates/DeveloperUpdateManifest.swift",
        "schemaVersion", "packageType", "minimumMacOS", "sourceSubdirectory")
developer = require("Sources/Melo/Updates/DeveloperUpdateManager.swift",
        "chooseUpdateFile", "chooseFolderToCheck",
        "checkRememberedFolder", "scanFolder", "buildAndInstallReadyUpdate",
        # Folder scanning must not extract whole archives, and a superseded task
        # must not be able to overwrite a newer operation's status.
        "peekManifest", "generation")
require("Sources/Melo/Updates/UpdateFolderBookmark.swift", "withSecurityScope")
require("Sources/Melo/Updates/UpdatePackageValidator.swift",
        "validateArchivePaths", "bundle identifier", "codesign", "notNewer",
        "peekManifest")
require("Sources/Melo/Updates/UpdateBuildCoordinator.swift",
        "Build Melo.command", "separate process", "--dev")
install = require("Sources/Melo/Updates/UpdateInstallationCoordinator.swift",
        "Melo.previous.app", "Melo.incoming.app", "rolling back",
        # The four reliability invariants of the swap.
        "preflightArgument", "lsregister", "EXPECTED", "aborting with nothing changed")
updates_tab = require("Sources/Melo/Views/Settings/Tabs/UpdatesTab.swift",
        "Choose Update File", "Choose Folder to Check", "#if MELO_DEV")

# Installing from a pasted URL is gone on purpose: a local folder is what makes
# the developer loop fast, while an arbitrary remote link only added a way to be
# talked into running someone else's build script.
for label, text in (("DeveloperUpdateManager.swift", developer), ("UpdatesTab.swift", updates_tab)):
    if "installFromLink" in text or "secure link" in text:
        failures.append(f"{label}: the remote-link install path is back")

# The developer-update machinery must be compiled out of shipping builds, not
# merely hidden. Source packages execute build scripts from the archive.
for relative, needle in (
    ("Sources/Melo/Updates/UpdateBuildCoordinator.swift", "#if !MELO_DEV"),
    ("Sources/Melo/Updates/DeveloperUpdateManager.swift", "#if MELO_DEV"),
):
    text = (root / relative).read_text(errors="replace")
    if needle not in text:
        failures.append(f"{relative}: developer updates are not gated behind {needle}")

# A running bundle must never be moved, and the new build must prove it launches.
if "kill -0" not in install or "exit 3" not in install:
    failures.append("UpdateInstallationCoordinator.swift: swap does not abort when the old process is still running")
if "handlePreflightAndExitIfNeeded" not in (root / "Sources/Melo/FineTuneApp.swift").read_text(errors="replace"):
    failures.append("FineTuneApp.swift: preflight handler is not installed at startup")
require("scripts/build-app.sh", "--melo-preflight", "--dev")
require("Package.swift", 'Sparkle.git', 'exact: "2.9.5"')
require("Melo.xcodeproj/project.pbxproj", 'Sparkle in Frameworks', 'version = 2.9.5')
require("scripts/build-app.sh", 'Sparkle.framework', 'Melo.local.entitlements')
require("scripts/make-developer-update.sh", 'manifest.json', 'sourceSubdirectory')

# Free update hosting: Pages serves the feed, Releases carry the archives.
require("scripts/setup-github-updates.sh", "SUFeedURL", "github.io", "/docs")
require("scripts/sparkle-setup.sh", "generate_keys", "SUPublicEDKey")
release = require("scripts/release.sh", "generate_appcast", "--download-url-prefix", "gh release create")
# A distributed build must never carry the developer-update machinery.
if "--release" not in release:
    failures.append("release.sh: publishes without forcing a --release build")
require("scripts/templates/download-page.html", "Open Anyway", "__RELEASES_URL__", "__VERSION__")
# The one-command path must create the repo and enable Pages over the API rather
# than sending the user into a browser to click through settings.
require("scripts/publish-setup.sh", "gh repo create", "repos/${SLUG}/pages", "generate_keys", "release.sh")

# Homebrew must not be a hard prerequisite: gh ships a standalone binary and many
# Macs do not have brew installed.
gh_lib = require("scripts/lib/gh.sh", "melo_ensure_gh", "cli/cli/releases")
# The tool must not live under .build-melo — build-app.sh wipes that folder at
# the start of every build, which deleted gh mid-release once already. Comments
# are stripped first, since the explanation of this rule names the folder.
gh_code = "\n".join(
    line for line in gh_lib.splitlines() if not line.lstrip().startswith("#")
)
if ".build-melo" in gh_code:
    failures.append("lib/gh.sh: installs into the folder build-app.sh wipes")
if ".tools" not in gh_code:
    failures.append("lib/gh.sh: does not install into a build-safe .tools folder")
# release.sh runs standalone for every future release, so it has to find gh
# itself rather than inheriting a PATH from publish-setup.sh.
for script in ("scripts/publish-setup.sh", "scripts/release.sh"):
    text = (root / script).read_text(errors="replace")
    if "melo_ensure_gh" not in text:
        failures.append(f"{script}: does not resolve the GitHub CLI itself")
require("Documentation/MELO-2.7-UPDATES.md", "Sparkle 2.9.5", "three sources")

with (root / "Config/Info.plist").open("rb") as file:
    info = plistlib.load(file)
if info.get("CFBundleShortVersionString") != "2.9.2": failures.append("wrong version")
if info.get("CFBundleVersion") != "297": failures.append("wrong build")
if "SUFeedURL" not in info or "SUPublicEDKey" not in info:
    failures.append("Sparkle configuration keys missing")

project = require("Melo.xcodeproj/project.pbxproj")
for source in sorted((root / "Sources/Melo").rglob("*.swift")):
    relative = str(source.relative_to(root))
    if relative not in project:
        failures.append(f"Xcode target missing {relative}")

if failures:
    print("Update-system verification failed:")
    for failure in failures:
        print(f"  - {failure}")
    sys.exit(1)
print("Update-system verification passed.")
