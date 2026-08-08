#!/usr/bin/env python3
# `str | None` in an annotation is evaluated at runtime before 3.10, and the
# system python3 on this machine is 3.9 — without this the whole script dies on
# import, so the one check that guards Melo's privacy promise silently stopped
# running. Deferring annotation evaluation costs nothing and restores it.
from __future__ import annotations

"""Holds the telemetry layer to the one promise that matters.

Melo taps other applications' audio. That means the app knows, at every moment,
exactly which programs a person is running — and it knows their audio devices,
which people name after themselves. None of that may ever leave the machine,
and "we were careful" is not a mechanism. This script is the mechanism.

It fails the build when:

  1. a telemetry send API accepts a free-form `String` event name,
  2. the consent default is anything but `.unasked`, or code that is not a
     control the user operated writes `.granted`,
  3. `TelemetryService` dispatches without checking consent, or starts a vendor
     SDK without checking consent,
  4. anything under Sources/Melo/Telemetry/ names an identifying accessor,
  5. a vendor SDK is referenced outside a `#if canImport(...)` block.

Like the other verify scripts here it is static analysis, not a compiler.
"""
from pathlib import Path
import re
import sys

root = Path(__file__).resolve().parents[1]
failures: list[str] = []

TELEMETRY_DIR = root / "Sources/Melo/Telemetry"
SOURCES = root / "Sources/Melo"


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


def strip_comments(src: str) -> str:
    """Comments legitimately discuss the things this script bans."""
    src = re.sub(r"/\*.*?\*/", "", src, flags=re.S)
    src = re.sub(r"//[^\n]*", "", src)
    return src


def swift_sources(base: Path) -> list[Path]:
    return sorted(base.rglob("*.swift"))


# ---------------------------------------------------------------------------
# 0. The layer exists at all.
# ---------------------------------------------------------------------------
event_src = require(
    "Sources/Melo/Telemetry/TelemetryEvent.swift",
    "enum TelemetryEvent",
    "enum TelemetryBucket",
    "var signalName: String",
)
environment_src = require(
    "Sources/Melo/Telemetry/TelemetryEnvironment.swift",
    "struct TelemetryEnvironment",
    "enum HardwareClass",
)
sink_src = require(
    "Sources/Melo/Telemetry/TelemetrySink.swift",
    "protocol TelemetrySink",
    "struct NoOpSink",
    "#if MELO_DEV",
    "struct ConsoleSink",
)
service_src = require(
    "Sources/Melo/Telemetry/TelemetryService.swift",
    "@Observable",
    "@MainActor",
    "final class TelemetryService",
    "static let shared",
)

# The environment snapshot must stay coarse. An exact OS build or a model
# identifier turns four harmless fields into a fingerprint.
if "operatingSystemVersionString" in environment_src:
    failures.append(
        "TelemetryEnvironment.swift: uses the full OS version string, which carries the build "
        "number — only major.minor may be collected"
    )
for banned in ("hw.model", "IOPlatformSerialNumber", "IOPlatformUUID", "identifierForVendor"):
    if banned in environment_src:
        failures.append(f"TelemetryEnvironment.swift: collects {banned!r}, which identifies the machine")

# ---------------------------------------------------------------------------
# 1. No free-form string event names.
# ---------------------------------------------------------------------------
# The type system is the redaction guard: a `send(_ name: String)` overload is
# how an app name eventually reaches a server, because somebody interpolates one
# into an event name and no reviewer notices the diff.
SEND_FUNC = re.compile(
    r"\bfunc\s+(send|track|record|report|signal|capture|log|emit)\b[^{]*",
    re.S,
)
for path in swift_sources(TELEMETRY_DIR):
    body = strip_comments(path.read_text(errors="replace"))
    for match in SEND_FUNC.finditer(body):
        signature = match.group(0)
        # Only the parameter list matters; a `-> String` return is harmless.
        params = signature.split("->")[0]
        if re.search(r":\s*String\b", params) or re.search(r":\s*StaticString\b", params):
            failures.append(
                f"{path.relative_to(root)}: {match.group(1)}(...) takes a free-form String — "
                "telemetry APIs must take TelemetryEvent values only"
            )

# ...and no caller anywhere may hand the service a literal, which is what a
# string-taking API would look like at the call site if one ever slipped back in.
LITERAL_SEND = re.compile(r"TelemetryService\.shared\.send\(\s*[\"\\]")
for path in swift_sources(SOURCES):
    body = strip_comments(path.read_text(errors="replace"))
    if LITERAL_SEND.search(body):
        failures.append(
            f"{path.relative_to(root)}: sends a string literal — telemetry takes TelemetryEvent values only"
        )

# The public entry point has to be the enum.
if "func send(_ event: TelemetryEvent)" not in service_src:
    failures.append("TelemetryService.swift: no `func send(_ event: TelemetryEvent)` entry point")

# ---------------------------------------------------------------------------
# 2. Consent defaults to .unasked, and only user-operated controls grant it.
# ---------------------------------------------------------------------------
settings_src = require(
    "Sources/Melo/Settings/SettingsManager.swift",
    "enum AnalyticsConsent",
    "case unasked",
    "var analyticsConsent: AnalyticsConsent = .unasked",
    "decodeIfPresent(AnalyticsConsent.self, forKey: .analyticsConsent) ?? .unasked",
)
if re.search(r"var analyticsConsent: AnalyticsConsent = \.(granted|denied)", settings_src):
    failures.append("SettingsManager.swift: analyticsConsent no longer defaults to .unasked")
if re.search(r"forKey: \.analyticsConsent\) \?\? \.(granted|denied)", settings_src):
    failures.append(
        "SettingsManager.swift: a settings file with no analytics key decodes to something "
        "other than .unasked — an absent key means the question was never asked"
    )

# `.granted` may only be written by a control the user just operated. Everything
# else — services, coordinators that run at launch, migration code — is banned
# from writing it, because a grant nobody pressed a button for is not consent.
CONSENT_GRANT_ALLOWED = {
    "Sources/Melo/Views/Onboarding/FirstRunOnboardingView.swift",  # the setup page's two buttons
    "Sources/Melo/Coordination/AnalyticsConsentPrompt.swift",      # the one-time ask's two buttons
    "Sources/Melo/Views/Settings/Tabs/GeneralTab.swift",           # the switch in Settings
}
GRANT_WRITE = re.compile(r"analyticsConsent\s*=\s*(?:AnalyticsConsent\.)?\.?granted")
for path in swift_sources(SOURCES):
    relative = str(path.relative_to(root))
    body = strip_comments(path.read_text(errors="replace"))
    if GRANT_WRITE.search(body) and relative not in CONSENT_GRANT_ALLOWED:
        failures.append(
            f"{relative}: writes analyticsConsent = .granted, but consent may only be granted "
            "by a control the user operated"
        )

# ---------------------------------------------------------------------------
# 3. Consent is checked before dispatch AND before the SDKs start.
# ---------------------------------------------------------------------------
service_body = strip_comments(service_src)


def function_body(body: str, name: str) -> str | None:
    """The braces-matched body of `func <name>`, and nothing after it.

    Brace matching rather than a fixed window: the first version of this check
    read 400 characters past the opening brace, which meant `send()` passed by
    borrowing the guard out of the *next* function down the file.
    """
    match = re.search(rf"func\s+{re.escape(name)}\s*\([^)]*\)[^{{]*\{{", body)
    if not match:
        return None
    depth = 1
    index = match.end()
    while index < len(body) and depth > 0:
        if body[index] == "{":
            depth += 1
        elif body[index] == "}":
            depth -= 1
        index += 1
    return body[match.end(): index - 1]


def guarded_function(body: str, name: str) -> bool:
    """True when `func <name>` refuses to proceed unless consent is granted."""
    inner = function_body(body, name)
    if inner is None:
        return False
    return bool(re.search(r"guard\s+consent\s*==\s*\.granted\s+else\s*\{", inner))


if not guarded_function(service_body, "send"):
    failures.append(
        "TelemetryService.swift: send(_:) does not early-return unless consent == .granted"
    )
if not guarded_function(service_body, "start"):
    failures.append(
        "TelemetryService.swift: start() does not early-return unless consent == .granted — "
        "the SDKs must never be initialised for someone who has not agreed"
    )
# Starting must be private and reachable only through the consent transition.
if "private func start()" not in service_body:
    failures.append("TelemetryService.swift: start() is not private; SDK ignition must not be callable from outside")
if "func refreshConsent()" not in service_body:
    failures.append("TelemetryService.swift: no refreshConsent() — there must be one auditable consent transition")

# ---------------------------------------------------------------------------
# 4. Nothing in the telemetry module may touch an identifying accessor.
# ---------------------------------------------------------------------------
IDENTIFYING = (
    "bundleIdentifier",
    "bundleID",
    "localizedName",
    "processName",
    "deviceName",
    "hostName",
    "userName",
    "NSFullUserName",
    "NSUserName",
    "runningApplications",
    "displayName",
    "persistenceIdentifier",
    "deviceUID",
)
if not TELEMETRY_DIR.is_dir():
    failures.append("missing Sources/Melo/Telemetry/")
for path in swift_sources(TELEMETRY_DIR):
    body = strip_comments(path.read_text(errors="replace"))
    for needle in IDENTIFYING:
        if needle in body:
            failures.append(
                f"{path.relative_to(root)}: mentions {needle!r} — app, device and machine names "
                "must never be reachable from the telemetry layer"
            )

# ---------------------------------------------------------------------------
# 5. Vendor SDKs live behind #if canImport(...) only.
# ---------------------------------------------------------------------------
# Melo ships with no new package dependencies. The tree has to build today with
# neither vendor present, and light up when they are added in Xcode — so every
# vendor symbol must sit inside a compiled-out block.
VENDOR_TOKENS = ("TelemetryDeck", "SentrySDK", "SentryOptions", "SentryEvent")


def strip_canimport_blocks(src: str) -> str:
    """Blank out every `#if canImport(...)` region, nesting included."""
    out: list[str] = []
    depth = 0          # nesting depth of #if inside a canImport region
    in_block = False
    for line in src.splitlines():
        stripped = line.strip()
        if not in_block and re.match(r"#if\s+canImport\s*\(", stripped):
            in_block = True
            depth = 1
            continue
        if in_block:
            if stripped.startswith("#if"):
                depth += 1
            elif stripped.startswith("#endif"):
                depth -= 1
                if depth == 0:
                    in_block = False
            continue
        out.append(line)
    if in_block:
        failures.append("a #if canImport(...) block is never closed")
    return "\n".join(out)


for path in swift_sources(SOURCES):
    body = strip_canimport_blocks(strip_comments(path.read_text(errors="replace")))
    for token in VENDOR_TOKENS:
        if token in body:
            failures.append(
                f"{path.relative_to(root)}: references {token} outside a #if canImport(...) block — "
                "the tree must build with no vendor packages linked"
            )

# Both vendors must actually be guarded somewhere, or the fallbacks are dead
# code that nobody would notice rotting.
if "#if canImport(TelemetryDeck)" not in service_src:
    failures.append("TelemetryService.swift: analytics SDK is not behind #if canImport(TelemetryDeck)")
if "#if canImport(Sentry)" not in service_src:
    failures.append("TelemetryService.swift: crash reporting is not behind #if canImport(Sentry)")

# No packages may have been added to satisfy the above.
package = (root / "Package.swift").read_text(errors="replace")
project = (root / "Melo.xcodeproj/project.pbxproj").read_text(errors="replace")
for token in ("TelemetryDeck", "sentry-cocoa", "Sentry.framework"):
    if token in package:
        failures.append(f"Package.swift: {token} was added; this change ships with zero new dependencies")

# ---------------------------------------------------------------------------
# 6. Consent is actually asked for, once, in the right order.
# ---------------------------------------------------------------------------
prompt_src = require(
    "Sources/Melo/Coordination/AnalyticsConsentPrompt.swift",
    "suppressedByOnboarding",
    "suppressedByWhatsNew",
    "onboardingVersionCompleted >= MeloExperienceVersion.onboarding",
    "analyticsConsent == .unasked",
    "NSWindowDelegate",
)
onboarding_src = require(
    "Sources/Melo/Views/Onboarding/FirstRunOnboardingView.swift",
    "analyticsPage",
)

# This was `"private let pageCount = 5"` — a literal that went red whenever the
# flow gained or lost a page, for no reason connected to consent, and that said
# nothing about the consent page still being *shown*. Two things are checked
# instead, both of which can actually break.
#
# `pageCount` drives the dot indicator and the Continue/finish split; the pages
# come out of one switch. A `pageCount` above the branch count leaves a dot for
# a page that does not exist and a Continue button that goes nowhere; below it,
# the last page is unreachable — which for this file means the consent question
# can be stranded behind the finish button. And `analyticsPage` has to appear
# in that switch: defining the page is not rendering it, which is precisely the
# severed-wiring failure CLAUDE.md records surviving eleven verify scripts.
def braced_block(src: str, opening: str) -> str:
    start = src.find(opening)
    if start < 0:
        return ""
    index = src.find("{", start) + 1
    depth = 1
    while index < len(src) and depth > 0:
        if src[index] == "{":
            depth += 1
        elif src[index] == "}":
            depth -= 1
        index += 1
    return src[src.find("{", start) + 1: index - 1]


page_switch = braced_block(onboarding_src, "switch page {")
declared = re.search(r"private let pageCount = (\d+)", onboarding_src)
branches = len(re.findall(r"^\s*case \d+:", page_switch, re.M)) + len(
    re.findall(r"^\s*default:", page_switch, re.M)
)
if not page_switch or not declared:
    failures.append(
        "FirstRunOnboardingView.swift: could not read the page switch and pageCount together"
    )
elif int(declared.group(1)) != branches:
    failures.append(
        f"FirstRunOnboardingView.swift: pageCount is {declared.group(1)} but the page switch "
        f"has {branches} branches — the dots and the finish button disagree with the pages"
    )
if page_switch and "analyticsPage" not in page_switch:
    failures.append(
        "FirstRunOnboardingView.swift: analyticsPage is defined but no page of the flow shows it"
    )
app_src = require(
    "Sources/Melo/FineTuneApp.swift",
    "TelemetryService.shared.configure(settings:",
    "analyticsConsent.showIfNeeded(",
)
require("Sources/Melo/Coordination/WhatsNewCoordinator.swift", "var isPresenting: Bool")

# Ordering: the consent prompt must come after What's New in the launch block.
whats_new_at = app_src.find("whatsNew.showIfNeeded(")
consent_at = app_src.find("analyticsConsent.showIfNeeded(")
if whats_new_at < 0 or consent_at < 0 or consent_at < whats_new_at:
    failures.append(
        "FineTuneApp.swift: the analytics prompt does not come after What's New in the launch block"
    )

# Closing either window without answering has to settle as .denied, or the same
# question is asked at every launch forever.
DENIAL = re.compile(r"analyticsConsent\s*=\s*\.denied|record\(\s*\.denied\s*\)")
if not DENIAL.search(strip_comments(prompt_src)):
    failures.append("AnalyticsConsentPrompt.swift: closing the window does not record a denial")
if not DENIAL.search(strip_comments(onboarding_src)):
    failures.append("FirstRunOnboardingView.swift: leaving setup unanswered does not settle as a denial")
if not DENIAL.search(strip_comments(
    require("Sources/Melo/Coordination/OnboardingWindowController.swift")
)):
    failures.append("OnboardingWindowController.swift: closing the setup window leaves consent unanswered")

# Findable in Settings search, and changeable after the fact.
require(
    "Sources/Melo/Views/Settings/Tabs/GeneralTab.swift",
    '"Share Anonymous Usage"',
    '"What Melo Collects"',
    "TelemetryService.shared.refreshConsent()",
)
require(
    "Sources/Melo/Models/SettingsGuide.swift",
    '"analytics"',
    '"analytics-collected"',
)

# Every new Swift file has to be in the Xcode target, or it builds here and
# vanishes in Xcode.
for source_path in swift_sources(SOURCES):
    relative = str(source_path.relative_to(root))
    if relative not in project:
        failures.append(f"Xcode project does not include {relative}")

# The documentation is part of the deliverable: nobody can add the packages
# without knowing where the app ID and the DSN go.
require(
    "Documentation/MELO-TELEMETRY.md",
    "Add Package Dependencies",
    "MeloAnalyticsAppID",
    "MeloCrashReportingDSN",
)

if failures:
    print("Telemetry verification failed:")
    for failure in failures:
        print(f"  - {failure}")
    sys.exit(1)
print("Telemetry verification passed.")
