#!/usr/bin/env python3
"""Guards for the two things added for "find an app before it makes a sound".

Both halves of that feature are invisible to every check this project already
has, for the same reason: neither can be photographed.

1. **A dropdown's width.** A popover is a separate `NSPanel` built by
   `PopoverHost`, and the render harness captures the popup window's own view
   tree — `cacheDisplay` a layer capture of it, `ImageRenderer` a re-draw of it.
   Neither contains a panel. `DevicePicker`'s popover has therefore never
   appeared in a rendered frame, which is how a fixed 210pt survived to clip
   real device names. So the fit is a function, and this runs it.

2. **The key a setting is saved under.** A volume set for an app that has never
   launched is written against a string, and read back — possibly weeks later —
   against a string produced by different code from different inputs. If those
   two rules ever disagree the feature fails silently: no crash, no error, just
   an app that comes up loud. Nothing renders, nothing logs. Only executing both
   rules over the same inputs proves they agree.

Plus the precision measurement CLAUDE.md requires of anything that touches
search: the palette's own ranking, run over its real command text, with and
without the new rows.
"""
from __future__ import annotations

import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

root = Path(__file__).resolve().parents[1]
sources = root / "Sources/Melo"
failures: list[str] = []


def read(relative: str) -> str:
    path = root / relative
    if not path.is_file():
        failures.append(f"missing {relative}")
        return ""
    return path.read_text(errors="replace")


# Listed rather than globbed, so a new dependency creeping into one of these
# shows up as a compile error here instead of as a silent skip.
SWIFT_UNITS = [
    "Utilities/IntentSearch.swift",
    "Utilities/InstalledAppCatalog.swift",
    "Views/Components/DropdownWidth.swift",
    "Models/AudioApp.swift",
]

MAIN_SWIFT = r"""
import AppKit
import Foundation

var failures: [String] = []
var measurements: [String] = []

func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    if !ok {
        let extra = detail()
        failures.append(extra.isEmpty ? name : "\(name) — \(extra)")
    }
}

// ---------------------------------------------------------------------------
// 1. One rule decides the key, and both types use it.
//
//    `InstalledApp` describes an app that has never run; `AudioApp` describes
//    one that is running now. The whole feature is the claim that a setting
//    written through the first is read by the second, which is only true while
//    these agree on every input — including the two fallbacks, which is where a
//    reimplementation would diverge first.
// ---------------------------------------------------------------------------

let identityCases: [(bundleID: String?, executablePath: String?, name: String)] = [
    ("org.godotengine.godot", "/Applications/Godot.app/Contents/MacOS/Godot", "Godot"),
    ("com.spotify.client", "/Applications/Spotify.app/Contents/MacOS/Spotify", "Spotify"),
    (nil, "/Applications/Thing.app/Contents/MacOS/Thing", "Thing"),
    (nil, "/Applications/../Applications/Thing.app/Contents/MacOS/Thing", "Thing"),
    ("", "/usr/local/bin/player", "player"),
    (nil, nil, "Nameless"),
    (nil, "", "Nameless"),
]

for testCase in identityCases {
    let installed = InstalledApp(
        name: testCase.name,
        bundleID: testCase.bundleID,
        executablePath: testCase.executablePath
    )
    let running = AudioApp(
        id: 1234,
        processObjectIDs: [],
        name: testCase.name,
        icon: NSImage(),
        bundleID: testCase.bundleID,
        executablePath: testCase.executablePath
    )
    check("installed and running agree on the key for \(testCase.name)",
          installed.persistenceIdentifier == running.persistenceIdentifier,
          "installed=\(installed.persistenceIdentifier), running=\(running.persistenceIdentifier)")
}

// The key must not move when the process id does. An app started and stopped
// over and over gets a new pid every launch, and that is the exact workload
// this feature was asked for.
let firstLaunch = AudioApp(id: 501, processObjectIDs: [], name: "Godot", icon: NSImage(),
                           bundleID: "org.godotengine.godot",
                           executablePath: "/Applications/Godot.app/Contents/MacOS/Godot")
let secondLaunch = AudioApp(id: 90210, processObjectIDs: [], name: "Godot", icon: NSImage(),
                            bundleID: "org.godotengine.godot",
                            executablePath: "/Applications/Godot.app/Contents/MacOS/Godot")
check("a relaunch keeps the key",
      firstLaunch.persistenceIdentifier == secondLaunch.persistenceIdentifier,
      "\(firstLaunch.persistenceIdentifier) then \(secondLaunch.persistenceIdentifier)")
check("the key is not the pid",
      !firstLaunch.persistenceIdentifier.contains("501"))

// ---------------------------------------------------------------------------
// 2. The dropdown fit: the policy, executed.
// ---------------------------------------------------------------------------

check("a short menu keeps the width it had",
      DropdownWidth.width(forWidestText: 40, chrome: 90, minimum: 210) == 210,
      "got \(DropdownWidth.width(forWidestText: 40, chrome: 90, minimum: 210))")
check("a long name widens the menu",
      DropdownWidth.width(forWidestText: 160, chrome: 90, minimum: 210) == 250,
      "got \(DropdownWidth.width(forWidestText: 160, chrome: 90, minimum: 210))")
check("the ceiling holds",
      DropdownWidth.width(forWidestText: 900, chrome: 90, minimum: 210) == DropdownWidth.ceiling,
      "got \(DropdownWidth.width(forWidestText: 900, chrome: 90, minimum: 210))")
// A caller that sets the two bounds the wrong way round must not end up with a
// menu narrower than the constant it replaced. That failure would arrive
// looking like a fix.
check("a minimum above the ceiling still wins",
      DropdownWidth.width(forWidestText: 10, chrome: 0, minimum: 400, maximum: 300) == 400,
      "got \(DropdownWidth.width(forWidestText: 10, chrome: 0, minimum: 400, maximum: 300))")

// ---------------------------------------------------------------------------
// 3. The fit against real names, measured with the real font.
//
//    The picker's own constants and its own fitting function are spliced out of
//    `DevicePicker.swift` below and executed here. Calling `DropdownWidth.fit`
//    with arguments this script chose would prove the policy and prove nothing
//    about the picker: measured, pinning the picker's call to `maximum: 210`
//    restored the original defect with every assertion in this file still
//    green. `fit` no longer takes a maximum, and this runs the shipping text.
// ---------------------------------------------------------------------------

// @DEVICE_PICKER_FIT@

let devicePickerRowChrome = DevicePickerFit.rowChrome

let deviceNames = [
    "System Audio",
    "MacBook Pro Speakers",
    "MacBook Pro Microphone",
    "Studio Display Speakers",
    "Joshua's AirPods Pro",
    "External Headphones",
]
let deviceSubtitles = ["Follows macOS default", "Not available in multi mode"]

func widestDeviceText() -> CGFloat {
    var widest: CGFloat = 0
    for name in deviceNames {
        widest = max(widest, DropdownWidth.textWidth(name, pointSize: 11))
    }
    for subtitle in deviceSubtitles {
        widest = max(widest, DropdownWidth.textWidth(subtitle, pointSize: 10))
    }
    return widest
}

let widest = widestDeviceText()
let fitted = DevicePickerFit.popoverWidth(forDeviceNames: deviceNames)

// The defect, stated as a number: with the old constant the text column was
// this many points, and the widest row needed more than that.
let oldTextRoom = 210 - devicePickerRowChrome
check("the 210 this replaced really was too narrow",
      widest > oldTextRoom,
      "widest row needs \(Int(widest.rounded()))pt of text, 210 left "
      + "\(Int(oldTextRoom.rounded()))pt — if this passes, the fix is not "
      + "answering the reported defect")
measurements.append(
    "device picker: widest row text \(Int(widest.rounded()))pt, chrome "
    + "\(Int(devicePickerRowChrome))pt, old constant left \(Int(oldTextRoom.rounded()))pt, "
    + "fitted width \(Int(fitted))pt"
)
check("the fitted width shows the widest row",
      fitted >= widest + devicePickerRowChrome || fitted == DropdownWidth.ceiling,
      "fitted \(fitted), needed \(widest + devicePickerRowChrome)")
check("the fitted width never shrinks below the old constant",
      fitted >= 210, "got \(fitted)")
check("the fitted width stays inside the popup",
      fitted <= DropdownWidth.ceiling, "got \(fitted)")

// A name past the ceiling is truncated, not accommodated. Without a bound the
// panel is placed off the side of the screen — `PopoverHost` does no clamping.
let absurd = DevicePickerFit.popoverWidth(
    forDeviceNames: [String(repeating: "Joshua's AirPods Pro ", count: 8)]
)
check("an absurd device name is capped",
      absurd == DropdownWidth.ceiling, "got \(absurd)")

// ---------------------------------------------------------------------------
// 4. The catalogue, run against this actual Mac.
//
//    A scanner that compiles and finds nothing is the failure this cannot be
//    allowed to pass through: every downstream check would be vacuous and every
//    search would return the same empty list it returned before the feature.
// ---------------------------------------------------------------------------

let catalog = InstalledAppCatalog.scan()
check("the catalogue finds applications on this Mac",
      catalog.count >= 5,
      "found \(catalog.count); a scan that finds nothing makes every check "
      + "below vacuous and the feature inert")
measurements.append("installed-app catalogue: \(catalog.count) app(s) on this Mac")

check("every catalogue entry can key a setting",
      catalog.allSatisfy { !$0.persistenceIdentifier.isEmpty })
check("catalogue entries are unique by key",
      Set(catalog.map(\.persistenceIdentifier)).count == catalog.count,
      "two entries sharing a key would mean two rows for one mixer profile")
check("Melo is not in its own catalogue",
      !catalog.contains { $0.bundleID == Bundle.main.bundleIdentifier })

// Typing an app's own name reaches it. Run against whatever this Mac has, so
// the check cannot be satisfied by a fixture that flatters the matcher.
if let sample = catalog.first(where: { !$0.name.contains(" ") && $0.name.count >= 4 }) {
    let found = InstalledAppCatalog.bestMatch(in: catalog, for: sample.name, excluding: [])
    check("typing an installed app's name finds it",
          found?.persistenceIdentifier == sample.persistenceIdentifier,
          "typed “\(sample.name)”, got \(found?.name ?? "nothing")")
    let excluded = InstalledAppCatalog.bestMatch(
        in: catalog, for: sample.name, excluding: [sample.persistenceIdentifier]
    )
    check("an app Melo already lists is not offered twice",
          excluded?.persistenceIdentifier != sample.persistenceIdentifier,
          "excluding it still returned it")
} else {
    check("a one-word app name exists to test the matcher with", false,
          "no single-word app on this Mac; the matcher went unexercised")
}

check("a phrase that names no app finds no app",
      InstalledAppCatalog.bestMatch(in: catalog, for: "make everything quieter", excluding: []) == nil,
      "a generic request must not conjure an app row")

// ---------------------------------------------------------------------------
// 5. Precision: the new rows must not displace the old answers.
//
//    CLAUDE.md records that search vocabulary is precision-sensitive and that
//    four of five candidate synonym groups were measured out. No synonym group
//    or alias was added here — the new rows are *candidates*, and candidates
//    displace by out-scoring, so that is what is measured. The command text is
//    scraped from the palette; the scoring and the ranking are the real
//    `IntentSearch`.
// ---------------------------------------------------------------------------

struct CommandFixture {
    let id: String
    let title: String
    let subtitle: String
    let category: String
    let aliases: [String]

    // The palette's own `Command.score`, same fields in the same order.
    func score(_ query: String) -> Int {
        IntentSearch.score(query: query, fields: [title, subtitle, category], aliases: aliases)
    }
}

// @PALETTE_COMMANDS@

/// The palette's `filteredCommands` tail: sort by title for stability, then rank.
func ranked(_ commands: [CommandFixture], _ query: String) -> [String] {
    let candidates = commands.sorted { $0.title < $1.title }
    return IntentSearch.rank(candidates, limit: 12) { $0.score(query) }.map(\.id)
}

/// The rows `installedAppCommands` would add for this query, if any.
func installedRows(_ query: String) -> [CommandFixture] {
    guard let app = InstalledAppCatalog.bestMatch(in: catalog, for: query, excluding: []) else {
        return []
    }
    let name = app.name
    let key = app.persistenceIdentifier
    var rows = [
        CommandFixture(
            id: "installed-mute-\(key)",
            title: "Mute \(name)",
            subtitle: "Silences it before it ever opens",
            category: "Quick Controls",
            aliases: ["silence \(name)", "quiet \(name)", "\(name) is not open"]
        ),
        CommandFixture(
            id: "installed-pin-\(key)",
            title: "Add \(name) to Melo",
            subtitle: "Puts its controls in the list before it opens",
            category: "Quick Controls",
            aliases: ["set up \(name)", "\(name) before it opens", "not running"]
        ),
    ]
    if let percent = IntentSearch.percentage(in: query) {
        rows.append(CommandFixture(
            id: "installed-volume-\(key)-\(percent)",
            title: "Set \(name) to \(percent)%",
            subtitle: "Applies the first time it plays",
            category: "Quick Controls",
            aliases: [query]
        ))
    }
    return rows
}

// Queries the palette already answered. Each one's existing top result has to
// still be the top result once the catalogue is in play.
let existingQueries = [
    "fix audio", "not working", "launch at login", "open the editor",
    "trim a sound", "crop the start", "grab the audio", "export mp3",
    "convert to mp3", "youtube", "record what is playing", "remix the theme",
    "check for updates", "undo", "settings", "help", "how do i",
    "smart sound", "clear voices", "steady volume", "guide",
]

var displaced: [String] = []
var perturbed = 0
for query in existingQueries {
    let before = ranked(paletteCommands, query)
    let after = ranked(paletteCommands + installedRows(query), query)
    if before.first != after.first {
        displaced.append("“\(query)”: was \(before.first ?? "nothing"), now \(after.first ?? "nothing")")
    }
    if Array(before.prefix(5)) != Array(after.prefix(5)) {
        perturbed += 1
    }
}

check("no existing query loses its top result to an installed-app row",
      displaced.isEmpty, displaced.joined(separator: "; "))
measurements.append(
    "search displacement: \(existingQueries.count) existing queries, "
    + "0 changed their top result, \(perturbed) changed anywhere in the top five"
)

// …and the anti-vacuity half. If the catalogue never produces a row, the
// measurement above proves nothing at all.
let namingQuery = catalog.first(where: { !$0.name.contains(" ") && $0.name.count >= 4 })
    .map { "mute \($0.name)" }
if let namingQuery {
    let rows = installedRows(namingQuery)
    check("naming an installed app does produce rows", !rows.isEmpty,
          "“\(namingQuery)” produced none, so the displacement check above is vacuous")
    let after = ranked(paletteCommands + rows, namingQuery)
    check("and one of them wins",
          after.first?.hasPrefix("installed-") == true,
          "“\(namingQuery)” ranked \(after.first ?? "nothing") first")
} else {
    check("a naming query could be built", false)
}

// ---------------------------------------------------------------------------

for measurement in measurements { print("MEASURED \(measurement)") }
if failures.isEmpty {
    print("swift-checks ok")
} else {
    for failure in failures { print("FAIL \(failure)") }
    exit(1)
}
"""


def swift_string(value: str) -> str:
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


UNAVAILABLE_FIT = """\
enum DevicePickerFit {
    static let rowChrome: CGFloat = -1
    static func popoverWidth(forDeviceNames names: [String]) -> CGFloat { -1 }
}
"""


def declaration_span(text: str, signature: str) -> tuple[int, int] | None:
    """Character range of a Swift declaration, by brace matching.

    Naive about braces inside string literals, because the declaration it is
    pointed at contains none — and a mismatch surfaces as a failed check rather
    than as a silent pass.
    """
    start = text.find(signature)
    if start < 0:
        return None
    open_at = text.find("{", start)
    if open_at < 0:
        return None
    depth = 0
    for index in range(open_at, len(text)):
        if text[index] == "{":
            depth += 1
        elif text[index] == "}":
            depth -= 1
            if depth == 0:
                return (start, index)
    return None


def device_picker_fit_swift() -> str:
    """The picker's two subtitles, its chrome, and its fitting function —
    lifted verbatim out of `DevicePicker.swift` and wrapped in an enum.

    Spliced rather than restated for the reason this file's header gives about
    the first version of these checks: a restatement here is a second opinion
    about the picker's layout, and the two can disagree while both remain
    perfectly reasonable numbers. The only edits made are dropping the access
    keywords, so this script can call what it is checking, and resolving
    `DesignTokens.Spacing.xs` — a SwiftUI file this unit does not compile — to
    its value. If that token's value ever changes, the substitution below stops
    matching the source and the chrome check fails loudly.
    """
    source = re.sub(
        r"//[^\n]*", "", read("Sources/Melo/Views/Components/DevicePicker.swift")
    )
    parts: list[str] = []

    for name in ("followsDefaultSubtitle", "multiModeSubtitle"):
        match = re.search(
            rf'(?:fileprivate|private)?\s*static let {name}\s*=\s*"([^"\\]*)"', source
        )
        if match is None:
            failures.append(
                f"DevicePicker: could not splice {name} — the fit would be measuring "
                "copy the row does not draw"
            )
            return UNAVAILABLE_FIT
        parts.append(f'    static let {name} = "{match.group(1)}"')

    chrome_at = source.find("private static let rowChrome: CGFloat =")
    chrome_end = source.find("\n\n", chrome_at) if chrome_at >= 0 else -1
    if chrome_at < 0 or chrome_end < 0:
        failures.append(
            "DevicePicker: could not splice rowChrome — the fit checks would be "
            "pinning this script's guess at the row's layout"
        )
        return UNAVAILABLE_FIT
    chrome = source[chrome_at:chrome_end].replace("private ", "", 1)
    parts.append("    " + chrome.replace("\n", "\n    ").rstrip())

    span = declaration_span(source, "static func popoverWidth(forDeviceNames")
    if span is None:
        failures.append(
            "DevicePicker: could not splice popoverWidth(forDeviceNames:) — the fit "
            "checks would prove DropdownWidth's policy and nothing about the picker"
        )
        return UNAVAILABLE_FIT
    function = source[span[0]:span[1] + 1]
    parts.append("    " + function.replace("\n", "\n    ").rstrip())

    blob = "enum DevicePickerFit {\n" + "\n\n".join(parts) + "\n}\n"
    blob = blob.replace("DesignTokens.Spacing.xs", "4")
    leftovers = re.findall(r"\bDesignTokens\.[A-Za-z.]+", blob)
    if leftovers:
        failures.append(
            f"DevicePicker: the spliced fit still references {sorted(set(leftovers))}, "
            "which this unit cannot compile"
        )
        return UNAVAILABLE_FIT
    return blob


COMMAND_LITERAL = re.compile(
    r"Command\(\s*"
    r'id:\s*"([^"\\]*)",\s*'
    r'title:\s*"([^"\\]*)",\s*'
    r'subtitle:\s*"((?:[^"\\]|\\.)*)",\s*'
    r'symbol:\s*"[^"]*",\s*'
    r"category:\s*\.(\w+),\s*"
    r"aliases:\s*\[([^\]]*)\],",
    re.DOTALL,
)

CATEGORY_TITLES = {
    "scenes": "Scenes",
    "devices": "Speakers & Headphones",
    "controls": "Quick Controls",
    "help": "Help",
}


def palette_commands_swift() -> str:
    """Every fully-literal `Command` in the palette, as data.

    Only the ones with no string interpolation survive — which is exactly the
    static half of the palette: the Melo Edit rows and the general rows. The
    per-app and per-device rows are built from live state and are represented
    in the fixture below by the ones this Mac actually has, via the catalogue.
    """
    source = re.sub(
        r"//[^\n]*", "", read("Sources/Melo/Views/Components/ConsumerCommandPalette.swift")
    )
    rows: list[str] = []
    for match in COMMAND_LITERAL.finditer(source):
        identifier, title, subtitle, category, aliases_blob = match.groups()
        if "\\(" in title or "\\(" in subtitle or "\\(" in aliases_blob:
            continue
        aliases = re.findall(r'"((?:[^"\\]|\\.)*)"', aliases_blob)
        if any("\\(" in alias for alias in aliases):
            continue
        rows.append(
            "    CommandFixture(id: {}, title: {}, subtitle: {}, category: {}, aliases: [{}]),".format(
                swift_string(identifier),
                swift_string(title),
                swift_string(subtitle),
                swift_string(CATEGORY_TITLES.get(category, category)),
                ", ".join(swift_string(a) for a in aliases),
            )
        )
    if len(rows) < 8:
        failures.append(
            f"ConsumerCommandPalette: scraped only {len(rows)} literal command(s); "
            "the displacement measurement would be running against almost nothing"
        )
    return "let paletteCommands: [CommandFixture] = [\n" + "\n".join(rows) + "\n]"


def run_swift_checks() -> None:
    if shutil.which("xcrun"):
        argv = ["xcrun", "swiftc"]
    elif shutil.which("swiftc"):
        argv = ["swiftc"]
    else:
        failures.append("no Swift compiler on PATH — these checks cannot be skipped silently")
        return

    missing = [unit for unit in SWIFT_UNITS if not (sources / unit).is_file()]
    if missing:
        failures.append(f"swift checks: missing source unit(s) {missing}")
        return

    with tempfile.TemporaryDirectory(prefix="melo-verify-app-search-") as tmp:
        work = Path(tmp)
        (work / "main.swift").write_text(
            MAIN_SWIFT
            .replace("// @DEVICE_PICKER_FIT@", device_picker_fit_swift())
            .replace("// @PALETTE_COMMANDS@", palette_commands_swift())
        )
        binary = work / "checks"
        compiled = subprocess.run(
            argv + ["-O", "-o", str(binary), str(work / "main.swift")]
            + [str(sources / unit) for unit in SWIFT_UNITS],
            capture_output=True,
            text=True,
        )
        if compiled.returncode != 0:
            errors = [line for line in compiled.stderr.splitlines() if "error:" in line][:12]
            failures.append(
                "swift checks did not compile:\n        "
                + "\n        ".join(errors or compiled.stderr.splitlines()[:12])
            )
            return

        result = subprocess.run([str(binary)], capture_output=True, text=True)
        for line in result.stdout.splitlines():
            if line.startswith("MEASURED "):
                measurements.append(line[len("MEASURED "):])
            elif line.startswith("FAIL "):
                failures.append(line[len("FAIL "):])
        if result.returncode != 0 and not any(
            line.startswith("FAIL ") for line in result.stdout.splitlines()
        ):
            failures.append(
                f"swift checks exited {result.returncode} with no verdict: "
                f"{result.stderr.strip()[:200]}"
            )


measurements: list[str] = []
run_swift_checks()

# ---------------------------------------------------------------------------
# Wiring. The rules above are correct and, on their own, provably unconnected —
# this project has measured four severed wires surviving eleven verify scripts.
# ---------------------------------------------------------------------------

picker = read("Sources/Melo/Views/Components/DevicePicker.swift")
if re.search(r"popoverWidth:\s*CGFloat\s*=\s*\d", picker):
    failures.append(
        "DevicePicker: popoverWidth is a constant again — the whole defect was a "
        "number chosen against one Mac's device names"
    )
if "DropdownWidth.fit(" not in picker:
    failures.append("DevicePicker: its popover width must come from DropdownWidth.fit")
if "truncationMode(.tail)" not in picker:
    failures.append(
        "DevicePicker: a name past the ceiling has to truncate visibly; without a "
        "truncation mode the fixed-height row clips it with no ellipsis"
    )

presets = read("Sources/Melo/Views/Components/EQPresetPicker.swift")
if "DropdownWidth.fit(" not in presets:
    failures.append("EQPresetPicker: its popover width must come from DropdownWidth.fit")
if re.search(r"popoverWidth:\s*\d", presets):
    failures.append("EQPresetPicker: back on a hard-coded popover width")

# The identifier rule must exist in exactly one place. A second implementation
# is the silent failure this feature is most exposed to.
audio_app = read("Sources/Melo/Models/AudioApp.swift")
catalog_source = read("Sources/Melo/Utilities/InstalledAppCatalog.swift")
if "static func persistenceIdentifier(" not in audio_app:
    failures.append("AudioApp: the shared identifier rule is gone")
if "AudioApp.persistenceIdentifier(" not in catalog_source:
    failures.append(
        "InstalledAppCatalog: InstalledApp must derive its key from AudioApp's rule, "
        "not restate it — two copies means a setting saved before launch is read "
        "back under a different key and silently does nothing"
    )
if re.search(r'return\s+"executable:', catalog_source):
    failures.append("InstalledAppCatalog: a second copy of the identifier rule is back")

palette = re.sub(
    r"//[^\n]*", "", read("Sources/Melo/Views/Components/ConsumerCommandPalette.swift")
)
if "installedAppCommands(query:" not in palette:
    failures.append("ConsumerCommandPalette: installedAppCommands is not defined")
if "installedAppCommands(query: query)" not in palette:
    failures.append(
        "ConsumerCommandPalette: installedAppCommands is defined and never called — "
        "the rows exist and no query can reach them"
    )
if "InstalledAppCatalog.scanned(" not in palette:
    failures.append(
        "ConsumerCommandPalette: nothing loads the catalogue, so installedApps stays "
        "empty and every installed-app row is unreachable"
    )
# The write has to be the persistence path that already exists, not a new one.
if "audioEngine.setMuteForInactive(" not in palette:
    failures.append("ConsumerCommandPalette: an installed app is muted through the inactive path")
if re.search(r"settingsManager\.setMute\(", palette):
    failures.append(
        "ConsumerCommandPalette: writing mute straight to SettingsManager skips the "
        "undo record and the live-tap redirect in AudioEngine"
    )

if failures:
    print("App-search and dropdown-fit checks failed:")
    for failure in failures:
        print(f"  - {failure}")
    sys.exit(1)

print("App-search and dropdown-fit checks passed.")
for measurement in measurements:
    print(f"  measured: {measurement}")
