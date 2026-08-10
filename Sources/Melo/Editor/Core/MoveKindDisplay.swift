// Melo/Editor/Core/MoveKindDisplay.swift
//
// How a move introduces itself in the Chain. `title` is the left of the row,
// `summary` is the right, `symbolName` is the glyph.
//
// Numbers are formatted the way a person reads them: a real minus sign, one
// decimal place where a tenth matters and none where it does not, kHz once a
// frequency stops being a three-digit number. Apply `.monospacedDigit()` at the
// view layer so a summary does not jitter while a slider moves — not here.

import Foundation

extension MoveKind {
    var title: String {
        switch self {
        case .trim: "Trim"
        case .removeSilence: "Remove silence"
        case .reverse: "Reverse"
        case .speed: "Speed"
        case .gain: "Gain"
        case .normalize: "Normalize"
        case .limiter: "Limiter"
        case .fadeIn: "Fade in"
        case .fadeOut: "Fade out"
        case .equalizer: "Equalizer"
        case .highPass: "High-pass"
        case .noiseGate: "Noise gate"
        case .channels: "Channels"
        case .fixDCOffset: "Fix DC offset"
        }
    }

    var symbolName: String {
        switch self {
        case .trim: "scissors"
        case .removeSilence: "rectangle.compress.vertical"
        case .reverse: "arrow.uturn.left"
        case .speed: "speedometer"
        case .gain: "speaker.wave.2"
        case .normalize: "equal.circle"
        case .limiter: "arrow.down.to.line"
        case .fadeIn: "waveform.path.badge.plus"
        case .fadeOut: "waveform.path.badge.minus"
        case .equalizer: "slider.vertical.3"
        case .highPass: "line.3.horizontal.decrease"
        case .noiseGate: "waveform.slash"
        case .channels: "circle.lefthalf.filled"
        case .fixDCOffset: "align.vertical.center"
        }
    }

    /// The right-hand side of a Chain row. Empty when the move has no number
    /// worth showing — `reverse` is the whole instruction already.
    var summary: String {
        switch self {
        case let .trim(start, end):
            "\(EditorFormat.timecode(start)) – \(EditorFormat.timecode(end))"

        case let .removeSilence(thresholdDB, minimumLength, _):
            "under \(EditorFormat.decibels(thresholdDB)) for \(EditorFormat.seconds(minimumLength))"

        case .reverse:
            ""

        case let .speed(rate):
            EditorFormat.multiplier(rate)

        case let .gain(dB):
            EditorFormat.decibels(dB)

        case let .normalize(appliedGainDB, _, targetLUFS):
            "\(EditorFormat.decibels(appliedGainDB)) to \(EditorFormat.number(targetLUFS, places: 0)) LUFS"

        case let .limiter(ceilingDBTP, releaseMS):
            "\(EditorFormat.number(ceilingDBTP, places: 1)) dBTP, \(EditorFormat.milliseconds(releaseMS)) release"

        case let .fadeIn(length, curve), let .fadeOut(length, curve):
            "\(EditorFormat.seconds(length)), \(curve.title)"

        case let .equalizer(bands, preampDB):
            EditorFormat.equalizerSummary(bandCount: bands.count, preampDB: preampDB)

        case let .highPass(frequency):
            EditorFormat.hertz(frequency)

        case let .noiseGate(thresholdDB, attackMS, releaseMS):
            "\(EditorFormat.decibels(thresholdDB)), \(EditorFormat.milliseconds(attackMS))/\(EditorFormat.milliseconds(releaseMS))"

        case let .channels(mode):
            mode.title

        case let .fixDCOffset(measuredOffset):
            EditorFormat.number(measuredOffset, places: 4)
        }
    }

}

extension FadeCurve {
    var title: String {
        switch self {
        case .linear: "linear"
        case .equalPower: "equal power"
        case .exponential: "exponential"
        }
    }
}

extension ChannelMode {
    var title: String {
        switch self {
        case .keep: "As it came"
        case .mono: "Mono"
        case .stereo: "Stereo"
        }
    }
}

// MARK: - Formatting

/// Melo Edit's number and time formatting, in one place so a dB in the
/// Chain, a dB in the inspector and a dB in a progress line are the same
/// string. Everything here is pure and synchronous.
enum EditorFormat {
    /// U+2212. A hyphen next to a digit reads as a dash, not a negative.
    static let minusSign = "\u{2212}"

    /// A plain number with a real minus sign. `places` is fixed, not maximum,
    /// because a value that gains and loses a decimal while a slider moves is
    /// harder to read than one that does not.
    static func number(_ value: Double, places: Int) -> String {
        guard value.isFinite else { return "—" }
        let rendered = String(format: "%.\(places)f", abs(value))
        // -0.0 formats as "0.0"; treat anything that rounds to zero as zero.
        let isZero = Double(rendered) == 0
        return (value < 0 && !isZero) ? minusSign + rendered : rendered
    }

    /// "−3.2 dB", "0.0 dB"
    static func decibels(_ value: Double, places: Int = 1) -> String {
        "\(number(value, places: places)) dB"
    }

    /// "80 Hz", "2.5 kHz", "16 kHz"
    static func hertz(_ value: Double) -> String {
        guard value.isFinite, value > 0 else { return "—" }
        if value < 1000 { return "\(number(value, places: 0)) Hz" }
        let kHz = value / 1000
        let places = kHz < 10 && kHz != kHz.rounded() ? 1 : 0
        return "\(number(kHz, places: places)) kHz"
    }

    /// "5 ms", "120 ms", "1.5 s" once milliseconds stop being readable.
    static func milliseconds(_ value: Double) -> String {
        value >= 1000 ? seconds(value / 1000) : "\(number(value, places: 0)) ms"
    }

    /// A length, not a position: "0.25s", "1.5s", "12s", "2:30".
    static func seconds(_ value: TimeInterval) -> String {
        guard value.isFinite else { return "—" }
        if value >= 60 { return timecode(value) }
        if value < 1 { return "\(number(value, places: 2))s" }
        if value < 10 { return "\(number(value, places: 1))s" }
        return "\(number(value, places: 0))s"
    }

    /// A position on the timeline: "0:07", "4:10", "1:02:03".
    static func timecode(_ value: TimeInterval) -> String {
        guard value.isFinite else { return "—:—" }
        let total = Int(max(value, 0).rounded(.down))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
    }

    /// "1:42 of 4:10" — the detail line of a `JobProgress`.
    static func elapsedOfTotal(_ elapsed: TimeInterval, _ total: TimeInterval) -> String {
        "\(timecode(elapsed)) of \(timecode(total))"
    }

    /// "1.25×", "2×"
    static func multiplier(_ value: Double) -> String {
        let places = value == value.rounded() ? 0 : 2
        return "\(number(value, places: places))×"
    }

    /// "6 bands, −3.0 dB preamp" — and just "6 bands" when there is no preamp,
    /// because a preamp of zero is not information.
    static func equalizerSummary(bandCount: Int, preampDB: Double) -> String {
        let bands = bandCount == 1 ? "1 band" : "\(bandCount) bands"
        guard abs(preampDB) >= 0.05 else { return bands }
        return "\(bands), \(decibels(preampDB)) preamp"
    }
}
