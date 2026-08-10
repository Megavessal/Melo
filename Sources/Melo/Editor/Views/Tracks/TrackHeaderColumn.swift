// Melo/Editor/Views/Tracks/TrackHeaderColumn.swift
//
// The column of track headers, and the way to add one.

import SwiftUI

/// One header per lane, in document order.
///
/// **Not drawn for a single-track document.** `EditorRootView` decides that,
/// because the decision is about the whole window: open a file and it looks
/// exactly as it did before tracks existed — one lane, the destination picker,
/// the Chain — and the mixer is simply not drawn before there is anything to
/// mix. This view assumes it is only ever asked for once that is no longer
/// true, and draws whatever tracks it is given.
///
/// ## How it stays level with the lanes
///
/// It does not compute a lane height. `EditorTimelineGeometry` divides the
/// timeline pane — the pane less the ruler above and the scroll strip below,
/// less a gap between each pair — equally between the tracks, and this column
/// reaches the identical numbers by reserving the same two bands and handing a
/// `VStack` rows that are all `maxHeight: .infinity`. Equal flexibility is
/// equal division. Nobody measures anybody, and there is no second copy of the
/// formula to fall out of step with the first.
///
/// The three shared constants are the ruler band, the scroll strip and the
/// gap, all read from `EditorWaveformMetrics`; the floor is
/// `EditorTrackMetrics.minimumLaneHeight`, which the lanes have to match.
///
/// There is no scroller. The timeline pane does not scroll vertically this
/// round, so a scroller here would be a column that moves against lanes that
/// do not — the exact shear this whole arrangement exists to prevent. Past the
/// point where the floor stops the division, both sides clip at the bottom.
@MainActor
struct TrackHeaderColumn: View {
    @ObservedObject var store: EditorStore

    private var tracks: [Track] { store.document?.tracks ?? [] }

    var body: some View {
        VStack(spacing: 0) {
            addTrackStrip
                .frame(height: EditorTrackMetrics.topBand)

            VStack(spacing: EditorTrackMetrics.laneGap) {
                ForEach(tracks) { track in
                    TrackHeaderRow(store: store, trackID: track.id)
                        .frame(
                            minHeight: EditorTrackMetrics.minimumLaneHeight,
                            maxHeight: .infinity
                        )
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)

            Color.clear
                .frame(height: EditorTrackMetrics.bottomBand)
                .accessibilityHidden(true)
        }
        .frame(width: EditorTrackMetrics.columnWidth)
        // Overflow clips at the bottom, the way the lanes canvas does, rather
        // than spilling out of both ends. A `VStack` handed less height than
        // its children insist on overflows *symmetrically*, which is how this
        // window's sidebar once lost its first section off the top — see the
        // accordion note in `EditorRootView`.
        .clipped()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tracks")
    }

    /// "Add an Empty Track", in the band the ruler occupies on the other side.
    ///
    /// The same words as the menu item, because it is the same action. It says
    /// *Empty* because it is no longer the only way to get a lane: bringing in
    /// a file, a link or a recording adds one with audio already in it, and
    /// this is the one that does not.
    ///
    /// At the head of the column rather than the foot, and that is forced
    /// rather than chosen: the lanes divide the whole pane between themselves,
    /// so there is no spare strip under the last header to put a button in, and
    /// taking one would make every header shorter than its lane. The ruler band
    /// is 22pt of space this column has to reserve and cannot otherwise use.
    ///
    /// Before there is a column there is no strip, and the ways to a second
    /// lane are all in the window header's source menu: add a file, a link or a
    /// recording — each of which now brings its own audio — or this, which does
    /// not. A document with one track draws no column and, by the governing
    /// decision, no add-track button competing for attention with the sound the
    /// user just opened.
    ///
    /// *Known deviation:* 22pt is under `Dimensions.minTouchTarget`. It is a
    /// 200pt-wide strip rather than a 22pt square, so it is easy to hit by
    /// area, and the same action is in a menu at full size. Making the band
    /// taller is not available — it would put every header 6pt above its lane.
    private var addTrackStrip: some View {
        Button {
            // `_ =` because `withAnimation` infers its result type from the
            // closure, and `addTrack()` returns the new id.
            withAnimation(DesignTokens.Animation.panel) {
                _ = store.addTrack()
            }
        } label: {
            HStack(spacing: DesignTokens.Spacing.xs) {
                Image(systemName: "plus")
                    .font(DesignTokens.Typography.Scale.caption(.bold))
                    .accessibilityHidden(true)

                Text("Add an Empty Track")
                    .font(DesignTokens.Typography.Scale.caption(.medium))
                    .lineLimit(1)

                Spacer(minLength: 0)
            }
            .foregroundStyle(DesignTokens.Colors.interactiveDefault)
            .padding(.horizontal, DesignTokens.Spacing.sm2)
            .frame(
                width: EditorTrackMetrics.columnWidth,
                height: EditorTrackMetrics.topBand
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.meloHover)
        // "At the end", not "below". `addTrack()` appends, so the new lane
        // arrives at the bottom of the column while this strip sits at the top
        // — the tooltip has to describe where the track goes, not where the
        // button is.
        .help("Add an empty track at the end")
        .accessibilityLabel("Add an empty track")
    }
}

#if MELO_DEV
/// Documents the render harness can seed, so the states that only exist after
/// somebody clicks something have frames.
///
/// Here rather than in `SnapshotScenes.swift` because the shapes are this
/// piece's business and the scene list is the lead's. A scene calls
/// `EditorStore.setForSnapshot(document:waveform:)` with one of these.
enum EditorTrackFixtures {

    /// A multitrack document built from one source.
    ///
    /// Every track after the first holds a clip of the same source, offset and
    /// trimmed, so the lanes have something to draw and the frame shows a
    /// timeline rather than a column of headers beside an empty rectangle. One
    /// source, several clips, is also exactly what the source pool is for.
    static func document(
        source: EditorSource,
        trackCount: Int,
        names: [Int: String] = [:],
        gains: [Int: Double] = [:],
        pans: [Int: Double] = [:],
        muted: Set<Int> = [],
        soloed: Set<Int> = [],
        master: [Move] = [],
        destination: Destination? = nil,
        analysis: AnalysisReport? = nil
    ) -> EditorDocument {
        let duration = max(source.duration, 0)
        let tracks: [Track] = (0..<max(trackCount, 1)).map { index in
            let clip: Clip
            if index == 0 || duration == 0 {
                clip = Clip(wholeOf: source)
            } else {
                let inPoint = duration * 0.08 * Double(index)
                let outPoint = min(duration, inPoint + duration * 0.55)
                clip = Clip(
                    sourceID: source.id,
                    start: duration * 0.12 * Double(index),
                    sourceIn: inPoint,
                    sourceOut: max(outPoint, inPoint + Clip.minimumDuration)
                )
            }
            return Track(
                name: names[index] ?? Track.defaultName(at: index),
                gainDB: gains[index] ?? 0,
                pan: pans[index] ?? 0,
                isMuted: muted.contains(index),
                isSoloed: soloed.contains(index),
                clips: [clip]
            )
        }
        return EditorDocument(
            sources: [source],
            tracks: tracks,
            master: master,
            destination: destination,
            analysis: analysis
        )
    }

    /// What the app now actually produces: a document built by adding audio to
    /// one that was already open.
    ///
    /// `openSource` adds a track rather than replacing the document, the new
    /// clip lands at 0, and the track takes the source's display name. So this
    /// is several *sources*, one track each, all starting together and each
    /// named after the file it came from — which is the shape a frame should be
    /// judged against. `document(source:trackCount:)` above is the other real
    /// shape: one file, extra lanes the user asked for and filled by hand.
    ///
    /// Durations are staggered so the lanes are different lengths, because a
    /// document where every clip ends on the same frame is the one arrangement
    /// that cannot show whether `EditorDocument.duration` is being read.
    static func layered(
        from source: EditorSource,
        names: [String],
        gains: [Int: Double] = [:],
        pans: [Int: Double] = [:],
        muted: Set<Int> = [],
        soloed: Set<Int> = [],
        destination: Destination? = nil,
        analysis: AnalysisReport? = nil
    ) -> EditorDocument {
        let sources: [EditorSource] = names.enumerated().map { index, name in
            var copy = source
            // A fresh id per source. Reusing one would make every clip point at
            // the same entry in the pool, which is the thing this fixture
            // exists to *not* be.
            copy.id = UUID()
            copy.displayName = name
            copy.duration = max(source.duration * (1 - 0.13 * Double(index)), 1)
            return copy
        }

        let tracks: [Track] = sources.enumerated().map { index, resolved in
            Track(
                name: resolved.displayName,
                gainDB: gains[index] ?? 0,
                pan: pans[index] ?? 0,
                isMuted: muted.contains(index),
                isSoloed: soloed.contains(index),
                clips: [Clip(wholeOf: resolved)]
            )
        }

        return EditorDocument(
            sources: sources,
            tracks: tracks,
            destination: destination,
            analysis: analysis
        )
    }
}
#endif
