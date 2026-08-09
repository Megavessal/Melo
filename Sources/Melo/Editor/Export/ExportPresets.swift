// Melo/Editor/Export/ExportPresets.swift
//
// What each output format is, what each destination implies, and how big the
// file is going to be. No view code: the sheet, the preset chips and the
// progress strip all read their strings from here so they cannot phrase the
// same fact two different ways.

import Foundation

// MARK: - What a format is

/// The facts about an output format that the export UI needs and that
/// `AudioFormatKind` deliberately does not carry.
///
/// Behind a single `exportFacts` property rather than a handful of extension
/// members, so this file cannot collide with anything later added to
/// `AudioFormatKind`.
struct ExportFormatFacts {
    /// One line, in the app's voice, saying why you would pick this.
    var blurb: String
    /// Empty when the format has no bit rate to choose.
    var bitRateChoicesKbps: [Int]
    var defaultBitRateKbps: Int?
    /// Non-nil when the codec speaks one sample rate and one only.
    var fixedSampleRate: Double?
    /// What `AudioFileIO.writerSettings` actually writes. Not a choice —
    /// `ExportSettings` has no bit-depth field — so the sheet states it rather
    /// than offering it.
    var depthLabel: String?
    /// Bytes per sample of the underlying PCM, for the size estimate.
    var pcmBytesPerSample: Int
    /// Compressed-lossless size as a fraction of that PCM. `nil` means the
    /// format stores the PCM as-is and the size is arithmetic, not a guess.
    var losslessRatio: Double?
    /// A second sentence, shown only when this format is the one selected and
    /// there is something the user would want to know before pressing Export.
    var caveat: String?

    var supportsBitRate: Bool { !bitRateChoicesKbps.isEmpty }
}

extension AudioFormatKind {

    var exportFacts: ExportFormatFacts {
        switch self {
        case .wav:
            return ExportFormatFacts(
                blurb: "Uncompressed. Everything opens it.",
                bitRateChoicesKbps: [],
                defaultBitRateKbps: nil,
                fixedSampleRate: nil,
                depthLabel: "32-bit float",
                pcmBytesPerSample: 4,
                losslessRatio: nil,
                caveat: nil
            )
        case .aiff:
            return ExportFormatFacts(
                blurb: "Uncompressed, the Apple one.",
                bitRateChoicesKbps: [],
                defaultBitRateKbps: nil,
                fixedSampleRate: nil,
                depthLabel: "24-bit",
                pcmBytesPerSample: 3,
                losslessRatio: nil,
                // The honest version of "lossless". Melo's samples are floats
                // and AIFF cannot hold one, so this is the only uncompressed
                // format where what comes out is not bit-for-bit what went in.
                caveat: "AIFF can't hold Melo's float samples, so this one rounds to 24-bit. WAV and CAF don't."
            )
        case .caf:
            return ExportFormatFacts(
                blurb: "Uncompressed, with no size ceiling.",
                bitRateChoicesKbps: [],
                defaultBitRateKbps: nil,
                fixedSampleRate: nil,
                depthLabel: "32-bit float",
                pcmBytesPerSample: 4,
                losslessRatio: nil,
                caveat: nil
            )
        case .m4aAAC:
            return ExportFormatFacts(
                blurb: "Small enough to send, good enough to keep.",
                bitRateChoicesKbps: [64, 96, 128, 160, 192, 256, 320],
                defaultBitRateKbps: 256,
                fixedSampleRate: nil,
                depthLabel: nil,
                pcmBytesPerSample: 4,
                losslessRatio: nil,
                caveat: nil
            )
        case .m4aALAC:
            return ExportFormatFacts(
                blurb: "Lossless, at about half the size.",
                bitRateChoicesKbps: [],
                defaultBitRateKbps: nil,
                fixedSampleRate: nil,
                depthLabel: "24-bit",
                pcmBytesPerSample: 3,
                losslessRatio: 0.60,
                caveat: nil
            )
        case .flac:
            return ExportFormatFacts(
                blurb: "Lossless and open.",
                bitRateChoicesKbps: [],
                defaultBitRateKbps: nil,
                fixedSampleRate: nil,
                depthLabel: "24-bit",
                pcmBytesPerSample: 3,
                losslessRatio: 0.58,
                caveat: nil
            )
        case .mp3:
            return ExportFormatFacts(
                blurb: "Plays on absolutely anything.",
                bitRateChoicesKbps: [128, 160, 192, 256, 320],
                defaultBitRateKbps: 320,
                fixedSampleRate: nil,
                depthLabel: nil,
                pcmBytesPerSample: 4,
                losslessRatio: nil,
                caveat: nil
            )
        case .opus:
            return ExportFormatFacts(
                blurb: "Tiny, and very good at voice.",
                bitRateChoicesKbps: [48, 64, 96, 128, 192],
                defaultBitRateKbps: 128,
                fixedSampleRate: 48_000,
                depthLabel: nil,
                pcmBytesPerSample: 4,
                losslessRatio: nil,
                caveat: "Opus works at 48 kHz and resamples anything else on the way in."
            )
        }
    }

    /// Display order for the picker: the six macOS can write, then the two the
    /// bundled ffmpeg writes. All eight are available on any normal build; the
    /// order is about which encoder does the work, not about what the user has.
    static var exportOrder: [AudioFormatKind] {
        [.wav, .aiff, .caf, .m4aAAC, .m4aALAC, .flac, .mp3, .opus]
    }
}

// MARK: - What came in

/// Which output format matches the file the user opened, so the export sheet
/// can default to "same as it came in" rather than asking.
enum ExportSourceFormat {

    /// `nil` when the source is not a file Melo can name a format for.
    static func kind(for source: EditorSource) -> AudioFormatKind? {
        if case .file(let originalURL) = source.origin,
           let fromPath = kind(forPathExtension: originalURL.pathExtension) {
            return fromPath
        }
        if let fromPath = kind(forPathExtension: source.url.pathExtension) {
            return fromPath
        }
        // "MP3 · 320 kbps · 44.1 kHz stereo" — the leading token is the format.
        let leading = source.formatDescription
            .split(separator: "·")
            .first
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        return kind(forPathExtension: leading)
    }

    static func kind(forPathExtension raw: String) -> AudioFormatKind? {
        switch raw.lowercased() {
        case "wav", "wave": return .wav
        case "aif", "aiff", "aifc": return .aiff
        case "caf": return .caf
        // m4a is two codecs in one container. AAC is what the overwhelming
        // majority of them are, and guessing ALAC would quadruple the file the
        // user gets back.
        case "m4a", "m4b", "m4r", "aac", "mp4": return .m4aAAC
        case "alac", "apple lossless": return .m4aALAC
        case "flac": return .flac
        case "mp3", "mpeg audio": return .mp3
        case "opus", "ogg", "oga": return .opus
        default: return nil
        }
    }
}

// MARK: - The presets

/// One click to a whole set of settings. This is the least-knowledgeable
/// user's export: pick the row naming where the sound is going, press Export.
struct ExportPreset: Identifiable, Equatable {
    var id: String
    var title: String
    /// The settings, spelled out: "AAC · 128 kbps · Mono".
    var summary: String
    var symbolName: String
    var format: AudioFormatKind
    /// `nil` keeps the source's rate.
    var sampleRate: Double?
    var bitRateKbps: Int?
    var channels: ChannelMode
}

enum ExportPresets {

    /// "Same as it came in" first, then one per destination. The destinations
    /// come from `DestinationCatalogue.all`, so the two surfaces cannot drift
    /// apart.
    static func all(for source: EditorSource) -> [ExportPreset] {
        [sameAsSource(source)] + DestinationCatalogue.all.map { preset(for: $0, source: source) }
    }

    /// What nearly everybody wants: the file back in the shape it arrived in,
    /// only better.
    static func sameAsSource(_ source: EditorSource) -> ExportPreset {
        let format = ExportSourceFormat.kind(for: source) ?? .m4aAAC
        let facts = format.exportFacts
        return ExportPreset(
            id: "same",
            title: "Same as it came in",
            summary: ExportCopy.summary(
                format: format,
                sampleRate: nil,
                bitRateKbps: facts.defaultBitRateKbps,
                channels: .keep,
                source: source
            ),
            symbolName: "arrow.uturn.backward.circle",
            format: format,
            sampleRate: nil,
            bitRateKbps: facts.defaultBitRateKbps,
            channels: .keep
        )
    }

    /// Matched to what the destination implies rather than to a genre. Video
    /// wants uncompressed at 48 kHz because that is what a picture timeline
    /// runs at; a voice memo wants one small mono channel.
    static func preset(for destination: Destination, source: EditorSource) -> ExportPreset {
        let shape = shape(for: destination)
        return ExportPreset(
            id: destination.id,
            title: destination.title,
            summary: ExportCopy.summary(
                format: shape.format,
                sampleRate: shape.sampleRate,
                bitRateKbps: shape.bitRateKbps,
                channels: shape.channels,
                source: source
            ),
            symbolName: destination.symbolName,
            format: shape.format,
            sampleRate: shape.sampleRate,
            bitRateKbps: shape.bitRateKbps,
            channels: shape.channels
        )
    }

    private struct Shape {
        var format: AudioFormatKind
        var sampleRate: Double?
        var bitRateKbps: Int?
        var channels: ChannelMode
    }

    /// Matched on a normalised id rather than an exact string, because
    /// `DestinationCatalogue` owns the ids and "voice-memo" and "voiceMemo"
    /// should both land here.
    private static func shape(for destination: Destination) -> Shape {
        let key = destination.id.lowercased().filter(\.isLetter)
        let channels: ChannelMode = destination.prefersMono ? .mono : .keep

        if key.contains("podcast") {
            // Apple Podcasts asks for AAC and names 128 kbps stereo as its
            // sweet spot; mono halves that again without hurting speech.
            return Shape(format: .m4aAAC, sampleRate: nil, bitRateKbps: 128, channels: channels)
        }
        if key.contains("video") {
            // Picture timelines run at 48 kHz and want nothing decoded twice.
            return Shape(format: .wav, sampleRate: 48_000, bitRateKbps: nil, channels: channels)
        }
        if key.contains("ringtone") {
            return Shape(format: .m4aAAC, sampleRate: 44_100, bitRateKbps: 192, channels: channels)
        }
        if key.contains("voice") || key.contains("memo") {
            return Shape(format: .m4aAAC, sampleRate: nil, bitRateKbps: 64, channels: .mono)
        }
        if key.contains("music") {
            return Shape(format: .m4aAAC, sampleRate: nil, bitRateKbps: 256, channels: channels)
        }
        return Shape(format: .m4aAAC, sampleRate: nil, bitRateKbps: 192, channels: channels)
    }
}

// MARK: - Size

/// What the user is about to get, in bytes. A 4-minute song exported to WAV
/// should not surprise anybody with 80 MB after the fact.
enum ExportSizeEstimate {

    /// The length the export will actually be. Trim and speed are exact and
    /// worth honouring — a trim to 30 seconds should not quote the size of the
    /// whole file. Silence removal shortens things further, so an estimate
    /// with one of those in the stack reads high.
    static func estimatedDuration(source: EditorSource, moves: [Move]) -> TimeInterval {
        var duration = source.duration
        for move in moves where move.isEnabled {
            switch move.kind {
            case let .trim(start, end):
                duration = max(0, end - start)
            case let .speed(rate) where rate > 0:
                duration /= rate
            default:
                continue
            }
        }
        return duration
    }

    static func sampleRate(_ requested: Double?, format: AudioFormatKind, source: EditorSource) -> Double {
        if let fixed = format.exportFacts.fixedSampleRate { return fixed }
        return requested ?? source.sampleRate
    }

    static func bytes(
        format: AudioFormatKind,
        duration: TimeInterval,
        sampleRate: Double,
        channelCount: Int,
        bitRateKbps: Int?
    ) -> Int64 {
        let facts = format.exportFacts
        guard duration.isFinite, duration > 0 else { return 0 }
        if facts.supportsBitRate {
            let kbps = Double(bitRateKbps ?? facts.defaultBitRateKbps ?? 256)
            return Int64(kbps * 1000 / 8 * duration)
        }
        let raw = duration * sampleRate * Double(channelCount) * Double(facts.pcmBytesPerSample)
        return Int64(raw * (facts.losslessRatio ?? 1))
    }
}

// MARK: - Copy

/// The strings the export surfaces share. Numbers become text through
/// `EditorFormat` wherever it already has a rule for them.
enum ExportCopy {

    static func fileSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// "8s", "35s", "2m". Deliberately coarse: a remaining-time readout that
    /// changes every frame is noise, not information.
    static func coarseDuration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds > 0 else { return "a moment" }
        if seconds < 10 { return "\(Int(seconds.rounded(.up)))s" }
        if seconds < 60 { return "\(Int((seconds / 5).rounded(.up)) * 5)s" }
        let minutes = Int((seconds / 60).rounded())
        return "\(max(minutes, 1))m"
    }

    static func channels(_ mode: ChannelMode, source: EditorSource) -> String {
        switch mode {
        case .mono: return "Mono"
        case .stereo: return "Stereo"
        case .keep: return source.channelCount == 1 ? "Mono" : "Stereo"
        }
    }

    static func channelChoice(_ mode: ChannelMode, source: EditorSource) -> String {
        switch mode {
        case .keep: return "Same as the source"
        case .mono: return "Mono"
        case .stereo: return "Stereo"
        }
    }

    /// "AAC · 256 kbps · 48 kHz · Stereo". The one line saying what the user
    /// is about to get.
    static func summary(
        format: AudioFormatKind,
        sampleRate: Double?,
        bitRateKbps: Int?,
        channels: ChannelMode,
        source: EditorSource
    ) -> String {
        let facts = format.exportFacts
        var parts = [format.displayName]
        if facts.supportsBitRate, let kbps = bitRateKbps ?? facts.defaultBitRateKbps {
            parts.append("\(kbps) kbps")
        } else if let depth = facts.depthLabel {
            parts.append(depth)
        }
        parts.append(EditorFormat.hertz(ExportSizeEstimate.sampleRate(sampleRate, format: format, source: source)))
        parts.append(self.channels(channels, source: source))
        return parts.joined(separator: " · ")
    }
}
