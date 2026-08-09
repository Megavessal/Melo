#!/usr/bin/env python3
"""Guards for Melo Edit: the DSP it measures with, the moves it proposes, and their arrival.

Named `verify-cutting-room.py`, and its frames are named `cutting-room-*`, after
the name the feature shipped under in 3.1.0. That is the snapshot harness's own
namespace rather than a product name: renaming the scenes would invalidate every
frame already on disk, and this script reads six of them by name.

Three kinds of check, in descending order of how much they prove. The ordering
is not stylistic. This project's anchor records a run in which four wiring
points were severed at once, the tree built, 83 frames rendered, and all eleven
verify scripts passed — because every assertion that should have caught it
tested a pure function nothing proved was called (CLAUDE.md, "Dead patterns").

1. **Executed.** The whole offline DSP layer and `MoveProposer` are pure, so a
   generated `main.swift` compiles the shipped sources and runs them. A −20 dBFS
   1 kHz sine has to measure −20.0 LUFS; the same signal buried in silence has
   to measure the same thing, which is only true if BS.1770's relative gate is
   there; a limiter set to −1 dBTP has to come out at −1 dBTP measured through
   the 4× oversampler. Then the whole novice path end to end: write a real WAV,
   probe it, measure it, ask `MoveProposer` for a plan, put that plan on a
   document, and re-measure what `RenderEngine` actually renders. A quiet file
   has to arrive at the destination's published loudness; a peaky one has to
   arrive under its published ceiling.

   The single most important assertion in this file is that a quiet file and an
   already-compliant file get **different** plans. If the same list comes out
   for every file, the destination has silently become a genre preset, which is
   the one thing the feature was designed not to be — and nothing about the
   types, the build, or a rendered frame would say so.

   Section J covers the multitrack mix, which is the same route and the same
   compile: clip windows, clip moves, fades and gain, placement at `start`,
   the sum inside a track, track moves, gain and pan, the sum across audible
   tracks, the master stack, the safety clip. Its own strongest assertion is
   that **splitting a clip and rendering is sample-identical to not splitting
   it**, over six cases. That is a claim about a class of boundary bug rather
   than one instance: a split a frame out leaves a hole or a doubled frame, and
   no level, no duration and no rendered pixel would ever show it. The rest of
   J is written the same way wherever it can be — solo renders sample-identical
   to rendering that track alone, a muted track sample-identical to the
   one-track render, centre pan sample-identical to no pan, a clip at
   `start: 2.0` exactly zero before 2 s and the decode frame-for-frame after —
   because identity fails on a one-frame error and a tolerance does not.

2. **Rendered.** Three claims are about pixels. The equalizer's drawn response
   must peak at the frequency and gain the band declares, which is checked by
   subtracting a flat frame from a one-band frame and locating what is left. The
   destination picker's two frames — same source, same destination, different
   measurement — must differ, or the button has stopped reading the file. And a
   disabled move must go dim without going away.

3. **Structural.** What is left is wiring that neither tier can reach: that
   every `MoveKind` still has an arm in `RenderEngine` that reaches a processor,
   that no `default:` there swallows one, that no processor is left with nothing
   calling it, and that the two views the rendered checks depend on still draw
   from the functions the executed checks pin. Shape, not substring: an arm has
   to *be* its delegation.

Three things mutating this file taught, which reading it did not. Section J was
promoted after 22 deliberate breaks in `RenderEngine` were run against it and
all 22 came back red; these are the three where the *assertions* had to change
before that was true. Each is a trap a future edit can re-set.

1. **An assertion can be unfalsifiable and look like the strongest one there.**
   "A fade in starts at zero" passed on a sine whose first sample is zero
   whether anything faded it or not, and a `drop-clip-fadein` mutation walked
   straight through it. It is now checked at **20% into the fade**, where the
   level has to be 0.2 of the clip's, and that is the assertion that goes red.
   The sample-zero check is kept because it is cheap and true, not because it
   proves anything. Do not let this drift back to sample zero.

2. **Five test cases can all round the same way.** The five ordinary split
   points were satisfied by rounding `start` and `sourceIn` separately, so an
   `independent-rounding` mutation survived a check that looked exhaustive. A
   sixth, adversarial case was added — `start` 0.1 of a frame past a boundary,
   `sourceIn` 0.9 past one, the split half a frame long — and it now fails with
   a one-frame hole at output frame 50000. Coverage counted in cases is not
   coverage: the cases have to disagree with each other about something.

3. **A surviving mutation is not always a missing assertion.** `pan-dips-centre`
   removed a fast-path guard and survived, which read as a hole in the pan
   checks. It was not: under a balance law that guard is a no-op, so the
   mutation changed no output and there was nothing to catch. It was replaced
   with `pan-constant-power`, a genuinely different sine/cosine law, which the
   half-left assertion catches — Melo's pan holds the near side at unity and
   only attenuates the far side, and constant-power agrees at hard left and at
   centre and disagrees at half left. Fix the mutation before widening the
   suite; a check added to catch a no-op is a check that can never fail.

**Timing checks are opt-in, and that is a decision, not an omission.** Section
J12's decode-cost assertions — eight clips not costing eight decodes, the pool
surviving between renders, a one-source render not evicting the mix's decodes —
have no observable but wall-clock, because the pool is private. The margins read
as generous (3x, 0.6x, 0.35x) and the whole block costs about 1.4 s, so neither
runtime nor headroom is the objection. Measured 2026-08-09, on an idle machine,
which is the objection: cold render 0.053 s, warm 0.003 s, eight clips 0.056 s,
three sources cold 0.167 s and 0.009 s after a single-source render. Those
ratios are between numbers a few milliseconds apart. A 30 ms scheduler stall on
the warm render — ordinary when several agents are running `swiftc` at once,
which is this project's normal state — inverts `warm < cold * 0.6` while nothing
is wrong. A gate that goes amber for that teaches people to re-run it until it
is green, and that habit costs more than these three checks are worth. They also
assert a *performance* property, and hanging one on the same latch as the
correctness signal means a blip blocks the thing the latch is for. Rejected:
taking the minimum of N repetitions, which would blunt the noise but not remove
it, and which changes assertions that were proven as written.

So they run under `MELO_VERIFY_TIMING=1`, and print a line saying they were
skipped when it is unset — a silent skip would be the worse failure. What is
lost while they are off, stated plainly: the `decode-per-clip`,
`no-source-cache` and `prune-to-document` mutations are not caught. The
correctness half of J12 — eight adjacent tiles reconstructing their source frame
for frame — is free and always runs.

Standalone `python3`, no arguments, no shared library. Exits non-zero and prints
every failure it found rather than the first.
"""
from __future__ import annotations

import math
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
# 1. Executed. Compile the real sources and run assertions against them.
# ---------------------------------------------------------------------------

# Listed rather than globbed, so a new dependency creeping into the offline DSP
# shows up here as a compile error naming it instead of as a silently narrower
# set of checks. `AudioFileIO` and `RenderEngine` are in the list because the
# end-to-end assertion goes through both: a plan that is only ever applied by
# this file's own copy of the switch would prove the plan and not the render.
SWIFT_UNITS = [
    "Editor/Core/EditorTypes.swift",
    "Editor/Core/MoveKindDisplay.swift",
    "Editor/Core/AudioFileIO.swift",
    "Editor/DSP/PCMBlockChannels.swift",
    "Editor/DSP/LoudnessMeter.swift",
    "Editor/DSP/TruePeakMeter.swift",
    "Editor/DSP/LookaheadLimiter.swift",
    "Editor/DSP/MoveProcessors.swift",
    "Editor/DSP/SignalAnalysis.swift",
    "Editor/DSP/OfflineBiquadChain.swift",
    "Editor/DSP/RenderEngine.swift",
    "Editor/Analysis/MoveProposer.swift",
    "Editor/Analysis/DestinationCatalogue.swift",
    "Editor/Analysis/EQResponseCurve.swift",
    # `AudioFileIO.encode` shells out for the two formats macOS cannot write, so
    # it drags the tool runner in even when the test only ever writes a WAV.
    "Editor/Sources/ToolProcessRunner.swift",
    "Editor/Sources/ExternalToolLocator.swift",
    "Audio/Loudness/KWeightingFilter.swift",
    "Audio/Loudness/LoudnessEqualizerMath.swift",
    "Audio/EQ/BiquadMath.swift",
    "Audio/Engine/SoftLimiter.swift",
    "Models/EQSettings.swift",
    "Models/EQPreset.swift",
    "Models/AutoEQProfile.swift",
]

MAIN_SWIFT = r"""
import Foundation

var failures: [String] = []

func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    if !ok {
        let extra = detail()
        failures.append(extra.isEmpty ? name : "\(name) — \(extra)")
    }
}

func near(_ actual: Double, _ expected: Double, _ tolerance: Double) -> Bool {
    actual.isFinite && abs(actual - expected) <= tolerance
}

let rate = 48_000.0

func tone(_ frequency: Double,
          _ dbfs: Double,
          _ seconds: Double,
          channels: Int = 2,
          phase: Double = 0,
          sampleRate: Double = rate) -> PCMBlock {
    let amplitude = Float(pow(10.0, dbfs / 20.0))
    let frames = Int(seconds * sampleRate)
    var samples = [Float](repeating: 0, count: frames * channels)
    for frame in 0..<frames {
        let value = amplitude
            * Float(sin(2 * Double.pi * frequency * Double(frame) / sampleRate + phase))
        for channel in 0..<channels { samples[frame * channels + channel] = value }
    }
    return PCMBlock(samples: samples, sampleRate: sampleRate, channelCount: channels)
}

func silence(_ seconds: Double, channels: Int = 2) -> PCMBlock {
    PCMBlock(samples: [Float](repeating: 0, count: Int(seconds * rate) * channels),
             sampleRate: rate,
             channelCount: channels)
}

func joined(_ blocks: [PCMBlock]) -> PCMBlock {
    PCMBlock(samples: blocks.flatMap(\.samples),
             sampleRate: blocks[0].sampleRate,
             channelCount: blocks[0].channelCount)
}

// ---------------------------------------------------------------------------
// A. Integrated loudness, ITU-R BS.1770-4.
//
// What existed before this feature was the K-weighting pre-filter and a
// smoothed RMS of it, which is not LUFS. These are the assertions that say the
// rest of the standard is really there.
// ---------------------------------------------------------------------------

let referenceTone = tone(1000, -20, 5)
let reference = try LoudnessMeter.measure(referenceTone).integratedLUFS
check("a -20 dBFS 1 kHz stereo sine measures -20 LUFS",
      near(reference, -20.0, 0.1), "measured \(reference)")

let quieter = try LoudnessMeter.measure(tone(1000, -26, 5)).integratedLUFS
check("6 dB down measures 6 LU down",
      near(quieter - reference, -6.0, 0.05),
      "reference \(reference), quieter \(quieter)")

// BS.1770 sums channel powers, so the same programme on one channel measures
// ~3 LU lower. The whole mono/stereo target split in the catalogue rests on it.
let monoTone = try LoudnessMeter.measure(tone(1000, -20, 5, channels: 1)).integratedLUFS
check("a single-channel file measures 3 LU below the same programme in stereo",
      near(monoTone - reference, -3.01, 0.15),
      "stereo \(reference), mono \(monoTone)")

let quiet = try LoudnessMeter.measure(silence(3)).integratedLUFS
check("digital silence reports the floor of the scale, not a measurement",
      quiet == LoudnessMeter.silenceLUFS, "measured \(quiet)")

// The two gates, separately.
//
// Digital silence is removed by the *absolute* gate at −70 LUFS, which the
// check above already exercises. Room tone is not: at −45 dBFS it is well above
// −70, so only the **relative** gate — 10 LU below the mean of what survived —
// can keep it out of the answer. Three seconds of programme in twelve seconds
// of room tone averages about 7 dB low if that gate is missing, and every other
// assertion in this file is blind to the difference.
let sparse = joined([tone(1000, -45, 6), tone(1000, -20, 3), tone(1000, -45, 6)])
let sparseLUFS = try LoudnessMeter.measure(sparse).integratedLUFS
let ungated = 10 * log10((3 * pow(10.0, -2.0) + 12 * pow(10.0, -4.5)) / 15) - 0.691
check("room tone around the programme is gated out of the measurement",
      near(sparseLUFS, reference, 1.0),
      "programme alone \(reference), programme in room tone \(sparseLUFS) — "
      + "without the relative gate this lands near \(ungated)")
check("the gated answer is not the ungated one",
      abs(sparseLUFS - ungated) > 3.0,
      "measured \(sparseLUFS), ungated arithmetic gives \(ungated)")

// ---------------------------------------------------------------------------
// B. True peak, ITU-R BS.1770-4 Annex 2.
//
// Only sample peak existed before. A -1 dBTP ceiling is meaningless without
// oversampling, and the difference is invisible from the outside.
// ---------------------------------------------------------------------------

let sineTruePeak = try TruePeakMeter.truePeakDBTP(tone(1000, -20, 2))
check("a -20 dBFS sine has a -20 dBTP true peak",
      near(sineTruePeak, -20.0, 0.1), "measured \(sineTruePeak)")

// fs/4, offset a quarter period: every sample lands at ±0.707 while the
// waveform itself reaches ±1. Sample peak says -3 dBFS, true peak says 0.
let interSample = tone(rate / 4, 0, 1, channels: 1, phase: .pi / 4)
let samplePeak = SignalAnalysis.peakDBFS(interSample)
let truePeak = try TruePeakMeter.truePeakDBTP(interSample)
check("true peak sees the inter-sample peak that sample peak cannot",
      truePeak - samplePeak > 2.5,
      "sample peak \(samplePeak) dBFS, true peak \(truePeak) dBTP — "
      + "a difference under 2.5 dB means the 4x oversampler is not running")

// ---------------------------------------------------------------------------
// C. The lookahead limiter.
//
// `SoftLimiter` is a stateless soft clip fixed at 0.95 and cannot express a
// ceiling at all. This is the one that can, and the claim is exact: measured
// through the same oversampled envelope, the output sits at the ceiling.
// ---------------------------------------------------------------------------

for ceiling in [-1.0, -2.0, -3.0] {
    var hot = joined([tone(440, -0.1, 1), tone(80, -0.5, 1)])
    try LookaheadLimiter.apply(&hot, ceilingDBTP: ceiling, releaseMS: 100)
    let after = try TruePeakMeter.truePeakDBTP(hot)
    check("a limiter at \(ceiling) dBTP holds the true peak at or under it",
          after <= ceiling + 0.02, "came out at \(after) dBTP")
    check("a limiter at \(ceiling) dBTP does not over-duck",
          after >= ceiling - 0.5, "came out at \(after) dBTP, well under the ceiling")
}

var alreadyQuiet = tone(1000, -20, 1)
let untouched = alreadyQuiet.samples
try LookaheadLimiter.apply(&alreadyQuiet, ceilingDBTP: -1, releaseMS: 100)
check("material already under the ceiling comes back untouched",
      alreadyQuiet.samples == untouched)

// ---------------------------------------------------------------------------
// D. `MoveProposer`. Every move must be caused by a measurement.
// ---------------------------------------------------------------------------

func report(lufs: Double,
            truePeak: Double,
            noiseFloor: Double = -62,
            lead: TimeInterval = 0,
            tail: TimeInterval = 0,
            gaps: [ClosedRange<TimeInterval>] = [],
            dc: Double = 0,
            clipped: Int = 0,
            dualMono: Bool = false) -> AnalysisReport {
    AnalysisReport(
        integratedLUFS: lufs,
        truePeakDBTP: truePeak,
        loudnessRangeLU: 7,
        peakDBFS: truePeak - 0.2,
        noiseFloorDBFS: noiseFloor,
        dcOffset: dc,
        clippedSampleCount: clipped,
        spectralTiltDBPerOctave: -2,
        leadingSilence: lead,
        trailingSilence: tail,
        interiorSilences: gaps,
        isEffectivelyMono: dualMono,
        measuredAt: Date(timeIntervalSince1970: 1_770_000_000))
}

func fixtureSource(duration: TimeInterval, channels: Int = 2) -> EditorSource {
    EditorSource(
        url: URL(fileURLWithPath: "/tmp/verify.wav"),
        displayName: "verify",
        origin: .file(originalURL: URL(fileURLWithPath: "/tmp/verify.wav")),
        duration: duration,
        sampleRate: rate,
        channelCount: channels,
        formatDescription: "WAV")
}

func signature(_ moves: [Move]) -> [String] { moves.map { "\($0.kind)" } }
func contains(_ moves: [Move], _ predicate: (MoveKind) -> Bool) -> Bool {
    moves.contains { predicate($0.kind) }
}
func isNormalize(_ kind: MoveKind) -> Bool { if case .normalize = kind { return true }; return false }
func isLimiter(_ kind: MoveKind) -> Bool { if case .limiter = kind { return true }; return false }
func isTrim(_ kind: MoveKind) -> Bool { if case .trim = kind { return true }; return false }
func isFadeOut(_ kind: MoveKind) -> Bool { if case .fadeOut = kind { return true }; return false }
func isMono(_ kind: MoveKind) -> Bool { if case .channels(.mono) = kind { return true }; return false }

let longSource = fixtureSource(duration: 250)
let needsWork = report(lufs: -22.4, truePeak: -0.4, noiseFloor: -48.5,
                       lead: 1.8, tail: 2.4,
                       gaps: [31.2...33.4, 88.0...90.4, 150.2...152.1],
                       dc: 0.0042, dualMono: true)
let alreadyRight = report(lufs: -16.2, truePeak: -1.6, lead: 0.1, tail: 0.2)

let podcast = DestinationCatalogue.podcast
let plannedForQuiet = MoveProposer.propose(for: needsWork, destination: podcast, source: longSource)
let plannedForLoud = MoveProposer.propose(for: alreadyRight, destination: podcast, source: longSource)

// The assertion the whole novice path rests on.
check("a quiet file and an already-correct file get different plans",
      signature(plannedForQuiet) != signature(plannedForLoud),
      "both produced \(signature(plannedForQuiet)) — the destination has become a preset")

check("a file 6 dB under the target is offered a level change",
      contains(plannedForQuiet, isNormalize))
check("a file whose peaks will overshoot is offered a limiter",
      contains(plannedForQuiet, isLimiter))
check("dead air at both ends is offered a trim",
      contains(plannedForQuiet, isTrim))
check("a dual-mono file bound for a mono destination is offered the fold",
      contains(plannedForQuiet, isMono))

check("a file already inside the tolerance is not offered a level change",
      !contains(plannedForLoud, isNormalize),
      "proposed \(signature(plannedForLoud))")
check("a file already under the ceiling is not offered a limiter",
      !contains(plannedForLoud, isLimiter),
      "proposed \(signature(plannedForLoud))")

// The ceiling in the move is the destination's published one, not a constant.
for move in plannedForQuiet {
    if case .limiter(let ceiling, _) = move.kind {
        check("the proposed limiter uses the destination's published ceiling",
              ceiling == podcast.truePeakCeilingDBTP,
              "proposed \(ceiling), published \(podcast.truePeakCeilingDBTP)")
    }
}

// Six destinations, one measurement. If they all produce the same plan, the
// destinations are decoration.
var distinctPlans = Set<String>()
for destination in DestinationCatalogue.all {
    let plan = MoveProposer.propose(for: needsWork, destination: destination, source: longSource)
    distinctPlans.insert(signature(plan).joined(separator: "|"))
    for move in plan {
        let rationale = move.rationale ?? ""
        check("every proposed move says what caused it (\(destination.id), \(move.kind.title))",
              !rationale.isEmpty, "no rationale")
        // The mono fold is the one move whose cause is a fact rather than a
        // figure — the two channels either carry the same signal or they do
        // not — so it is the one rationale with no number in it. Every other
        // move exists because some measurement crossed a threshold, and the
        // sentence has to say which.
        var causedByABoolean = false
        if case .channels = move.kind { causedByABoolean = true }
        if !causedByABoolean {
            check("the rationale names the number that caused it "
                  + "(\(destination.id), \(move.kind.title))",
                  rationale.rangeOfCharacter(from: .decimalDigits) != nil,
                  "\"\(rationale)\"")
        }
    }
}
check("the six destinations do not all propose the same thing",
      distinctPlans.count >= 3, "only \(distinctPlans.count) distinct plans")

// Video is the destination that must not trim, because trimming a video's
// audio slides every word away from the mouth that said it.
let videoPlan = MoveProposer.propose(for: needsWork, destination: DestinationCatalogue.video,
                                     source: longSource)
check("Video never trims dead air",
      !contains(videoPlan, isTrim), "proposed \(signature(videoPlan))")

// The tolerance is consulted, not decorative: the same 3 LU gap is worth fixing
// for Podcast (+/- 1 LU, published by Apple) and is not for Just better (4 LU).
let threeUnder = report(lufs: -19.0, truePeak: -6.0)
check("a 3 LU gap is worth fixing for Podcast",
      contains(MoveProposer.propose(for: threeUnder, destination: podcast, source: longSource),
               isNormalize))
check("the same 3 LU gap is left alone by Just better",
      !contains(MoveProposer.propose(for: threeUnder,
                                     destination: DestinationCatalogue.justBetter,
                                     source: longSource),
                isNormalize))

// Apple caps an exported ringtone at 30 seconds, and a cut at exactly 30
// seconds lands mid-sound, so it gets half a second of fade.
let ringtoneSource = fixtureSource(duration: 60)
let ringtonePlan = MoveProposer.propose(for: report(lufs: -20, truePeak: -3),
                                        destination: DestinationCatalogue.ringtone,
                                        source: ringtoneSource)
var ringtoneWindow: Double?
for move in ringtonePlan {
    if case .trim(let start, let end) = move.kind { ringtoneWindow = end - start }
}
check("a long ringtone is cut to the published 30 seconds",
      ringtoneWindow.map { near($0, DestinationCatalogue.ringtoneMaximumDuration, 0.01) } ?? false,
      "window \(String(describing: ringtoneWindow))")
check("a truncated ringtone gets a fade so the cut does not click",
      contains(ringtonePlan, isFadeOut))
check("a ringtone shorter than the cap is not truncated",
      !contains(MoveProposer.propose(for: report(lufs: -20, truePeak: -3),
                                     destination: DestinationCatalogue.ringtone,
                                     source: fixtureSource(duration: 12)),
                isTrim))

check("a mono source is aimed 3 LU lower, per the published mono figure",
      near(MoveProposer.effectiveTargetLUFS(for: podcast, source: fixtureSource(duration: 60, channels: 1)),
           podcast.targetLUFS - 3.0, 0.001))
check("a stereo source is aimed at the published figure itself",
      near(MoveProposer.effectiveTargetLUFS(for: podcast, source: longSource),
           podcast.targetLUFS, 0.001))

// ---------------------------------------------------------------------------
// E. The equalizer's drawn response is the coefficients, not a picture of them.
// ---------------------------------------------------------------------------

let probe = AutoEQFilter(type: .peaking, frequency: 1000, gainDB: 9, q: 1.4)
let atCentre = EQResponseCurve.magnitudeDB(bands: [probe], preampDB: 0, at: 1000)
check("a +9 dB band reads +9 dB at its own centre",
      near(atCentre, 9.0, 0.1), "read \(atCentre)")
let atBottom = EQResponseCurve.magnitudeDB(bands: [probe], preampDB: 0, at: 20)
check("a 1 kHz band does nothing at 20 Hz",
      near(atBottom, 0.0, 0.3), "read \(atBottom)")

// Q is a coefficient, and nothing but the real biquad makes it matter.
let wide = EQResponseCurve.magnitudeDB(
    bands: [AutoEQFilter(type: .peaking, frequency: 1000, gainDB: 9, q: 0.5)],
    preampDB: 0, at: 500)
let narrow = EQResponseCurve.magnitudeDB(
    bands: [AutoEQFilter(type: .peaking, frequency: 1000, gainDB: 9, q: 4.0)],
    preampDB: 0, at: 500)
check("a wide band still lifts an octave down and a narrow one does not",
      wide > 4.0 && narrow < 1.0, "Q 0.5 gives \(wide) dB, Q 4.0 gives \(narrow) dB")

let withPreamp = EQResponseCurve.magnitudeDB(bands: [probe], preampDB: -9, at: 1000)
check("the preamp moves the whole curve",
      near(withPreamp, 0.0, 0.1), "read \(withPreamp)")

check("a boosting curve is pulled back by its own peak",
      near(EQResponseCurve.automaticPreampDB(for: EQPreset.electronic.settings.autoEQFilters),
           -7.0, 0.001))
check("a cut-only curve takes no headroom",
      EQResponseCurve.automaticPreampDB(for: EQPreset.bassCut.settings.autoEQFilters) == 0)

check("Melo's ten flat bands are recognised as the graphic shape",
      EQResponseCurve.isGraphicShaped(EQResponseCurve.flatGraphicBands))
check("a single off-grid band is not",
      !EQResponseCurve.isGraphicShaped([probe]))

// The drawn polyline is 240 log-spaced points, and the rendered assertion in
// verify-cutting-room.py locates the peak of it in pixels. This is the same
// claim in numbers, so a failure says which of the two is wrong.
let drawn = EQResponseCurve.curve(bands: [probe], preampDB: 0)
check("the drawn curve is 240 points", drawn.count == 240, "\(drawn.count)")
if let highest = drawn.max(), let index = drawn.firstIndex(of: highest) {
    let position = Double(index) / Double(drawn.count - 1)
    let frequency = EQResponseCurve.frequency(atPosition: position)
    check("the drawn curve peaks at the band's own frequency",
          near(frequency, 1000, 30), "peaks at \(frequency) Hz")
    check("the drawn curve peaks at the band's own gain",
          near(highest, 9.0, 0.2), "peaks at \(highest) dB")
}

// ---------------------------------------------------------------------------
// F. The processors do what their names say.
// ---------------------------------------------------------------------------

let attenuated = MoveProcessors.gain(tone(1000, -20, 1), dB: -6)
check("gain of -6 dB is -6 dB",
      near(SignalAnalysis.peakDBFS(attenuated), -26.0, 0.05),
      "peak \(SignalAnalysis.peakDBFS(attenuated))")
check("the mono fold produces one channel",
      MoveProcessors.channels(tone(1000, -20, 1), mode: .mono).channelCount == 1)
check("trimming 1s to 3s of a 4s file leaves 2s",
      near(MoveProcessors.trim(tone(1000, -20, 4), start: 1, end: 3).duration, 2.0, 0.001))
let original = tone(300, -12, 0.5)
check("reversing twice is the identity",
      MoveProcessors.reverse(MoveProcessors.reverse(original)).samples == original.samples)
let faded = MoveProcessors.fade(tone(1000, -6, 2), length: 0.5, curve: .equalPower, isFadeIn: false)
check("a fade out ends at silence",
      abs(faded.samples[faded.samples.count - 1]) < 0.001,
      "last sample \(faded.samples[faded.samples.count - 1])")
check("a fade out leaves the beginning alone",
      faded.samples[0] == tone(1000, -6, 2).samples[0])

// ---------------------------------------------------------------------------
// G. The catalogue's numbers are inside the range they claim to be in.
// ---------------------------------------------------------------------------

check("there are six destinations", DestinationCatalogue.all.count == 6,
      "\(DestinationCatalogue.all.count)")
check("destination ids are unique",
      Set(DestinationCatalogue.all.map(\.id)).count == DestinationCatalogue.all.count)
for destination in DestinationCatalogue.all {
    check("\(destination.id) leaves codec headroom",
          destination.truePeakCeilingDBTP <= 0,
          "ceiling \(destination.truePeakCeilingDBTP) dBTP")
    check("\(destination.id) aims somewhere a person would listen to",
          destination.targetLUFS <= -6 && destination.targetLUFS >= -30,
          "target \(destination.targetLUFS) LUFS")
    check("\(destination.id) has a tolerance",
          DestinationCatalogue.loudnessToleranceLU(for: destination) > 0)
    check("\(destination.id)'s blurb is one line, not a paragraph",
          destination.blurb.count <= 120 && !destination.blurb.contains("\n"),
          "\(destination.blurb.count) characters")
}
check("the ringtone cap is Apple's published 30 seconds",
      DestinationCatalogue.ringtoneMaximumDuration == 30)

// ---------------------------------------------------------------------------
// H. One formatter. A dB in a rationale and a dB in the row under it are the
//    same string, and both use a real minus sign rather than a hyphen.
// ---------------------------------------------------------------------------

check("negative numbers use a real minus sign",
      EditorFormat.number(-16.1, places: 1).hasPrefix("\u{2212}"),
      "got \"\(EditorFormat.number(-16.1, places: 1))\"")
check("negative decibels use a real minus sign",
      EditorFormat.decibels(-3.0).hasPrefix("\u{2212}"),
      "got \"\(EditorFormat.decibels(-3.0))\"")
check("no ASCII hyphen leaks into a formatted number",
      !EditorFormat.number(-16.1, places: 1).contains("-"))
check("timecode is minutes and seconds",
      EditorFormat.timecode(250) == "4:10", "got \"\(EditorFormat.timecode(250))\"")
check("elapsed of total reads as one phrase",
      EditorFormat.elapsedOfTotal(102, 250) == "1:42 of 4:10",
      "got \"\(EditorFormat.elapsedOfTotal(102, 250))\"")

// ---------------------------------------------------------------------------
// I. End to end, through the real file I/O and the real render.
//
// Everything above proves a rule. This proves arrival: a file on disk, measured
// by the code the app measures with, planned by the planner the button calls,
// rendered by the actor the transport plays from, and measured again.
// ---------------------------------------------------------------------------

func write(_ block: PCMBlock, named name: String, into directory: URL) async throws -> EditorSource {
    let url = directory.appendingPathComponent(name)
    try await AudioFileIO.encode(block,
                                 settings: ExportSettings(format: .wav, destinationURL: url))
    return try AudioFileIO.probe(url)
}

let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("melo-verify-cutting-room-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: scratch) }

// A quiet recording with dead air at both ends, the shape the novice path is
// built for.
var programme: [PCMBlock] = [silence(1.2)]
for step in 0..<8 { programme.append(tone(180 + Double(step) * 30, -26, 0.9)) }
programme.append(silence(1.6))
let quietSource = try await write(joined(programme), named: "quiet.wav", into: scratch)

check("what was written is what comes back",
      quietSource.channelCount == 2 && near(quietSource.sampleRate, rate, 0.5)
        && near(quietSource.duration, 10.0, 0.01),
      "probe says \(quietSource.channelCount)ch \(quietSource.sampleRate)Hz \(quietSource.duration)s")

let engine = RenderEngine()
let measured = try await engine.analyse(EditorDocument(source: quietSource))
check("the measured file is the quiet one that was written",
      measured.integratedLUFS < -24, "measured \(measured.integratedLUFS) LUFS")
check("the dead air at the front is found",
      near(measured.leadingSilence, 1.2, 0.15), "found \(measured.leadingSilence)s")

for destination in [DestinationCatalogue.podcast, DestinationCatalogue.music] {
    let plan = MoveProposer.propose(for: measured, destination: destination, source: quietSource)
    check("\(destination.id) has something to do about a file 10 LU under its target",
          !plan.isEmpty)
    var document = EditorDocument(source: quietSource)
    document.destination = destination
    document.analysis = measured
    document.moves = plan

    let rendered = try await engine.analyse(document)
    // The output's own channel count decides the target: BS.1770 sums channels,
    // so a mono render of the same programme correctly measures 3 LU lower, and
    // that is exactly the mono figure the catalogue cites.
    let foldsToMono = plan.contains { if case .channels(.mono) = $0.kind { return true }; return false }
    let expected = destination.targetLUFS - (foldsToMono ? 3.0 : 0.0)
    check("\(destination.id) arrives at its published loudness",
          near(rendered.integratedLUFS, expected, 0.6),
          "rendered \(rendered.integratedLUFS) LUFS, wanted \(expected)")
    check("\(destination.id) arrives under its published ceiling",
          rendered.truePeakDBTP <= destination.truePeakCeilingDBTP + 0.05,
          "rendered \(rendered.truePeakDBTP) dBTP, ceiling \(destination.truePeakCeilingDBTP)")
}

// A quiet bed with brief loud transients: low loudness, high true peak, so the
// level lift would push the peaks well past the ceiling and a limiter has to be
// proposed and has to work.
func peakySource(seconds: Double) -> PCMBlock {
    let frames = Int(seconds * rate)
    let bedAmplitude = Float(pow(10.0, -34.0 / 20.0))
    let hitAmplitude = Float(pow(10.0, -1.0 / 20.0))
    var mono = (0..<frames).map { bedAmplitude * Float(sin(2 * Double.pi * 220 * Double($0) / rate)) }
    var cursor = 0
    while cursor + 240 < frames {
        for offset in 0..<240 {
            let hit = hitAmplitude * Float(sin(2 * Double.pi * 3300 * Double(offset) / rate))
            mono[cursor + offset] = mono[cursor + offset] * 0.2 + hit
        }
        cursor += Int(rate * 1.1)
    }
    var interleaved = [Float](repeating: 0, count: frames * 2)
    for frame in 0..<frames {
        interleaved[frame * 2] = mono[frame]
        interleaved[frame * 2 + 1] = mono[frame]
    }
    return PCMBlock(samples: interleaved, sampleRate: rate, channelCount: 2)
}

let peaky = try await write(peakySource(seconds: 8), named: "peaky.wav", into: scratch)
let peakyMeasured = try await engine.analyse(EditorDocument(source: peaky))
check("the peaky file really is peaky",
      peakyMeasured.truePeakDBTP > -2.0 && peakyMeasured.integratedLUFS < -15,
      "\(peakyMeasured.integratedLUFS) LUFS, \(peakyMeasured.truePeakDBTP) dBTP")

let music = DestinationCatalogue.music
let peakyPlan = MoveProposer.propose(for: peakyMeasured, destination: music, source: peaky)
check("a lift that would overshoot the ceiling brings a limiter with it",
      peakyPlan.contains { if case .limiter = $0.kind { return true }; return false },
      "proposed \(signature(peakyPlan))")

var peakyDocument = EditorDocument(source: peaky)
peakyDocument.destination = music
peakyDocument.analysis = peakyMeasured
peakyDocument.moves = peakyPlan
let peakyRendered = try await engine.analyse(peakyDocument)
check("the rendered file's true peak sits under the published ceiling",
      peakyRendered.truePeakDBTP <= music.truePeakCeilingDBTP + 0.03,
      "rendered \(peakyRendered.truePeakDBTP) dBTP, ceiling \(music.truePeakCeilingDBTP)")

// A move that is switched off is not in the render.
var disabled = peakyDocument
for index in disabled.moves.indices { disabled.moves[index].isEnabled = false }
let bypassed = try await engine.analyse(disabled)
check("a stack of disabled moves renders the source unchanged",
      near(bypassed.integratedLUFS, peakyMeasured.integratedLUFS, 0.05),
      "source \(peakyMeasured.integratedLUFS), rendered \(bypassed.integratedLUFS)")

// ---------------------------------------------------------------------------
// J. The multitrack mix.
//
// Everything above section I renders one source through one move stack, which
// is the whole document Melo Edit had before 3.2. `RenderEngine` now cuts each
// clip's source window, applies the clip's moves, fades and gain, lays it at
// its start, sums the clips in a track, applies the track's moves, gain and
// pan, sums the audible tracks, runs the master stack and safety-clips. Every
// one of those verbs is a place a mix can go silently wrong, and none of them
// is visible in a rendered frame or to the compiler.
//
// Real WAVs through the real decode, as above. Nothing here is a mock.
// ---------------------------------------------------------------------------

func lane(_ clips: [Clip],
          gain: Double = 0,
          pan: Double = 0,
          muted: Bool = false,
          soloed: Bool = false,
          moves: [Move] = []) -> Track {
    Track(name: "lane", gainDB: gain, pan: pan, isMuted: muted, isSoloed: soloed,
          clips: clips, moves: moves)
}

func paper(_ sources: [EditorSource], _ tracks: [Track], master: [Move] = []) -> EditorDocument {
    EditorDocument(sources: sources, tracks: tracks, master: master)
}

func render(_ document: EditorDocument,
            range: ClosedRange<TimeInterval>? = nil,
            on renderer: RenderEngine = RenderEngine()) async throws -> PCMBlock {
    try await renderer.render(document, range: range, progress: { _ in })
}

/// Peak of a window of the render, in dBFS. Digital silence reads about -240.
func peak(_ block: PCMBlock, _ from: TimeInterval, _ to: TimeInterval) -> Double {
    SignalAnalysis.peakDBFS(block.slice(from...to))
}

func channelPeak(_ block: PCMBlock, _ index: Int) -> Double {
    var top: Float = 0
    for value in block.channel(index) { top = max(top, abs(value)) }
    return 20 * log10(Double(max(top, 1e-12)))
}

/// Printed, not asserted: the numbers behind the assertions, so a failure can
/// be read without re-deriving them.
func note(_ name: String, _ value: Double, _ unit: String = "dBFS") {
    print("  \(name): \(String(format: "%.3f", value)) \(unit)")
}

let silent = -200.0

// `banded` is three seconds of three different tones, so a window into it is
// identifiable by what is in it — a trim that reads the wrong second fails
// rather than measuring the same level in the wrong place.
let banded = joined([tone(200, -12, 1), tone(1000, -12, 1), tone(3000, -12, 1)])
let bandedSource = try await write(banded, named: "banded.wav", into: scratch)
let steady = try await write(tone(1000, -12, 3), named: "steady.wav", into: scratch)
let quieterSource = try await write(tone(1000, -24, 3), named: "quieter.wav", into: scratch)
let monoSource = try await write(tone(1000, -12, 3, channels: 1), named: "mono.wav", into: scratch)
let offRate = try await write(tone(1000, -12, 2, sampleRate: 44_100),
                              named: "off-rate.wav", into: scratch)

let decodedSteady = try AudioFileIO.decode(steady.url)
check("the WAV round trip is lossless, so sample-identity assertions mean something",
      decodedSteady.samples == tone(1000, -12, 3).samples,
      "the written file did not come back sample for sample")

// J0. The document the app opens today renders exactly what it always did.
//
// The one-source, one-track, one-clip document is what `EditorDocument(source:)`
// still builds, and it is what every user who never touches a second lane will
// ever render. Multitrack is a regression risk to it, so it is pinned first.
let plain = EditorDocument(source: steady)
let plainRender = try await render(plain)
check("one source, one track, one clip renders the source sample for sample",
      plainRender.samples == MoveProcessors.safetyClip(decodedSteady).samples,
      "\(plainRender.frameCount) frames rendered against \(decodedSteady.frameCount) decoded")
check("the default document's render keeps the source's own format",
      plainRender.channelCount == 2 && near(plainRender.sampleRate, rate, 0.5),
      "\(plainRender.channelCount)ch at \(plainRender.sampleRate)")

var plainWithMaster = plain
plainWithMaster.master = [Move(kind: .gain(dB: -6))]
let masterRender = try await render(plainWithMaster)
check("a master move still lands on the mix",
      near(SignalAnalysis.peakDBFS(masterRender), -18.0, 0.05),
      "peak \(SignalAnalysis.peakDBFS(masterRender))")

// J1. A clip at start 2.0 puts exact silence in the first two seconds and the
// decode, frame for frame, after them.
let placed = paper([steady], [lane([Clip(sourceID: steady.id, start: 2.0,
                                         sourceIn: 0, sourceOut: 3)])])
let placedRender = try await render(placed)
print("clip placement")
note("duration", placedRender.duration, "s")
note("peak 0.0-1.999s", peak(placedRender, 0, 1.999))
note("peak 2.1-4.9s", peak(placedRender, 2.1, 4.9))
check("a clip at start 2.0 makes a five second render out of a three second source",
      near(placedRender.duration, 5.0, 0.001), "\(placedRender.duration)s")
check("the first two seconds are digital silence",
      peak(placedRender, 0, 1.999) < silent,
      "peak \(peak(placedRender, 0, 1.999)) dBFS")
check("the clip's own audio is there after two seconds",
      near(peak(placedRender, 2.1, 4.9), -12.0, 0.05),
      "peak \(peak(placedRender, 2.1, 4.9)) dBFS")
let boundary = placedRender.frameIndex(at: 2.0)
check("the last silent frame is the one before 2.0s exactly",
      placedRender.samples[(boundary - 1) * 2] == 0,
      "frame \(boundary - 1) holds \(placedRender.samples[(boundary - 1) * 2])")
check("everything from 2.0s on is the source, frame for frame",
      Array(placedRender.samples[(boundary * 2)...]) == decodedSteady.samples,
      "\(placedRender.frameCount - boundary) frames against \(decodedSteady.frameCount)")

// J2. Two tracks sum. Muting one takes it back to the one-track render exactly.
//
// The tones are -12 dBFS rather than -6: two -6 dBFS tones sum to 1.0 and the
// safety clip starts at 0.95, so that probe would be measuring the clipper.
let both = paper([steady],
                 [lane([Clip(wholeOf: steady)]), lane([Clip(wholeOf: steady)])])
let bothRender = try await render(both)
var oneMuted = both
oneMuted.tracks[1].isMuted = true
let mutedRender = try await render(oneMuted)

print("summing")
note("one track", SignalAnalysis.peakDBFS(plainRender))
note("two tracks", SignalAnalysis.peakDBFS(bothRender))
note("second track muted", SignalAnalysis.peakDBFS(mutedRender))
check("two tracks carrying the same -12 dBFS tone sum to -6",
      near(SignalAnalysis.peakDBFS(bothRender), -6.02, 0.05),
      "measured \(SignalAnalysis.peakDBFS(bothRender))")
check("the sum is the doubling, sample for sample",
      bothRender.samples.count == plainRender.samples.count
        && zip(bothRender.samples, plainRender.samples).allSatisfy { abs($0 - 2 * $1) < 1e-6 })
check("muting one of them puts it back to -12",
      near(SignalAnalysis.peakDBFS(mutedRender), -12.0, 0.05),
      "measured \(SignalAnalysis.peakDBFS(mutedRender))")
check("a muted track renders identically to not being there at all",
      mutedRender.samples == plainRender.samples)

// J3. Solo is a filter over what is rendered, not an edit to the other tracks.
var soloed = paper([steady, quieterSource],
                   [lane([Clip(wholeOf: steady)]), lane([Clip(wholeOf: quieterSource)])])
let beforeSolo = try await render(soloed)
soloed.tracks[1].isSoloed = true
let soloRender = try await render(soloed)
let bOnly = try await render(paper([quieterSource], [lane([Clip(wholeOf: quieterSource)])]))
var unsoloed = soloed
unsoloed.tracks[1].isSoloed = false
let afterSolo = try await render(unsoloed)

print("solo")
note("both tracks", SignalAnalysis.peakDBFS(beforeSolo))
note("solo on B", SignalAnalysis.peakDBFS(soloRender))
note("B on its own", SignalAnalysis.peakDBFS(bOnly))
check("solo on B changes what comes out",
      soloRender.samples != beforeSolo.samples)
check("solo on B renders B and nothing else, sample for sample",
      soloRender.samples == bOnly.samples,
      "peak \(SignalAnalysis.peakDBFS(soloRender)) against B alone at "
      + "\(SignalAnalysis.peakDBFS(bOnly))")
check("track A goes inaudible without its own state changing",
      soloed.tracks[0].isMuted == false && soloed.tracks[0].isSoloed == false)
check("un-soloing restores exactly what was there",
      afterSolo.samples == beforeSolo.samples)

// J4. Trim. A clip on the middle second of a three second source.
let whole = try await render(paper([bandedSource], [lane([Clip(wholeOf: bandedSource)])]))
let middle = try await render(
    paper([bandedSource], [lane([Clip(sourceID: bandedSource.id, start: 0,
                                      sourceIn: 1, sourceOut: 2)])]))
print("trim")
note("trimmed duration", middle.duration, "s")
check("a clip trimmed to the middle second is one second long",
      near(middle.duration, 1.0, 0.001), "\(middle.duration)s")
check("and it is the middle second, frame for frame",
      middle.samples
        == Array(whole.samples[(whole.frameIndex(at: 1) * 2)..<(whole.frameIndex(at: 2) * 2)]))
check("the middle second is not the first second",
      middle.samples != Array(whole.samples[0..<(whole.frameIndex(at: 1) * 2)]))

// J5. Splitting a clip changes nothing at all.
//
// The strongest assertion in this section, and the one that covers a whole
// class of boundary bug rather than one instance of it: the two halves have to
// meet on the exact frame the whole clip would have had there. A split that is
// a frame out leaves a hole or a doubled frame that no level measurement, no
// duration check and no rendered frame would ever show.

func split(_ clip: Clip, at time: TimeInterval) -> [Clip] {
    // Exactly what EditorStore.splitClip does. If that drifts, this drifts with
    // it and stops proving anything, which is why it names the source.
    let offset = time - clip.start
    var right = clip
    right.id = UUID()
    right.start = clip.start + offset
    right.sourceIn = clip.sourceIn + offset
    right.fadeIn = 0
    right.fadeOut = min(clip.fadeOut, right.duration)
    var left = clip
    left.sourceOut = clip.sourceIn + offset
    left.fadeOut = 0
    left.fadeIn = min(clip.fadeIn, offset)
    return [left, right]
}

// The last row is adversarial and is the only one of the six that separates the
// two ways of computing where a clip lands. `start` sits 0.1 of a frame past a
// boundary and `sourceIn` sits 0.9 past one, and the split is half a frame
// long, so rounding `start` and `sourceIn` separately puts the second half one
// frame late and leaves a hole at output frame 50000. The five ordinary rows
// all pass either way — see the docstring's second note.
let adversarialStart = 1000.1 / rate
let adversarialIn = 500.9 / rate
print("split")
for (start, sourceIn, sourceOut, at) in [
    (0.0, 0.0, 3.0, 1.5),
    (0.0, 0.0, 3.0, 1.5000173),
    (1.3, 0.37, 2.61, 2.1),
    (1.3, 0.37, 2.61, 2.1000173),
    (0.7777777, 0.1111111, 2.9999, 1.6666666),
    (adversarialStart, adversarialIn, 60_000 / rate, adversarialStart + 24_000.45 / rate),
] {
    let clip = Clip(sourceID: bandedSource.id, start: start,
                    sourceIn: sourceIn, sourceOut: sourceOut)
    let unsplit = try await render(paper([bandedSource], [lane([clip])]))
    let cut = try await render(paper([bandedSource], [lane(split(clip, at: at))]))
    let same = unsplit.samples == cut.samples
    let firstDifference = zip(unsplit.samples, cut.samples)
        .enumerated().first { $0.element.0 != $0.element.1 }?.offset
    print("  start \(start) in \(sourceIn) split at \(at): "
          + "\(unsplit.frameCount) vs \(cut.frameCount) frames, identical \(same)")
    check("splitting a clip at \(at) renders the same samples as not splitting it",
          same,
          "\(unsplit.frameCount) frames against \(cut.frameCount); first difference at "
          + String(describing: firstDifference))
}

let twoClips = paper([bandedSource], [lane(split(Clip(wholeOf: bandedSource), at: 1.4))])
check("two clips on one source still render the whole source",
      try await render(twoClips).samples == whole.samples)

// J6. Overlapping clips on one track are both heard.
let overlapping = paper(
    [steady],
    [lane([Clip(sourceID: steady.id, start: 0, sourceIn: 0, sourceOut: 2),
           Clip(sourceID: steady.id, start: 1, sourceIn: 1, sourceOut: 3)])])
let overlapRender = try await render(overlapping)
print("overlap")
note("0.2-0.8s", peak(overlapRender, 0.2, 0.8))
note("1.2-1.8s", peak(overlapRender, 1.2, 1.8))
note("2.2-2.8s", peak(overlapRender, 2.2, 2.8))
check("two clips that overlap are both heard, so the overlap is 6 dB up",
      near(peak(overlapRender, 1.2, 1.8), -6.02, 0.05),
      "overlap peaks at \(peak(overlapRender, 1.2, 1.8))")
check("outside the overlap the level is unchanged",
      near(peak(overlapRender, 0.2, 0.8), -12.0, 0.05)
        && near(peak(overlapRender, 2.2, 2.8), -12.0, 0.05),
      "\(peak(overlapRender, 0.2, 0.8)) and \(peak(overlapRender, 2.2, 2.8))")

// J7. Clip gain, the clip's own move stack, and clip fades.
var gainClip = Clip(wholeOf: steady)
gainClip.gainDB = -6
let clipGainRender = try await render(paper([steady], [lane([gainClip])]))
check("a clip's gain is in the render",
      near(SignalAnalysis.peakDBFS(clipGainRender), -18.0, 0.05),
      "peak \(SignalAnalysis.peakDBFS(clipGainRender))")

var movedClip = Clip(wholeOf: steady)
movedClip.moves = [Move(kind: .gain(dB: -6))]
let clipMoveRender = try await render(paper([steady], [lane([movedClip])]))
check("a clip's own move stack is in the render",
      near(SignalAnalysis.peakDBFS(clipMoveRender), -18.0, 0.05),
      "peak \(SignalAnalysis.peakDBFS(clipMoveRender))")

var offClip = Clip(wholeOf: steady)
offClip.moves = [Move(kind: .gain(dB: -6), isEnabled: false)]
let clipOffRender = try await render(paper([steady], [lane([offClip])]))
check("a clip move switched off is not in the render",
      near(SignalAnalysis.peakDBFS(clipOffRender), -12.0, 0.05),
      "peak \(SignalAnalysis.peakDBFS(clipOffRender))")

// The fade has to reach zero at the *clip's* end, which is not the render's
// end here: a second track runs on past it.
var fading = Clip(sourceID: steady.id, start: 0, sourceIn: 0, sourceOut: 3)
fading.fadeOut = 0.5
fading.fadeCurve = .linear
let fadedOut = try await render(
    paper([steady, quieterSource],
          [lane([fading]),
           lane([Clip(sourceID: quieterSource.id, start: 3, sourceIn: 0, sourceOut: 2)])]))
let clipEnd = fadedOut.frameIndex(at: 3.0)
print("fade")
note("0.1-2.0s, before the fade", peak(fadedOut, 0.1, 2.0))
note("2.7-2.8s, 40% through the fade", peak(fadedOut, 2.7, 2.8))
note("the last frame of the clip", Double(abs(fadedOut.samples[(clipEnd - 1) * 2])), "linear")
check("the render runs past the fading clip, so this is the clip's end and not the file's",
      near(fadedOut.duration, 5.0, 0.001), "\(fadedOut.duration)s")
check("a fade out reaches zero at the clip's own end",
      abs(fadedOut.samples[(clipEnd - 1) * 2]) < 1e-6,
      "last frame \(fadedOut.samples[(clipEnd - 1) * 2])")
check("40% into a linear fade out the level is 0.6 of it",
      near(peak(fadedOut, 2.7, 2.8), -12.0 + 20 * log10(0.6), 0.3),
      "measured \(peak(fadedOut, 2.7, 2.8)), wanted \(-12.0 + 20 * log10(0.6))")
check("the fade leaves the front of the clip alone",
      near(peak(fadedOut, 0.1, 2.0), -12.0, 0.05), "\(peak(fadedOut, 0.1, 2.0))")

var fadingIn = Clip(wholeOf: steady)
fadingIn.fadeIn = 0.5
fadingIn.fadeCurve = .linear
let fadedIn = try await render(paper([steady], [lane([fadingIn])]))
// The level 20% in, and this line is load-bearing. "A fade in starts at zero"
// is unfalsifiable on a sine, whose first sample is zero whether anything faded
// it or not; a dropped fade-in walked straight through that version. The check
// below is the one that fails. Do not let this drift back to sample zero — see
// the docstring's first note.
note("20% into a linear fade in", peak(fadedIn, 0.05, 0.1))
check("20% into a linear fade in the level is 0.2 of it",
      near(peak(fadedIn, 0.05, 0.1), -12.0 + 20 * log10(0.2), 0.3),
      "measured \(peak(fadedIn, 0.05, 0.1)), wanted \(-12.0 + 20 * log10(0.2))")
check("a fade in starts at zero",
      abs(fadedIn.samples[0]) < 1e-6, "first frame \(fadedIn.samples[0])")
check("a fade in leaves the end of the clip alone",
      near(peak(fadedIn, 1.0, 3.0), -12.0, 0.05), "\(peak(fadedIn, 1.0, 3.0))")

// J8. Track gain, the track's move stack, and pan.
let trackGainRender = try await render(
    paper([steady], [lane([Clip(wholeOf: steady)], gain: -6)]))
check("a track's gain is in the render",
      near(SignalAnalysis.peakDBFS(trackGainRender), -18.0, 0.05),
      "peak \(SignalAnalysis.peakDBFS(trackGainRender))")

let trackMoveRender = try await render(
    paper([steady], [lane([Clip(wholeOf: steady)], moves: [Move(kind: .gain(dB: -6))])]))
check("a track's own move stack is in the render",
      near(SignalAnalysis.peakDBFS(trackMoveRender), -18.0, 0.05),
      "peak \(SignalAnalysis.peakDBFS(trackMoveRender))")

let hardLeft = try await render(paper([steady], [lane([Clip(wholeOf: steady)], pan: -1)]))
let hardRight = try await render(paper([steady], [lane([Clip(wholeOf: steady)], pan: 1)]))
let centre = try await render(paper([steady], [lane([Clip(wholeOf: steady)], pan: 0)]))
let halfLeft = try await render(paper([steady], [lane([Clip(wholeOf: steady)], pan: -0.5)]))
print("pan")
note("hard left, left channel", channelPeak(hardLeft, 0))
note("hard left, right channel", channelPeak(hardLeft, 1))
note("hard right, left channel", channelPeak(hardRight, 0))
note("hard right, right channel", channelPeak(hardRight, 1))
note("half left, left channel", channelPeak(halfLeft, 0))
note("half left, right channel", channelPeak(halfLeft, 1))
check("pan hard left puts the signal in the left channel only",
      near(channelPeak(hardLeft, 0), -12.0, 0.05) && channelPeak(hardLeft, 1) < silent,
      "left \(channelPeak(hardLeft, 0)), right \(channelPeak(hardLeft, 1))")
check("pan hard right is the other way round",
      near(channelPeak(hardRight, 1), -12.0, 0.05) && channelPeak(hardRight, 0) < silent,
      "left \(channelPeak(hardRight, 0)), right \(channelPeak(hardRight, 1))")
check("pan at centre is unity on both sides, sample for sample",
      centre.samples == plainRender.samples)
// The law, not just the extremes. Melo's pan is a balance: the near side stays
// at unity and only the far side is attenuated. This is the assertion that
// separates it from constant-power, which agrees at hard left and at centre.
check("half left leaves the left alone and takes 6 dB off the right",
      near(channelPeak(halfLeft, 0), -12.0, 0.05)
        && near(channelPeak(halfLeft, 1), -18.02, 0.05),
      "left \(channelPeak(halfLeft, 0)), right \(channelPeak(halfLeft, 1))")

let pannedMono = try await render(
    paper([monoSource], [lane([Clip(wholeOf: monoSource)], pan: -1)]))
check("panning a mono timeline widens the mix rather than going inert",
      pannedMono.channelCount == 2 && channelPeak(pannedMono, 1) < silent,
      "\(pannedMono.channelCount)ch, right \(channelPeak(pannedMono, 1))")
let unpannedMono = try await render(paper([monoSource], [lane([Clip(wholeOf: monoSource)])]))
check("a mono timeline nobody panned stays mono",
      unpannedMono.channelCount == 1, "\(unpannedMono.channelCount)ch")

// J9. Sources whose format is not the mix's.
let mixedRate = paper([steady, offRate],
                      [lane([Clip(wholeOf: steady)]),
                       lane([Clip(sourceID: offRate.id, start: 3, sourceIn: 0, sourceOut: 2)])])
let mixedRender = try await render(mixedRate)
print("formats")
note("mixed rate render duration", mixedRender.duration, "s")
note("mixed rate render rate", mixedRender.sampleRate, "Hz")
check("a 44.1 kHz clip on a 48 kHz timeline occupies the two seconds it claims",
      near(mixedRender.duration, 5.0, 0.005),
      "\(mixedRender.duration)s — 4.84 would mean its samples were poured in raw")
check("the mix keeps the first source's rate",
      near(mixedRender.sampleRate, 48_000, 0.5), "\(mixedRender.sampleRate)")
check("the 44.1 kHz clip is audible where it was placed",
      near(peak(mixedRender, 3.2, 4.8), -12.0, 0.3),
      "peak \(peak(mixedRender, 3.2, 4.8))")

let mixedChannelRender = try await render(
    paper([steady, monoSource],
          [lane([Clip(wholeOf: steady)]), lane([Clip(wholeOf: monoSource)])]))
check("a mono source on a stereo timeline arrives on both sides",
      mixedChannelRender.channelCount == 2
        && near(channelPeak(mixedChannelRender, 0), channelPeak(mixedChannelRender, 1), 0.01)
        && near(channelPeak(mixedChannelRender, 0), -6.02, 0.05),
      "\(mixedChannelRender.channelCount)ch, "
      + "\(channelPeak(mixedChannelRender, 0)) / \(channelPeak(mixedChannelRender, 1))")

// J10. A range render — what the transport plays from — is a slice of the one
// render, on a document with something happening on every layer.
let busy = paper([steady, quieterSource, bandedSource],
                 [lane([Clip(sourceID: steady.id, start: 0, sourceIn: 0.4, sourceOut: 2.2)],
                       gain: -3, pan: -0.4),
                  lane([Clip(sourceID: quieterSource.id, start: 1.1, sourceIn: 0, sourceOut: 3)],
                       gain: 2),
                  lane([Clip(sourceID: bandedSource.id, start: 0.3, sourceIn: 0.9,
                             sourceOut: 2.7)])],
                 master: [Move(kind: .gain(dB: -2))])
let busyFull = try await render(busy)
let busyRange = try await render(busy, range: 1.0...2.0)
check("a range render is the same samples as the same window of the full render",
      busyRange.samples == busyFull.slice(1.0...2.0).samples,
      "\(busyRange.frameCount) frames against \(busyFull.slice(1.0...2.0).frameCount)")

// J11. Nothing to render.
var refused = false
do {
    _ = try await render(paper([steady], [lane([])]))
} catch {
    refused = true
}
check("a timeline with no clips says so rather than returning silence", refused)

// J12. The decode is paid for once per source.
//
// The correctness half is free and always runs: eight adjacent tiles of one
// source have to reconstruct it. The cost half is timing — the pool is private
// and there is nothing else to observe — and timing is opt-in here rather than
// in the gate. See the docstring's note on `MELO_VERIFY_TIMING`.
var tiles: [Clip] = []
for step in 0..<8 {
    tiles.append(Clip(sourceID: steady.id,
                      start: Double(step) * (steady.duration / 8),
                      sourceIn: Double(step) * (steady.duration / 8),
                      sourceOut: Double(step + 1) * (steady.duration / 8)))
}
let tiled = try await render(paper([steady], [lane(tiles)]))
check("eight adjacent tiles of one source reconstruct it, frame for frame",
      tiled.samples == plainRender.samples,
      "\(tiled.frameCount) frames against \(plainRender.frameCount)")

if ProcessInfo.processInfo.environment["MELO_VERIFY_TIMING"] == "1" {
    func seconds(_ body: () async throws -> Void) async rethrows -> Double {
        let began = Date()
        try await body()
        return Date().timeIntervalSince(began)
    }

    let long = try await write(tone(440, -12, 90), named: "long.wav", into: scratch)
    let engineA = RenderEngine()
    let oneClipDocument = paper([long], [lane([Clip(wholeOf: long)])])
    let coldOne = try await seconds { _ = try await render(oneClipDocument, on: engineA) }
    let warmOne = try await seconds { _ = try await render(oneClipDocument, on: engineA) }

    var wide: [Clip] = []
    for step in 0..<8 {
        wide.append(Clip(sourceID: long.id,
                         start: Double(step) * (long.duration / 8),
                         sourceIn: Double(step) * (long.duration / 8),
                         sourceOut: Double(step + 1) * (long.duration / 8)))
    }
    let engineB = RenderEngine()
    let eightClipDocument = paper([long], [lane(wide)])
    let coldEight = try await seconds { _ = try await render(eightClipDocument, on: engineB) }

    print("decode cost")
    note("cold render, 1 clip", coldOne, "s")
    note("warm render, 1 clip", warmOne, "s")
    note("cold render, 8 clips on the same source", coldEight, "s")
    // Three, not eight: the claim is that this is not linear in the clip count,
    // and a threshold sitting just under the machine's own noise is a flake.
    check("eight clips on one source do not cost eight decodes",
          coldEight < coldOne * 3.0,
          "one clip cold \(coldOne)s, eight clips cold \(coldEight)s")
    check("the decode is kept between renders",
          warmOne < coldOne * 0.6,
          "cold \(coldOne)s, warm \(warmOne)s")

    // EditorClipWaveforms asks this same engine about one source at a time,
    // through a synthetic EditorDocument(source:) naming only that one. That
    // must not cost the mix its other decodes — a lane being zoomed would
    // otherwise make the next render of the whole timeline cold again. Three
    // sources, so a prune keyed on the synthetic document throws two of the
    // three decodes away and the difference is not a margin call.
    let secondLong = try await write(tone(660, -12, 90), named: "long-two.wav", into: scratch)
    let thirdLong = try await write(tone(880, -12, 90), named: "long-three.wav", into: scratch)
    let engineC = RenderEngine()
    let trio = paper([long, secondLong, thirdLong],
                     [lane([Clip(wholeOf: long)]),
                      lane([Clip(sourceID: secondLong.id, start: 0, sourceIn: 0, sourceOut: 90)]),
                      lane([Clip(sourceID: thirdLong.id, start: 0, sourceIn: 0, sourceOut: 90)])])
    let trioCold = try await seconds { _ = try await render(trio, on: engineC) }
    let trioWarm = try await seconds { _ = try await render(trio, on: engineC) }
    _ = try await render(EditorDocument(source: thirdLong), on: engineC)  // one lane's waveform
    let trioAfterSingle = try await seconds { _ = try await render(trio, on: engineC) }
    note("three sources, cold", trioCold, "s")
    note("three sources, warm", trioWarm, "s")
    note("three sources after a one-source render on the same engine", trioAfterSingle, "s")
    check("asking the engine about one source does not evict the rest of the pool",
          trioAfterSingle < trioCold * 0.35,
          "cold \(trioCold)s, warm \(trioWarm)s, after a single-source render "
          + "\(trioAfterSingle)s")
} else {
    print("decode cost: timing checks skipped — set MELO_VERIFY_TIMING=1 to run them")
}

// ---------------------------------------------------------------------------

for failure in failures { print("FAIL \(failure)") }
if failures.isEmpty {
    print("OK \(failures.count)")
} else {
    exit(1)
}
"""


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

    with tempfile.TemporaryDirectory(prefix="melo-verify-cutting-room-") as tmp:
        work = Path(tmp)
        (work / "main.swift").write_text(MAIN_SWIFT)
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
                "Melo Edit's DSP checks did not compile:\n        "
                + "\n        ".join(errors or compiled.stderr.splitlines()[:12])
            )
            return

        result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=600)
        reported = [
            line[len("FAIL "):] for line in result.stdout.splitlines() if line.startswith("FAIL ")
        ]
        failures.extend(reported)
        if result.returncode != 0 and not reported:
            failures.append(
                f"Melo Edit's DSP checks exited {result.returncode} with no verdict: "
                f"{(result.stderr.strip() or result.stdout.strip())[:300]}"
            )


run_swift_checks()


# ---------------------------------------------------------------------------
# 2. Rendered. Read the pixels the harness just produced.
# ---------------------------------------------------------------------------
#
# The snapshot directory is chosen by whoever invokes dev-verify.sh and is not
# passed down, so it is found the same way every other verify script finds it:
# the harness writes `_complete` last, and the verify loop runs inside the same
# build lock as the render. Standalone, the newest `_complete` may belong to
# some other experiment, which is what the mtime guard below is for.

FRAME_INPUTS = [
    "Sources/Melo/Utilities/SnapshotScenes.swift",
    "Sources/Melo/Editor/Analysis/EQCurveView.swift",
    "Sources/Melo/Editor/Analysis/EQResponseCurve.swift",
    "Sources/Melo/Editor/Analysis/DestinationPicker.swift",
    "Sources/Melo/Editor/Analysis/MoveProposer.swift",
    "Sources/Melo/Editor/Analysis/DestinationCatalogue.swift",
    "Sources/Melo/Editor/Views/Stack/MoveStackView.swift",
]

REQUIRED_FRAMES = [
    "cutting-room-eqcurve-flat.png",
    "cutting-room-eqcurve-probe.png",
    "cutting-room-destination-quiet.png",
    "cutting-room-destination-compliant.png",
    "cutting-room-stack-disables-before.png",
    "cutting-room-stack-disables-after.png",
]

# The scene geometry the pixel checks depend on, restated here rather than
# imported: an assertion that reads its expectations out of the thing it is
# checking is not an assertion. If `SnapshotScenes.swift` changes either of
# these, this file has to change with it, deliberately.
EQ_SCENE_SIZE = (480.0, 150.0)
EQ_CANVAS_HEIGHT = 108.0

# `EQCurveView`'s axes, computed here from first principles so the check does
# not borrow the arithmetic it is testing.
EQ_MIN_HZ = 20.0
EQ_MAX_HZ = 20000.0
EQ_DISPLAY_RANGE_DB = 15.0
EQ_CURVE_POINTS = 240
PROBE_HZ = 1000.0
PROBE_GAIN_DB = 9.0
# `EQCurveView` strokes the response at 1.6pt with a round cap, so the topmost
# lit pixel sits half a line width above the path it was drawn along. Named
# rather than absorbed into the tolerance, so the tolerance below stays a
# statement about how wrong the *gain* may be and not a number with a drawing
# constant hidden inside it. Measured on the first real render of these two
# frames: with this subtracted the peak lands 0.003 of the canvas from where the
# arithmetic puts it, and without it, 0.010.
EQ_STROKE_HALF_WIDTH_PT = 0.8
# +/-0.9 dB vertically and about a fifth of an octave horizontally.
EQ_TOLERANCE = 0.03


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


def frequency_position(hz: float) -> float:
    low, high = math.log10(EQ_MIN_HZ), math.log10(EQ_MAX_HZ)
    return (math.log10(hz) - low) / (high - low)


def vertical_position(db: float) -> float:
    return (EQ_DISPLAY_RANGE_DB - db) / (EQ_DISPLAY_RANGE_DB * 2)


def provenance_band_top(image) -> int:
    """First row of the dark-red provenance band, i.e. the end of the content.

    Read rather than assumed: the band's height depends on how much its own
    text wraps, so a fixed fraction of the image is a fraction of a number that
    moves whenever a scene's note gets longer.
    """
    rgb = image.convert("RGB").load()
    for y in range(image.height):
        r, g, b = rgb[10, y]
        if r > 100 and g < 60 and b < 60:
            return y
    return image.height


def control_noise(frames: Path, name: str) -> float | None:
    """The fraction this family moved with nothing done to it, from this run."""
    log = frames / "_transitions.log"
    if not log.is_file():
        return None
    pattern = re.compile(
        re.escape(f"{name}-after vs {name}-before") + r":\s*([0-9.]+)% of pixels moved"
    )
    for line in log.read_text(errors="replace").splitlines():
        found = pattern.search(line)
        if found:
            return float(found.group(1)) / 100.0
    return None


def changed_fraction(left, right) -> float | None:
    """Fraction of differing pixels across the two frames' *content*.

    The provenance band is excluded, and that is not tidiness. The band's height
    is a function of how far its own text wraps, so two frames of the same pane
    come back different overall heights the moment their scene notes differ in
    length — measured on the first real render of these two, at 1020 and 1080
    pixels. Comparing whole images made the check fail for a reason that has
    nothing to do with what it is about.
    """
    if left.width != right.width:
        return None
    height = min(provenance_band_top(left), provenance_band_top(right))
    if height < 8:
        return None
    a = left.convert("RGB").load()
    b = right.convert("RGB").load()
    width = left.width
    moved = 0
    for y in range(height):
        for x in range(width):
            pa, pb = a[x, y], b[x, y]
            if abs(pa[0] - pb[0]) > 8 or abs(pa[1] - pb[1]) > 8 or abs(pa[2] - pb[2]) > 8:
                moved += 1
    return moved / float(width * height)


def check_eq_curve(frames: Path) -> None:
    """The drawn response peaks where the band says it should.

    Subtracting the flat frame from the one-band frame removes the grid, the
    decade labels and the recessed ground, all of which are identical in both.
    What survives is the response of a single +9 dB peaking band at 1 kHz, and
    the highest surviving pixel is the top of it. A curve drawn from anything
    other than `BiquadMath`'s coefficients — a straight line, a hand-rolled
    bell, a mis-scaled axis, a dropped preamp — does not land there.
    """
    from PIL import Image

    flat = Image.open(frames / "cutting-room-eqcurve-flat.png").convert("RGB")
    probe = Image.open(frames / "cutting-room-eqcurve-probe.png").convert("RGB")
    # Widths only. The heights are content plus a provenance band whose depth
    # depends on how far its own text wraps, so two scenes with notes of
    # different lengths are legitimately different heights.
    if flat.width != probe.width:
        failures.append(
            f"the two EQ curve frames are different widths ({flat.width} and {probe.width}); "
            "they are meant to differ only in the bands"
        )
        return

    scale = probe.width / EQ_SCENE_SIZE[0]
    canvas_rows = int(EQ_CANVAS_HEIGHT * scale)
    if canvas_rows < 8 or canvas_rows > probe.height:
        failures.append(
            f"cutting-room-eqcurve-probe is {probe.size}, which is not a "
            f"{EQ_SCENE_SIZE[0]}x{EQ_SCENE_SIZE[1]}pt scene — the pixel geometry this "
            "check depends on has changed"
        )
        return

    a, b = flat.load(), probe.load()
    peak_row: int | None = None
    peak_column = 0
    strong = 0
    for y in range(canvas_rows):
        lit = [
            x
            for x in range(probe.width)
            if max(
                abs(a[x, y][0] - b[x, y][0]),
                abs(a[x, y][1] - b[x, y][1]),
                abs(a[x, y][2] - b[x, y][2]),
            ) > 40
        ]
        strong += len(lit)
        # Two, not one: a single differing pixel above the curve is an
        # antialiasing edge, and the apex of a stroked line is several wide.
        if peak_row is None and len(lit) >= 2:
            peak_row = y
            peak_column = lit[len(lit) // 2]

    if peak_row is None:
        failures.append(
            "cutting-room-eqcurve-probe is pixel-identical to cutting-room-eqcurve-flat "
            "inside the canvas. A +9 dB band at 1 kHz drew nothing, so the response is "
            "not being drawn from the bands at all."
        )
        return

    got_x = peak_column / float(probe.width)
    got_y = peak_row / float(canvas_rows)

    # The polyline is sampled at 240 log-spaced points, so the peak lands on the
    # sample nearest 1 kHz rather than at 1 kHz exactly.
    nearest = round(frequency_position(PROBE_HZ) * (EQ_CURVE_POINTS - 1))
    want_x = nearest / float(EQ_CURVE_POINTS - 1)
    want_y = vertical_position(PROBE_GAIN_DB) - EQ_STROKE_HALF_WIDTH_PT / EQ_CANVAS_HEIGHT
    drawn_db = EQ_DISPLAY_RANGE_DB - (
        got_y + EQ_STROKE_HALF_WIDTH_PT / EQ_CANVAS_HEIGHT
    ) * 2 * EQ_DISPLAY_RANGE_DB

    if abs(got_x - want_x) > EQ_TOLERANCE:
        failures.append(
            "cutting-room-eqcurve-probe: the drawn peak is at "
            f"{got_x:.3f} of the width, and {PROBE_HZ:.0f} Hz on a log axis from "
            f"{EQ_MIN_HZ:.0f} to {EQ_MAX_HZ:.0f} Hz is at {want_x:.3f}. The curve is not "
            "drawn against the frequency axis its bands are placed on."
        )
    if abs(got_y - want_y) > EQ_TOLERANCE:
        failures.append(
            "cutting-room-eqcurve-probe: the drawn peak is at "
            f"{got_y:.3f} of the canvas height, and +{PROBE_GAIN_DB:.0f} dB on a "
            f"+/-{EQ_DISPLAY_RANGE_DB:.0f} dB axis is at {want_y:.3f} once the stroke's own "
            f"half width is allowed for — so {drawn_db:+.1f} dB was drawn. "
            "The curve is not showing the gain the band carries."
        )
    if strong < 200:
        failures.append(
            f"cutting-room-eqcurve-probe: only {strong} pixels in the whole canvas differ "
            "from the flat frame, which is far too few for a bell three octaves wide"
        )


def check_destination_reads_the_measurement(frames: Path) -> None:
    """Same source, same destination, different measurement — different pane.

    `DestinationPicker` draws exactly one thing from the analysis: the proposal,
    through `MoveProposer`. Everything else on the pane is a function of the
    catalogue and the source, which are identical in both frames. So if the two
    come back the same, the button has stopped asking what is wrong with the
    file and has become a preset — which is the failure this whole feature was
    shaped to avoid, and which nothing else here can see.
    """
    from PIL import Image

    quiet = Image.open(frames / "cutting-room-destination-quiet.png")
    compliant = Image.open(frames / "cutting-room-destination-compliant.png")
    moved = changed_fraction(quiet, compliant)
    if moved is None:
        failures.append(
            "the two destination frames are different widths and cannot be compared; they "
            "are meant to be the same pane at the same size, differing only in the measurement"
        )
        return

    # Calibrated against this run's own negative control rather than a number
    # chosen here: the control is two captures of this pane with nothing done
    # between them, so it is exactly the noise a dead picker would produce.
    noise = control_noise(frames, "control-destination")
    floor = max((noise or 0.0) * 5.0, 0.001)
    if moved <= floor:
        failures.append(
            "cutting-room-destination-quiet and -compliant differ by only "
            f"{moved * 100:.4f}% of pixels (floor {floor * 100:.4f}%"
            + (f", from control-destination at {noise * 100:.4f}%" if noise is not None else "")
            + "). The picker is drawing the same answer for a file 6 dB under the "
            "target and one already inside every tolerance, so it is not reading the "
            "measurement."
        )


def check_disabled_move_dims(frames: Path) -> None:
    """A move switched off stays on the list and goes dim.

    Both halves matter and the harness can only prove that *something* changed.
    Vanishing would make A/B listening impossible, which is the entire reason the
    stack is non-destructive; getting brighter would mean the treatment is wired
    backwards.

    **The first version of this could not fail on the half that matters most.**
    It counted ink over the whole page and asked for a 30% drop; one row of nine
    is about 12% of the page, so a move that vanished outright passed. A check
    whose stated purpose cannot fire is the defect class this whole script exists
    for, so it now differences the two frames, finds the band of rows that
    actually moved, and measures inside that band alone.
    """
    from PIL import Image

    before_image = Image.open(frames / "cutting-room-stack-disables-before.png")
    after_image = Image.open(frames / "cutting-room-stack-disables-after.png")
    if before_image.width != after_image.width:
        failures.append(
            "the two stack frames are different widths and cannot be compared"
        )
        return

    height = min(provenance_band_top(before_image), provenance_band_top(after_image))
    # The switch and the chevron sit on the right and stay full strength on
    # purpose — the switch is what you press to bring the move back — so the left
    # of the row is exactly the content the dim applies to.
    right = int(before_image.width * 0.7)

    before_grey = before_image.convert("L")
    after_grey = after_image.convert("L")
    b, a = before_grey.load(), after_grey.load()

    changed = [
        y
        for y in range(height)
        if sum(1 for x in range(right) if abs(b[x, y] - a[x, y]) > 25) >= 3
    ]
    if not changed:
        failures.append(
            "cutting-room-stack-disables: nothing in the left of the pane moved when a move "
            "was switched off. The row is not reading `isEnabled`."
        )
        return

    # Runs of adjacent changed rows, merged across the leading between a row's
    # own lines of text. The long one is the row that was switched off; a short
    # one higher up is the "1 off" counter appearing in the control strip, and
    # measuring that instead would say nothing about the row.
    #
    # The merge gap is why this is not four pixels. Measured on the first real
    # pair: a disabled row came back as *five* runs — title, summary and two
    # lines of rationale — separated by 9 to 16 rows of unlit leading, and the
    # longest of the five was 21 rows carrying 507 bright pixels. Picking one
    # line of a row and calling it the row is luck; a smaller line would have
    # tripped the "not a drawn row" guard below and failed a frame that was
    # correct. Rows in this pane sit about 120 rows apart and the counter was
    # 184 away, so a gap scaled to the frame separates rows while closing
    # leading.
    merge_gap = max(8, height // 40)
    runs: list[tuple[int, int]] = []
    start = previous = changed[0]
    for y in changed[1:]:
        if y - previous > merge_gap:
            runs.append((start, previous))
            start = y
        previous = y
    runs.append((start, previous))
    top, bottom = max(runs, key=lambda run: run[1] - run[0])

    if bottom - top > height * 0.6:
        failures.append(
            f"cutting-room-stack-disables: {bottom - top} of {height} rows moved when one "
            "move was switched off. That is the whole pane relaying out, not a row dimming."
        )
        return

    def ink(pixels) -> tuple[int, int]:
        bright = present = 0
        for y in range(top, bottom + 1):
            for x in range(right):
                value = pixels[x, y]
                if value > 45:
                    present += 1
                if value > 150:
                    bright += 1
        return bright, present

    before_bright, before_present = ink(b)
    after_bright, after_present = ink(a)

    if before_bright < 200:
        failures.append(
            f"cutting-room-stack-disables: the band that moved (rows {top}–{bottom}) carried "
            f"only {before_bright} bright pixels before the move was switched off. Whatever "
            "changed, it was not a drawn row going dim."
        )
        return
    if after_bright > before_bright * 0.25:
        failures.append(
            f"cutting-room-stack-disables: rows {top}–{bottom} kept {after_bright} bright "
            f"pixels of {before_bright} when the move was switched off. A disabled move is "
            "meant to dim to roughly 0.4 of its ink, which leaves none of it bright."
        )
    if after_present < before_present * 0.4:
        failures.append(
            f"cutting-room-stack-disables: rows {top}–{bottom} kept {after_present} lit "
            f"pixels of {before_present}. The row is meant to stay on the list, not leave "
            "it — turning a move off and listening is what the stack is for."
        )


def run_frame_checks() -> None:
    try:
        from PIL import Image  # noqa: F401
    except ImportError:
        failures.append("Pillow is not installed; the rendered assertions cannot run")
        return

    frames = locate_frames()
    if frames is None:
        failures.append(
            "no rendered frames found — run ./scripts/dev-verify.sh <dir> first; these "
            "claims are about pixels and cannot be checked from source"
        )
        return

    missing = [name for name in REQUIRED_FRAMES if not (frames / name).is_file()]
    if missing:
        failures.append(
            f"frames in {frames} are missing {missing} — either the render predates the "
            "Melo Edit scenes or a scene was renamed without updating this script"
        )
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

    check_eq_curve(frames)
    check_destination_reads_the_measurement(frames)
    check_disabled_move_dims(frames)


run_frame_checks()


# ---------------------------------------------------------------------------
# 3. Structural. Only where neither of the above can reach.
# ---------------------------------------------------------------------------

def function_body(text: str, signature: str) -> str | None:
    """The braced body of the first function whose declaration contains `signature`."""
    start = text.find(signature)
    if start < 0:
        return None
    opening = text.find("{", start)
    if opening < 0:
        return None
    depth = 0
    for index in range(opening, len(text)):
        if text[index] == "{":
            depth += 1
        elif text[index] == "}":
            depth -= 1
            if depth == 0:
                return text[opening + 1:index]
    return None


# Every `MoveKind` has to become audio somewhere, and its arm has to *do*
# something. A missing arm is a build error while the switch is exhaustive; an
# arm quietly emptied to `return block` is not, and it is the exact shape the
# anchor records — a rule that is still correct and a wire that is cut. So the
# arms are read as spans and each is required to reach a processor.
editor_types = read("Sources/Melo/Editor/Core/EditorTypes.swift")
render_engine = read("Sources/Melo/Editor/DSP/RenderEngine.swift")

kind_block = editor_types.split("enum MoveKind", 1)
declared_kinds: list[str] = []
if len(kind_block) == 2:
    body = kind_block[1]
    end = body.find("\nenum ")
    declared_kinds = re.findall(r"^\s*case (\w+)", body[: end if end > 0 else len(body)], re.M)

# "This arm turns the move into audio." Anything that reaches a processor, the
# limiter, or another arm of the same walk counts; nothing else does.
DOES_WORK = ("MoveProcessors.", "LookaheadLimiter.", "applyLevel(", "apply(")


def switch_arms(text: str) -> list[tuple[list[str], str]]:
    """Every `case .a, .b:` arm in `text`, as (case names, arm body).

    An arm ends at the next arm *or* at the brace that closes its switch,
    whichever comes first. The second half is load-bearing: the last arm of a
    switch is followed by the next function's declaration, and reading that as
    part of the arm let a `default:` that had stopped delegating borrow the word
    `applyLevel` out of the signature below it and pass.
    """
    matches = list(re.finditer(r"^[ \t]*(?:case ((?:\s*\.\w+[^\n:]*?)+)|default)\s*:", text, re.M))
    arms: list[tuple[list[str], str]] = []
    for index, match in enumerate(matches):
        stop = matches[index + 1].start() if index + 1 < len(matches) else len(text)
        body = text[match.end():stop]
        depth = 0
        for position, character in enumerate(body):
            if character in "{([":
                depth += 1
            elif character in "})]":
                if depth == 0:
                    body = body[:position]
                    break
                depth -= 1
        names = re.findall(r"\.(\w+)", match.group(1) or "")
        arms.append((names, body))
    return arms


if len(declared_kinds) < 10:
    failures.append(
        f"could not read MoveKind's cases out of EditorTypes.swift (found {declared_kinds})"
    )
elif not render_engine:
    pass  # `read` already recorded the missing file
else:
    arms = switch_arms(render_engine)
    for kind in declared_kinds:
        matching = [arm for names, arm in arms if kind in names]
        if not matching:
            failures.append(
                f"RenderEngine names no `.{kind}` at all — that move renders as nothing, and "
                "every pure-function test of it still passes"
            )
        elif not any(any(token in arm for token in DOES_WORK) for arm in matching):
            failures.append(
                f"RenderEngine's `.{kind}` arm reaches no processor. The move is accepted, "
                "stored, drawn in the stack and rendered as silence."
            )
    # A `default:` is fine when it hands the move on and fatal when it swallows
    # one, and the difference is one line of its body.
    for names, arm in arms:
        if names:
            continue
        if not any(token in arm for token in DOES_WORK) and "throw" not in arm:
            failures.append(
                "RenderEngine has a `default:` arm in a move switch that neither delegates "
                "nor throws, so a MoveKind added later falls into it and renders as nothing"
            )

# The other half of the same failure: a processor that nothing calls. Every one
# of these is a pure function with tests above it, which is precisely the state
# the four severed wires were in when eleven verify scripts went green.
processors = read("Sources/Melo/Editor/DSP/MoveProcessors.swift")
callers = "\n".join(
    path.read_text(errors="replace")
    for path in sorted(sources.rglob("*.swift"))
    if path.name != "MoveProcessors.swift"
)
for name in re.findall(r"^\s{4}static func (\w+)\(", processors, re.M):
    if f"MoveProcessors.{name}(" not in callers:
        failures.append(
            f"MoveProcessors.{name} is called from nowhere in Sources/Melo. Either the wire "
            "to it was cut or it should not exist."
        )

# The two views the rendered checks read. The pixel assertions above prove the
# behaviour; these name the wire, so a failure says which end came loose.
curve_view = read("Sources/Melo/Editor/Analysis/EQCurveView.swift")
draw_curve = function_body(curve_view, "func drawCurve(")
if draw_curve is None:
    failures.append("EQCurveView has no drawCurve — the response is drawn somewhere else now")
elif "EQResponseCurve.curve(" not in draw_curve:
    failures.append(
        "EQCurveView.drawCurve no longer evaluates EQResponseCurve.curve, so the picture "
        "and the coefficients have stopped being the same arithmetic"
    )

picker = read("Sources/Melo/Editor/Analysis/DestinationPicker.swift")
if "MoveProposer.propose(" not in picker:
    failures.append(
        "DestinationPicker never calls MoveProposer.propose — the button is no longer "
        "computing its answer from the measurement"
    )

# The scenes the rendered tier depends on have to still be in the list. A
# renamed scene would otherwise take its assertion with it quietly.
scene_list = read("Sources/Melo/Utilities/SnapshotScenes.swift")
for name in REQUIRED_FRAMES:
    stem = name[: -len(".png")]
    for suffix in ("-before", "-after"):
        if stem.endswith(suffix):
            stem = stem[: -len(suffix)]
    if f'"{stem}"' not in scene_list:
        failures.append(
            f"SnapshotScenes.swift no longer declares a scene named \"{stem}\", which "
            "this script reads the pixels of"
        )


# ---------------------------------------------------------------------------

if failures:
    print("Melo Edit checks failed:")
    for failure in failures:
        print(f"  - {failure}")
    sys.exit(1)

print("Melo Edit DSP, proposals, rendered arrival and wiring checks passed.")
