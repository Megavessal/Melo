// Melo/Editor/Views/Tracks/TrackHeaderRow.swift
//
// One track's header: its name, whether you can hear it, how loud, and where.

import SwiftUI

/// The header for one lane.
///
/// **Takes whatever height it is given and never asks for a particular one.**
/// The lanes divide the pane between the tracks; the column does the same
/// division by handing a `VStack` rows that are equally flexible. So this row
/// is `maxHeight: .infinity` with its three rows of controls centred inside,
/// and the only height it insists on is `EditorTrackMetrics
/// .minimumLaneHeight`, which is the sum of those three rows.
///
/// No divider participates in layout. The separator is drawn as an overlay on
/// the bottom edge, which costs zero points — a 1pt `Divider()` between rows
/// would put header *n* a point lower than lane *n*, and by the sixth track
/// that is a visible fraction of a row of drift.
///
/// It takes a `Track.ID` rather than a `Track`, and reads the track out of the
/// store on every body pass. A header handed a value is a header that can be
/// one edit stale, and the two states this row shows that are *not* its own —
/// whether solo elsewhere has silenced it, and whether it is the last track and
/// so cannot be removed — are both properties of the document rather than of
/// the track.
@MainActor
struct TrackHeaderRow: View {
    @ObservedObject var store: EditorStore
    let trackID: Track.ID

    @State private var isRenaming = false
    @State private var draftName = ""
    @State private var isHovered = false
    @FocusState private var nameFieldFocused: Bool

    // MARK: Reading the document

    private var track: Track? { store.document?.track(trackID) }
    private var tracks: [Track] { store.document?.tracks ?? [] }
    private var index: Int? { tracks.firstIndex { $0.id == trackID } }
    private var isSelected: Bool { store.selectedTrackID == trackID }

    /// Whether this track is actually heard, with solo resolved.
    ///
    /// **Read from `EditorDocument.audibleTrackIDs` and nowhere else.** The
    /// render engine reads the same property, so the row cannot tell the user a
    /// track is playing while the mix leaves it out. Asking `!track.isMuted`
    /// here would be the version that lies, and it would lie in exactly the
    /// case solo exists for.
    private var isAudible: Bool {
        store.document?.audibleTrackIDs.contains(trackID) ?? true
    }

    /// How far the level fader has travelled, which is what `MuteButton` draws
    /// its wave bucket from. Not a claim about loudness — it is the fader's
    /// position, so a track pulled down looks quieter on its own button.
    private var levelFraction: Double {
        guard let track else { return 1 }
        let span = Track.gainRange.upperBound - Track.gainRange.lowerBound
        return (track.gainDB - Track.gainRange.lowerBound) / span
    }

    private var gain: Binding<Double> {
        Binding(
            get: { track?.gainDB ?? 0 },
            set: { store.setTrackGain(trackID, dB: $0) }
        )
    }

    private var pan: Binding<Double> {
        Binding(
            get: { track?.pan ?? 0 },
            set: { store.setTrackPan(trackID, $0) }
        )
    }

    // MARK: Body

    var body: some View {
        // A track can leave the document while its row is on screen — Remove
        // Track from this very menu does it — and a row that outlives its track
        // by one layout pass draws nothing rather than reaching for a value
        // that is gone.
        if let track {
            content(track)
        }
    }

    private func content(_ track: Track) -> some View {
        VStack(alignment: .leading, spacing: EditorTrackMetrics.rowSpacing) {
            nameRow(track)
                .frame(height: EditorTrackMetrics.nameRowHeight)

            levelRow(track)
                .frame(height: EditorTrackMetrics.levelRowHeight)

            TrackPanControl(pan: pan, subject: track.name)
                .frame(height: EditorTrackMetrics.panRowHeight)
                .opacity(isAudible ? 1 : 0.45)
        }
        .padding(.horizontal, DesignTokens.Spacing.sm2)
        // Centred rather than pinned to the top. Two tracks in a tall window
        // gives each lane 200pt or more, and a block of controls stuck to the
        // top of a 200pt header reads as a header that failed to lay out; the
        // waveform in the lane beside it is centred too.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .background {
            // Flat at rest, hover is the signal — the same rule the other 41
            // rows in this app follow.
            Rectangle()
                .fill(isHovered ? DesignTokens.Colors.hoverSurface : Color.clear)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .leading) {
            // Selection is a bar, not a fill. The house rule is that a row is
            // flat at rest and hover owns the fill, so a selected row cannot
            // take one — the popup draws an accent ring instead, and a ring
            // around a 200pt-tall lane header reads as a box drawn over the
            // column. A bar on the leading edge is the same stroke-not-fill
            // idea in the shape a lane actually has.
            Rectangle()
                .fill(Color.accentColor)
                .frame(width: 2.5)
                .opacity(isSelected ? 1 : 0)
                .allowsHitTesting(false)
        }
        // No separator line. The lanes are set `EditorWaveformMetrics.laneGap`
        // apart and so are these, and a hairline under a row that already has
        // six points of air below it reads as an underline rather than as a
        // boundary. A `Divider()` would be worse still: one point of layout,
        // and every header below it a point out of line with its lane.
        .contentShape(Rectangle())
        .onTapGesture { store.selectedTrackID = trackID }
        .onHover { hovering in isHovered = hovering }
        .animation(DesignTokens.Animation.hover, value: isHovered)
        .animation(DesignTokens.Animation.rowChange, value: isSelected)
        .contextMenu { menu(track) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(track.name)
        .accessibilityValue(spokenState(track))
    }

    // MARK: Name

    @ViewBuilder
    private func nameRow(_ track: Track) -> some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            if isRenaming {
                TextField("Track name", text: $draftName)
                    .textFieldStyle(.plain)
                    .font(DesignTokens.Typography.Scale.footnote(.semibold))
                    .foregroundStyle(DesignTokens.Colors.textPrimary)
                    .focused($nameFieldFocused)
                    .onSubmit { commitRename() }
                    .onExitCommand { isRenaming = false }
                    .onAppear { nameFieldFocused = true }
                    // Losing focus commits, the way a Finder rename does.
                    // Cancelling is Escape, which `onExitCommand` handles above.
                    .onChange(of: nameFieldFocused) { _, focused in
                        if !focused, isRenaming { commitRename() }
                    }
            } else {
                Text(track.name)
                    .font(DesignTokens.Typography.Scale.footnote(.semibold))
                    .foregroundStyle(DesignTokens.Colors.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .opacity(isAudible ? 1 : 0.45)
                    .onTapGesture(count: 2) { beginRename(track) }
                    .help("Double-click to rename")
            }

            Spacer(minLength: 0)

            trackMenu(track)
        }
    }

    private func beginRename(_ track: Track) {
        draftName = track.name
        isRenaming = true
    }

    private func commitRename() {
        isRenaming = false
        store.renameTrack(trackID, to: draftName)
    }

    // MARK: Level

    private func levelRow(_ track: Track) -> some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            // Melo's own mute button, not a second one. It carries the pulse,
            // the haptic, the red muted state and the stable width already.
            MuteButton(
                isMuted: track.isMuted,
                levelFraction: levelFraction,
                subject: track.name
            ) {
                store.toggleMute(trackID)
            }

            TrackSoloButton(isSoloed: track.isSoloed, subject: track.name) {
                store.toggleSolo(trackID)
            }

            // `showUnityMarker: false`, and this is a limitation rather than a
            // choice. `LiquidGlassSlider` draws its marker and puts its middle
            // detent at the midpoint of the range; the fader's range is
            // −24…+12, whose midpoint is −6 dB, so a marker here would sit six
            // decibels away from unity and be worse than none. The readout to
            // its right is the way back to 0.0 dB.
            LiquidGlassSlider(
                value: gain,
                in: Track.gainRange,
                showUnityMarker: false,
                accessibilityTitle: "\(track.name) level",
                valueDescription: { EditorFormat.decibels($0) }
            )
            .frame(maxWidth: .infinity)
            .opacity(isAudible ? 1 : 0.45)

            Button {
                store.setTrackGain(trackID, dB: 0)
            } label: {
                Text(EditorFormat.decibels(track.gainDB))
                    .font(DesignTokens.Typography.Scale.caption2(.medium))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .foregroundStyle(
                        track.gainDB == 0
                            ? DesignTokens.Colors.textTertiary
                            : DesignTokens.Colors.accentPrimary
                    )
                    .frame(width: 44, height: 16)
                    .background(Capsule().fill(DesignTokens.Colors.pickerBackground))
            }
            .buttonStyle(.meloHover)
            .disabled(track.gainDB == 0)
            .opacity(isAudible ? 1 : 0.45)
            .help("Back to 0.0 dB")
            .accessibilityLabel("Reset \(track.name) level")
        }
    }

    // MARK: The rest of it

    /// Rename, reorder and remove, in one menu.
    ///
    /// Mute and solo are the two controls people reach for constantly and they
    /// are one click, always visible, never in here. Everything in this menu is
    /// something a person does to a track once.
    ///
    /// *Rejected:* dragging headers to reorder. The lane column shares a
    /// vertical scroller with the timeline, and a drag that might be a scroll
    /// is the one interaction this window has already decided must not be made
    /// ambiguous — `MoveStackView` owns drag-to-reorder, in a pane with its own
    /// scroller and nothing else competing for the gesture. Move Up and Move
    /// Down also work from the keyboard and read correctly to VoiceOver, which
    /// a drag does not.
    @ViewBuilder
    private func trackMenu(_ track: Track) -> some View {
        Menu {
            menu(track)
        } label: {
            Image(systemName: "ellipsis")
                .font(DesignTokens.Typography.Scale.caption(.bold))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(DesignTokens.Colors.interactiveDefault)
        .help("Rename, reorder, remove")
        .accessibilityLabel("\(track.name) options")
    }

    @ViewBuilder
    private func menu(_ track: Track) -> some View {
        let position = index ?? 0

        Button("Rename", systemImage: "pencil") { beginRename(track) }

        Divider()

        Button("Move Up", systemImage: "arrow.up") {
            store.moveTracks(fromOffsets: [position], toOffset: position - 1)
        }
        .disabled(position == 0)

        // `toOffset` counts pre-removal indices, so one place down is `+2`.
        // Getting this wrong is a silent reordering bug, which is why
        // `EditorStore.move(fromOffsets:toOffset:)` uses SwiftUI's own
        // implementation rather than a hand-rolled one.
        Button("Move Down", systemImage: "arrow.down") {
            store.moveTracks(fromOffsets: [position], toOffset: position + 2)
        }
        .disabled(position >= tracks.count - 1)

        Divider()

        // `removeTrack` refuses to take the last one, so this is disabled
        // rather than silently doing nothing. A document with no tracks has no
        // timeline; "Close This Sound" is the action that means that.
        Button("Remove Track", systemImage: "trash", role: .destructive) {
            store.removeTrack(trackID)
        }
        .disabled(tracks.count <= 1)
    }

    /// What VoiceOver reads for the row as a whole, so the state that is *not*
    /// on any one control — silenced by somebody else's solo — is still spoken.
    private func spokenState(_ track: Track) -> String {
        var parts: [String] = []
        if track.isSoloed { parts.append("Soloed") }
        if track.isMuted {
            parts.append("Muted")
        } else if !isAudible {
            parts.append("Silent, another track is soloed")
        }
        parts.append(EditorFormat.decibels(track.gainDB))
        parts.append(EditorPanFormat.spoken(track.pan))
        return parts.joined(separator: ", ")
    }
}
