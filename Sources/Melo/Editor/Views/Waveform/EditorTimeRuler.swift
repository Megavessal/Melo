// Melo/Editor/Views/Waveform/EditorTimeRuler.swift
//
// A ruler whose tick density follows the zoom and whose labels never collide.
//
// The collision rule is the whole design. A ruler that picks a "nice" interval
// and hopes is legible at one zoom and unreadable at the next: at four minutes
// across a 700pt pane, one tick a second is 2.9pt apart and the labels overlap
// into a grey smear. So the interval is chosen *by measuring what the label will
// need* — the ladder is walked from the finest interval upward and the first one
// whose spacing clears its own label width wins. Zoom in and the ladder walks
// down of its own accord: seconds, then tenths, then hundredths, then
// milliseconds.

import AppKit
import SwiftUI

@MainActor
struct EditorTimeRuler: View {

    @ObservedObject var timeline: EditorTimeline

    /// Observed, not read once. `M` appends to this from the key handler while
    /// the ruler is already on screen, and a `Canvas` only redraws when
    /// something it observes changes.
    @ObservedObject private var markers = EditorMarkers.shared

    /// Intervals a person reads without arithmetic. Nothing here is a power of
    /// two, and nothing is 3 or 7 seconds: an unfamiliar interval makes the
    /// reader do sums to place a moment between two ticks.
    private static let ladder: [Double] = [
        0.0002, 0.0005,
        0.001, 0.002, 0.005,
        0.01, 0.02, 0.05,
        0.1, 0.2, 0.5,
        1, 2, 5, 10, 15, 30,
        60, 120, 300, 600, 900, 1800, 3600
    ]

    var body: some View {
        Canvas(opaque: false) { context, size in
            draw(&context, size: size)
        }
        // The waveform is the accessible element and it speaks the playhead and
        // the selection in words. A ruler read out tick by tick is noise.
        .accessibilityHidden(true)
    }

    // MARK: - Drawing

    private func draw(_ context: inout GraphicsContext, size: CGSize) {
        guard size.width > 4, size.height > 4 else { return }
        let span = timeline.visible
        guard span > 0, timeline.duration > 0 else { return }

        let pointsPerSecond = Double(size.width) / span
        let major = Self.majorInterval(pointsPerSecond: pointsPerSecond, hasHours: timeline.duration >= 3600)
        let decimals = Self.decimals(for: major)
        let minorCount = Self.minorSubdivisions(interval: major, pointsPerSecond: pointsPerSecond)

        // Baseline. The ruler sits on the waveform, so the hairline belongs at
        // the bottom where the two meet.
        context.fill(
            Path(CGRect(x: 0, y: size.height - 0.5, width: size.width, height: 0.5)),
            with: .color(EditorWaveformPalette.rulerTickMinor)
        )

        let visibleEnd = timeline.start + span
        var tick = (timeline.start / major).rounded(.down) * major
        // A hard cap rather than trusting the arithmetic: a `major` that came
        // back as zero would spin here forever, and a hung draw loop is a hung
        // window.
        var guardCount = 0

        while tick <= visibleEnd + major, guardCount < 4_000 {
            guardCount += 1
            defer { tick += major }

            if minorCount > 1 {
                for step in 1..<minorCount {
                    let minorTime = tick + major * Double(step) / Double(minorCount)
                    let minorX = CGFloat((minorTime - timeline.start) * pointsPerSecond)
                    guard minorX >= 0, minorX <= size.width, minorTime >= 0, minorTime <= timeline.duration else { continue }
                    context.fill(
                        Path(CGRect(x: minorX, y: size.height - 4, width: 1, height: 4)),
                        with: .color(EditorWaveformPalette.rulerTickMinor)
                    )
                }
            }

            guard tick >= -0.000_001, tick <= timeline.duration + 0.000_001 else { continue }
            let x = CGFloat((tick - timeline.start) * pointsPerSecond)
            guard x >= -0.5, x <= size.width else { continue }

            context.fill(
                Path(CGRect(x: x, y: size.height - 8, width: 1, height: 8)),
                with: .color(EditorWaveformPalette.rulerTickMajor)
            )

            let label = context.resolve(
                Text(EditorFormat.timecode(max(tick, 0), decimals: decimals))
                    .font(DesignTokens.Typography.Scale.caption2(.medium).monospacedDigit())
                    .foregroundStyle(DesignTokens.Colors.textTertiary)
            )
            let measured = label.measure(in: size)
            // Left of the tick it labels, the way Logic and QuickTime place
            // them. Centred labels are what collide first at the two edges,
            // where half of one hangs off the pane.
            let labelX = x + 3
            guard labelX + measured.width <= size.width - 2 else { continue }
            context.draw(label, at: CGPoint(x: labelX, y: 1), anchor: .topLeading)
        }

        drawMarkers(&context, size: size, pointsPerSecond: pointsPerSecond, visibleEnd: visibleEnd)
    }

    /// The markers `M` drops, painted over the ticks.
    ///
    /// Last, so a marker is never hidden under a tick label. That ordering is
    /// the whole of the interaction: `M` was bound and drawn by nothing for one
    /// build, which is a key that appears in the cheat sheet and does nothing a
    /// person can see.
    ///
    /// Full height rather than a stub at the top. A marker is a place in the
    /// piece and the eye has to be able to drop from the ruler onto the
    /// waveform without losing the column; an 8pt nub in a 20pt strip is a
    /// tick with a number next to it.
    private func drawMarkers(
        _ context: inout GraphicsContext,
        size: CGSize,
        pointsPerSecond: Double,
        visibleEnd: TimeInterval
    ) {
        for marker in markers.markers {
            guard marker.time >= timeline.start, marker.time <= visibleEnd else { continue }
            let x = CGFloat((marker.time - timeline.start) * pointsPerSecond)
            guard x >= -0.5, x <= size.width else { continue }

            context.fill(
                Path(CGRect(x: x, y: 0, width: 1, height: size.height)),
                with: .color(EditorWaveformPalette.marker)
            )

            let flag = context.resolve(
                Text(marker.name)
                    .font(DesignTokens.Typography.Scale.caption2(.semibold).monospacedDigit())
                    .foregroundStyle(EditorWaveformPalette.markerLabel)
            )
            let measured = flag.measure(in: size)
            // A filled tab behind the number, because the number sits on top of
            // whatever timecode label is already there and two glyphs in the
            // same 8pt square are unreadable at any weight.
            let tab = CGRect(x: x, y: 0, width: measured.width + 6, height: measured.height + 2)
            guard tab.maxX <= size.width else { continue }
            context.fill(
                Path(roundedRect: tab, cornerRadius: 2, style: .continuous),
                with: .color(EditorWaveformPalette.marker)
            )
            context.draw(flag, at: CGPoint(x: x + 3, y: 1), anchor: .topLeading)
        }
    }

    // MARK: - The ladder

    /// The finest interval whose ticks are further apart than the label they
    /// carry. Walking upward from the finest is what makes the ruler get denser
    /// as you zoom in without anyone writing a zoom-to-interval table.
    static func majorInterval(pointsPerSecond: Double, hasHours: Bool) -> Double {
        guard pointsPerSecond > 0, pointsPerSecond.isFinite else { return 60 }
        for candidate in ladder {
            let places = decimals(for: candidate)
            // "0:07" is about 22pt at 9pt SF with monospaced digits; each
            // decimal adds a digit, and an hour field adds two more plus a
            // colon. Twelve points of air keeps adjacent labels from touching.
            let labelWidth = (hasHours ? 40.0 : 22.0) + Double(places) * 5.5 + 12.0
            if candidate * pointsPerSecond >= labelWidth { return candidate }
        }
        return ladder[ladder.count - 1]
    }

    static func decimals(for interval: Double) -> Int {
        switch interval {
        case 1...: return 0
        case 0.1...: return 1
        case 0.01...: return 2
        case 0.001...: return 3
        default: return 4
        }
    }

    /// Unlabelled ticks between the labelled ones, so the eye can subdivide
    /// without the ruler having to say every value. Suppressed below six points
    /// apart, where they stop being ticks and become a grey band.
    static func minorSubdivisions(interval: Double, pointsPerSecond: Double) -> Int {
        // 60 divides by 4 into quarter-minutes, which is what a listener counts
        // in; 10 and 5 are right for everything decimal.
        let candidates: [Int] = interval >= 60 ? [4, 2] : [10, 5, 4, 2]
        for divisor in candidates where interval / Double(divisor) * pointsPerSecond >= 6 {
            return divisor
        }
        return 1
    }
}
