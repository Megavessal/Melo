// Melo/Editor/Views/Waveform/EditorTransportCommands.swift
//
// The one reach for playback and zoom.
//
// `EditorCommands` calls `store.togglePlayback()`, `store.zoomIn()`,
// `store.zoomOut()` and `store.zoomToFit()` from a single key monitor, and the
// transport bar's buttons call exactly the same four methods. That is on
// purpose and it is the point of this file: a shortcut and a button that reach
// playback by two different routes are two things that can drift, and this
// project has already measured what happens when a control's rule is tested
// somewhere its call site is not (`CLAUDE.md:138`).
//
// They live in an extension here rather than in `EditorStore` itself
// because the state they touch is not the store's. The store holds the
// document, the playhead and the selection; **where you are looking** lives in
// `EditorTimeline` and **whether it is playing** lives in `EditorPlayback`, and
// neither belongs in a document model that an undo stack copies twelve deep.

import Foundation

// MARK: - Zoom steps

extension EditorTimeline {

    /// One press. 1.75× is a little under a doubling: doubling overshoots what
    /// the eye can follow between two frames, and 1.25× takes nine presses to
    /// cross a four-minute song.
    static let zoomStep: Double = 1.75

    /// Where a keyboard or button zoom pivots: the playhead when it is on
    /// screen, the middle of the view when it is not. Zooming into the middle of
    /// a window whose interesting moment is at the edge throws that moment off
    /// screen, which is the same failure as not anchoring at all.
    func anchorFraction(preferring time: TimeInterval) -> Double {
        guard visible > 0 else { return 0.5 }
        let fraction = (time - start) / visible
        return (fraction >= 0.02 && fraction <= 0.98) ? fraction : 0.5
    }

    func zoomIn(anchoredAt fraction: Double) {
        zoom(by: Self.zoomStep, anchorFraction: fraction)
    }

    func zoomOut(anchoredAt fraction: Double) {
        zoom(by: 1 / Self.zoomStep, anchorFraction: fraction)
    }
}

// MARK: - What the key monitor and the buttons both call

extension EditorStore {

    func togglePlayback() {
        EditorPlayback.shared.toggle()
    }

    func jumpToStart() {
        EditorPlayback.shared.jumpToStart()
    }

    func toggleLoop() {
        EditorPlayback.shared.loops.toggle()
    }

    /// Hold-to-bypass. `true` on key-down, `false` on key-up — it is not a
    /// toggle, so a caller that only sends `true` leaves the stack off.
    ///
    /// Two callers, both of which send both edges: the transport bar's
    /// press-and-hold chip, and `EditorKeyCommandView`, whose monitor
    /// matches `[.keyDown, .keyUp]` and carries the edge as
    /// `EditorShortcut.Phase`.
    func setBypassHeld(_ held: Bool) {
        EditorPlayback.shared.setBypassed(held)
    }

    func zoomIn() {
        let timeline = EditorTimeline.shared
        timeline.zoomIn(anchoredAt: timeline.anchorFraction(preferring: playhead))
    }

    func zoomOut() {
        let timeline = EditorTimeline.shared
        timeline.zoomOut(anchoredAt: timeline.anchorFraction(preferring: playhead))
    }

    func zoomToFit() {
        EditorTimeline.shared.fitAll()
    }
}
