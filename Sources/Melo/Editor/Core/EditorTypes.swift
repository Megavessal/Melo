// Melo/Editor/Core/EditorTypes.swift
//
// The Cutting Room's document model. Every type the editor shares lives here,
// and nowhere else. A type that is missing belongs in this file rather than
// being declared locally — a duplicate `Move` in two files is a build failure
// that arrives all at once.

import Foundation

// MARK: - The document

/// One sound and everything we are doing to it.
///
/// A value type on purpose: the undo stack in `CuttingRoomStore` is an array of
/// these, which is the whole reason the simple thing works here. There is no
/// command pattern and there should not be one.
struct EditorDocument: Codable, Equatable, Sendable {
    var source: EditorSource
    /// Ordered. The render walks it front to back; reordering is a real edit.
    var moves: [Move]
    /// `nil` until the user picks one.
    var destination: Destination?
    /// `nil` until the file has been measured. Describes the *source*, not the
    /// rendered result, so it survives every change to `moves`.
    var analysis: AnalysisReport?

    init(source: EditorSource,
         moves: [Move] = [],
         destination: Destination? = nil,
         analysis: AnalysisReport? = nil) {
        self.source = source
        self.moves = moves
        self.destination = destination
        self.analysis = analysis
    }
}

/// Where the audio came from. The editor never mutates the original file.
struct EditorSource: Codable, Equatable, Sendable, Identifiable {
    var id: UUID = UUID()
    /// The decoded file on disk. For an extraction or a recording this is a
    /// working copy Melo wrote, not something the user chose.
    var url: URL
    /// "morning-show-ep41" — no extension.
    var displayName: String
    var origin: Origin
    var duration: TimeInterval
    var sampleRate: Double
    var channelCount: Int
    /// "MP3 · 320 kbps · 44.1 kHz stereo"
    var formatDescription: String

    enum Origin: Codable, Equatable, Sendable {
        case file(originalURL: URL)
        case extractedFromLink(pageURL: URL, siteName: String)
        case systemRecording(startedAt: Date)
        /// The bundled theme, opened for editing.
        case meloTheme
    }
}

// MARK: - Moves

/// A stored, resolved instruction.
///
/// **Every move holds concrete numbers.** Analysis proposes a number; it never
/// leaves a target for the renderer to work out later. Load-bearing twice over:
/// a range render and a full render would otherwise disagree, and the user
/// could not see or edit the value.
struct Move: Codable, Equatable, Sendable, Identifiable {
    var id: UUID = UUID()
    var kind: MoveKind
    var isEnabled: Bool = true
    /// One sentence, in the app's voice, saying what this does to *this* file.
    /// Written when the move is created; shown in the stack.
    var rationale: String?
}

enum MoveKind: Codable, Equatable, Sendable {
    // Timeline — these change how long the sound is.
    case trim(start: TimeInterval, end: TimeInterval)
    case removeSilence(thresholdDB: Double, minimumLength: TimeInterval, leaveTail: TimeInterval)
    case reverse
    /// 0.5…2.0, pitch preserved.
    case speed(rate: Double)

    // Level
    case gain(dB: Double)
    case normalize(appliedGainDB: Double, measuredLUFS: Double, targetLUFS: Double)
    case limiter(ceilingDBTP: Double, releaseMS: Double)
    case fadeIn(length: TimeInterval, curve: FadeCurve)
    case fadeOut(length: TimeInterval, curve: FadeCurve)

    // Tone
    /// `AutoEQFilter` is Melo's existing parametric band (`Models/AutoEQProfile.swift`),
    /// and `BiquadMath.coefficientsForAutoEQFilters` already turns an array of
    /// them into coefficients. The editor does not declare a band type.
    case equalizer(bands: [AutoEQFilter], preampDB: Double)
    case highPass(frequency: Double)
    case noiseGate(thresholdDB: Double, attackMS: Double, releaseMS: Double)

    // Shape
    case channels(ChannelMode)
    case fixDCOffset(measuredOffset: Double)
}

enum FadeCurve: String, Codable, Sendable, CaseIterable {
    case linear, equalPower, exponential
}

enum ChannelMode: String, Codable, Sendable, CaseIterable {
    case keep, mono, stereo
}

extension ChannelMode {
    /// What this mode means for a source with `sourceCount` channels.
    func resolvedChannelCount(from sourceCount: Int) -> Int {
        switch self {
        case .keep: max(sourceCount, 1)
        case .mono: 1
        case .stereo: 2
        }
    }
}

// MARK: - The graphic ↔ parametric bridge

// Melo's runtime EQ is a fixed ten-band graphic: gain only, Q = 1.4, always
// peaking. The editor's EQ is the same filters with frequency and Q unlocked.
// Both render through `BiquadMath`, so they cannot disagree — and because the
// bridge exists, every Melo preset and every saved user preset opens in the
// editor for free.

extension EQSettings {
    /// This graphic curve expressed as parametric bands, at Melo's own
    /// frequencies and Melo's own Q. Lossless in this direction.
    var autoEQFilters: [AutoEQFilter] {
        let gains = clampedGains
        return EQSettings.frequencies.enumerated().map { index, frequency in
            AutoEQFilter(
                type: .peaking,
                frequency: frequency,
                gainDB: index < gains.count ? gains[index] : 0,
                q: BiquadMath.graphicEQQ
            )
        }
    }

    /// Parametric bands read back onto the ten-band graphic.
    ///
    /// **Lossy on purpose.** Each graphic band takes the gain of the nearest
    /// parametric band within a third of an octave; anything further away, and
    /// anything shelving, has no graphic equivalent and is dropped. The
    /// parametric array stays the document's truth — this exists so the graphic
    /// view has something to draw, not so it can round-trip.
    init(autoEQFilters filters: [AutoEQFilter], isEnabled: Bool = true) {
        // A third of an octave either side.
        let tolerance = pow(2.0, 1.0 / 3.0)
        let gains: [Float] = EQSettings.frequencies.map { frequency in
            let nearest = filters
                .filter { $0.type == .peaking && $0.frequency > 0 }
                .min { abs(log2($0.frequency / frequency)) < abs(log2($1.frequency / frequency)) }
            guard let nearest,
                  nearest.frequency <= frequency * tolerance,
                  nearest.frequency >= frequency / tolerance
            else { return 0 }
            return nearest.gainDB
        }
        self.init(bandGains: gains, isEnabled: isEnabled)
    }
}

// MARK: - Analysis

struct AnalysisReport: Codable, Equatable, Sendable {
    var integratedLUFS: Double
    var truePeakDBTP: Double
    var loudnessRangeLU: Double
    var peakDBFS: Double
    var noiseFloorDBFS: Double
    var dcOffset: Double
    var clippedSampleCount: Int
    var spectralTiltDBPerOctave: Double
    var leadingSilence: TimeInterval
    var trailingSilence: TimeInterval
    var interiorSilences: [ClosedRange<TimeInterval>]
    var isEffectivelyMono: Bool
    var measuredAt: Date
}

/// Where a destination's loudness target came from, so a surface can say
/// "Apple Podcasts asks for −16" rather than "target −16", and can say
/// "Melo's own −12" for the one nobody publishes a figure for.
///
/// This exists because the distinction was previously only in a source comment,
/// and a comment cannot reach the UI. Without it, the honest phrasing had to be
/// reconstructed by matching a destination's id — which works right up until
/// somebody adds a seventh destination, and then quietly presents one of Melo's
/// own guesses to the user as a specification.
///
/// The default is `.unverified`. A destination whose author did not say where
/// the number came from is a destination whose number Melo cannot vouch for,
/// and that is the safe way round.
enum TargetProvenance: Codable, Equatable, Sendable, Hashable {
    /// The organisation running the destination states the figure publicly.
    /// `authority` is who says it, short enough for a caption: "Apple Podcasts".
    case published(authority: String)
    /// Everyone in the industry agrees and it is trivially reproducible, but
    /// the platform does not publish it. YouTube normalising to −14 is this.
    case measured(authority: String)
    /// No published figure exists and this one is Melo's. Never to be presented
    /// as a specification.
    case unverified
}

/// Where the sound is going. Not a genre, and not a preset.
///
/// `DestinationCatalogue.all` is the list, and holds its contents and every
/// number in it. This file declares the shape only.
struct Destination: Codable, Equatable, Sendable, Identifiable, Hashable {
    /// "podcast". **A persistence format**: `EditorSession` stores this rather
    /// than the whole struct, and `ExportPresets` keys off it. Changing one of
    /// the six strings orphans every saved session that used it.
    var id: String
    /// "Podcast"
    var title: String
    /// One line, the app's voice.
    var blurb: String
    var symbolName: String
    var targetLUFS: Double
    /// Where `targetLUFS` came from. Ask this rather than the id.
    var targetProvenance: TargetProvenance
    var truePeakCeilingDBTP: Double
    var highPassHz: Double?
    var prefersMono: Bool
    var wantsSilenceTrimmed: Bool
    var wantsNoiseGate: Bool

    init(id: String,
         title: String,
         blurb: String,
         symbolName: String,
         targetLUFS: Double,
         targetProvenance: TargetProvenance = .unverified,
         truePeakCeilingDBTP: Double,
         highPassHz: Double? = nil,
         prefersMono: Bool = false,
         wantsSilenceTrimmed: Bool = false,
         wantsNoiseGate: Bool = false) {
        self.id = id
        self.title = title
        self.blurb = blurb
        self.symbolName = symbolName
        self.targetLUFS = targetLUFS
        self.targetProvenance = targetProvenance
        self.truePeakCeilingDBTP = truePeakCeilingDBTP
        self.highPassHz = highPassHz
        self.prefersMono = prefersMono
        self.wantsSilenceTrimmed = wantsSilenceTrimmed
        self.wantsNoiseGate = wantsNoiseGate
    }
}

// MARK: - The canonical buffer

/// Interleaved 32-bit float, one block, held in memory.
///
/// **Do not "fix" this to deinterleaved to match `AVAudioFile.processingFormat`.**
/// It is interleaved so that `samples` is already the exact layout Melo's own
/// DSP eats: `BiquadProcessor.process` (`Audio/EQ/BiquadProcessor.swift:199`)
/// is allocation-free and hands `vDSP_biquad` a stride of 2 over interleaved
/// stereo, so a `PCMBlock` goes into the editor's EQ with no conversion at all.
/// Deinterleaving here would move that conversion to every DSP boundary, which
/// is exactly where sample-order bugs live — and they are silent.
/// `AudioFileIO` owns the one interleave and the one deinterleave.
///
/// The source is decoded whole. The cost is honest and bounded: interleaved
/// Float32 is about 690 MB an hour at 48 kHz stereo, and the budget is two
/// hours — see `AudioFileIO.maximumDuration`, which refuses past it rather than
/// truncating or quietly allocating eight gigabytes.
struct PCMBlock: Sendable, Equatable {
    /// `count == frameCount * channelCount`, frame-major:
    /// `samples[frame * channelCount + channel]`.
    var samples: [Float]
    var sampleRate: Double
    var channelCount: Int

    init(samples: [Float], sampleRate: Double, channelCount: Int) {
        self.samples = samples
        self.sampleRate = sampleRate
        self.channelCount = channelCount
    }

    var frameCount: Int { samples.count / max(channelCount, 1) }
    var duration: TimeInterval { Double(frameCount) / max(sampleRate, 1) }
    var isEmpty: Bool { samples.isEmpty }

    /// The frame index a time lands on, clamped into the block.
    func frameIndex(at time: TimeInterval) -> Int {
        min(max(Int((time * sampleRate).rounded()), 0), frameCount)
    }
}

// MARK: - Waveform

struct WaveformData: Equatable, Sendable {
    /// `bucketCount * channelCount` entries, channel-interleaved within each
    /// time bucket: `buckets[bucket * channelCount + channel]`.
    var buckets: [Bucket]
    var duration: TimeInterval
    /// Where `removeSilence` spliced the sound, on this data's own timeline.
    /// Supplied by the render because the render is the only thing that knows;
    /// a second silence detector on the drawing side would have to agree with
    /// the first, which is the defect class `CLAUDE.md:138` records.
    var joins: [TimeInterval]

    struct Bucket: Equatable, Sendable {
        var minimum: Float
        var maximum: Float
        var rms: Float

        init(minimum: Float, maximum: Float, rms: Float) {
            self.minimum = minimum
            self.maximum = maximum
            self.rms = rms
        }
    }

    init(buckets: [Bucket], duration: TimeInterval, joins: [TimeInterval] = []) {
        self.buckets = buckets
        self.duration = duration
        self.joins = joins
    }
}

// MARK: - Progress

/// One progress type, so one progress view serves import, analysis, render,
/// export, extraction and recording.
struct JobProgress: Equatable, Sendable {
    /// `nil` means indeterminate — say so with a spinner, not a bar at zero.
    var fraction: Double?
    /// "Measuring loudness"
    var stage: String
    /// "1:42 of 4:10"
    var detail: String?
    var isCancellable: Bool

    init(stage: String,
         detail: String? = nil,
         fraction: Double? = nil,
         isCancellable: Bool = false) {
        self.fraction = fraction
        self.stage = stage
        self.detail = detail
        self.isCancellable = isCancellable
    }
}

// MARK: - Export

enum AudioFormatKind: String, CaseIterable, Codable, Sendable {
    case wav, aiff, caf, m4aAAC, m4aALAC, flac, mp3, opus

    var displayName: String {
        switch self {
        case .wav: "WAV"
        case .aiff: "AIFF"
        case .caf: "CAF"
        case .m4aAAC: "AAC"
        case .m4aALAC: "Apple Lossless"
        case .flac: "FLAC"
        case .mp3: "MP3"
        case .opus: "Opus"
        }
    }

    var fileExtension: String {
        switch self {
        case .wav: "wav"
        case .aiff: "aiff"
        case .caf: "caf"
        case .m4aAAC, .m4aALAC: "m4a"
        case .flac: "flac"
        case .mp3: "mp3"
        case .opus: "opus"
        }
    }

    /// `nil` when macOS can write it. Non-nil names the tool that has to be on
    /// the machine — there is no native MP3 or Opus encoder, and Melo says so
    /// rather than pretending.
    var requiresExternalTool: ExternalTool? {
        switch self {
        case .mp3, .opus: .ffmpeg
        case .wav, .aiff, .caf, .m4aAAC, .m4aALAC, .flac: nil
        }
    }
}

enum ExternalTool: String, Sendable, CaseIterable {
    case ffmpeg, ytdlp

    var executableName: String {
        switch self {
        case .ffmpeg: "ffmpeg"
        case .ytdlp: "yt-dlp"
        }
    }

    var installHint: String {
        switch self {
        case .ffmpeg: "brew install ffmpeg"
        case .ytdlp: "brew install yt-dlp"
        }
    }
}

struct ExportSettings: Codable, Equatable, Sendable {
    var format: AudioFormatKind
    /// `nil` keeps the source rate.
    var sampleRate: Double?
    /// Compressed formats only; ignored elsewhere.
    var bitRateKbps: Int?
    var channels: ChannelMode
    var destinationURL: URL

    init(format: AudioFormatKind,
         destinationURL: URL,
         sampleRate: Double? = nil,
         bitRateKbps: Int? = nil,
         channels: ChannelMode = .keep) {
        self.format = format
        self.sampleRate = sampleRate
        self.bitRateKbps = bitRateKbps
        self.channels = channels
        self.destinationURL = destinationURL
    }
}
