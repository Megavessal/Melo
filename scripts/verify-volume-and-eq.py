#!/usr/bin/env python3
"""Guards for what a volume percent means, what AutoEQ is offered on, and EQ headroom.

Three kinds of check, in descending order of how much they prove.

1. **Executed.** `IntentSearch`, `VolumeMapping`, `EQSettings`, `EQPreset` and
   `AudioDeviceID.autoEQEligibility` are pure and self-contained, so a generated
   `main.swift` compiles the shipped source and calls the real implementations.
   The Guide's ranking is executed too, against catalog data scraped out of
   `SettingsGuide.swift`. `supportsAutoEQ()` is run against this Mac's actual
   output devices and cross-checked against the rule.

2. **Rendered.** Two claims are about pixels a user sees, and are checked by
   reading the frames `dev-verify.sh` just produced: the app row's readout says
   *200%*, and the EQ panel's headroom label appears on a boosting curve and
   only on a boosting curve. A pure function nothing proves is called is not a
   feature.

3. **Structural.** What is left is wiring — a call site, a delegation — and
   those are checked by shape, not by substring: a function body must *be* its
   delegation, and the real-time headroom parameters must carry no default
   value, because a default is what lets a caller silently stop passing them.

This project has been bitten by assertions that check a symbol exists rather
than that a behaviour holds (CLAUDE.md, "Dead patterns"), and by a set of
checks that proved three rules correct while all four of their wires were cut.
Both are the reason for the ordering above.
"""
from __future__ import annotations

import os
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


# ---------------------------------------------------------------------------
# Executable assertions: compile the real sources and run them.
# ---------------------------------------------------------------------------

# Each entry is a file the generated main.swift needs in order to link. They are
# listed explicitly rather than globbed so that a new dependency creeping into one
# of these models shows up here as a compile error rather than as a silent skip.
SWIFT_UNITS = [
    "Utilities/IntentSearch.swift",
    "Models/EQSettings.swift",
    "Models/EQPreset.swift",
    "Models/VolumeMapping.swift",
    "Models/BoostLevel.swift",
    "Audio/Monitors/DeviceVolumeProviding.swift",
    "Audio/Extensions/AudioDeviceID+Classification.swift",
    "Audio/Extensions/AudioDeviceID+Streams.swift",
    "Audio/Extensions/AudioDeviceID+Info.swift",
    "Audio/Extensions/AudioObjectID+Properties.swift",
    "Audio/Types/TransportType.swift",
    "Audio/Types/AudioScope.swift",
]

MAIN_SWIFT = r"""
import AppKit
import AudioToolbox
import Foundation

var failures: [String] = []

func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    if !ok {
        let extra = detail()
        failures.append(extra.isEmpty ? name : "\(name) — \(extra)")
    }
}

// ---------------------------------------------------------------------------
// 1. A percent is effective gain x 100, in 0...400, everywhere it is parsed.
// ---------------------------------------------------------------------------

check("maximumVolumePercent is 400",
      IntentSearch.maximumVolumePercent == 400,
      "got \(IntentSearch.maximumVolumePercent)")

let phrases: [(String, Int?)] = [
    ("Spotify to 40%", 40),
    ("mute Music", nil),
    // The reported defect: the row, the slider and the Shortcuts intent all
    // accept 200%, and this used to return nil so no command was offered at all.
    ("Music to 200%", 200),
    ("Music 200%", 200),
    ("set music to 400", 400),
    ("Music to 400%", 400),
    ("Music to 0%", 0),
    ("Music to 100%", 100),
    // Above the ceiling is not silently clamped: answering 900 with 400 answers
    // a question the user did not ask.
    ("Music to 401%", nil),
    ("Music to 900%", nil),
    ("Music to 1000%", nil),
    // The precision guard that must survive widening the range: a bare number in
    // an app's own name is not a volume.
    ("Studio 3", nil),
    ("Logic Pro 11", nil),
]
for (phrase, expected) in phrases {
    let actual = IntentSearch.percentage(in: phrase)
    check("percentage(\(phrase))", actual == expected,
          "expected \(String(describing: expected)), got \(String(describing: actual))")
}

// ---------------------------------------------------------------------------
// 2. Every percent survives the base-volume + boost decomposition unchanged.
//    This is what makes the row readout, the slider, the palette and the
//    shortcut agree: they all write through this one function.
// ---------------------------------------------------------------------------

for percent in 0...400 {
    let components = VolumeMapping.components(forEffectiveGain: Float(percent) / 100)
    let roundTrip = Int((Double(components.volume * components.boost.rawValue) * 100).rounded())
    check("percent \(percent) round-trips through volume+boost",
          roundTrip == percent, "came back as \(roundTrip)%")
    check("percent \(percent) keeps base volume in 0...1",
          components.volume >= 0 && components.volume <= 1.0001,
          "base volume \(components.volume)")
}

// ---------------------------------------------------------------------------
// 3. The EQ has headroom, and it is derived from the curve rather than declared.
// ---------------------------------------------------------------------------

check("flat EQ needs no headroom", EQSettings.flat.preampDB == 0)
check("flat EQ leaves the level alone", EQSettings.flat.preampGainLinear == 1)

let electronic = EQPreset.electronic.settings
check("electronic preset carries +7 dB of boost",
      (electronic.clampedGains.max() ?? 0) == 7,
      "peak band is \(electronic.clampedGains.max() ?? 0) dB")
check("electronic preset is pulled back by its own peak",
      electronic.preampDB == -7, "preamp is \(electronic.preampDB) dB")
check("a -7 dB preamp is about 0.447x",
      abs(electronic.preampGainLinear - 0.446684) < 0.0005,
      "gain is \(electronic.preampGainLinear)")

// A curve that only cuts already has headroom; taking more would be a level
// drop with nothing behind it.
let bassCut = EQPreset.bassCut.settings
check("a cut-only preset takes no headroom", bassCut.preampDB == 0,
      "preamp is \(bassCut.preampDB) dB")
check("a cut-only preset leaves the level alone", bassCut.preampGainLinear == 1)

// The defect in one line: no shipped preset may boost without compensating.
for preset in EQPreset.allCases {
    let settings = preset.settings
    let peak = settings.clampedGains.max() ?? 0
    check("preset \(preset.rawValue) lands at or below unity after headroom",
          peak + settings.preampDB <= 0.0001,
          "peak \(peak) dB, preamp \(settings.preampDB) dB")
}

// Headroom is a property of an *applied* curve. A disabled EQ is not in the
// signal path, so it must not quietly cost level.
var disabled = EQPreset.electronic.settings
disabled.isEnabled = false
check("a disabled EQ takes no headroom", disabled.preampDB == 0,
      "preamp is \(disabled.preampDB) dB")
check("a disabled EQ leaves the level alone", disabled.preampGainLinear == 1)

// The preamp is one constant for the whole curve, so the shape survives it.
let shaped = EQSettings(bandGains: [7, 6, 4, 0, -2, -2, 1, 3, 4, 3])
let before = zip(shaped.clampedGains.dropLast(), shaped.clampedGains.dropFirst()).map { $1 - $0 }
let after = zip(shaped.clampedGains.dropLast(), shaped.clampedGains.dropFirst())
    .map { ($1 + shaped.preampDB) - ($0 + shaped.preampDB) }
check("headroom does not change the shape of the curve", before == after)

// ---------------------------------------------------------------------------
// 4. AutoEQ is a headphone correction, so it is offered on headphones.
// ---------------------------------------------------------------------------

struct DeviceCase {
    let label: String
    let name: String
    let transport: TransportType
    let isAggregate: Bool
    let channels: Int
    let inputs: Int
    let jack: Bool
    let expected: Bool
}

let deviceCases: [DeviceCase] = [
    // Positive: things worn on a head.
    .init(label: "AirPods over Bluetooth", name: "AirPods Pro", transport: .bluetooth,
          isAggregate: false, channels: 2, inputs: 1, jack: false, expected: true),
    .init(label: "a named Bluetooth headset", name: "WH-1000XM5 Headset", transport: .bluetooth,
          isAggregate: false, channels: 2, inputs: 1, jack: false, expected: true),
    .init(label: "a USB gaming headset", name: "Arctis Nova Pro Headset", transport: .usb,
          isAggregate: false, channels: 2, inputs: 1, jack: false, expected: true),
    // The word "monitor" used to refuse these. A studio monitor is a
    // loudspeaker; "Studio Monitor" in a device name is usually headphones.
    .init(label: "monitor headphones, named as headphones",
          name: "ATH-M50x Studio Monitor Headphones",
          transport: .usb, isAggregate: false, channels: 2, inputs: 0, jack: false, expected: true),
    .init(label: "monitor headphones, NOT named as headphones",
          name: "Beyerdynamic DT 990 Studio Monitor",
          transport: .usb, isAggregate: false, channels: 2, inputs: 0, jack: false, expected: true),
    .init(label: "a bare USB DAC", name: "Schiit Modi 3+", transport: .usb,
          isAggregate: false, channels: 2, inputs: 0, jack: false, expected: true),
    .init(label: "the built-in jack with something plugged in", name: "MacBook Pro Speakers",
          transport: .builtIn, isAggregate: false, channels: 2, inputs: 0, jack: true, expected: true),
    // Negative: things that sit in a room. Each of these returned `true` before.
    .init(label: "a large interface feeding monitors", name: "Scarlett 18i20", transport: .usb,
          isAggregate: false, channels: 20, inputs: 18, jack: false, expected: false),
    // The size of interface people actually own. Two outputs, so the output
    // test walks past it; two inputs, which is what gives it away.
    .init(label: "a 2-channel interface feeding monitors", name: "Scarlett Solo USB",
          transport: .usb, isAggregate: false, channels: 2, inputs: 2, jack: false, expected: false),
    .init(label: "another 2-channel interface", name: "MOTU M2", transport: .usb,
          isAggregate: false, channels: 2, inputs: 2, jack: false, expected: false),
    .init(label: "a USB speakerphone", name: "Jabra Speak 510", transport: .usb,
          isAggregate: false, channels: 2, inputs: 2, jack: false, expected: false),
    .init(label: "a Thunderbolt interface", name: "Apogee Symphony", transport: .thunderbolt,
          isAggregate: false, channels: 2, inputs: 0, jack: false, expected: false),
    .init(label: "a soundbar", name: "Beam Soundbar", transport: .usb,
          isAggregate: false, channels: 2, inputs: 0, jack: false, expected: false),
    // A brand that only makes headphones, on a product that is a speaker. The
    // form factor in the name has to outvote the brand in the name.
    .init(label: "a branded Bluetooth speaker", name: "Beats Pill Speaker",
          transport: .bluetooth, isAggregate: false, channels: 2, inputs: 0,
          jack: false, expected: false),
    // Multichannel with nothing to capture: only the output-channel test sees
    // this one.
    .init(label: "a multichannel USB device", name: "Sound Blaster X 7.1",
          transport: .usb, isAggregate: false, channels: 8, inputs: 0,
          jack: false, expected: false),
    .init(label: "USB desktop speakers", name: "USB Audio Speakers", transport: .usb,
          isAggregate: false, channels: 2, inputs: 0, jack: false, expected: false),
    .init(label: "an aggregate device", name: "My Aggregate", transport: .usb,
          isAggregate: true, channels: 2, inputs: 0, jack: false, expected: false),
    .init(label: "a multi-output device", name: "Multi-Output Device", transport: .aggregate,
          isAggregate: false, channels: 2, inputs: 0, jack: false, expected: false),
    .init(label: "a television", name: "LG TV", transport: .hdmi,
          isAggregate: false, channels: 2, inputs: 0, jack: false, expected: false),
    .init(label: "a DisplayPort monitor", name: "Dell U2723", transport: .displayPort,
          isAggregate: false, channels: 2, inputs: 0, jack: false, expected: false),
    .init(label: "an AirPlay speaker", name: "Kitchen", transport: .airPlay,
          isAggregate: false, channels: 2, inputs: 0, jack: false, expected: false),
    .init(label: "a loopback device", name: "BlackHole 2ch", transport: .virtual,
          isAggregate: false, channels: 2, inputs: 2, jack: false, expected: false),
    .init(label: "Mac speakers with nothing plugged in", name: "MacBook Pro Speakers",
          transport: .builtIn, isAggregate: false, channels: 2, inputs: 0, jack: false, expected: false),
    // The four product names the old rule hardcoded, still excluded.
    .init(label: "HomePod mini", name: "HomePod mini", transport: .airPlay,
          isAggregate: false, channels: 2, inputs: 0, jack: false, expected: false),
    .init(label: "Apple TV", name: "Apple TV", transport: .bluetooth,
          isAggregate: false, channels: 2, inputs: 0, jack: false, expected: false),
    .init(label: "Studio Display", name: "Studio Display", transport: .usb,
          isAggregate: false, channels: 2, inputs: 0, jack: false, expected: false),
    .init(label: "Pro Display XDR", name: "Pro Display XDR", transport: .thunderbolt,
          isAggregate: false, channels: 2, inputs: 0, jack: false, expected: false),
]

// The permissive branch, pinned rather than left unexercised. Every one of
// these is a real loudspeaker that Melo still offers a headphone correction
// for, because its name says nothing, it presents one stereo pair, and it
// captures nothing. They are here so the gap is a visible, dated decision
// instead of something a later reader discovers. Changing any of these to
// `false` is a deliberate act that turns this suite red and asks for a reason.
let autoEQEligibilityKnownLimitations: [DeviceCase] = [
    .init(label: "a Bluetooth speaker", name: "Bose SoundLink Mini II", transport: .bluetooth,
          isAggregate: false, channels: 2, inputs: 1, jack: false, expected: true),
    .init(label: "a smart speaker", name: "Sonos Roam", transport: .bluetooth,
          isAggregate: false, channels: 2, inputs: 1, jack: false, expected: true),
    .init(label: "a powered monitor on a 2-channel DAC", name: "Genelec 8010",
          transport: .usb, isAggregate: false, channels: 2, inputs: 0, jack: false, expected: true),
    .init(label: "another powered monitor", name: "KRK Rokit 5", transport: .usb,
          isAggregate: false, channels: 2, inputs: 0, jack: false, expected: true),
]


func eligibility(_ testCase: DeviceCase) -> Bool {
    AudioDeviceID.autoEQEligibility(
        name: testCase.name,
        transport: testCase.transport,
        isAggregate: testCase.isAggregate,
        outputChannelCount: testCase.channels,
        inputChannelCount: testCase.inputs,
        builtInHeadphonesActive: testCase.jack
    )
}

for testCase in deviceCases {
    check("AutoEQ on \(testCase.label)", eligibility(testCase) == testCase.expected,
          "expected \(testCase.expected), got \(eligibility(testCase))")
}
for testCase in autoEQEligibilityKnownLimitations {
    check("AutoEQ known limitation — \(testCase.label)",
          eligibility(testCase) == testCase.expected,
          "this case is pinned as still-offered; changing it needs a reason, "
          + "expected \(testCase.expected), got \(eligibility(testCase))")
}

// The permissive branch must actually be reachable, or every case above is
// decided by an exclusion and inverting the fall-through changes nothing.
check("the permissive fall-through is reachable",
      autoEQEligibilityKnownLimitations.contains { eligibility($0) })

// Punctuation and case must not hide a form-factor word.
check("hyphenated headset name is recognised",
      AudioDeviceID.nameIndicatesHeadphones("JBL Quantum-Headset"))
check("uppercase speaker name is recognised",
      AudioDeviceID.nameIndicatesLoudspeaker("DESKTOP SPEAKER"))
// And a word must be a whole word: "tv" inside another word is not a television.
check("a substring is not a word",
      !AudioDeviceID.nameIndicatesLoudspeaker("Vertvox One"))

// ---------------------------------------------------------------------------
// 5. `supportsAutoEQ()` must *be* the rule, on this Mac's real hardware.
//
//    The table above proves the rule. It cannot prove the shipped entry point
//    calls it: a `return true` inserted ahead of the delegation leaves every
//    case above passing. So enumerate the machine's actual output devices, ask
//    the shipped function, and ask the rule with the same four reads. They must
//    agree device by device.
//
//    This is machine-dependent by construction, and says so: on a Mac where
//    every output legitimately qualifies, a short-circuit to `true` would agree
//    with the rule and slip past. That is why `verify-volume-and-eq.py` also
//    checks the *shape* of the function body.
// ---------------------------------------------------------------------------

var deviceListAddress = AudioObjectPropertyAddress(
    mSelector: kAudioHardwarePropertyDevices,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain
)
var deviceListSize: UInt32 = 0
let sizeStatus = AudioObjectGetPropertyDataSize(
    AudioObjectID(kAudioObjectSystemObject), &deviceListAddress, 0, nil, &deviceListSize
)
var deviceIDs = [AudioDeviceID](
    repeating: 0,
    count: sizeStatus == noErr ? Int(deviceListSize) / MemoryLayout<AudioDeviceID>.size : 0
)
if !deviceIDs.isEmpty {
    _ = AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &deviceListAddress, 0, nil,
        &deviceListSize, &deviceIDs
    )
}

var examinedOutputs = 0
for deviceID in deviceIDs where deviceID.hasOutputStreams() {
    examinedOutputs += 1
    let name = (try? deviceID.readDeviceName()) ?? "(unnamed)"
    let shipped = deviceID.supportsAutoEQ()
    let rule = AudioDeviceID.autoEQEligibility(
        name: name,
        transport: deviceID.readTransportType(),
        isAggregate: deviceID.isAggregateDevice(),
        outputChannelCount: deviceID.outputChannelCount(),
        inputChannelCount: deviceID.autoEQInputChannelCount(),
        builtInHeadphonesActive: deviceID.builtInHasHeadphonesActive()
    )
    check("supportsAutoEQ() delegates to the rule for “\(name)”", shipped == rule,
          "shipped says \(shipped), the rule says \(rule) — the entry point is "
          + "deciding something of its own")
}
check("at least one real output device was examined", examinedOutputs > 0,
      "no output device on this Mac; the delegation check proved nothing")

// ---------------------------------------------------------------------------
// 6. The Guide sends the reader to the preamp they actually met.
//
//    Melo has two, with different contracts: the imported-profile preamp is a
//    switch, and the equaliser's headroom is automatic. Both make things
//    quieter, so both answer the same symptom, and the ranking has to tell them
//    apart. The catalog entries are scraped out of SettingsGuide.swift and
//    scored by the real `IntentSearch`.
// ---------------------------------------------------------------------------

struct GuideEntryFixture {
    let id: String
    let title: String
    let keywords: [String]
    let body: [String]
}

// @GUIDE_ENTRIES@

func guideScore(_ id: String, _ query: String) -> Int? {
    guard let entry = guideEntries.first(where: { $0.id == id }) else { return nil }
    return IntentSearch.score(query: query, title: entry.title, keywords: entry.keywords, body: entry.body)
}

let guideDuels: [(query: String, winner: String, loser: String)] = [
    // The search a user runs after Electronic drops 7 dB.
    ("quieter after a preset", "app-eq-headroom", "autoeq-preamp"),
    ("preset sounds quieter", "app-eq-headroom", "autoeq-preamp"),
    ("equalizer lowered the volume", "app-eq-headroom", "autoeq-preamp"),
    // …and the existing route must not be collateral damage.
    ("quieter after a profile", "autoeq-preamp", "app-eq-headroom"),
]

for duel in guideDuels {
    guard let winner = guideScore(duel.winner, duel.query),
          let loser = guideScore(duel.loser, duel.query) else {
        check("guide entries present for “\(duel.query)”", false,
              "missing \(duel.winner) or \(duel.loser) in the catalog")
        continue
    }
    check("“\(duel.query)” ranks \(duel.winner) above \(duel.loser)",
          winner > loser, "\(duel.winner)=\(winner), \(duel.loser)=\(loser)")
    check("“\(duel.query)” finds \(duel.winner) at all", winner > 0)
}

// ---------------------------------------------------------------------------
// 6. Find an Action's own arithmetic, executed rather than described.
//
// The two functions below are spliced verbatim out of
// ConsumerCommandPalette.swift; only the engine they call is a stub. That is
// deliberate: this project measured a `x 100` changed to `x 10` surviving every
// verify script and eighty-three rendered frames, because every check that
// should have caught it tested a rule nothing proved was executed. Running the
// real text is the only thing that catches it. `maximumPercent` is scraped from
// the same file for the same reason — hard-coding 400 here would pin this
// check's opinion instead of the palette's.
// ---------------------------------------------------------------------------

// @PALETTE_UNIT@

let arithmetic = PaletteArithmetic()

// A 2x app reads 200%, not 100%. Reading base volume alone is the defect.
arithmetic.audioEngine.volume = 1.0
arithmetic.audioEngine.boost = .x2
check("the palette reads a 2x app as 200%",
      arithmetic.effectivePercent(for: "fixture") == 200,
      "got \(arithmetic.effectivePercent(for: "fixture"))%")

arithmetic.audioEngine.volume = 0.5
arithmetic.audioEngine.boost = .x1
check("the palette reads a half-volume app as 50%",
      arithmetic.effectivePercent(for: "fixture") == 50,
      "got \(arithmetic.effectivePercent(for: "fixture"))%")

// The number a row promises is the number the action writes. Round-tripping
// every percent through the real write and the real read is what makes that a
// fact rather than a comment.
for percent in 0...400 {
    arithmetic.setEffectivePercent(percent, for: "fixture")
    let readBack = arithmetic.effectivePercent(for: "fixture")
    check("percent \(percent) survives the palette's write and read",
          readBack == percent, "came back as \(readBack)%")
}

// The ceiling is enforced on the way in, not answered with a different number.
arithmetic.setEffectivePercent(900, for: "fixture")
check("the palette clamps above its ceiling",
      arithmetic.effectivePercent(for: "fixture") == PaletteArithmetic.maximumPercent,
      "got \(arithmetic.effectivePercent(for: "fixture"))%")
arithmetic.setEffectivePercent(-50, for: "fixture")
check("the palette clamps below zero",
      arithmetic.effectivePercent(for: "fixture") == 0,
      "got \(arithmetic.effectivePercent(for: "fixture"))%")

// Two constants naming the same ceiling is how these surfaces drifted apart
// before; they must be the same number.
check("the palette's ceiling is the one Shortcuts and the row use",
      PaletteArithmetic.maximumPercent == IntentSearch.maximumVolumePercent,
      "palette \(PaletteArithmetic.maximumPercent), "
      + "shared \(IntentSearch.maximumVolumePercent)")

// ---------------------------------------------------------------------------
// 7. What the palette suggests before anything is typed.
//
// The state that decides whether that list is any good is a Mac with nothing
// playing, and it is the one state the render harness cannot stage:
// `audioEngine.apps` is `processMonitor.activeApps` behind `private(set)`, and
// the harness is handed an engine already built. So the rule is executed here
// instead, spliced from the palette, against exactly that list.
// ---------------------------------------------------------------------------

check("nothing playing still features an app",
      PaletteSuggestion.featuredApp(in: [10, 11, 12], isActive: { _ in false }) == 10,
      "an empty suggestion list is the defect this replaced")
check("the app making sound is featured over the first row",
      PaletteSuggestion.featuredApp(in: [10, 11, 12], isActive: { $0 == 12 }) == 12)
check("the first app making sound wins when several are",
      PaletteSuggestion.featuredApp(in: [10, 11, 12], isActive: { $0 != 10 }) == 11)
check("no apps at all features nothing",
      PaletteSuggestion.featuredApp(in: [Int](), isActive: { _ in true }) == nil)

// ---------------------------------------------------------------------------

if failures.isEmpty {
    print("swift-checks ok")
} else {
    for failure in failures { print("FAIL \(failure)") }
    exit(1)
}
"""


def guide_entry_fields(source: str, entry_id: str) -> dict[str, object] | None:
    """Pull one Guide entry's searchable fields straight out of the catalog.

    Scraped rather than compiled: `SettingsGuide.swift` reaches into
    `GuidedTourTarget`, which lives in a SwiftUI file, so the catalog cannot be
    built standalone. The *scoring* is still the real `IntentSearch` — only the
    data takes a shortcut, and a malformed scrape fails loudly below rather than
    quietly scoring an empty entry.
    """
    marker = f'"{entry_id}",'
    at = source.find(marker)
    if at < 0:
        return None
    end = source.find("\n        ),", at)
    if end < 0:
        return None
    block = source[at:end]
    if "\\(" in block:
        return None  # string interpolation would not survive re-emission

    def literal(field: str) -> str:
        match = re.search(rf'{field}: "((?:[^"\\]|\\.)*)"', block)
        return match.group(1) if match else ""

    keywords: list[str] = []
    kw_at = block.find("keywords: [")
    if kw_at >= 0:
        depth = 0
        for index in range(block.index("[", kw_at), len(block)):
            if block[index] == "[":
                depth += 1
            elif block[index] == "]":
                depth -= 1
                if depth == 0:
                    keywords = re.findall(r'"((?:[^"\\]|\\.)*)"', block[kw_at:index])
                    break

    return {
        "id": entry_id,
        "title": literal("title"),
        "keywords": keywords,
        "body": [literal("summary"), literal("details"), "Sound"],
    }


def swift_string(value: str) -> str:
    # The scraped text is already Swift-escaped source, so it round-trips as-is.
    return f'"{value}"'


def guide_entries_swift() -> str:
    source = read("Sources/Melo/Models/SettingsGuide.swift")
    rows: list[str] = []
    for entry_id in ("app-eq-headroom", "autoeq-preamp"):
        fields = guide_entry_fields(source, entry_id)
        if fields is None:
            failures.append(
                f"SettingsGuide: could not scrape entry {entry_id!r} — the Guide "
                "ranking check cannot run"
            )
            continue
        if not fields["keywords"]:
            failures.append(f"SettingsGuide: entry {entry_id!r} has no keywords")
        keywords = ", ".join(swift_string(k) for k in fields["keywords"])
        body = ", ".join(swift_string(b) for b in fields["body"])
        rows.append(
            f'    GuideEntryFixture(id: {swift_string(entry_id)}, '
            f'title: {swift_string(fields["title"])}, '
            f'keywords: [{keywords}], body: [{body}]),'
        )
    return "let guideEntries: [GuideEntryFixture] = [\n" + "\n".join(rows) + "\n]"


def function_span(text: str, signature: str) -> tuple[int, int] | None:
    """Character range of a Swift function body, by brace matching.

    Deliberately naive — it does not know about braces inside string literals —
    because the two functions it is pointed at contain none, and a mismatch
    surfaces as a failed check rather than as a silent pass.
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
                return (open_at, index)
    return None


# Find an Action.
#
# These checks used to name two exact call sites — `audioEngine.getVolume(` and
# `audioEngine.setVolume(` — and require one of each, inside the two percent
# helpers. That spelling was correct while the palette addressed apps by their
# live `AudioApp`. It now addresses every app the popup lists by persistence
# identifier, through the `…ForInactive` family, because a pinned or merely
# quiet app has no `AudioApp` to pass and so had no palette commands at all.
#
# The invariant did not change and neither did the defect behind it, so what
# follows pins the invariant by shape rather than by the old names — and, more
# to the point, stops relying on names entirely for the part that matters. The
# `x 100` -> `x 10` mutation this project measured survives *any* spelling test;
# only running the arithmetic catches it, which `PaletteArithmetic` below does
# by splicing these two functions out of the real source and executing them.
palette = read("Sources/Melo/Views/Components/ConsumerCommandPalette.swift")


def strip_line_comments(text: str) -> str:
    """Swift source with `//` comments blanked out.

    The palette explains its own history in prose, so it names
    `audioEngine.apps` in three comments describing why it no longer calls it.
    A check that reads those as call sites would be unfixable without deleting
    the explanation.
    """
    return re.sub(r"//[^\n]*", "", text)


palette_code = strip_line_comments(palette)


def function_source(text: str, signature: str) -> str | None:
    """A Swift function declaration, verbatim, signature through closing brace."""
    start = text.find(signature)
    if start < 0:
        return None
    span = function_span(text, signature)
    if span is None:
        return None
    return text[start:span[1] + 1]


# Bodies used when the real ones cannot be found, so the executed checks report
# a wrong answer under their own names instead of the whole Swift unit failing
# to compile under a message about braces.
UNAVAILABLE_ARITHMETIC = """\
    private func effectivePercent(for identifier: String) -> Int { -1 }
    private func setEffectivePercent(_ percent: Int, for identifier: String) {}
"""
UNAVAILABLE_FEATURED = """\
    nonisolated static func featuredApp<App>(
        in apps: [App], isActive: (App) -> Bool
    ) -> App? { nil }
"""


def palette_unit_swift() -> str:
    """The palette's percent arithmetic and suggestion rule, spliced out of the
    real file so the Swift checks execute the shipping text.

    `AudioEngine` is replaced by a stub with the same four method names. That is
    the seam and it is a narrow one: rename an engine method and this stops
    compiling, which is the intended signal, not a false alarm.

    The only edit made to the spliced text is dropping a leading `private`, so
    the checks below can call what they are checking. Bodies are untouched — the
    arithmetic executed here is character-for-character the arithmetic that
    ships.
    """
    parts: list[str] = []
    for signature in (
        "private func effectivePercent(",
        "private func setEffectivePercent(",
    ):
        source = function_source(palette_code, signature)
        if source is None:
            failures.append(
                f"ConsumerCommandPalette: could not splice {signature.strip()} — "
                "the executed arithmetic checks cannot run"
            )
            parts = [UNAVAILABLE_ARITHMETIC]
            break
        source = re.sub(r"\Aprivate\s+", "", source)
        parts.append("    " + source.replace("\n", "\n    ").rstrip() + "\n")

    featured = function_source(palette_code, "static func featuredApp")
    if featured is None:
        failures.append(
            "ConsumerCommandPalette: could not splice featuredApp — the "
            "empty-active-set check cannot run"
        )
        featured_swift = UNAVAILABLE_FEATURED
    else:
        featured_swift = "    " + featured.replace("\n", "\n    ").rstrip() + "\n"

    ceiling = re.search(r"static let maximumPercent\s*=\s*(\d+)", palette_code)
    if ceiling is None:
        failures.append(
            "ConsumerCommandPalette: could not read maximumPercent — the "
            "executed arithmetic checks would be pinning this script's guess"
        )
    ceiling_value = ceiling.group(1) if ceiling else "-1"

    return (
        "struct PaletteArithmetic {\n"
        "    final class EngineStub {\n"
        "        var volume: Float = 1\n"
        "        var boost: BoostLevel = .x1\n"
        "        func getVolumeForInactive(identifier: String) -> Float { volume }\n"
        "        func setVolumeForInactive(identifier: String, to volume: Float) {\n"
        "            self.volume = volume\n"
        "        }\n"
        "        func getBoostForInactive(identifier: String) -> BoostLevel { boost }\n"
        "        func setBoostForInactive(identifier: String, to boost: BoostLevel) {\n"
        "            self.boost = boost\n"
        "        }\n"
        "    }\n"
        "    let audioEngine = EngineStub()\n"
        f"    static let maximumPercent = {ceiling_value}\n"
        "\n" + "\n".join(parts) + "}\n"
        "\n"
        "enum PaletteSuggestion {\n" + featured_swift + "}\n"
    )


def run_swift_checks() -> None:
    swiftc = shutil.which("xcrun")
    argv: list[str]
    if swiftc:
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

    with tempfile.TemporaryDirectory(prefix="melo-verify-volume-eq-") as tmp:
        work = Path(tmp)
        (work / "main.swift").write_text(
            MAIN_SWIFT
            .replace("// @GUIDE_ENTRIES@", guide_entries_swift())
            .replace("// @PALETTE_UNIT@", palette_unit_swift())
        )
        binary = work / "checks"
        compile_result = subprocess.run(
            argv + ["-O", "-o", str(binary), str(work / "main.swift")]
            + [str(sources / unit) for unit in SWIFT_UNITS],
            capture_output=True,
            text=True,
        )
        if compile_result.returncode != 0:
            errors = [
                line for line in compile_result.stderr.splitlines() if "error:" in line
            ][:12]
            failures.append(
                "swift checks did not compile:\n        "
                + "\n        ".join(errors or compile_result.stderr.splitlines()[:12])
            )
            return

        run_result = subprocess.run([str(binary)], capture_output=True, text=True)
        if run_result.returncode != 0:
            for line in run_result.stdout.splitlines():
                if line.startswith("FAIL "):
                    failures.append(line[len("FAIL "):])
            if not any(line.startswith("FAIL ") for line in run_result.stdout.splitlines()):
                failures.append(
                    f"swift checks exited {run_result.returncode} with no verdict: "
                    f"{run_result.stderr.strip()[:200]}"
                )


run_swift_checks()

# ---------------------------------------------------------------------------
# Source checks for the surfaces that cannot be run headless.
# ---------------------------------------------------------------------------

# The app row's readout. `volume` alone is the base gain; without the boost
# factor a 2x app reads 100% while its slider sits at the far right.
app_row = read("Sources/Melo/Views/Rows/AppRow.swift")
if "volume * boost.rawValue" not in app_row:
    failures.append("AppRow: the row percentage must multiply base volume by boost")
if "min(4," not in app_row:
    failures.append("AppRow: the row percentage must clamp to a gain of 4 (400%)")

controls = read("Sources/Melo/Views/Rows/AppRowControls.swift")
if "range: 0...400" not in controls:
    failures.append("AppRowControls: the editable percentage must span 0...400")


# Every read and write of an app's volume or boost has to go through the two
# boost-aware helpers. A bare volume write anywhere else in this file is, by
# construction, a site that has forgotten boost exists — which is how an app
# boosted to 2x once reported "100%" while its own row said "200%".
ACCESSOR = re.compile(r"audioEngine\.(get|set)(Volume|Boost)[A-Za-z]*\(")
reader = function_span(palette_code, "private func effectivePercent(")
writer = function_span(palette_code, "private func setEffectivePercent(")
if reader is None or writer is None:
    failures.append(
        "ConsumerCommandPalette: could not find effectivePercent / setEffectivePercent"
    )
else:
    reads: list[tuple[str, str]] = []
    writes: list[tuple[str, str]] = []
    strays: list[str] = []
    for match in ACCESSOR.finditer(palette_code):
        kind = (match.group(1), match.group(2))
        if reader[0] < match.start() < reader[1]:
            reads.append(kind)
        elif writer[0] < match.start() < writer[1]:
            writes.append(kind)
        else:
            strays.append(match.group(0))
    if strays:
        failures.append(
            "ConsumerCommandPalette: an app's volume or boost is touched outside "
            f"the two percent helpers: {sorted(set(strays))}"
        )
    if sorted(reads) != [("get", "Boost"), ("get", "Volume")]:
        failures.append(
            "ConsumerCommandPalette: effectivePercent must read exactly one volume "
            f"and one boost, and write neither; got {sorted(reads)}"
        )
    if sorted(writes) != [("set", "Boost"), ("set", "Volume")]:
        failures.append(
            "ConsumerCommandPalette: setEffectivePercent must write exactly one "
            f"volume and one boost, and read neither; got {sorted(writes)}"
        )

if "VolumeMapping.components(" not in palette_code:
    failures.append(
        "ConsumerCommandPalette: writes must go through VolumeMapping.components, "
        "the same decomposition the slider uses"
    )
if re.search(r"min\(1,\s*audioEngine\.getVolume", palette_code):
    failures.append("ConsumerCommandPalette: Raise must not clamp to a gain of 1.0")

# The palette must not address apps by the active-only list. `audioEngine.apps`
# is `processMonitor.activeApps`; the popup lists `displayableApps`, which is
# that plus open-but-silent plus pinned. Every command keyed on the former is
# unreachable for an app sitting in plain sight making no sound, which is most
# apps most of the time.
if re.search(r"audioEngine\.apps\b", palette_code):
    failures.append(
        "ConsumerCommandPalette: back on audioEngine.apps — an app the popup "
        "lists but that is not currently playing would have no commands"
    )

# The default list has to contain the thing Melo is for: a palette opened in a
# per-app volume app must not suggest only scenes, devices and Settings.
#
# The previous check for this asserted that the token `appCommands` appeared
# inside `suggestedCommands`. It was green while `appCommands` read
# `audioEngine.apps`, so on a Mac with nothing playing the list it guarded was
# empty and the check said so was fine — a rule proved correct and never proved
# connected, the pattern this project's anchor records. What replaces it names
# the wiring exactly, and hands the decision itself to the Swift checks, which
# run it against the empty-active-set state the render harness cannot stage.
suggested = function_span(palette_code, "private var suggestedCommands:")
if suggested is None:
    failures.append("ConsumerCommandPalette: could not find suggestedCommands")
else:
    body = palette_code[suggested[0]:suggested[1]]
    if "audioEngine.displayableApps" not in body:
        failures.append(
            "ConsumerCommandPalette: suggestedCommands must draw its app from "
            "displayableApps — every app the popup lists, not only the ones "
            "currently making sound"
        )
    if "featuredApp(" not in body:
        failures.append(
            "ConsumerCommandPalette: suggestedCommands must choose with "
            "featuredApp(in:isActive:), the rule the Swift checks execute; "
            "inlining the choice puts it back out of reach of every test"
        )
    if "commands(for:" not in body:
        failures.append(
            "ConsumerCommandPalette: suggestedCommands must offer per-app commands "
            "before anything is typed"
        )

# Shortcuts. There used to be a second, independent copy of the boost thresholds
# here; two copies is how these surfaces drifted apart in the first place.
intents = read("Sources/Melo/Shortcuts/MeloAppIntents.swift")
if "VolumeMapping.components(" not in intents:
    failures.append("MeloAppIntents: the bridge must use VolumeMapping.components")
if re.search(r"case \.\.\.200:\s*boost", intents):
    failures.append("MeloAppIntents: a second copy of the boost thresholds is back")
if "0 to 400" not in intents:
    failures.append("MeloAppIntents: the Volume parameter must document the 0–400 range")

# The real-time path.
tap = read("Sources/Melo/Audio/Engine/ProcessTapController.swift")

# 1. The headroom is applied to the same buffer the band filters are about to
#    run over, and *before* them — after them it is a plain volume cut that does
#    nothing about what the filters already did.
block_at = tap.find("if let eq = eq, eq.isEnabled")
ramp_at = tap.find("eqPreampGain += (eqPreampTargetGain - eqPreampGain)")
process_at = tap.find("eq.process(input: outputSamples")
if min(block_at, ramp_at, process_at) < 0:
    failures.append(
        "ProcessTapController: could not find the EQ block, its headroom ramp, "
        "and its process call"
    )
elif not block_at < ramp_at < process_at:
    failures.append(
        "ProcessTapController: the EQ headroom must be applied inside the EQ "
        "block and ahead of eq.process"
    )

# 2. It is ramped, not stepped, with the same coefficient every neighbouring
#    gain in this callback uses. A 7 dB step at a buffer boundary is a click on
#    the most reachable control in the EQ panel.
if ramp_at < 0 or "* rampCoefficient" not in tap[ramp_at:ramp_at + 80]:
    failures.append(
        "ProcessTapController: the EQ headroom must be ramped with rampCoefficient, "
        "not applied as a step"
    )

# 3. **The wire cannot be cut silently.** `eqPreampGain` and
#    `eqPreampTargetGain` on the real-time function must carry no default value.
#    A default is exactly what let the one live call site stop passing the
#    headroom and still compile: the feature went inert, and every check that
#    merely named the symbol stayed green. Without a default, severing it is a
#    build failure, which is the only check that cannot be argued with.
rt_at = tap.find("nonisolated private static func processMappedBuffersRT(")
rt_end = tap.find(") {", rt_at) if rt_at >= 0 else -1
if rt_at < 0 or rt_end < 0:
    failures.append("ProcessTapController: could not find processMappedBuffersRT's signature")
else:
    signature = tap[rt_at:rt_end]
    if "eqPreampGain: inout Float," not in signature:
        failures.append(
            "ProcessTapController: processMappedBuffersRT must take the headroom "
            "as `inout Float` with no default"
        )
    if not re.search(r"eqPreampTargetGain: Float,?\s*\n", signature):
        failures.append(
            "ProcessTapController: processMappedBuffersRT must take "
            "`eqPreampTargetGain: Float` with no default"
        )
    if re.search(r"eqPreamp\w*: [^,\n]*= ", signature):
        failures.append(
            "ProcessTapController: a default value on a headroom parameter makes "
            "the live call site severable — that is how the feature went inert"
        )

# 4. The live callback passes both, from its own per-callback ramp state.
live_call = tap.find("Self.processMappedBuffersRT(")
if live_call < 0:
    failures.append("ProcessTapController: could not find the live call site")
else:
    call = tap[live_call:live_call + 1400]
    for argument in ("eqPreampGain: &eqPreampGain", "eqPreampTargetGain: eqPreampTargetGain"):
        if argument not in call:
            failures.append(f"ProcessTapController: the live call site must pass {argument!r}")

if "eqPreampTargetGain = settings.preampGainLinear" not in tap:
    failures.append("ProcessTapController: updateEQSettings must republish the headroom target")
if "eqPreampTargetGain = initial.eqSettings.preampGainLinear" not in tap:
    failures.append("ProcessTapController: a tap must start seeded with its curve's headroom")
if "primaryEQPreampGain = eqPreampTargetGain" not in tap:
    failures.append(
        "ProcessTapController: a new tap must start *at* its headroom, not ramp to it "
        "— otherwise the curve's whole boost runs undamped for the first 30 ms"
    )

# `supportsAutoEQ()` must *be* the rule.
#
# Checked by shape, not by substring. Inserting `if true { return true }` ahead
# of the delegation restores the original defect while leaving every executable
# case in this file green and every name it mentions present. A body that is one
# expression cannot hide a short circuit.
classification = read("Sources/Melo/Audio/Extensions/AudioDeviceID+Classification.swift")
body = function_span(classification, "func supportsAutoEQ() -> Bool")
if body is None:
    failures.append("AudioDeviceID+Classification: could not find supportsAutoEQ()")
else:
    inner = classification[body[0] + 1:body[1]]
    inner = re.sub(r"//[^\n]*", "", inner)
    inner = re.sub(r"\s+", "", inner)
    if not re.fullmatch(r"Self\.autoEQEligibility\(.*\)", inner):
        failures.append(
            "AudioDeviceID+Classification: supportsAutoEQ() must be exactly a "
            "delegation to autoEQEligibility and nothing else; found "
            f"{inner[:80]!r}"
        )
    for label in (
        "name:", "transport:", "isAggregate:",
        "outputChannelCount:", "inputChannelCount:", "builtInHeadphonesActive:",
    ):
        if label not in inner:
            failures.append(
                f"AudioDeviceID+Classification: supportsAutoEQ() no longer passes {label}"
            )

# A level drop the user cannot see the reason for reads as a bug, so the panel
# says what it took — in the visible string, not only to VoiceOver.
panel = read("Sources/Melo/Views/EQPanelView.swift")
if "settings.preampDB" not in panel:
    failures.append("EQPanelView: the panel must show the headroom it is taking")
if '"Headroom \\(value)"' not in panel:
    failures.append(
        "EQPanelView: the visible label must carry the word 'Headroom' — a bare "
        "dB figure beside an EQ switch is a number with no noun"
    )

# ---------------------------------------------------------------------------
# Rendered assertions: read the frames dev-verify.sh just produced.
#
# Everything above proves rules and wiring. These two prove *arrival*: that the
# number a user reads in the app row is the number the rule computes, and that
# the headroom label a user sees appears exactly when the curve boosts. Both
# were severable while every other check in this file stayed green.
# ---------------------------------------------------------------------------

# The snapshot directory is chosen by whoever invokes dev-verify.sh and is not
# passed down to the verify scripts, so it is found: the harness writes
# `_complete` as its last act, and the verify loop runs inside the same build
# lock as the render, so under dev-verify.sh the newest `_complete` on the
# machine is always this run's.
#
# Run standalone, that stops being true — the newest render may be from some
# other experiment. The mtime guard below catches the common case (source edited
# after the render) but not all of them, and a leftover snapshot directory from
# a deliberately-broken build will make these two checks fail. That is the safe
# direction, and the fix is to re-run dev-verify.sh rather than to loosen this.
def locate_frames() -> Path | None:
    candidates: list[tuple[float, Path]] = []
    bases = {Path("/tmp"), Path(os.environ.get("TMPDIR", "/tmp"))}
    for base in bases:
        try:
            entries = list(base.iterdir())
        except OSError:
            continue
        for entry in entries:
            sentinel = entry / "_complete"
            try:
                if entry.is_dir() and sentinel.is_file():
                    candidates.append((sentinel.stat().st_mtime, entry))
            except OSError:
                continue
    return max(candidates)[1] if candidates else None


# Files whose contents the frames below are evidence *about*. If any is newer
# than the frames, the frames are describing code that no longer exists and
# reading them would be worse than not reading them.
FRAME_INPUTS = [
    "Sources/Melo/Views/Rows/AppRow.swift",
    "Sources/Melo/Views/Rows/AppRowControls.swift",
    "Sources/Melo/Views/EQPanelView.swift",
    "Sources/Melo/Models/EQSettings.swift",
    "Sources/Melo/Models/EQPreset.swift",
    "Sources/Melo/Utilities/SnapshotScenes.swift",
]

REQUIRED_FRAMES = [
    "app-row-200-percent.png",
    "eq-headroom-boosting.png",
    "eq-headroom-cut-only.png",
]


def ink_column_runs(image, x0: int, x1: int, y0: int, y1: int, threshold: int) -> list[tuple[int, int]]:
    """Contiguous columns containing ink, i.e. one entry per rendered glyph."""
    pixels = image.load()
    runs: list[tuple[int, int]] = []
    current: list[int] | None = None
    for x in range(x0, x1):
        lit = any(pixels[x, y] > threshold for y in range(y0, y1))
        if lit:
            if current is None:
                current = [x, x]
            else:
                current[1] = x
        elif current is not None:
            runs.append((current[0], current[1]))
            current = None
    if current is not None:
        runs.append((current[0], current[1]))
    return runs


def provenance_band_top(image) -> int:
    """First row of the dark-red provenance band, i.e. the end of the content."""
    rgb = image.convert("RGB").load()
    for y in range(image.height):
        r, g, b = rgb[10, y]
        if r > 100 and g < 60 and b < 60:
            return y
    return image.height


def run_frame_checks() -> None:
    try:
        from PIL import Image
    except ImportError:
        failures.append("Pillow is not installed; the rendered assertions cannot run")
        return

    frames = locate_frames()
    if frames is None:
        failures.append(
            "no rendered frames found — run ./scripts/dev-verify.sh <dir> first; "
            "these two claims are about pixels and cannot be checked from source"
        )
        return

    missing = [name for name in REQUIRED_FRAMES if not (frames / name).is_file()]
    if missing:
        failures.append(f"frames in {frames} are missing {missing}")
        return

    oldest_frame = min((frames / name).stat().st_mtime for name in REQUIRED_FRAMES)
    newest_input = max(
        ((root / rel).stat().st_mtime for rel in FRAME_INPUTS if (root / rel).is_file()),
        default=0.0,
    )
    if newest_input > oldest_frame:
        failures.append(
            f"frames in {frames} are older than the source they are evidence about — "
            "re-render before trusting them"
        )
        return

    # --- The app row's readout says 200%, in pixels.
    #
    # `volume 1.0 x boost 2x` renders "200%": four glyphs. Dropping the boost
    # factor renders "100%", which the source check above catches; scaling the
    # percent wrongly renders "20%", which nothing else can see. The readout is
    # the only ink in the right quarter of a collapsed row, and the digits
    # segment cleanly with 3-4px of tracking between them.
    row = Image.open(frames / "app-row-200-percent.png").convert("L")
    content_bottom = provenance_band_top(Image.open(frames / "app-row-200-percent.png"))
    glyphs = ink_column_runs(
        row, int(row.width * 0.75), row.width, 0, content_bottom, threshold=110
    )
    if len(glyphs) != 4:
        failures.append(
            "app-row-200-percent: the readout renders "
            f"{len(glyphs)} glyph(s), expected 4 for “200%”. Runs: {glyphs}"
        )

    # --- The headroom label reaches the screen, and only when it should.
    #
    # Same panel, same size, same layout; the only difference in the strip to
    # the right of the "EQ" switch is the label. On the boosting curve it is
    # there, on the cut-only curve it must not be. A severed label makes the
    # first count collapse to zero; a label that ignores its condition makes the
    # second one non-zero.
    #
    # The strip stops well short of the "Preset" picker, whose text differs
    # between the two curves for reasons that have nothing to do with headroom.
    label_x0, label_x1 = 220, 700
    label_y0, label_y1 = 335, 375
    # Recessed panel background measures 32; the tertiary label peaks at 87.
    label_threshold = 50
    counts = {}
    for name in ("eq-headroom-boosting.png", "eq-headroom-cut-only.png"):
        image = Image.open(frames / name).convert("L")
        if image.width < label_x1 or image.height < label_y1:
            failures.append(f"{name}: smaller than the region the label check reads")
            return
        pixels = image.load()
        counts[name] = sum(
            1
            for x in range(label_x0, label_x1)
            for y in range(label_y0, label_y1)
            if pixels[x, y] > label_threshold
        )
    if counts["eq-headroom-boosting.png"] < 100:
        failures.append(
            "eq-headroom-boosting: no headroom label rendered beside the EQ switch "
            f"({counts['eq-headroom-boosting.png']} lit pixels). The rule computes "
            "-7.0 dB for this curve; the panel is not showing it."
        )
    if counts["eq-headroom-cut-only.png"] != 0:
        failures.append(
            "eq-headroom-cut-only: something is drawn where the headroom label goes "
            f"({counts['eq-headroom-cut-only.png']} lit pixels), but a cut-only curve "
            "takes no headroom"
        )


run_frame_checks()

if failures:
    print("Volume/AutoEQ/EQ-headroom checks failed:")
    for failure in failures:
        print(f"  - {failure}")
    sys.exit(1)

print("Volume percent, AutoEQ eligibility, and EQ headroom checks passed.")
