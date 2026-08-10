// Melo/Editor/Core/EditorTypes.swift
//
// Melo Edit's document model. Every type the editor shares lives here,
// and nowhere else. A type that is missing belongs in this file rather than
// being declared locally — a duplicate `Move` in two files is a build failure
// that arrives all at once.

import Foundation

// MARK: - The document

/// A timeline and everything we are doing to it.
///
/// A value type on purpose: the undo stack in `EditorStore` is an array of
/// these, which is the whole reason the simple thing works here. There is no
/// command pattern and there should not be one.
///
/// **One track by default, and it grows.** Opening a file makes exactly one
/// track holding exactly one clip covering the whole source, which is why the
/// window looks the same as it did before there were tracks at all. The mixer
/// is not drawn before there is anything to mix; nothing is hidden behind a
/// mode. See `.run-notes/TIMELINE-FRAME.md`.
struct EditorDocument: Codable, Equatable, Sendable {
    /// The decoded-file pool. A clip refers to one of these by id, so two clips
    /// cut from the same file cost one decode and one copy in memory. **Nothing
    /// removes a source because a clip stopped pointing at it** — dragging a
    /// clip's edge back out has to restore audio, and undo has to be able to
    /// bring the clip back.
    var sources: [EditorSource]
    /// Top to bottom, the way they are drawn.
    var tracks: [Track]
    /// What the destination path proposes, applied to the mix. Ordered: the
    /// render walks it front to back and reordering is a real edit.
    ///
    /// This is where a 3.1.x session's flat move list lands on migration, which
    /// is the only reading of the old Chain that stays true — those moves were
    /// applied to the whole sound.
    var master: [Move]
    /// `nil` until the user picks one.
    var destination: Destination?
    /// `nil` until the file has been measured. Describes the *first source*,
    /// not the rendered mix, so it survives every edit.
    var analysis: AnalysisReport?

    init(sources: [EditorSource] = [],
         tracks: [Track] = [],
         master: [Move] = [],
         destination: Destination? = nil,
         analysis: AnalysisReport? = nil) {
        self.sources = sources
        self.tracks = tracks
        self.master = master
        self.destination = destination
        self.analysis = analysis
    }

    /// One file, one track, one clip covering the whole of it.
    ///
    /// **The default state of the feature**, and the shape a migrated 3.1.x
    /// session takes. `moves` goes on the master because that is what the old
    /// flat list meant.
    init(source: EditorSource,
         moves: [Move] = [],
         destination: Destination? = nil,
         analysis: AnalysisReport? = nil) {
        self.init(
            sources: [source],
            tracks: [Track(name: Track.defaultName(at: 0), clips: [Clip(wholeOf: source)])],
            master: moves,
            destination: destination,
            analysis: analysis
        )
    }

    /// End of the last clip on any track. Zero for a document with no clips —
    /// which is a real state, because removing the last clip is allowed and is
    /// not the same thing as closing the file.
    var duration: TimeInterval {
        tracks.flatMap(\.clips).map(\.end).max() ?? 0
    }

    // MARK: Lookup

    func source(_ id: EditorSource.ID) -> EditorSource? {
        sources.first { $0.id == id }
    }

    func track(_ id: Track.ID) -> Track? {
        tracks.first { $0.id == id }
    }

    func clip(_ id: Clip.ID) -> Clip? {
        for track in tracks {
            if let found = track.clips.first(where: { $0.id == id }) { return found }
        }
        return nil
    }

    /// Which track a clip is on. There is exactly one; a clip id is unique
    /// across the document.
    func trackID(containing clipID: Clip.ID) -> Track.ID? {
        tracks.first { $0.clips.contains { $0.id == clipID } }?.id
    }

    /// Whether the mixer has anything to mix. The track headers and the
    /// timeline both ask, and they have to agree.
    var isMultitrack: Bool { tracks.count > 1 }

    /// The tracks that are actually heard, with solo resolved.
    ///
    /// **Solo is a filter, not a state change on other tracks.** Un-soloing
    /// restores exactly what was there, because nothing was ever written to the
    /// tracks that went quiet. The render and the headers read this one
    /// function rather than each deciding what solo means.
    var audibleTrackIDs: Set<Track.ID> {
        let soloed = tracks.filter(\.isSoloed)
        let heard = soloed.isEmpty ? tracks.filter { !$0.isMuted } : soloed.filter { !$0.isMuted }
        return Set(heard.map(\.id))
    }
}

// MARK: - The single-track view of a document

// **Transitional, and deliberately narrow.** Every surface written before
// tracks existed says `document.source` and `document.moves`, and every one of
// them is true of the default document: one source, and a master list that is
// what the old flat list became. Keeping these two spellings alive is what lets
// the render engine, export, playback and the waveform keep compiling while
// they are moved over one at a time, instead of the whole tree going red at
// once. They are not the model; the model is above. Delete them when the last
// caller is gone.
extension EditorDocument {

    /// The first source in the pool — for a document opened from one file, the
    /// only one.
    var source: EditorSource {
        get { sources.first ?? .unavailable }
        set {
            if sources.isEmpty { sources = [newValue] } else { sources[0] = newValue }
        }
    }

    /// The master list under its 3.1.x name.
    var moves: [Move] {
        get { master }
        set { master = newValue }
    }
}

// MARK: - Tracks and clips

/// One lane. Named, levelled, panned, muted, soloed — and holding clips.
struct Track: Codable, Equatable, Sendable, Identifiable {
    var id: UUID = UUID()
    /// "Track 1". The user can rename it; an empty name is not stored, the
    /// store puts the default back.
    var name: String
    var gainDB: Double = 0
    /// −1 hard left … +1 hard right.
    var pan: Double = 0
    var isMuted: Bool = false
    /// One track soloed silences the rest at render time. Nothing is written to
    /// the other tracks — see `EditorDocument.audibleTrackIDs`.
    var isSoloed: Bool = false
    /// In start order. The store keeps them sorted so the view can draw them
    /// without sorting in a `body`; overlaps are allowed and layer.
    var clips: [Clip] = []
    /// Applied to this track's mix, after the clips and before gain and pan.
    var moves: [Move] = []

    init(id: UUID = UUID(),
         name: String,
         gainDB: Double = 0,
         pan: Double = 0,
         isMuted: Bool = false,
         isSoloed: Bool = false,
         clips: [Clip] = [],
         moves: [Move] = []) {
        self.id = id
        self.name = name
        self.gainDB = gainDB
        self.pan = pan
        self.isMuted = isMuted
        self.isSoloed = isSoloed
        self.clips = clips
        self.moves = moves
    }

    /// "Track 1" for the first lane. Numbered from the position, not from a
    /// running counter, so the name matches what the user is looking at.
    static func defaultName(at index: Int) -> String { "Track \(index + 1)" }

    /// The tightest sensible range for this track: −24 to +12 dB, which is what
    /// the fader draws and what the store clamps to. A track fader is trim, not
    /// an amplifier.
    static let gainRange: ClosedRange<Double> = -24...12

    var end: TimeInterval { clips.map(\.end).max() ?? 0 }
}

/// A window onto a source, placed on the timeline.
///
/// **Trim is `sourceIn`/`sourceOut` and is therefore always non-destructive and
/// always reversible.** Dragging an edge back out restores audio that was never
/// thrown away, because nothing was ever cut — the numbers moved. Split makes
/// two clips sharing one source. Copy and paste move clips, not samples.
struct Clip: Codable, Equatable, Sendable, Identifiable {
    var id: UUID = UUID()
    var sourceID: EditorSource.ID
    /// Where the clip sits on the timeline.
    var start: TimeInterval = 0
    /// The window into the source, in the source's own time.
    var sourceIn: TimeInterval = 0
    var sourceOut: TimeInterval
    var gainDB: Double = 0
    /// Measured from the clip's own start and end. Both are draggable handles
    /// on the clip, which is why they live here and not in the Chain.
    var fadeIn: TimeInterval = 0
    var fadeOut: TimeInterval = 0
    var fadeCurve: FadeCurve = .equalPower
    /// Applied to this clip alone, before the track sees it.
    var moves: [Move] = []

    init(id: UUID = UUID(),
         sourceID: EditorSource.ID,
         start: TimeInterval = 0,
         sourceIn: TimeInterval = 0,
         sourceOut: TimeInterval,
         gainDB: Double = 0,
         fadeIn: TimeInterval = 0,
         fadeOut: TimeInterval = 0,
         fadeCurve: FadeCurve = .equalPower,
         moves: [Move] = []) {
        self.id = id
        self.sourceID = sourceID
        self.start = start
        self.sourceIn = sourceIn
        self.sourceOut = sourceOut
        self.gainDB = gainDB
        self.fadeIn = fadeIn
        self.fadeOut = fadeOut
        self.fadeCurve = fadeCurve
        self.moves = moves
    }

    /// The whole of a source, at the head of the timeline. What opening a file
    /// makes.
    init(wholeOf source: EditorSource, start: TimeInterval = 0) {
        self.init(sourceID: source.id, start: start, sourceIn: 0, sourceOut: source.duration)
    }

    /// A millisecond. Small enough that zooming to sample-adjacent still leaves
    /// something to grab, large enough that a trim cannot collapse a clip to
    /// nothing and strand its id in the selection.
    static let minimumDuration: TimeInterval = 0.001

    /// **Clamped at zero**, unlike the plain subtraction in the frame. A clip
    /// whose window inverted would otherwise report a negative length, and the
    /// first thing that happens to `duration` is arithmetic on a frame count.
    /// The store never produces an inverted window; this is about what a
    /// decoded sidecar can hand us.
    var duration: TimeInterval { max(0, sourceOut - sourceIn) }
    var end: TimeInterval { start + duration }
    var range: ClosedRange<TimeInterval> { start...(start + max(duration, .ulpOfOne)) }

    /// Whether a point on the timeline falls inside this clip.
    func contains(_ time: TimeInterval) -> Bool {
        time >= start && time < end
    }

    /// The point in the *source* that a point on the timeline reads from.
    func sourceTime(atTimelineTime time: TimeInterval) -> TimeInterval {
        sourceIn + (time - start)
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

    /// What `EditorDocument.source` answers for a document with an empty pool.
    ///
    /// Only reachable through a decoded document that has no sources at all,
    /// which nothing in the app produces — every open goes through
    /// `EditorDocument(source:)`. It exists so the transitional accessor can be
    /// non-optional without a force-unwrap: a zero-length source draws nothing
    /// and measures nothing, where a crash on the way to the window is a defect
    /// this project has already paid for once.
    static let unavailable = EditorSource(
        url: URL(fileURLWithPath: "/"),
        displayName: "",
        origin: .file(originalURL: URL(fileURLWithPath: "/")),
        duration: 0,
        sampleRate: 48_000,
        channelCount: 2,
        formatDescription: ""
    )
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
    /// Written when the move is created; shown in the Chain.
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

    /// `nil` when macOS can write it. Non-nil names the tool that does the
    /// encoding — there is no native MP3 or Opus encoder on macOS, so both go
    /// out through the `ffmpeg` Melo ships in `Contents/Helpers`. It is not a
    /// statement about what the user has to install.
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

    /// Whether Melo ships this one inside the app bundle.
    ///
    /// ffmpeg is built from upstream source by `scripts/build-ffmpeg.sh` and
    /// copied to `Contents/Helpers/ffmpeg` — it is audio-only, arm64, and does
    /// not move. yt-dlp is not bundled and will not be: it tracks sites that
    /// change weekly, so a frozen copy is a broken feature that looks installed.
    var isBundled: Bool {
        switch self {
        case .ffmpeg: true
        case .ytdlp: false
        }
    }

    /// The shell command that gets you the tool, or `nil` when there is nothing
    /// for the user to install. Melo ships ffmpeg, so telling someone to
    /// `brew install` it would be asking them to fix Melo's problem.
    var installCommand: String? {
        switch self {
        case .ffmpeg: nil
        case .ytdlp: "brew install yt-dlp"
        }
    }

    /// What went wrong when the tool is not there.
    ///
    /// For ffmpeg that is a damaged or incomplete copy of Melo, not a missing
    /// dependency — every normal build carries one.
    var missingDescription: String {
        switch self {
        case .ffmpeg: "Melo's own ffmpeg is missing from the app."
        case .ytdlp: "That needs yt-dlp, which isn't on this Mac."
        }
    }

    /// What to do about it. A sentence, not a command — `installCommand` is the
    /// command, when there is one, so a view can offer it as copyable text.
    var missingRecovery: String {
        switch self {
        case .ffmpeg: "Reinstalling Melo puts it back."
        case .ytdlp: "Install it with brew install yt-dlp."
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
