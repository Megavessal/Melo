// Melo/Editor/Views/Waveform/EditorFormat+Precision.swift
//
// An extension on `EditorFormat` rather than a second formatter, so there is
// still exactly one implementation of timecode in the tree.
//
// `EditorFormat.timecode` rounds down to the whole second, which is right for a
// move summary and wrong for a ruler: zoomed to four milliseconds across the
// window, every tick would be labelled the same second.

import Foundation

extension EditorFormat {

    /// A position on the timeline with sub-second precision: `0:07.250`.
    ///
    /// Rounding happens before the split into minutes and seconds, so 59.999 at
    /// zero decimals is `1:00` and never `0:60`.
    ///
    /// - Parameters:
    ///   - value: Seconds from the start of the sound.
    ///   - decimals: Fractional digits, clamped to 0…4. Zero is
    ///     `EditorFormat.timecode(_:)`'s own output.
    static func timecode(_ value: TimeInterval, decimals: Int) -> String {
        guard value.isFinite else { return "—:—" }
        let places = min(max(decimals, 0), 4)
        guard places > 0 else { return timecode(value) }

        let scale = pow(10.0, Double(places))
        let rounded = ((max(value, 0) * scale).rounded()) / scale

        let whole = Int(rounded.rounded(.down))
        let hours = whole / 3600
        let minutes = (whole % 3600) / 60
        // Seconds *within the current minute*, fraction intact.
        let seconds = rounded - Double(whole - whole % 60)
        // Two integer digits always, so the label width only changes when the
        // precision does: "%06.3f" → "07.250".
        let secondsText = String(format: "%0\(places + 3).\(places)f", seconds)

        return hours > 0
            ? "\(hours):" + String(format: "%02d", minutes) + ":" + secondsText
            : "\(minutes):" + secondsText
    }

    /// How much precision a viewport showing `secondsPerPoint` seconds in every
    /// screen point can honestly display. Zoomed out, a hundredth of a second is
    /// noise; zoomed in, it is the only thing that distinguishes two ticks.
    static func timecodeDecimals(forSecondsPerPoint secondsPerPoint: Double) -> Int {
        switch secondsPerPoint {
        case ..<0.00006: return 4
        case ..<0.0006: return 3
        case ..<0.006: return 2
        case ..<0.06: return 1
        default: return 0
        }
    }

    /// What VoiceOver should say. `1:23` read aloud is "one twenty-three",
    /// which is a street address.
    static func spokenTime(_ value: TimeInterval) -> String {
        guard value.isFinite else { return "unknown" }
        let total = Int(max(0, value).rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60

        var parts: [String] = []
        if hours > 0 { parts.append("\(hours) hour\(hours == 1 ? "" : "s")") }
        if minutes > 0 { parts.append("\(minutes) minute\(minutes == 1 ? "" : "s")") }
        if seconds > 0 || parts.isEmpty { parts.append("\(seconds) second\(seconds == 1 ? "" : "s")") }
        return parts.joined(separator: " ")
    }
}
