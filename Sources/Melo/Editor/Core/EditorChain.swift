// Melo/Editor/Core/EditorChain.swift
//
// What "the original" means, written down once, because three surfaces now have
// to agree about it and they live in three different layers.
//
// `EditorPlayback` needs it to build the buffer that hold-to-bypass plays.
// `EditorClipWaveforms` needs its complement to render the picture the compare
// lane is drawn *against*. And `scripts/verify-compare-bypass.py` needs to
// execute it without a window, an audio device or a view, which is the only
// reason it is here in Core rather than next to either caller.
//
// It used to be two private static functions on `EditorPlayback`, which is a
// SwiftUI-adjacent object holding an `AVAudioEngine`. Nothing headless can
// reach that, so the definition of the one thing a bypass is *for* was the one
// thing no assertion could execute — and a bypass whose filter silently matched
// nothing would have played the identical buffer, lit the identical control,
// and passed every frame anyone looked at. `CLAUDE.md`'s four-severed-wiring
// -points entry is that failure with different nouns.
//
// **The split is by what a move does to the clock, not by what it does to the
// level.** Anything that changes where a sample sits in time is kept on both
// sides; anything that changes what a sample sounds like is what comes out.
// That is not an aesthetic choice, it is what makes the comparison legible:
// `EditorPlayback.restart(at:)` splices the two renders at the same sample
// position, and the compare lane draws two pictures over one span of the
// ruler. Both break the instant the two sides stop being the same length.

import Foundation

/// The move chain, sliced two ways: what Melo did, and what was already there.
enum EditorChain {

    // MARK: - The split

    /// Whether a move changes *where* audio is rather than *what it sounds
    /// like*.
    ///
    /// Exhaustive over `MoveKind` on purpose: a new kind should fail to compile
    /// here rather than silently pick a side. A defaulted `default: false`
    /// would put every future move on the tone-and-level side without anybody
    /// deciding, and the failure mode of guessing wrong here is a bypass that
    /// jumps in time — which reads as a bug in playback, not as a
    /// classification mistake.
    static func shapesTime(_ move: Move) -> Bool {
        switch move.kind {
        case .trim, .removeSilence, .speed, .reverse:
            return true
        case .gain, .normalize, .limiter, .fadeIn, .fadeOut,
             .equalizer, .highPass, .noiseGate, .channels, .fixDCOffset:
            return false
        }
    }

    // MARK: - What bypass plays

    /// The document with **Melo's processing** removed and the user's
    /// arrangement left exactly as they built it.
    ///
    /// Three rules, in the order they bind.
    ///
    /// 1. **Anything that changes where a sample sits in time stays.** See the
    ///    file comment: the splice is at a sample position, so a bypass buffer
    ///    of a different length would jump rather than compare. `trim`,
    ///    `removeSilence`, `speed` and `reverse` therefore survive at clip,
    ///    track and master level alike.
    ///
    /// 2. **Tone and level moves come out, at every level.** A move is what
    ///    Melo proposed; the whole point of the control is judging those rather
    ///    than taking them on faith. Before tracks existed there was one list
    ///    and this filtered it; the multitrack render put the same kinds of
    ///    move on clips and tracks, and a bypass that stripped only the master
    ///    would quietly stop being a bypass.
    ///
    /// 3. **The user's own mixer is not touched.** Clip gain, track gain, pan,
    ///    mute and solo stay put, and so do the fades.
    ///
    /// Rule 3 is a deliberate departure from "strip level at every level", and
    /// the reason is what the control is *for*. Melo does not propose a track
    /// fader — the user dragged it. Flattening the faders makes bypass an A/B
    /// against a mix they never made, and on a four-track document the
    /// unity-gain sum of every track can be louder than anything they have
    /// heard so far, which is the worst possible surprise from a key you hold
    /// down to listen. Neutralising them is one line if that call is wrong;
    /// clamp the three gains and pan to zero here.
    ///
    /// Fades stay for a different reason and it is the stronger one: taking
    /// them out puts a click at every clip boundary, and a click is an artefact
    /// of the comparison rather than part of what is being compared. Two or
    /// three milliseconds of ramp is a cheaper lie than a transient that is not
    /// in either version of the audio.
    static func arrangementOnly(_ document: EditorDocument) -> EditorDocument {
        var copy = document
        copy.master = document.master.filter(shapesTime)
        for index in copy.tracks.indices {
            copy.tracks[index].moves = copy.tracks[index].moves.filter(shapesTime)
            for clipIndex in copy.tracks[index].clips.indices {
                copy.tracks[index].clips[clipIndex].moves =
                    copy.tracks[index].clips[clipIndex].moves.filter(shapesTime)
            }
        }
        return copy
    }

    // MARK: - What the compare lane draws

    /// The other half: the enabled moves that change the sound and not the
    /// clock.
    ///
    /// `isEnabled` is filtered here and **not** in `arrangementOnly`, which
    /// looks asymmetric and is not. `arrangementOnly` hands its result to
    /// `RenderEngine`, which does its own `filter(\.isEnabled)` at every level;
    /// filtering twice would be a second place for the rule to live. This
    /// result is handed to a synthetic document whose stack the caller builds,
    /// so a disabled move left in it would be dropped by the engine anyway —
    /// but it would still change the chain's fingerprint and cost a render that
    /// produces the identical picture, which is the cheapest kind of stale
    /// cache to avoid.
    static func toneAndLevel(_ moves: [Move]) -> [Move] {
        moves.filter { $0.isEnabled && !shapesTime($0) }
    }

    /// Everything that will colour one clip's sound, innermost first: the
    /// clip's own stack, then its track's, then the master.
    ///
    /// **The master is in here and that is an approximation, stated rather than
    /// hidden.** The master stack runs on the *sum* of every audible track, so
    /// applying it to one clip's audio in isolation is not what that clip
    /// contributes to the mix — a limiter on the master is driven by material
    /// this clip cannot see. It is included anyway for a reason that beats the
    /// inaccuracy: on the default document — one source, one track, one clip —
    /// the master is where every proposed move lives, so a compare lane that
    /// left it out would draw two identical pictures for the overwhelmingly
    /// common case and be worse than absent. The frame the lane sits in says
    /// what it is.
    ///
    /// *Rejected:* rendering the real mix and slicing this clip's span out of
    /// it. `EditorClipWaveforms`' file comment already argues why a clip is
    /// drawn from its source and not from the mix — after a trim the mix is a
    /// different length than the thing being drawn — and a compare lane cannot
    /// be the one place that reasoning stops applying.
    static func effectiveChain(
        clip: Clip,
        track: Track,
        document: EditorDocument
    ) -> [Move] {
        toneAndLevel(clip.moves) + toneAndLevel(track.moves) + toneAndLevel(document.master)
    }

    /// One source with nothing on it but `moves`, for asking `RenderEngine`
    /// what a chain does to a file.
    ///
    /// The same trick `EditorClipWaveforms.requestDetail` already uses for the
    /// sharp picture, with a stack on it. It is **not** a second render path:
    /// it is the one render actor asked about one file. And because `moves` has
    /// been through `toneAndLevel`, the answer is guaranteed to be the same
    /// length as the source — which is the invariant the compare lane's
    /// geometry rests on and the one `verify-compare-bypass.py` executes.
    static func isolated(_ source: EditorSource, through moves: [Move]) -> EditorDocument {
        EditorDocument(source: source, moves: moves)
    }

    // MARK: - Staleness

    /// A stamp that changes whenever anything in the document could change what
    /// a processed picture looks like.
    ///
    /// **Computed once per drawing pass for the whole document, never per
    /// clip.** `String(describing:)` on an enum with associated values goes
    /// through reflection, and the timeline's `plan` runs on every body
    /// evaluation — sixty a second while the sound plays. One pass over a
    /// handful of moves is affordable there; one pass per clip was not, and
    /// keying the cache by a per-clip fingerprint is what would have forced it.
    ///
    /// Callers only ever compare two stamps for equality, so the cost of a
    /// collision is a stale picture and not a wrong one — and a collision needs
    /// two different chains whose reflected descriptions match, which for
    /// values carrying their own numbers means they are the same chain.
    ///
    /// Only called when the compare lane is on. With it off there is no
    /// processed picture to be stale about and the timeline does not pay this.
    static func stamp(_ document: EditorDocument) -> String {
        var parts: [String] = []
        parts.append(describe(document.master))
        for track in document.tracks {
            parts.append(describe(track.moves))
            for clip in track.clips {
                parts.append(clip.id.uuidString)
                parts.append(describe(clip.moves))
            }
        }
        return parts.joined(separator: "\u{1}")
    }

    private static func describe(_ moves: [Move]) -> String {
        toneAndLevel(moves).map { String(describing: $0.kind) }.joined(separator: "\u{2}")
    }
}
