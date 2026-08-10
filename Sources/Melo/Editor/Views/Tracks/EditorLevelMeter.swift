// Melo/Editor/Views/Tracks/EditorLevelMeter.swift
//
// How loud a lane is, as a bar, and the decibel ladder Full mode puts under it.
//
// ## What this meter is, and what it is not
//
// It is a **level meter over the whole lane**, not a live output meter. It
// reads the same drawing the waveform reads — `EditorClipWaveforms`' overview
// for each source the track's clips point at — takes the loudest peak and the
// mean RMS across it, and applies the track's own fader. So it moves when the
// gain moves, it dims when solo elsewhere silences the lane, and two lanes
// carrying different audio read differently. It does not sweep while playback
// runs.
//
// **A live meter is not available from here and pretending otherwise would be
// the dead-control failure this project already shipped once.** Metering during
// playback needs a tap installed on the engine, which lives in
// `Editor/Views/Waveform/EditorPlayback.swift` — a file this piece does not
// own. The patch that would light these bars up in real time is named in the
// run report rather than half-applied here. What is drawn is true; it is simply
// static, and the accessibility value says "loudest" rather than "level" so a
// screen-reader user is not told it is following the playhead either.

import SwiftUI

/// Peak and RMS for one lane, in dBFS.
///
/// A value type with the arithmetic on it rather than a method on the view, so
/// the numbers can be reasoned about without a hosting view — and so the two
/// callers (a track header, the master panel) cannot compute "loudest" two
/// different ways.
struct EditorLevelReading: Equatable, Sendable {

    /// The loudest single bucket, in dBFS. `-.infinity` for silence.
    var peakDB: Double
    /// Mean RMS across every bucket, in dBFS.
    var rmsDB: Double

    static let silent = EditorLevelReading(peakDB: -.infinity, rmsDB: -.infinity)

    /// The bottom of the meter. −48 rather than −60: below about −48 a lane is
    /// inaudible under anything else in the mix, and stretching the scale down
    /// to −60 spends a fifth of a 110pt bar on the part nobody is looking at.
    /// Speech at a sensible working level sits between −24 and −6, which this
    /// range puts in the right-hand half where the eye already is.
    static let floorDB: Double = -48

    /// Where a reading sits along the meter, 0…1.
    ///
    /// Linear in decibels, which is not the same as linear in amplitude and is
    /// the whole reason a meter is drawn in dB at all: −6 dBFS is half the
    /// voltage of full scale and lands at seven eighths of the bar, which is
    /// where a listener expects "nearly as loud as it goes" to be.
    static func fraction(ofDB value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max((value - floorDB) / -floorDB, 0), 1)
    }

    /// Reads one lane out of whatever pictures have arrived.
    ///
    /// Every bucket of every source the track's clips point at, scanned in
    /// full. Not sampled: 2048 buckets per source is a few thousand float
    /// comparisons, which is beneath the cost of the layout pass that asked for
    /// it, and a strided scan can walk straight past the one transient that
    /// decides whether the meter goes red.
    ///
    /// Sources are visited **once each**, not once per clip: four clips cut
    /// from one file would otherwise weight that file's RMS four times and
    /// report a lane as denser than it is.
    @MainActor
    static func forTrack(_ track: Track, in document: EditorDocument) -> EditorLevelReading {
        var seen = Set<UUID>()
        var peak: Float = 0
        var rmsSum = 0.0
        var rmsCount = 0

        for clip in track.clips where !seen.contains(clip.sourceID) {
            seen.insert(clip.sourceID)
            guard let source = document.sources.first(where: { $0.id == clip.sourceID }),
                  let found = EditorClipWaveforms.shared.buckets(
                      for: clip.sourceID,
                      covering: 0...max(source.duration, 0.001),
                      columns: 1
                  )
            else { continue }

            for bucket in found.data.buckets {
                peak = max(peak, max(abs(bucket.maximum), abs(bucket.minimum)))
                rmsSum += Double(bucket.rms) * Double(bucket.rms)
                rmsCount += 1
            }
        }

        guard rmsCount > 0 else { return .silent }
        let rms = (rmsSum / Double(rmsCount)).squareRoot()
        return EditorLevelReading(
            peakDB: decibels(Double(peak)) + track.gainDB,
            rmsDB: decibels(rms) + track.gainDB
        )
    }

    /// The mix, from the one picture the store already holds.
    ///
    /// `store.waveform` is the rendered overview of everything summed — the
    /// same drawing the single-track window puts on screen — so the master
    /// meter is measuring the mix rather than adding up the lanes and hoping
    /// the arithmetic matches what the render engine did.
    static func forMix(_ waveform: WaveformData?) -> EditorLevelReading {
        guard let waveform, !waveform.buckets.isEmpty else { return .silent }
        var peak: Float = 0
        var rmsSum = 0.0
        for bucket in waveform.buckets {
            peak = max(peak, max(abs(bucket.maximum), abs(bucket.minimum)))
            rmsSum += Double(bucket.rms) * Double(bucket.rms)
        }
        let rms = (rmsSum / Double(waveform.buckets.count)).squareRoot()
        return EditorLevelReading(peakDB: decibels(Double(peak)), rmsDB: decibels(rms))
    }

    private static func decibels(_ amplitude: Double) -> Double {
        amplitude > 0 ? 20 * log10(amplitude) : -.infinity
    }

    /// "−3.4 dB", or "silent". Read by the accessibility value and by the
    /// master panel's numerals, so the two cannot disagree about a rounding.
    static func label(_ value: Double) -> String {
        value.isFinite ? EditorFormat.decibels(value) : "silent"
    }
}

/// A horizontal level bar: trough, RMS fill, peak tick, and — in Full — a
/// decibel ladder under it.
///
/// Horizontal rather than the vertical strip VEGAS draws beside each header.
/// The column is 200pt wide and a lane can be as short as 86pt, so a vertical
/// meter would be a 40pt-tall sliver competing with the fader for the one
/// dimension that is scarce; laid along the row it gets the full width the
/// name already has and costs six points of height.
@MainActor
struct EditorLevelMeter: View {

    let reading: EditorLevelReading
    /// Drawn dim when solo elsewhere has silenced the lane. Not hidden: a lane
    /// you cannot hear still has a level, and hiding the bar would make a
    /// silenced track look like an empty one.
    var isAudible: Bool = true
    /// `EditorMode.Extra.meterScale`. The ladder is the thing Full adds here.
    var showsScale: Bool = false
    /// Whether the block keeps the ladder's height when the ladder is not
    /// drawn. `true` on a track header, where the reserved space is what stops
    /// a mode switch from resizing every lane — see
    /// `EditorTrackMetrics.minimumLaneHeight`. `false` on the master panel,
    /// which is inside a scroller and has no lane to stay level with.
    var reservesScale: Bool = true
    /// Spoken by the row that owns this. `nil` on the master, which speaks for
    /// itself.
    var subject: String?

    var body: some View {
        VStack(alignment: .leading, spacing: EditorTrackMetrics.meterScaleGap) {
            bar
            if showsScale {
                scale
            } else if reservesScale {
                // Not a `Spacer`, and not padding on the bar. A fixed clear
                // block is the only one of the three that is the *same* height
                // whatever else is in the stack, which is the entire point: the
                // header must occupy the identical box in Simple and in Full.
                Color.clear
                    .frame(height: EditorTrackMetrics.meterScaleHeight)
                    .accessibilityHidden(true)
            }
        }
        .opacity(isAudible ? 1 : 0.45)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(subject.map { "\($0) loudest" } ?? "Loudest")
        .accessibilityValue(EditorLevelReading.label(reading.peakDB))
    }

    private var bar: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let rms = EditorLevelReading.fraction(ofDB: reading.rmsDB)
            let peak = EditorLevelReading.fraction(ofDB: reading.peakDB)

            ZStack(alignment: .leading) {
                Rectangle().fill(DesignTokens.Colors.meterTrough)

                Rectangle()
                    .fill(Self.colour(forDB: reading.rmsDB))
                    .frame(width: width * rms)

                // The peak as a tick rather than a second fill. A fill from
                // zero to the peak would bury the RMS bar inside it and the
                // meter would carry one number wearing two colours; a tick says
                // "and it got this far once", which is the question a peak
                // answers.
                if peak > 0 {
                    Rectangle()
                        .fill(Self.colour(forDB: reading.peakDB))
                        .frame(width: Self.peakTickWidth)
                        .offset(x: max(0, width * peak - Self.peakTickWidth))
                }
            }
        }
        .frame(height: EditorTrackMetrics.meterBarHeight)
        // Square, not a capsule. The whole pass is panels that meet and edges
        // that are edges; a rounded meter inside a square header is the
        // floating-card look the frame refuses, at 4pt.
        .clipShape(Rectangle())
        .overlay(
            Rectangle().strokeBorder(DesignTokens.Colors.panelSeparator, lineWidth: 0.5)
        )
    }

    /// −24, −12 and 0, with unlabelled ticks at −36 and −6.
    ///
    /// Five ticks and three numerals, measured against the space rather than
    /// chosen: the meter is about 118pt wide inside a 200pt column, and
    /// `caption2` digits are roughly 5.5pt each, so "−24" needs 17pt. Six
    /// numerals would leave 3pt between them and read as a grey smear — the
    /// failure `EditorTimeRuler` walks a whole ladder to avoid. The two
    /// unlabelled ticks carry the subdivision the numerals cannot afford.
    private var scale: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .topLeading) {
                ForEach(Self.scaleTicks, id: \.value) { tick in
                    let x = width * EditorLevelReading.fraction(ofDB: tick.value)
                    Rectangle()
                        .fill(DesignTokens.Colors.meterScale)
                        .frame(width: 1, height: 2)
                        .offset(x: min(x, width - 1))

                    if let label = tick.label {
                        Text(label)
                            .font(DesignTokens.Typography.Scale.caption2())
                            .monospacedDigit()
                            .foregroundStyle(DesignTokens.Colors.meterScale)
                            .fixedSize()
                            // Right-aligned against the tick for 0, so the
                            // last numeral does not hang off the end of the
                            // column; left-aligned for the rest.
                            .offset(x: tick.value >= 0 ? max(0, x - 10) : x + 1, y: 2)
                    }
                }
            }
        }
        .frame(height: EditorTrackMetrics.meterScaleHeight)
        .accessibilityHidden(true)
    }

    private struct Tick {
        let value: Double
        let label: String?
    }

    private static let scaleTicks: [Tick] = [
        Tick(value: -36, label: nil),
        Tick(value: -24, label: "−24"),
        Tick(value: -12, label: "−12"),
        Tick(value: -6, label: nil),
        Tick(value: 0, label: "0")
    ]

    /// 2pt, so it survives a non-integral offset on a 1x display. A 1pt tick
    /// landing on a half point antialiases to two grey columns and reads as a
    /// smudge rather than as a mark.
    private static let peakTickWidth: CGFloat = 2

    /// Green under −6, warm to −1, red above it. The thresholds are the ones
    /// every mastering tool uses and are not Melo's to reinvent; what is Melo's
    /// is that the warm band is warm and not amber-alarming, because −6 to −1
    /// is where a finished podcast is *supposed* to sit.
    static func colour(forDB value: Double) -> Color {
        guard value.isFinite else { return DesignTokens.Colors.meterBody }
        if value >= -1 { return DesignTokens.Colors.meterHot }
        if value >= -6 { return DesignTokens.Colors.meterWarm }
        return DesignTokens.Colors.meterBody
    }
}
