// Melo/Editor/Views/Waveform/EditorTransportBar.swift
//
// Play, where you are, and how close you are looking.
//
// Every numeral here is `.monospacedDigit()`, which is the whole reason the bar
// does not shiver while it counts. `design: .monospaced` would do the same job
// and swap in SF Mono, which reads as a code font sitting inside a consumer UI —
// `DesignTokens.Typography.percentage` already records that decision for the
// popup and this is the same call.

import AppKit
import SwiftUI

@MainActor
struct EditorTransportBar: View {

    @ObservedObject private var store: CuttingRoomStore
    @ObservedObject private var timeline = EditorTimeline.shared
    @ObservedObject private var playback = EditorPlayback.shared

    /// Set only by the `#if MELO_DEV` initialiser. Playback state lives behind
    /// an audio device that a render harness does not have, so without these the
    /// pause glyph, the lit loop and the held bypass could never appear in a
    /// frame — and a control nobody has ever seen in its active state is the
    /// dead-button failure this project has already measured once.
    private var forcedIsPlaying: Bool?
    private var forcedLoops: Bool?
    private var forcedBypass: Bool?
    private var forcedPreparing: Bool?

    init(store: CuttingRoomStore) {
        _store = ObservedObject(wrappedValue: store)
    }

    // MARK: - Resolved state

    private var isPlaying: Bool { forcedIsPlaying ?? playback.isPlaying }
    private var isLooping: Bool { forcedLoops ?? playback.loops }
    private var isBypassed: Bool { forcedBypass ?? playback.isBypassed }
    private var isPreparing: Bool { forcedPreparing ?? playback.isPreparing }
    private var hasSound: Bool { store.document != nil }

    // MARK: - Body

    /// Height is fixed, not a minimum: the strip is three clusters of 28pt
    /// controls and it has no reason to grow or shrink. Everything above it in
    /// the window may take whatever is left.
    static let height: CGFloat = 44

    /// Below this the selection chip is dropped. The rest of the bar is
    /// 464pt of incompressible controls, which clears the 820pt minimum
    /// window's 499pt pane; the chip is the one thing here that is a nicety
    /// rather than a control, so it is the one thing that goes.
    private static let selectionChipMinimumWidth: CGFloat = 620

    var body: some View {
        // A real width rather than letting the layout negotiate. Every label in
        // this bar is `fixedSize`, so an over-committed row would clip instead
        // of reflowing, and a measured width is what lets it shed the optional
        // part before it gets there.
        GeometryReader { proxy in
            // Adopted in `body`, the same way and for the same reasons the
            // waveform does it: it publishes nothing, and it is idempotent, so
            // whichever of the two renders first points the timeline at the
            // sound and the other reads what it recorded. Rendered on its own
            // with no waveform beside it, this is the only thing that stops the
            // strip inheriting the previous scene's sound.
            let _ = timeline.adopt(
                sourceID: store.document?.source.id,
                duration: store.waveform?.duration ?? store.document?.source.duration ?? 0,
                sampleRate: store.document?.source.sampleRate ?? 48_000,
                width: timeline.width
            )
            HStack(spacing: DesignTokens.Spacing.md) {
                transport
                Spacer(minLength: DesignTokens.Spacing.sm)
                readout(showsSelection: proxy.size.width >= Self.selectionChipMinimumWidth)
                Spacer(minLength: DesignTokens.Spacing.sm)
                zoom
            }
            .padding(.horizontal, DesignTokens.Spacing.lg)
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .frame(height: Self.height)
        .onAppear { playback.attach(store) }
        .onChange(of: store.document) { _, _ in
            playback.noteDocumentChanged()
        }
        .onChange(of: store.selection) { _, _ in playback.noteSelectionChanged() }
        .onChange(of: store.playhead) { _, value in playback.notePlayheadChanged(value) }
    }

    // MARK: - Transport cluster

    private var transport: some View {
        HStack(spacing: DesignTokens.Spacing.xxs) {
            TransportButton(
                symbol: "backward.end.fill",
                size: 11,
                label: "Jump to start",
                help: "Back to the top",
                isEnabled: hasSound
            ) {
                store.jumpToStart()
            }

            TransportButton(
                symbol: isPlaying ? "pause.fill" : "play.fill",
                size: 15,
                label: isPlaying ? "Pause" : "Play",
                help: isPreparing ? "Getting it ready" : (isPlaying ? "Pause" : "Play from the playhead"),
                isEnabled: hasSound && !isPreparing
            ) {
                // Through the store, which is what `CuttingRoomCommands` calls
                // for the Space key. One route, so the button cannot work while
                // the shortcut is severed.
                store.togglePlayback()
            }

            TransportButton(
                symbol: "repeat",
                size: 12,
                label: "Loop",
                help: store.selection == nil ? "Loop the whole sound" : "Loop the selection",
                isEnabled: hasSound,
                isOn: isLooping
            ) {
                store.toggleLoop()
                Haptics.step()
            }

            bypass
        }
    }

    /// Press and hold. Not a toggle: the point is to hear the two side by side
    /// in one motion, and a toggle makes that two clicks and a memory test.
    private var bypass: some View {
        Text("Bypass")
            .font(DesignTokens.Typography.Scale.caption(.semibold))
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(isBypassed ? Color.white : DesignTokens.Colors.interactiveDefault)
            .padding(.horizontal, DesignTokens.Spacing.xs2)
            .padding(.vertical, DesignTokens.Spacing.xxs)
            .background {
                DesignTokens.Dimensions.Shape.xs
                    .fill(isBypassed ? Color.accentColor : Color.clear)
            }
            .frame(minWidth: DesignTokens.Dimensions.minTouchTarget,
                   minHeight: DesignTokens.Dimensions.minTouchTarget)
            .contentShape(Rectangle())
            .opacity(hasSound ? 1 : 0.4)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard hasSound, !playback.isBypassed else { return }
                        store.setBypassHeld(true)
                    }
                    .onEnded { _ in store.setBypassHeld(false) }
            )
            .animation(DesignTokens.Animation.toggle, value: isBypassed)
            .help("Hold to hear it without the stack")
            .accessibilityLabel("Bypass the stack")
            .accessibilityHint("Hold to hear the sound without any of the moves applied")
            .accessibilityAddTraits(isBypassed ? [.isSelected] : [])
    }

    // MARK: - Readout

    /// Every label is `lineLimit(1).fixedSize()`. A time that can wrap is a time
    /// that *will* wrap the moment a neighbour grows, and a stack of single
    /// letters is the one failure in a strip like this that reads as broken
    /// rather than tight.
    private func readout(showsSelection: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.xs2) {
            Text(EditorFormat.timecode(store.playhead, decimals: readoutDecimals))
                .font(DesignTokens.Typography.Scale.title3(.semibold).monospacedDigit())
                .foregroundStyle(DesignTokens.Colors.textPrimary)
                .lineLimit(1)
                .fixedSize()

            Text("/")
                .font(DesignTokens.Typography.Scale.footnote())
                .foregroundStyle(DesignTokens.Colors.textQuaternary)
                .lineLimit(1)
                .fixedSize()

            Text(EditorFormat.timecode(timeline.duration))
                .font(DesignTokens.Typography.Scale.footnote(.medium).monospacedDigit())
                .foregroundStyle(DesignTokens.Colors.textSecondary)
                .lineLimit(1)
                .fixedSize()

            if showsSelection, let selection = store.selection {
                Text(EditorFormat.seconds(selection.upperBound - selection.lowerBound) + " selected")
                    .font(DesignTokens.Typography.Scale.caption().monospacedDigit())
                    .foregroundStyle(DesignTokens.Colors.textTertiary)
                    .lineLimit(1)
                    .fixedSize()
                    .transition(.opacity)
            }
        }
        .animation(DesignTokens.Animation.rowChange, value: store.selection)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Position")
        .accessibilityValue(spokenPosition)
    }

    /// One decimal normally, two when the zoom makes the second one mean
    /// something. Never three: the third digit changes a thousand times a second
    /// and reads as static, and the count of digits is the one thing
    /// `.monospacedDigit()` cannot hold still.
    private var readoutDecimals: Int {
        min(2, EditorFormat.timecodeDecimals(forSecondsPerPoint: timeline.secondsPerPoint) + 1)
    }

    private var spokenPosition: String {
        var value = "\(EditorFormat.spokenTime(store.playhead)) of \(EditorFormat.spokenTime(timeline.duration))"
        if let selection = store.selection {
            value += ", \(EditorFormat.spokenTime(selection.upperBound - selection.lowerBound)) selected"
        }
        return value
    }

    // MARK: - Zoom

    private var zoom: some View {
        HStack(spacing: DesignTokens.Spacing.xs2) {
            TransportButton(
                symbol: "minus.magnifyingglass",
                size: 12,
                label: "Zoom out",
                help: "Zoom out",
                isEnabled: hasSound && !timeline.isFitToWindow
            ) {
                store.zoomOut()
            }

            LiquidGlassSlider(
                value: zoomBinding,
                in: 0...1,
                accessibilityTitle: "Zoom",
                valueDescription: { _ in
                    timeline.isFitToWindow
                        ? "The whole sound"
                        : "\(EditorFormat.seconds(timeline.visible)) on screen"
                }
            )
            .frame(width: 84)
            .disabled(!hasSound)

            TransportButton(
                symbol: "plus.magnifyingglass",
                size: 12,
                label: "Zoom in",
                help: "Zoom in",
                isEnabled: hasSound
            ) {
                store.zoomIn()
            }

            // A glyph, not the word "Fit".
            //
            // The word was the one thing in this strip that could reflow, and at
            // 1000×640 it did: three stacked letters jammed against the right
            // edge. `fixedSize` alone would have stopped the wrap and pushed the
            // overflow into a clip instead. Making it the third fixed 28pt
            // control in a row of them removes the demand rather than capping
            // it, and the cluster reads better for being homogeneous — two
            // magnifiers and a span, around one slider.
            TransportButton(
                symbol: "arrow.left.and.right",
                size: 11,
                label: "Fit the whole sound",
                help: "Show the whole sound",
                isEnabled: hasSound && !timeline.isFitToWindow
            ) {
                store.zoomToFit()
                Haptics.commit()
            }
        }
    }

    private var zoomBinding: Binding<Double> {
        Binding(
            get: { timeline.zoomFraction },
            set: { timeline.setZoomFraction($0, anchorFraction: 0.5) }
        )
    }
}

// MARK: - Button

/// The transport's own icon button. Not a second `MuteButton`: that one is a
/// two-state mute with its own red active colour and lives in a popup row. This
/// is the shared `iconButtonStyle` hover behaviour with an accent-lit "on"
/// state, which `iconButtonStyle(isActive:)` renders in `mutedIndicator` red —
/// the right colour for muted and the wrong one for a lit loop.
private struct TransportButton: View {

    let symbol: String
    let size: CGFloat
    let label: String
    let help: String
    var isEnabled: Bool = true
    var isOn: Bool = false
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                // A fixed point size, not a token: these glyphs are sized
                // against each other so the play button reads as the primary
                // one, and the type scale is for text.
                .font(.system(size: size, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(foreground)
                .frame(width: DesignTokens.Dimensions.minTouchTarget,
                       height: DesignTokens.Dimensions.minTouchTarget)
                .contentShape(Rectangle())
                .accessibilityHidden(true)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
        .onHover { isHovered = $0 }
        .animation(DesignTokens.Animation.hover, value: isHovered)
        .animation(DesignTokens.Animation.toggle, value: isOn)
        .help(help)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
    }

    private var foreground: Color {
        if isOn { return DesignTokens.Colors.accentPrimary }
        return isHovered
            ? DesignTokens.Colors.interactiveHover
            : DesignTokens.Colors.interactiveDefault
    }
}

// MARK: - Snapshot seeding

#if MELO_DEV
extension EditorTransportBar {
    /// Seeds the states that only exist behind an audio device.
    ///
    /// `CuttingRoomStore.setForSnapshot` gives the bar a document, a duration
    /// and a selection; nothing gives it a running `AVAudioEngine`, so playing,
    /// looping, bypassed and preparing are reachable only from here.
    init(
        store: CuttingRoomStore,
        playing: Bool? = nil,
        looping: Bool? = nil,
        bypassed: Bool? = nil,
        preparing: Bool? = nil
    ) {
        _store = ObservedObject(wrappedValue: store)
        forcedIsPlaying = playing
        forcedLoops = looping
        forcedBypass = bypassed
        forcedPreparing = preparing
    }
}
#endif
