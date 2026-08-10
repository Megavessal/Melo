// Melo/Editor/Window/EditorKeyboardActions.swift
//
// The verbs the VEGAS keyboard pass needed and the store did not have.
//
// They are methods on `EditorStore` rather than code inside the key monitor for
// the reason `EditorTransportCommands.swift` states at length: a shortcut and a
// button that reach the same behaviour by two routes are two things that drift,
// and the buttons for most of these are still to be built. When the transport
// grows a "go to next edge" chip it calls `jumpToClipEdge(forward:)`, not a
// copy of the arithmetic below.
//
// They live in an extension in the window layer, next to their only current
// caller, the same way the transport's four do — the state they read is
// `EditorTimeline`'s and `EditorPlayback`'s, neither of which belongs in a
// document model an undo stack copies twelve deep.
//
// **Every one of them returns whether it did something.** That is not a style
// choice: `EditorKeyCommandView.handle` gives the key back to the responder
// chain on `false`, so a nudge at the end of the file beeps instead of being a
// key that silently does nothing. A method here that returned `Void` would be
// asserting it always succeeds.

import AppKit
import Foundation

// MARK: - Markers

/// A named point on the timeline.
///
/// Drawn by `EditorTimeRuler.drawMarkers`, which observes `EditorMarkers.shared`
/// and paints a full-height green stripe with a numbered tab. That was one pass
/// behind this file — M was bound and nothing changed on screen — and it is
/// recorded here because a key in a shipped cheat sheet that does nothing
/// visible is the shape of gap that survives a green test run.
struct EditorMarker: Identifiable, Equatable, Sendable {
    let id = UUID()
    var time: TimeInterval
    /// "1", "2", "3" as they are dropped. Numbered rather than named because
    /// naming needs a text field, and a text field in the ruler is a piece of
    /// UI nobody has designed — a marker you cannot rename is still a marker
    /// you can see and jump to.
    var name: String
}

/// Where markers live until the document model has somewhere for them.
///
/// Session-scoped and not persisted, which is stated here so nobody discovers
/// it by losing a set of markers: `EditorDocument` is `Codable` and is what the
/// session sidecar writes, and adding a field to it is a migration in a file
/// this piece does not own. The moment markers move onto the document this
/// object should be deleted rather than kept in sync — two homes for the same
/// list is the defect class this project's anchor is mostly made of.
@MainActor
final class EditorMarkers: ObservableObject {
    static let shared = EditorMarkers()

    @Published private(set) var markers: [EditorMarker] = []

    private init() {}

    /// - Returns: `false` when a marker is already within `tolerance` of `time`,
    ///   so pressing M twice at a playhead that has not moved does not stack two
    ///   markers on one pixel.
    @discardableResult
    func add(at time: TimeInterval, tolerance: TimeInterval = 0.005) -> Bool {
        guard !markers.contains(where: { abs($0.time - time) < tolerance }) else { return false }
        markers.append(EditorMarker(time: max(0, time), name: "\(markers.count + 1)"))
        markers.sort { $0.time < $1.time }
        return true
    }

    func removeAll() {
        markers.removeAll()
    }
}

// MARK: - Moving about

extension EditorStore {

    /// One arrow press, as a fraction of what is on screen.
    ///
    /// Zoom-relative rather than a fixed number of milliseconds, because a
    /// fixed step is either invisible when zoomed out or unusable when zoomed
    /// in — twenty presses crossing the visible window is the same gesture at
    /// every zoom level. The value is the one
    /// `EditorWaveformView`'s `accessibilityAdjustableAction` already uses, so
    /// an arrow key and VoiceOver's increment move the playhead by the same
    /// amount. It is duplicated rather than shared only because that call site
    /// is in a file this piece does not own; the patch that folds them together
    /// is in this run's report.
    private var nudgeStep: TimeInterval {
        max(EditorTimeline.shared.visible / 20, 0.001)
    }

    /// Keeps the playhead on screen without fighting a scroll.
    ///
    /// `reveal(range:)` rather than `reveal(_:)` on purpose: the latter is the
    /// playback follow and goes silent once the user has scrolled, which would
    /// make arrow-key navigation walk the playhead off the edge and leave it
    /// there. `reveal(range:)` moves only when the target has left the window
    /// entirely, which is exactly the rule a keyboard nudge wants.
    private func keepInView(_ time: TimeInterval) {
        EditorTimeline.shared.reveal(range: time...time)
    }

    /// End of the last clip on any track.
    ///
    /// Asymmetric with `jumpToStart()`, which calls into `EditorPlayback` and
    /// re-splices immediately. This only writes the playhead, and the reseek
    /// arrives through the transport bar's `onChange` on `store.playhead` — the
    /// same debounced path every drag uses. Worth the asymmetry: jumping to the
    /// end is jumping to where playback stops anyway, so a 90 ms reseek is
    /// inaudible, and a second immediate-restart path is a second thing to keep
    /// correct.
    @discardableResult
    func jumpToEnd() -> Bool {
        guard let document else { return false }
        let end = document.duration
        guard end > 0, playhead != end else { return false }
        playhead = end
        keepInView(end)
        return true
    }

    /// ← and →.
    @discardableResult
    func nudgePlayhead(steps: Int) -> Bool {
        let timeline = EditorTimeline.shared
        let target = timeline.clampToSound(playhead + Double(steps) * nudgeStep)
        guard target != playhead else { return false }
        playhead = target
        keepInView(target)
        return true
    }

    /// ⌥← and ⌥→ — the next place a clip begins or ends.
    ///
    /// Every edge on every track, not just the selected one. A multitrack edit
    /// is mostly about lining one lane up against another, so an edge jump that
    /// ignored the other lanes would skip past the exact moments the gesture
    /// exists to find. `0` is included so ⌥← always has somewhere to land.
    @discardableResult
    func jumpToClipEdge(forward: Bool) -> Bool {
        guard let document else { return false }
        var edges: Set<TimeInterval> = [0]
        for track in document.tracks {
            for clip in track.clips {
                edges.insert(clip.start)
                edges.insert(clip.end)
            }
        }
        // A hair of tolerance, or an edge the playhead is already sitting on
        // answers every press with itself and the key looks dead.
        let epsilon = 0.0005
        let candidate = forward
            ? edges.filter { $0 > playhead + epsilon }.min()
            : edges.filter { $0 < playhead - epsilon }.max()
        guard let target = candidate else { return false }
        playhead = target
        keepInView(target)
        return true
    }
}

// MARK: - Choosing

extension EditorStore {

    /// ⇧← and ⇧→.
    ///
    /// The selection grows from the playhead outwards: → moves the far edge
    /// later, ← moves the near edge earlier. *Rejected:* the active-edge model
    /// most DAWs use, where ⇧← after ⇧→ shrinks what ⇧→ grew. It reads better
    /// in a manual and it needs a stored "which edge did they last touch",
    /// which nothing else in this window has and which is invisible on screen —
    /// so the same two presses would do different things depending on state the
    /// user cannot see. Growing symmetrically is duller and is never surprising.
    @discardableResult
    func extendSelection(steps: Int) -> Bool {
        let timeline = EditorTimeline.shared
        let step = nudgeStep * Double(abs(steps))
        let current = selection ?? playhead...playhead
        let target: ClosedRange<TimeInterval>
        if steps > 0 {
            let upper = timeline.clampToSound(current.upperBound + step)
            guard upper > current.upperBound else { return false }
            target = current.lowerBound...upper
        } else {
            let lower = timeline.clampToSound(current.lowerBound - step)
            guard lower < current.lowerBound else { return false }
            target = lower...current.upperBound
        }
        guard target != selection else { return false }
        selection = target
        EditorTimeline.shared.reveal(range: target)
        return true
    }

    /// ↑ and ↓.
    ///
    /// With nothing selected, ↓ takes the first track and ↑ takes the last, so
    /// the first press always lands somewhere rather than being the press that
    /// does nothing.
    @discardableResult
    func selectAdjacentTrack(offset: Int) -> Bool {
        guard let document, !document.tracks.isEmpty else { return false }
        let last = document.tracks.count - 1
        let current = selectedTrackID.flatMap { id in
            document.tracks.firstIndex { $0.id == id }
        }
        let target: Int
        if let current {
            target = min(max(current + offset, 0), last)
            guard target != current else { return false }
        } else {
            target = offset > 0 ? 0 : last
        }
        selectedTrackID = document.tracks[target].id
        return true
    }

    /// ⌘A. Every clip on every track, not the selected track's.
    @discardableResult
    func selectAllClips() -> Bool {
        guard let document else { return false }
        let everything = Set(document.tracks.flatMap(\.clips).map(\.id))
        guard !everything.isEmpty, everything != selectedClipIDs else { return false }
        selectedClipIDs = everything
        return true
    }

    /// ⇧⌘A. Clears the clip selection and the time selection together, because
    /// they are one thing to the person pressing it.
    ///
    /// Leaves `selectedMoveID` alone: the Chain is a different pane with its own
    /// idea of what is selected, and clearing it from a timeline shortcut would
    /// close an inspector someone was reading.
    @discardableResult
    func deselectEverything() -> Bool {
        guard !selectedClipIDs.isEmpty || selection != nil else { return false }
        selectedClipIDs = []
        selection = nil
        return true
    }

    /// ⌥M.
    @discardableResult
    func toggleMuteOnSelectedTrack() -> Bool {
        guard let id = resolvedTrackID else { return false }
        toggleMute(id)
        return true
    }

    /// ⌥S.
    @discardableResult
    func toggleSoloOnSelectedTrack() -> Bool {
        guard let id = resolvedTrackID else { return false }
        toggleSolo(id)
        return true
    }

    /// The selected track, or the only track when there is one.
    ///
    /// A single-track document never gives anyone a reason to click a header, so
    /// `selectedTrackID` is usually nil there — and ⌥M doing nothing in the
    /// commonest document in the app would read as the shortcut being broken.
    /// With two or more lanes the fallback is dropped: muting a lane the user
    /// did not point at is worse than a beep.
    private var resolvedTrackID: Track.ID? {
        if let selectedTrackID { return selectedTrackID }
        guard let document, document.tracks.count == 1 else { return nil }
        return document.tracks[0].id
    }
}

// MARK: - Looping

extension EditorStore {

    /// I — the loop starts at the playhead.
    ///
    /// The loop range *is* `selection`; `EditorPlayback.refreshSegment` reads
    /// nothing else. So I and O edit the selection rather than a second range,
    /// which is what stops the loop the user set and the selection they can see
    /// from being two different things.
    @discardableResult
    func setLoopIn() -> Bool {
        let end = selection.map { max($0.upperBound, playhead) } ?? EditorTimeline.shared.duration
        guard end > playhead else { return false }
        let target = playhead...end
        guard target != selection else { return false }
        selection = target
        return true
    }

    /// O — the loop ends at the playhead.
    @discardableResult
    func setLoopOut() -> Bool {
        let start = selection.map { min($0.lowerBound, playhead) } ?? 0
        guard playhead > start else { return false }
        let target = start...playhead
        guard target != selection else { return false }
        selection = target
        return true
    }

    /// M.
    @discardableResult
    func addMarkerAtPlayhead() -> Bool {
        EditorMarkers.shared.add(at: playhead)
    }
}

// MARK: - Editing

extension EditorStore {

    /// ⌘X — the gap the owner named. Before this there was no cut at all: copy,
    /// then Delete, as two presses leaving one undo entry per clip.
    ///
    /// `removeSelectedClips` rather than a loop over `removeClip`, because it
    /// takes the whole set out through one `mutate` — one press, one ⌘Z, the
    /// same rule `moveClips` states for a drag. A loop here would make cutting
    /// three clips take three undos to put back.
    @discardableResult
    func cutSelectedClips() -> Bool {
        guard !selectedClipIDs.isEmpty else { return false }
        copyClips(Array(selectedClipIDs))
        removeSelectedClips()
        return true
    }

    /// ⌘D — the same clips again, immediately after the ones they came from.
    ///
    /// Placed after the block rather than on top of it: a duplicate that lands
    /// exactly over its original is invisible, and the user's next drag moves
    /// whichever one the hit test happened to pick.
    ///
    /// Goes through `EditorStore.duplicateClips`, which does the paste
    /// arithmetic without touching the clipboard.
    ///
    /// It was copy-then-paste for one build. That works, and it silently throws
    /// away whatever the user had copied — a clipboard is not in the document,
    /// so ⌘Z cannot bring it back and nothing on screen says it went.
    ///
    /// *Rejected:* rebuilding the clip through `addClip` then `trimClip`,
    /// `setClipGain`, `setClipFades` and `setClipMoves`. Five `mutate` calls, so
    /// ⌘Z after a duplicate would have undone only the fades — worse than
    /// losing a clipboard, and harder to notice.
    @discardableResult
    func duplicateSelectedClips() -> Bool {
        guard !selectedClipIDs.isEmpty else { return false }
        return !duplicateClips(Array(selectedClipIDs)).isEmpty
    }
}
