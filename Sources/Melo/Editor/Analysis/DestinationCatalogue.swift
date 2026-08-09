// Melo/Editor/Analysis/DestinationCatalogue.swift
import Foundation

/// Where a sound can be going, and the published numbers that define "right"
/// once it gets there.
///
/// This is the novice path's whole vocabulary. It is deliberately **not** a
/// genre list: "Rock" cannot explain itself, and it cannot tell you whether
/// your file is already correct. A destination can, because a destination has
/// a number behind it and the number came from somewhere.
///
/// ## Where the numbers came from
///
/// Every figure below carries its source in the comment beside it. Three kinds
/// appear, and they are labelled differently on purpose:
///
/// - **Published.** The organisation that runs the destination states the
///   figure. Cite the page.
/// - **Widely measured.** Everyone in the industry agrees on the number and it
///   is trivially reproducible, but the platform does not publish it. Say so.
/// - **unverified.** No published figure exists and this one is Melo's choice.
///   Say the word, say why the choice is what it is, and never dress it up as
///   a standard.
///
/// Checked 2026-08-09. Loudness targets move; when one does, this file is the
/// only place that has to change.
enum DestinationCatalogue {

    // MARK: - Identifiers

    /// Stable ids. Used as the `Destination.id`, persisted inside the document,
    /// and matched by `MoveProposer` for the two rules that are genuinely
    /// destination-specific rather than field-driven.
    enum ID {
        static let podcast = "podcast"
        static let music = "music"
        static let video = "video"
        static let ringtone = "ringtone"
        static let voiceMemo = "voice-memo"
        static let justBetter = "just-better"
    }

    // MARK: - The list

    static let all: [Destination] = [
        podcast, music, video, ringtone, voiceMemo, justBetter
    ]

    // MARK: - Podcast

    static let podcast = Destination(
        id: ID.podcast,
        title: "Podcast",
        blurb: "Lands where podcast apps expect it, so nobody reaches for the volume.",
        symbolName: "mic.fill",
        // PUBLISHED. Apple Podcasts, "Audio requirements": episode audio should
        // be preconditioned so "the overall loudness remains around -16 dB LKFS,
        // with a +/- 1 dB tolerance". LKFS and LUFS are the same scale under
        // ITU-R BS.1770; the two names exist for historical reasons.
        // https://podcasters.apple.com/support/893-audio-requirements
        //
        // A single-channel file measures ~3 LU lower than the same programme
        // carried on two channels, because BS.1770 sums channel powers. Melo
        // does not encode a second mono number here — `MoveProposer` applies the
        // 3 LU offset from the file's own channel count, which is the only way
        // to get it right for a file that is about to be converted to mono.
        targetLUFS: -16.0,
        targetProvenance: .published(authority: "Apple Podcasts"),
        // PUBLISHED. Same Apple page: "the true-peak value doesn't exceed
        // -1 dB FS". The 1 dB of headroom is what stops an MP3 or AAC encoder
        // from clipping on inter-sample peaks it reconstructs above full scale.
        truePeakCeilingDBTP: -1.0,
        // unverified as a published figure. 80 Hz is Melo's choice: an adult
        // speaking voice has essentially no fundamental below it, so everything
        // under 80 Hz in a spoken recording is room, desk and traffic. It is
        // proposed only when the measured noise floor says there is something
        // down there to remove — see `MoveProposer`.
        highPassHz: 80,
        // Proposed only when the two channels already carry the same signal, so
        // it halves the file and changes nothing audible.
        prefersMono: true,
        wantsSilenceTrimmed: true,
        wantsNoiseGate: true
    )

    // MARK: - Music

    static let music = Destination(
        id: ID.music,
        title: "Music",
        blurb: "For streaming, where every track gets pulled to the same level anyway.",
        symbolName: "music.note",
        // PUBLISHED. Spotify for Artists, "Loudness normalization": Spotify
        // normalises to -14 dB LUFS.
        // https://support.spotify.com/us/artists/article/loudness-normalization/
        //
        // Widely measured: YouTube, Amazon Music and Tidal land on the same
        // -14 LUFS. Apple Music's Sound Check is measured at roughly -16 LUFS,
        // but Apple does not publish that figure, so it is not the target here.
        targetLUFS: -14.0,
        targetProvenance: .published(authority: "Spotify"),
        // PUBLISHED, twice over. Spotify: keep masters "below -1dB TP (True
        // Peak) max", and -2 dBTP if the master is louder than -14 LUFS. Apple
        // Digital Masters requires <= -1 dBTP for certification because the
        // pipeline runs the file through Apple's AAC encoder.
        truePeakCeilingDBTP: -1.0,
        highPassHz: nil,
        prefersMono: false,
        wantsSilenceTrimmed: true,
        wantsNoiseGate: false
    )

    // MARK: - Video

    static let video = Destination(
        id: ID.video,
        title: "Video",
        blurb: "For picture. Nothing gets trimmed, so nothing slides out of sync.",
        symbolName: "film",
        // WIDELY MEASURED, not published by YouTube: uploads are normalised to
        // about -14 LUFS integrated, and content quieter than that is left
        // alone rather than turned up. That asymmetry is the reason this is
        // -14 and not the broadcast figure.
        //
        // Broadcast delivery is a different world and its numbers *are*
        // published: EBU R 128 sets programme loudness at -23 LUFS with a
        // +/- 0.5 LU tolerance (https://tech.ebu.ch/publications/r128/), and
        // ATSC A/85, which the US CALM Act adopts by reference, targets
        // -24 LKFS (https://www.atsc.org/wp-content/uploads/2025/06/A85-2013-with-Corrigendum-No-1.pdf).
        // Melo aims at the online figure because a menu-bar audio editor's file
        // is going to a video site, and -23 LUFS there is simply a quiet video.
        targetLUFS: -14.0,
        // Measured rather than published: YouTube is where this number is true,
        // and YouTube has never printed it.
        targetProvenance: .measured(authority: "YouTube"),
        // PUBLISHED, EBU R 128: maximum permitted true peak level -1 dBTP. The
        // same ceiling every lossy codec wants.
        truePeakCeilingDBTP: -1.0,
        highPassHz: nil,
        prefersMono: false,
        // The one field that makes Video genuinely different from Music.
        // Trimming dead air off the front of a video's audio slides every
        // subsequent word away from the mouth that said it.
        wantsSilenceTrimmed: false,
        wantsNoiseGate: false
    )

    // MARK: - Ringtone

    static let ringtone = Destination(
        id: ID.ringtone,
        title: "Ringtone",
        blurb: "Short, loud, and it starts on the first note.",
        symbolName: "bell.fill",
        // unverified. There is no published loudness standard for ringtones,
        // and nothing on a phone normalises them. -12 LUFS is Melo's choice:
        // a ringtone competes with a room and a pocket through a speaker the
        // size of a fingernail, so it runs hotter than anything a streaming
        // service would accept. It is 2 dB above the streaming figure, not 10 —
        // a ringtone crushed flat is still an unpleasant ringtone.
        targetLUFS: -12.0,
        targetProvenance: .unverified,
        // Derived from a published requirement rather than published for
        // ringtones as such: an .m4r is AAC, and Apple Digital Masters requires
        // <= -1 dBTP ahead of AAC encoding for exactly this reason.
        truePeakCeilingDBTP: -1.0,
        // unverified. 120 Hz is Melo's choice. A phone's earpiece speaker
        // reproduces almost nothing below it, so low end only eats the headroom
        // the ringtone needs to be heard. Proposed only when the file's noise
        // floor suggests there is something down there.
        highPassHz: 120,
        prefersMono: false,
        wantsSilenceTrimmed: true,
        wantsNoiseGate: false
    )

    // MARK: - Voice memo

    static let voiceMemo = Destination(
        id: ID.voiceMemo,
        title: "Voice memo",
        blurb: "Somebody talking, made easy to hear.",
        symbolName: "waveform",
        // PUBLISHED. Google's "Audio loudness" developer guidance for spoken
        // content: "the average loudness should be -16 LUFS ... for stereo
        // audio content", and "for mono audio content, the average loudness
        // should be -19 LUFS". The 3 LU gap is the dual-mono summation, and it
        // is the same relationship Melo applies from the file's channel count.
        // https://developers.google.com/assistant/tools/audio-loudness
        //
        // This is the same figure as Podcast because it is the same published
        // number for the same material. What differs is everything else below.
        // "Google" rather than the full title of the page, because this string
        // is read out in a caption beside a number. The citation is above.
        targetLUFS: -16.0,
        targetProvenance: .published(authority: "Google"),
        // Same reason as Podcast: 1 dB of codec headroom.
        truePeakCeilingDBTP: -1.0,
        // unverified. 100 Hz is Melo's choice, a little higher than Podcast's
        // 80 because a memo is usually a phone or laptop microphone held close
        // to a desk, and the desk is the loudest thing under 100 Hz.
        highPassHz: 100,
        prefersMono: true,
        wantsSilenceTrimmed: true,
        wantsNoiseGate: true
    )

    // MARK: - Just better

    static let justBetter = Destination(
        id: ID.justBetter,
        title: "Just better",
        blurb: "No idea where it's going? Melo fixes what is actually wrong with it.",
        symbolName: "wand.and.sparkles",
        // unverified as a target for this destination, and deliberately loose.
        // -16 LUFS is where Apple's Sound Check is widely measured to sit, so
        // it is a defensible middle between spoken word and streaming music.
        // The number matters far less here than the tolerance: `justBetter`
        // only proposes a level change when the file is more than 4 LU away
        // (see `loudnessToleranceLU`), because "make it better" means repair
        // the defects, not impose a level on someone who did not ask for one.
        targetLUFS: -16.0,
        // Informed by Sound Check, but the number is Melo's and the tolerance is
        // the point. Nobody publishes a target for "make it better".
        targetProvenance: .unverified,
        truePeakCeilingDBTP: -1.0,
        highPassHz: nil,
        prefersMono: false,
        wantsSilenceTrimmed: true,
        wantsNoiseGate: false
    )

    // MARK: - Tolerances

    /// How far off the target a file may already be before Melo proposes moving
    /// it. A file inside the tolerance is *already there*, and saying so is
    /// worth more than a move that changes nothing perceptible.
    ///
    /// Two of these come from the specs themselves.
    static func loudnessToleranceLU(for destination: Destination) -> Double {
        switch destination.id {
        // PUBLISHED. Apple Podcasts states the -16 LKFS target "with a +/- 1 dB
        // tolerance", so a podcast at -15.4 LUFS is compliant, not wrong.
        case ID.podcast, ID.voiceMemo:
            return 1.0
        // Melo's choice, and the point of this destination. Four loudness units
        // is roughly the range a listener would call "fine" without a reference
        // to compare against.
        case ID.justBetter:
            return 4.0
        // PUBLISHED. EBU R 128 restricts the -23 LUFS target's tolerance to
        // +/- 0.5 LU. Melo borrows the tolerance, not the target.
        default:
            return 0.5
        }
    }

    /// PUBLISHED. Apple's GarageBand user guide caps an exported ringtone at
    /// 30 seconds; a longer .m4r is not offered as a tone.
    ///
    /// This lives here rather than on `Destination` because `Destination` has no
    /// duration field. If a second destination ever needs one, the right fix is
    /// a `maximumDuration: TimeInterval?` on the struct, not a second constant.
    static let ringtoneMaximumDuration: TimeInterval = 30
}

// MARK: - Saying where a number came from

/// One set of phrasings, so the picker, the analysis pane, a move's rationale
/// and the after-export summary all describe a target the same way — and so
/// none of them has to match an id to work out whether Melo is quoting somebody
/// or quoting itself.
extension Destination {

    /// Who stands behind `targetLUFS`: "Apple Podcasts", "YouTube", or
    /// "Melo's own" when nobody does.
    ///
    /// This is the one a compact summary wants: `"\(targetAttribution) "
    /// + EditorFormat.number(targetLUFS, places: 1)` gives "Melo's own −12.0".
    var targetAttribution: String {
        switch targetProvenance {
        case .published(let authority), .measured(let authority): authority
        case .unverified: "Melo's own"
        }
    }

    /// False when the figure is Melo's own choice or an industry measurement
    /// nobody prints. A surface that is about to call a number a specification
    /// should ask this first.
    var isTargetPublished: Bool {
        if case .published = targetProvenance { return true }
        return false
    }

    /// A clause that reads as a sentence with a full stop after it.
    ///
    /// "Apple Podcasts asks for −16.0 LUFS" · "YouTube levels everything to
    /// −14.0 LUFS" · "Melo's own target is −12.0 LUFS".
    ///
    /// `effectiveLUFS` is what this particular file has to hit — `MoveProposer`
    /// drops the target 3 LU for a single-channel file. When it differs from the
    /// published figure the clause says so rather than attributing Melo's
    /// channel correction to Apple.
    func targetPhrase(effectiveLUFS: Double) -> String {
        let printed = EditorFormat.number(targetLUFS, places: 1)
        let head: String
        switch targetProvenance {
        case .published(let authority):
            head = "\(authority) asks for \(printed) LUFS"
        case .measured(let authority):
            head = "\(authority) levels everything to \(printed) LUFS"
        case .unverified:
            head = "Melo's own target is \(printed) LUFS"
        }
        guard abs(effectiveLUFS - targetLUFS) > 0.05 else { return head }
        return head + ", \(EditorFormat.number(effectiveLUFS, places: 1)) for a single channel"
    }

    /// The same fact in the middle of a sentence about a gap: "7.4 dB under
    /// **what Apple Podcasts asks for**", "8.0 dB under **Melo's own target**".
    var targetOwnerPhrase: String {
        switch targetProvenance {
        case .published(let authority): "what \(authority) asks for"
        case .measured(let authority): "where \(authority) levels everything"
        case .unverified: "Melo's own target"
        }
    }
}
