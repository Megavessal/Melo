// Melo/Editor/Analysis/MoveProposer.swift
import Foundation

/// The whole novice path, in one pure function.
///
/// A measured report plus a chosen destination produces the moves. Nothing here
/// touches audio, a file, a clock or the main actor, which is the point: the
/// most important function in the feature is the one that can be run a thousand
/// times in a test.
///
/// ## The rule that keeps this from being a preset
///
/// **Every move must be caused by a measurement.** A file already sitting at
/// −15.8 LUFS on its way to streaming does not get a normalize move — it gets
/// told it is already there. A file with no clipping does not get a limiter. A
/// quiet room does not get a noise gate. If the same list comes out for every
/// file, this is a genre preset wearing a costume, and the destinations were
/// chosen over genre presets precisely because a destination can explain
/// itself.
///
/// Each move carries a `rationale`: one sentence naming the number, from this
/// file, that caused it.
///
/// ## What this deliberately never proposes
///
/// - **An equalizer curve.** No destination publishes one. Inventing "the
///   podcast curve" would be the genre preset arriving through the back door,
///   and it would be the one move the user could not check against anything.
///   Tone correction here is a high pass, proposed only when the measured noise
///   floor says there is something below the voice to remove. The full
///   equalizer stays where the user puts it deliberately.
/// - **Speed or reverse.** Neither has a measurement that would call for it.
/// - **A fade in.** Nothing measurable distinguishes "starts abruptly" from
///   "starts".
enum MoveProposer {

    // MARK: - The entry point

    static func propose(
        for report: AnalysisReport,
        destination: Destination,
        source: EditorSource
    ) -> [Move] {
        var moves: [Move] = []

        // 1. DC offset — a correction to the recording, so it goes first.
        if let move = dcOffsetMove(report) { moves.append(move) }

        // 2/3/4. Timeline. The trim window is worked out once, because two
        // separate rules can move its edges and two trim moves would fight.
        let window = trimWindow(report: report, destination: destination, source: source)
        if let move = trimMove(window, report: report, source: source) { moves.append(move) }
        if let move = interiorSilenceMove(report, destination: destination) { moves.append(move) }
        if let move = ringtoneFadeMove(window) { moves.append(move) }

        // 5-9. Level and tone, in the order of Melo's own live signal chain:
        // EQ, noise gate, normalize, limiter, channel mode.
        if let move = highPassMove(report, destination: destination) { moves.append(move) }
        if let move = noiseGateMove(report, destination: destination) { moves.append(move) }

        let mono = monoMove(report, destination: destination, source: source)
        let loudness = loudnessAssessment(report: report, destination: destination, source: source)
        if let move = normalizeMove(loudness, destination: destination) { moves.append(move) }
        if let move = limiterMove(report, destination: destination, loudness: loudness) {
            moves.append(move)
        }
        if let move = mono { moves.append(move) }

        return moves
    }

    // MARK: - Loudness, shared with the views

    /// What the file has to hit, corrected for how many channels carry it.
    ///
    /// BS.1770 sums channel powers, so a genuinely single-channel file measures
    /// about 3 LU below the same programme carried on two channels — which is
    /// exactly the gap in Google's published spoken-word guidance (−16 LUFS
    /// stereo, −19 LUFS mono) and why that pair exists at all.
    ///
    /// A stereo file that Melo is *about to* fold to mono needs no correction
    /// here: the fold drops the measurement and the target by the same 3 LU, so
    /// the difference between them is unchanged.
    static func effectiveTargetLUFS(for destination: Destination, source: EditorSource) -> Double {
        source.channelCount <= 1 ? destination.targetLUFS - 3.0 : destination.targetLUFS
    }

    /// Everything the loudness rules need, computed once.
    struct LoudnessAssessment: Equatable, Sendable {
        var measuredLUFS: Double
        var targetLUFS: Double
        var toleranceLU: Double
        /// Positive means the file has to come up.
        var deltaDB: Double { targetLUFS - measuredLUFS }
        /// True when the file is already where the destination wants it.
        var isAlreadyThere: Bool { abs(deltaDB) <= toleranceLU }
    }

    static func loudnessAssessment(
        report: AnalysisReport,
        destination: Destination,
        source: EditorSource
    ) -> LoudnessAssessment {
        LoudnessAssessment(
            measuredLUFS: report.integratedLUFS,
            targetLUFS: effectiveTargetLUFS(for: destination, source: source),
            toleranceLU: DestinationCatalogue.loudnessToleranceLU(for: destination)
        )
    }

    // MARK: - DC offset

    /// A steady offset above 0.1% of full scale. Below that it is measurement
    /// noise and removing it is a move that does nothing.
    private static let dcOffsetFloor = 0.001

    private static func dcOffsetMove(_ report: AnalysisReport) -> Move? {
        guard abs(report.dcOffset) >= dcOffsetFloor else { return nil }
        let percent = abs(report.dcOffset) * 100
        return Move(
            id: UUID(),
            kind: .fixDCOffset(measuredOffset: report.dcOffset),
            isEnabled: true,
            rationale: "The waveform sits \(EditorFormat.number(percent, places: 2))% off centre, "
                + "which costs you headroom and can click at every edit."
        )
    }

    // MARK: - Trim

    /// Silence shorter than this at an end is a breath, not dead air.
    private static let endSilenceFloor: TimeInterval = 0.35

    /// Never propose a trim that would leave less than this behind.
    private static let minimumRemainder: TimeInterval = 0.5

    struct TrimWindow: Equatable, Sendable {
        var start: TimeInterval
        var end: TimeInterval
        var trimmedLead: Bool
        var trimmedTail: Bool
        var truncatedForRingtone: Bool
        var isChange: Bool
    }

    static func trimWindow(
        report: AnalysisReport,
        destination: Destination,
        source: EditorSource
    ) -> TrimWindow {
        var start: TimeInterval = 0
        var end = source.duration
        var trimmedLead = false
        var trimmedTail = false
        var truncated = false

        if destination.wantsSilenceTrimmed {
            if report.leadingSilence >= endSilenceFloor {
                start = report.leadingSilence
                trimmedLead = true
            }
            if report.trailingSilence >= endSilenceFloor {
                end = source.duration - report.trailingSilence
                trimmedTail = true
            }
        }

        // Apple's published 30-second cap on an exported ringtone. Applied after
        // the lead is trimmed, so the 30 seconds are 30 seconds of sound.
        if destination.id == DestinationCatalogue.ID.ringtone,
           end - start > DestinationCatalogue.ringtoneMaximumDuration {
            end = start + DestinationCatalogue.ringtoneMaximumDuration
            truncated = true
        }

        // A window that would leave almost nothing is a bad measurement, not an
        // instruction. Back out of the whole thing rather than shipping a move
        // that deletes the file.
        if end - start < minimumRemainder {
            return TrimWindow(
                start: 0, end: source.duration,
                trimmedLead: false, trimmedTail: false,
                truncatedForRingtone: false, isChange: false
            )
        }

        let isChange = start > 0.0001 || end < source.duration - 0.0001
        return TrimWindow(
            start: start, end: end,
            trimmedLead: trimmedLead, trimmedTail: trimmedTail,
            truncatedForRingtone: truncated, isChange: isChange
        )
    }

    private static func trimMove(
        _ window: TrimWindow,
        report: AnalysisReport,
        source: EditorSource
    ) -> Move? {
        guard window.isChange else { return nil }
        return Move(
            id: UUID(),
            kind: .trim(start: window.start, end: window.end),
            isEnabled: true,
            rationale: trimRationale(window, report: report, source: source)
        )
    }

    private static func trimRationale(
        _ window: TrimWindow,
        report: AnalysisReport,
        source: EditorSource
    ) -> String {
        if window.truncatedForRingtone {
            let cap = Int(DestinationCatalogue.ringtoneMaximumDuration)
            if window.trimmedLead {
                return "There's \(EditorFormat.seconds(report.leadingSilence)) of nothing up front and a "
                    + "ringtone stops at \(cap) seconds, so this keeps the \(cap) seconds "
                    + "after the sound starts."
            }
            return "This runs \(EditorFormat.timecode(source.duration)) and a ringtone stops at \(cap) seconds, "
                + "so this keeps the first \(cap)."
        }
        if window.trimmedLead && window.trimmedTail {
            return "There's \(EditorFormat.seconds(report.leadingSilence)) of room tone at the front and "
                + "\(EditorFormat.seconds(report.trailingSilence)) at the end — this starts you at the "
                + "first sound and stops at the last."
        }
        if window.trimmedLead {
            return "There's \(EditorFormat.seconds(report.leadingSilence)) of room tone before anything "
                + "happens, so this starts you at the first sound."
        }
        return "There's \(EditorFormat.seconds(report.trailingSilence)) of room tone after the last sound, "
            + "so this stops there instead."
    }

    /// A ringtone cut off at exactly 30 seconds lands mid-sound and clicks.
    /// Nothing else here is truncated, so nothing else gets a fade.
    private static func ringtoneFadeMove(_ window: TrimWindow) -> Move? {
        guard window.truncatedForRingtone else { return nil }
        return Move(
            id: UUID(),
            kind: .fadeOut(length: 0.5, curve: .equalPower),
            isEnabled: true,
            rationale: "The \(Int(DestinationCatalogue.ringtoneMaximumDuration))-second cut "
                + "lands mid-sound, so half a second of fade keeps it from clicking."
        )
    }

    // MARK: - Interior silence

    private static let longGapFloor: TimeInterval = 1.5
    private static let totalGapFloor: TimeInterval = 3.0

    /// Only for the spoken-word destinations. Shortening the gaps in music is
    /// not tidying, it is editing the piece.
    private static func interiorSilenceMove(
        _ report: AnalysisReport,
        destination: Destination
    ) -> Move? {
        guard destination.wantsNoiseGate else { return nil }
        let longGaps = report.interiorSilences.filter {
            $0.upperBound - $0.lowerBound >= longGapFloor
        }
        let total = longGaps.reduce(0.0) { $0 + ($1.upperBound - $1.lowerBound) }
        guard longGaps.count >= 2, total >= totalGapFloor else { return nil }

        // Threshold from the file's own noise floor rather than a constant: a
        // fixed −40 dB would find nothing in a quiet studio recording and
        // swallow whole words in a noisy one.
        return Move(
            id: UUID(),
            kind: .removeSilence(
                thresholdDB: report.noiseFloorDBFS + 6.0,
                minimumLength: longGapFloor,
                leaveTail: 0.25
            ),
            isEnabled: true,
            rationale: "\(longGaps.count) gaps longer than a second and a half, "
                + "\(EditorFormat.seconds(total)) in total — this shortens them and leaves a quarter "
                + "second of breath in each."
        )
    }

    // MARK: - High pass

    /// A noise floor above this is a room, not a recording booth, and a room has
    /// rumble in it. This is the measurement that turns the destination's
    /// high-pass frequency into a proposal; without it, every speech file would
    /// get the same filter and the move would be a template.
    private static let audibleNoiseFloorDBFS = -55.0

    private static func highPassMove(
        _ report: AnalysisReport,
        destination: Destination
    ) -> Move? {
        guard let frequency = destination.highPassHz,
              report.noiseFloorDBFS > audibleNoiseFloorDBFS else { return nil }
        return Move(
            id: UUID(),
            kind: .highPass(frequency: frequency),
            isEnabled: true,
            rationale: "Your noise floor sits at \(EditorFormat.number(report.noiseFloorDBFS, places: 1)) dBFS, "
                + "which is usually room rumble — a high pass at \(EditorFormat.hertz(frequency)) clears it without "
                + "touching the voice."
        )
    }

    // MARK: - Noise gate

    /// Quieter than this and there is nothing between the words worth gating.
    private static let gateWorthwhileFloorDBFS = -50.0

    private static func noiseGateMove(
        _ report: AnalysisReport,
        destination: Destination
    ) -> Move? {
        guard destination.wantsNoiseGate,
              report.noiseFloorDBFS > gateWorthwhileFloorDBFS else { return nil }
        let threshold = report.noiseFloorDBFS + 4.0
        return Move(
            id: UUID(),
            kind: .noiseGate(thresholdDB: threshold, attackMS: 5, releaseMS: 120),
            isEnabled: true,
            rationale: "Between words the room sits at \(EditorFormat.number(report.noiseFloorDBFS, places: 1)) dBFS; "
                + "gating just above it at \(EditorFormat.number(threshold, places: 1)) dBFS quiets that without clipping "
                + "the starts of words."
        )
    }

    // MARK: - Normalize

    private static func normalizeMove(
        _ loudness: LoudnessAssessment,
        destination: Destination
    ) -> Move? {
        guard !loudness.isAlreadyThere else { return nil }
        let delta = loudness.deltaDB
        let direction = delta > 0 ? "under" : "over"
        return Move(
            id: UUID(),
            kind: .normalize(
                appliedGainDB: delta,
                measuredLUFS: loudness.measuredLUFS,
                targetLUFS: loudness.targetLUFS
            ),
            isEnabled: true,
            // `targetOwnerPhrase`, not the destination's title: a rationale that
            // says "what podcast wants" makes Melo the authority for a figure
            // Apple publishes, and — worse — says the same thing about the
            // ringtone target, which Melo made up.
            rationale: "This measured \(EditorFormat.number(loudness.measuredLUFS, places: 1)) LUFS, "
                + "\(EditorFormat.decibels(abs(delta))) \(direction) \(destination.targetOwnerPhrase) "
                + "— this moves it to \(EditorFormat.number(loudness.targetLUFS, places: 1))."
        )
    }

    // MARK: - Limiter

    /// A hair of slack so a file sitting exactly on the ceiling does not get a
    /// limiter that has nothing to do.
    private static let ceilingSlackDB = 0.05

    private static func limiterMove(
        _ report: AnalysisReport,
        destination: Destination,
        loudness: LoudnessAssessment
    ) -> Move? {
        let appliedGain = loudness.isAlreadyThere ? 0 : loudness.deltaDB
        let predictedPeak = report.truePeakDBTP + appliedGain
        let ceiling = destination.truePeakCeilingDBTP
        guard predictedPeak > ceiling + ceilingSlackDB else { return nil }

        let rationale: String
        if report.clippedSampleCount > 0 {
            rationale = "\(sampleCount(report.clippedSampleCount)) samples are already flat at the top "
                + "and the peaks reach \(EditorFormat.number(predictedPeak, places: 1)) dBTP — a limiter holds "
                + "them at \(EditorFormat.number(ceiling, places: 1)) so nothing new distorts."
        } else if appliedGain > 0 {
            rationale = "Lifting it puts the peaks at \(EditorFormat.number(predictedPeak, places: 1)) dBTP, past "
                + "the \(EditorFormat.number(ceiling, places: 1)) dBTP ceiling, so a limiter holds them there."
        } else {
            rationale = "Peaks reach \(EditorFormat.number(report.truePeakDBTP, places: 1)) dBTP, above the "
                + "\(EditorFormat.number(ceiling, places: 1)) dBTP ceiling that keeps MP3 and AAC from "
                + "distorting on the way out."
        }

        return Move(
            id: UUID(),
            kind: .limiter(ceilingDBTP: ceiling, releaseMS: 100),
            isEnabled: true,
            rationale: rationale
        )
    }

    // MARK: - Channels

    /// Only when the two channels already carry the same signal. Folding a real
    /// stereo recording to mono is a decision about the material, not a
    /// correction, and Melo does not make it for you.
    private static func monoMove(
        _ report: AnalysisReport,
        destination: Destination,
        source: EditorSource
    ) -> Move? {
        guard destination.prefersMono,
              source.channelCount > 1,
              report.isEffectivelyMono else { return nil }
        return Move(
            id: UUID(),
            kind: .channels(.mono),
            isEnabled: true,
            rationale: "Both channels are carrying the same signal, so mono halves the file "
                + "with nothing lost."
        )
    }

    // MARK: - Formatting

    // Numbers become strings in exactly one place in this feature —
    // `EditorFormat`, in `Editor/Core/MoveKindDisplay.swift` — so a dB in a
    // rationale, a dB in the Chain row beside it and a dB in the inspector
    // below it are the same string. The only thing added here is a sample
    // count, which nothing else in the feature has to render.

    /// "1,284". Grouped, because five bare digits in a sentence read as a year.
    static func sampleCount(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}
