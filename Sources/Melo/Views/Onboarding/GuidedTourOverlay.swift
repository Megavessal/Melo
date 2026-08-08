import SwiftUI

/// What a step can point at. Each case names one control, not the region that
/// contains it: a highlight around the whole opened row while the card talks
/// about the equalizer teaches the row, not the equalizer.
///
/// The section-level cases — `apps`, `devices`, `smartAudio` — remain for a
/// walkthrough that addresses a whole area, and the What's New tour uses them.
enum GuidedTourTarget: Hashable {
    /// The device list as a whole. The step about choosing an output is about
    /// the list, since which row you want is the thing being chosen.
    case devices
    /// The AutoEQ wand inside a device row. Present only on a device that
    /// supports correction.
    case autoEQ
    case apps
    /// A whole app row, closed. Not used by the first-run tour, which points at
    /// the controls inside; the Settings guide uses it to show where a row is.
    case appRow
    /// A whole app row, opened. Same: an area, for the guide rather than for a
    /// step whose sentence names one control.
    case appControls
    /// One app's volume slider, inside its opened row.
    case appVolume
    /// The arrow beside an app's name that opens and closes its controls.
    case appDisclosure
    /// The ten-band equalizer panel inside an opened app row.
    case equalizer
    /// The preset picker inside that panel. Exists because the equalizer step's
    /// spotlight is deliberately the whole panel — "these ten bands" is what the
    /// step is about — and the centre of that panel is the blank gap between the
    /// 500 Hz and 1 k columns, on neither. This is the control the step's own
    /// sentence tells you to reach for first.
    case eqPreset
    /// The "no apps are playing" placeholder. Exists exactly when the app rows
    /// do not, so a step about apps still has something true to point at.
    case emptyApps
    case smartAudio
    /// Smart Sound's Off/Low/Medium/High picker.
    case smartSoundLevel
    case search
    case settings
    /// The badge and name at the leading edge of a device row — the part you
    /// click to make that device the main output. Exists because the centre of
    /// the `.devices` region is wherever a control happens to sit, and on a
    /// one-device Mac that is the row's mute button.
    case deviceSelection
}

extension GuidedTourTarget {
    /// Where a step should point when this target is not on screen, and one
    /// true sentence about why it is missing.
    ///
    /// The first-run tour writes its own alternates, because its copy is
    /// hand-written per step. A walkthrough built from data — the release
    /// notes — has no author to write them, and without this a note about an
    /// app control rendered as a bare centred card with no spotlight and no
    /// pointer while its copy described the control anyway.
    var absenceFallback: (target: GuidedTourTarget?, pointer: GuidedTourTarget?, note: String)? {
        switch self {
        // `.eqPreset` belongs here and not in the `nil` arm below: the picker is
        // inside the equalizer panel, inside an app row, so it is absent under
        // exactly the condition this note describes. The `nil` arm means "there
        // is no true alternate", which is only honest for the controls that are
        // always on screen.
        case .apps, .appRow, .appControls, .appVolume, .appDisclosure, .equalizer, .eqPreset:
            return (
                .emptyApps,
                nil,
                "Nothing is making sound right now, so there are no app rows yet — the first app to play audio takes one here."
            )
        case .autoEQ:
            return (
                .devices,
                .deviceSelection,
                "No device connected right now supports correction; the wand appears in the row of one that does."
            )
        case .emptyApps:
            return (.apps, nil, "Apps are playing, so their rows are here instead of the placeholder.")
        case .devices, .deviceSelection, .smartAudio, .smartSoundLevel, .search, .settings:
            return nil
        }
    }

    /// The control inside this target that a step should mark, when the target
    /// is a region containing several. The first-run tour writes this per step;
    /// a walkthrough built from data — the Settings Guide's "Show Me" — has no
    /// author to write it, and without it the mark lands on whatever
    /// control sits at the centre of the region, which for the device list is
    /// the row's mute button rather than the badge you are told to click.
    ///
    /// Only the two regions a step is actually pointed at are listed. A guess
    /// for the rest would move the mark somewhere nobody has looked at.
    var regionPointer: GuidedTourTarget? {
        switch self {
        case .devices: return .deviceSelection
        case .equalizer: return .eqPreset
        default: return nil
        }
    }
}

struct GuidedTourTargetPreferenceKey: PreferenceKey {
    static let defaultValue: [GuidedTourTarget: Anchor<CGRect>] = [:]

    static func reduce(
        value: inout [GuidedTourTarget: Anchor<CGRect>],
        nextValue: () -> [GuidedTourTarget: Anchor<CGRect>]
    ) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

extension View {
    /// `anchorPreference` *replaces* the value flowing up from this view, so a
    /// section-level anchor silently erased every anchor set inside it: the app
    /// list is wrapped in `.apps`, which discarded Smart Sound's anchor and each
    /// row's, and those steps fell back to a centred card with no spotlight at
    /// all. Transforming the value already in flight adds this target and keeps
    /// the ones underneath.
    func guidedTourTarget(_ target: GuidedTourTarget) -> some View {
        transformAnchorPreference(
            key: GuidedTourTargetPreferenceKey.self,
            value: .bounds
        ) { targets, anchor in
            targets[target] = anchor
        }
    }

    @ViewBuilder
    func guidedTourTarget(_ target: GuidedTourTarget, when enabled: Bool) -> some View {
        if enabled {
            guidedTourTarget(target)
        } else {
            self
        }
    }

    /// Area-level anchors for one app row, which the Settings guide points at
    /// when it is showing someone *where* a row is. The first-run tour uses the
    /// per-control anchors inside the row instead — a highlight around all of
    /// this teaches the row, not the control a step names.
    func guidedTourAppAnchors(isTourApp: Bool, isExpanded: Bool) -> some View {
        guidedTourTarget(.appRow, when: isTourApp && !isExpanded)
            .guidedTourTarget(.appControls, when: isTourApp && isExpanded)
    }
}

/// Full-bleed scrim with the highlighted control cut out of it. Filled and
/// hit-tested with the even-odd rule so the cutout is a genuine gap in both.
private struct SpotlightScrim: Shape {
    var cutout: CGRect?
    var cornerRadius: CGFloat

    /// Animating the rect rather than cross-fading two scrims is what makes the
    /// highlight travel from one control to the next, so a step change reads as
    /// "look here now" instead of a cut.
    var animatableData: AnimatablePair<
        AnimatablePair<CGFloat, CGFloat>,
        AnimatablePair<CGFloat, CGFloat>
    > {
        get {
            let rect = cutout ?? .zero
            return AnimatablePair(
                AnimatablePair(rect.origin.x, rect.origin.y),
                AnimatablePair(rect.size.width, rect.size.height)
            )
        }
        set {
            guard cutout != nil else { return }
            cutout = CGRect(
                x: newValue.first.first,
                y: newValue.first.second,
                width: newValue.second.first,
                height: newValue.second.second
            )
        }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path(rect)
        if let cutout, cutout.width > 0, cutout.height > 0 {
            path.addPath(
                Path(roundedRect: cutout, cornerRadius: cornerRadius, style: .continuous)
            )
        }
        return path
    }
}

/// The ring drawn on the edge of the cutout. Separate from the scrim because it
/// strokes the cutout only — the scrim's path also contains the popup-sized
/// outer rectangle, which would stroke a border around the whole window.
private struct SpotlightRing: Shape {
    var cutout: CGRect
    var cornerRadius: CGFloat

    var animatableData: AnimatablePair<
        AnimatablePair<CGFloat, CGFloat>,
        AnimatablePair<CGFloat, CGFloat>
    > {
        get {
            AnimatablePair(
                AnimatablePair(cutout.origin.x, cutout.origin.y),
                AnimatablePair(cutout.size.width, cutout.size.height)
            )
        }
        set {
            cutout = CGRect(
                x: newValue.first.first,
                y: newValue.first.second,
                width: newValue.second.first,
                height: newValue.second.second
            )
        }
    }

    func path(in rect: CGRect) -> Path {
        Path(roundedRect: cutout, cornerRadius: cornerRadius, style: .continuous)
    }
}

@MainActor
struct GuidedTourOverlay: View {
    @Bindable var coordinator: GuidedTourCoordinator
    let anchors: [GuidedTourTarget: Anchor<CGRect>]
    let geometry: GeometryProxy

    /// Drives the click ripple. A ring leaving the mark reads as "this is where
    /// you press"; a mark that shivers in place reads as a rendering fault.
    @State private var pressPulse = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let cardWidth: CGFloat = 316
    private static let cardCornerRadius: CGFloat = 16
    private static let spotlightCornerRadius: CGFloat = 13
    /// The cutout never shrinks below this. `DesignTokens.Dimensions.minTouchTarget`
    /// is 28, so every icon-only control in the popup lands on this floor rather
    /// than on its own size — a highlight exactly the size of the icon reads as a
    /// border drawn on the control, not as a hole cut out of the scrim.
    private static let minCutoutSize = CGSize(width: 52, height: 38)
    /// The mark's outer diameter when it is marking a point rather than a
    /// control, and how far outside a control it is drawn when it is marking
    /// one. See `markDiameter`.
    private static let markSize: CGFloat = 15
    private static let markClearance: CGFloat = 12
    /// Where enclosing stops meaning anything. A ring drawn around a 95pt
    /// preset picker is a second spotlight, not a press indicator.
    private static let maxEnclosingMark: CGFloat = 46
    /// How far the click ripple travels out of the mark's edge. A distance
    /// rather than a scale factor: 2.4 × a 15pt mark is a 10.5pt pulse, and
    /// 2.4 × a 40pt one is a 28pt pulse thrown clear across the row.
    private static let rippleTravel: CGFloat = 10.5

    /// What this step actually shows: a step whose target is not on screen
    /// falls back to copy that is true about that absence, rather than
    /// spotlighting a region that has nothing in it.
    private struct ResolvedStep {
        let title: String
        let message: String
        let frame: CGRect?
        /// Set only when the step names a control inside the highlighted
        /// region. Nil means "the centre of the cutout is the right place".
        let pointerFrame: CGRect?
        /// Whether there is a control here to press. The mark is a *press*
        /// indicator — a ring with a click ripple coming out of it — so it is
        /// only ever true about something the user can click.
        let hasSomethingToPress: Bool
    }

    private var resolved: ResolvedStep? {
        guard let step = coordinator.currentStep else { return nil }
        if let target = step.target, let anchor = anchors[target] {
            return ResolvedStep(
                title: step.title,
                message: step.message,
                frame: geometry[anchor],
                pointerFrame: step.pointerTarget
                    .flatMap { anchors[$0] }
                    .map { geometry[$0] },
                // The step found the control it names. Every first-run step
                // names a control you can operate through the cutout.
                hasSomethingToPress: true
            )
        }
        // A step with no target at all is legitimate — the What's New tour uses
        // one for release notes with nothing on screen to point at — and draws a
        // centred card with no cutout.
        guard step.target != nil, let alternate = step.unavailable else {
            return ResolvedStep(
                title: step.title,
                message: step.message,
                frame: nil,
                pointerFrame: nil,
                hasSomethingToPress: false
            )
        }
        let frame = alternate.target.flatMap { anchors[$0] }.map { geometry[$0] }
        return ResolvedStep(
            title: alternate.title,
            message: alternate.message,
            frame: frame,
            pointerFrame: alternate.pointerTarget
                .flatMap { anchors[$0] }
                .map { geometry[$0] },
            // An alternate is a sentence about a control that is *not* here, so
            // there is a press to indicate only when it names a substitute you
            // can actually click. `.autoEQ` does — it sends you to the device
            // row that would carry the wand. The app-control targets do not:
            // they fall back to `.emptyApps`, which is a paragraph of
            // placeholder text, and a press mark on a paragraph is an
            // instruction to click a sentence.
            hasSomethingToPress: alternate.pointerTarget != nil
        )
    }

    private var targetFrame: CGRect? { resolved?.frame }


    var body: some View {
        ZStack {
            dimmingLayer
                .ignoresSafeArea()

            if let rect = spotlightRect {
                spotlightRing(rect)
            }

            calloutCard

            // The mark answers "which point inside the highlight", and an
            // icon-only control leaves that question with nothing to answer: the
            // cutout is already pinned at its floor, so the highlight *is* the
            // control and a 15pt ring dropped in its centre lands on the glyph.
            // Measured on the AutoEQ step: that ring plus `wand.and.sparkles`'s
            // diagonal shaft drew a no-entry sign over the wand, under a card
            // reading "This wand searches measured headphone profiles." The ring
            // struck on the cutout still says which control the step is about,
            // and it is the mark that survives Reduce Motion anyway.
            //
            // The same ring had a third way of landing on the thing it was
            // supposed to be about, and neither rule above could see it. A step
            // whose control is absent falls back to `.emptyApps` — a large
            // placeholder, so the cutout is nowhere near its floor — with no
            // substitute control named, so the mark is the flat 15pt point-mark
            // dropped at the centre of the cutout. The centre of that cutout is
            // the placeholder's own sentence, and the ring drew straight
            // through "No user apps are open" in six frames. Nudging it off the
            // words is the pixel-constant fix this tour was already rebuilt to
            // get rid of; the mark simply does not belong on a paragraph, and
            // saying so is `hasSomethingToPress`.
            if spotlightRect != nil, !cutoutIsAtItsFloor, resolved?.hasSomethingToPress == true {
                pointer
            }
        }
        .animation(spotlightTravel, value: spotlightRect)
        .onAppear {
            pressPulse = !reduceMotion
            announceStep()
        }
        // Without this the dimmed popup underneath stays fully readable, so
        // VoiceOver walks controls the scrim has blocked, and a step change is
        // silent because nothing moves focus.
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .onChange(of: coordinator.index) { _, _ in announceStep() }
        .transition(.opacity)
    }

    /// The spotlight was previously a `blendMode(.destinationOut)` hole punched
    /// in a Rectangle that hit-tested across its whole area, so the tour pointed
    /// at a control the user could not actually touch — it described features
    /// instead of letting them be tried. The scrim is now a single even-odd
    /// path with the cutout removed, and the same path is used as the content
    /// shape, so clicks inside the highlight reach the real control while
    /// everything outside stays blocked.
    private var dimmingLayer: some View {
        let scrim = SpotlightScrim(
            cutout: spotlightRect,
            cornerRadius: Self.spotlightCornerRadius
        )
        return scrim
            .fill(.black.opacity(0.58), style: FillStyle(eoFill: true))
            .contentShape(scrim, eoFill: true)
    }

    /// Reduce Motion removes the ripple and the travel, so the ring is the only
    /// thing left saying which control the step is about. It is therefore drawn
    /// in both modes rather than being part of the animation.
    ///
    /// Two strokes, because the cutout shows whatever the control sits on: a
    /// white-only ring vanished against a highlighted light row, which is
    /// exactly where it is needed.
    private func spotlightRing(_ rect: CGRect) -> some View {
        let ring = SpotlightRing(cutout: rect, cornerRadius: Self.spotlightCornerRadius)
        return ZStack {
            ring.stroke(.black.opacity(0.45), lineWidth: 3)
            ring.stroke(.white.opacity(0.95), lineWidth: 1.5)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func announceStep() {
        guard let step = resolved else { return }
        AccessibilityNotification.Announcement(
            prefixed("\(step.title). \(step.message)")
        ).post()
    }

    private var spotlightRect: CGRect? {
        guard let frame = targetFrame else { return nil }
        let width = max(Self.minCutoutSize.width, frame.width + 12)
        let height = max(Self.minCutoutSize.height, frame.height + 10)
        let rect = CGRect(
            x: frame.midX - width / 2,
            y: frame.midY - height / 2,
            width: width,
            height: height
        )
        // A target taller than the popup (an opened app row on a short popup)
        // would otherwise cut the scrim in half and leave the card floating on
        // clear glass. A target scrolled entirely out of view yields a null
        // rect, whose origin is infinite — that has to become "no spotlight"
        // rather than a shape drawn at infinity.
        let clipped = rect.intersection(
            CGRect(origin: .zero, size: geometry.size).insetBy(dx: -2, dy: -2)
        )
        guard !clipped.isNull, clipped.width > 1, clipped.height > 1 else { return nil }
        return clipped
    }

    /// True when the target was too small to set the cutout's size, so the
    /// highlight came out at `minCutoutSize` with the whole control alone inside
    /// it. Read from the same floor the cutout is built from, because a second
    /// copy of 52 × 38 would let the two rules drift apart.
    private var cutoutIsAtItsFloor: Bool {
        guard let frame = targetFrame else { return true }
        return frame.width + 12 <= Self.minCutoutSize.width
            && frame.height + 10 <= Self.minCutoutSize.height
    }

    /// The card is content-sized: its height depends on how far the step's copy
    /// wraps, and at accessibility text sizes that is most of the popup. It was
    /// once positioned against a hardcoded 188pt, which clipped the
    /// Back/Next/Finish row off the bottom of any step that wrapped past three
    /// lines; it was then positioned against its own measured height, which is a
    /// feedback loop — the measurement changes the layout that produced it, so
    /// the card and the spotlight settle on different passes. It is now placed
    /// by alignment and insets, which needs no measurement at all: the card
    /// sizes to its content, stops at a ceiling, and scrolls beyond it.
    private var calloutCard: some View {
        ScrollView(.vertical) {
            calloutContent
                .padding(DesignTokens.Spacing.lg)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(width: Self.cardWidth)
        .frame(maxHeight: maxCardHeight)
        // Last in the chain, so the whole card is offered "as tall as you need"
        // and reports its content height clamped to the ceiling above. Without
        // it the scroll view takes every point the popup offers and the card
        // becomes a full-height slab with its copy floating in the middle.
        .fixedSize(horizontal: false, vertical: true)
        .background(
            .regularMaterial,
            in: DesignTokens.Dimensions.Shape.custom(Self.cardCornerRadius)
        )
        .overlay(
            DesignTokens.Dimensions.Shape.custom(Self.cardCornerRadius)
                .strokeBorder(.white.opacity(0.14), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.30), radius: 20, y: 8)
        .frame(
            maxWidth: .infinity,
            maxHeight: .infinity,
            alignment: cardPlacement.alignment
        )
        .padding(.top, cardPlacement.topInset)
        .padding(.bottom, cardPlacement.bottomInset)
    }

    /// Sits under the highlighted control when there is room and above it
    /// otherwise, without either side needing to know how tall the card is.
    private var cardPlacement: (alignment: Alignment, topInset: CGFloat, bottomInset: CGFloat) {
        let margin = DesignTokens.Spacing.md
        guard let rect = spotlightRect else {
            return (.center, 0, 0)
        }
        let gap: CGFloat = 14
        let roomBelow = geometry.size.height - rect.maxY
        if roomBelow > geometry.size.height * 0.42 {
            return (.top, min(rect.maxY + gap, geometry.size.height - 120), margin)
        }
        return (.bottom, margin, min(geometry.size.height - rect.minY + gap, geometry.size.height - 120))
    }

    @ViewBuilder
    private var calloutContent: some View {
        if let step = resolved {
            calloutBody(step)
        }
    }

    private func calloutBody(_ step: ResolvedStep) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                    if !stepCounter.isEmpty {
                        Text(stepCounter)
                            // The DesignTokens type scale is fixed-size by design.
                            // Onboarding is exactly where someone who enlarges
                            // system text needs it to grow, so the card's three
                            // styles are relative ones.
                            .font(.system(.caption2, design: .default, weight: .bold))
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                            .tracking(0.7)
                    }
                    Text(step.title)
                        .font(.system(.headline, design: .rounded, weight: .semibold))
                }
                Spacer()
                if !isSingleSpotlight {
                    Button("Skip Tour") { coordinator.skip() }
                        .buttonStyle(.plain)
                        .font(.system(.caption, weight: .medium))
                        .foregroundStyle(.secondary)
                        // Escape is the system gesture for dismissing an overlay,
                        // and without it Escape fell through to the popup and closed
                        // the whole window mid-tour.
                        .keyboardShortcut(.cancelAction)
                        .help("End the tour (esc)")
                }
            }

            Text(step.message)
                .font(.system(.callout))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // Wraps to a second line before it clips: at accessibility text
            // sizes Back and Next no longer fit side by side on a 316pt card.
            ViewThatFits(in: .horizontal) {
                navigationRow
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                    advanceButton
                    if !coordinator.isFirstStep { backButton }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(prefixed(step.title))
    }

    private var navigationRow: some View {
        HStack {
            if !coordinator.isFirstStep { backButton }
            Spacer()
            advanceButton
        }
    }

    private var backButton: some View {
        Button("Back") { coordinator.back() }
            .buttonStyle(.bordered)
            .keyboardShortcut(.leftArrow, modifiers: [])
    }

    private var advanceButton: some View {
        Button(advanceTitle, action: advance)
        .buttonStyle(.borderedProminent)
        .keyboardShortcut(.defaultAction)
        // `defaultAction` is Return alone. The tour is a linear sequence, so
        // Right Arrow advances it too — a shortcut a button can only carry one
        // of, hence the hidden twin.
        .background {
            Button("") { advance() }
                .keyboardShortcut(.rightArrow, modifiers: [])
                .hidden()
        }
        // A single spotlight draws no Skip Tour, so nothing visible is carrying
        // Escape — and the tour's own history records Escape falling through to
        // the popup and closing the whole window when nothing catches it.
        .background {
            if isSingleSpotlight {
                Button("") { coordinator.skip() }
                    .keyboardShortcut(.cancelAction)
                    .hidden()
            }
        }
    }

    /// "Finish" is a word about a sequence. Being shown where one control is
    /// has no sequence to finish.
    private var advanceTitle: String {
        if isSingleSpotlight { return "Done" }
        return coordinator.isLastStep ? "Finish" : "Next"
    }

    private func advance() {
        if coordinator.isLastStep {
            coordinator.finish()
        } else {
            coordinator.next()
        }
    }

    /// A single spotlight is not a tour, so it carries no position in one. The
    /// Settings Guide's "Show Me" builds exactly one step, and the tour
    /// chrome told the user they were "1 OF 1" of the way through something
    /// they could "Skip Tour" out of.
    private var isSingleSpotlight: Bool { coordinator.steps.count == 1 }

    private var stepCounter: String {
        isSingleSpotlight ? "" : "\(coordinator.index + 1) of \(coordinator.steps.count)"
    }

    /// The counter, when there is one, in front of whatever it is prefixing —
    /// so a single spotlight is not announced as "1 of 1" either.
    private func prefixed(_ text: String) -> String {
        stepCounter.isEmpty ? text : "\(stepCounter). \(text)"
    }

    /// Leaves a 12pt margin top and bottom so the card can never be taller
    /// than the popup it is drawn inside.
    private var maxCardHeight: CGFloat {
        max(140, geometry.size.height - 24)
    }

    /// Marks the point the step's sentence names, with the ring and dot and
    /// nothing else. This used to draw a copy of the system arrow on top of the
    /// dot: a second pointer, in the user's own pointer's artwork, that the
    /// user cannot move and that is never where their hand actually is. Apple's
    /// *Pointing devices* guidance describes one pointer — the system's, under
    /// the user's control — and offers no drawn stand-in. Two arrows on one
    /// screen is not an instruction, it is a question about which one is real.
    private var pointer: some View {
        pressRipple
            .position(pointerPosition)
            .animation(pointerTravel, value: pointerPosition)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    /// Two parts, because a tour has to work with motion switched off. The inner
    /// mark is always drawn, so the exact point being indicated is legible in a
    /// still frame and under Reduce Motion; the ring expanding out of it — what
    /// a click looks like — is the part the setting removes.
    private var pressRipple: some View {
        ZStack {
            // Dark under light everywhere: the cutout shows the real control,
            // which is light in Light Mode and on a highlighted row, and a
            // white-only mark disappeared there.
            Circle()
                .strokeBorder(.black.opacity(0.5), lineWidth: 3)
                .frame(width: markDiameter, height: markDiameter)
            Circle()
                .strokeBorder(.white.opacity(0.9), lineWidth: 1.5)
                .frame(width: markDiameter, height: markDiameter)
            if !reduceMotion {
                Circle()
                    .strokeBorder(.black.opacity(pressPulse ? 0.0 : 0.35), lineWidth: 3)
                    .frame(width: markDiameter, height: markDiameter)
                    .scaleEffect(pressPulse ? rippleScale : 1.0)
                    .animation(ripplePulse, value: pressPulse)
                Circle()
                    .strokeBorder(.white.opacity(pressPulse ? 0.0 : 0.75), lineWidth: 1.5)
                    .frame(width: markDiameter, height: markDiameter)
                    .scaleEffect(pressPulse ? rippleScale : 1.0)
                    .animation(ripplePulse, value: pressPulse)
            }
        }
    }

    /// A loop that never stops is precisely the motion Reduce Motion exists to
    /// remove, and it ran for the whole tour. Not routed through
    /// `DesignTokens.Animation` because the token scale has no repeating curve
    /// by design.
    private var ripplePulse: SwiftUI.Animation? {
        reduceMotion
            ? nil
            : .easeOut(duration: 1.15).repeatForever(autoreverses: false)
    }

    /// The pointer travelling between steps is the thing that says the tour
    /// moved somewhere; a cut leaves the user hunting for what changed.
    private var pointerTravel: SwiftUI.Animation? {
        reduceMotion ? nil : DesignTokens.Animation.panel
    }

    private var spotlightTravel: SwiftUI.Animation? {
        reduceMotion ? nil : DesignTokens.Animation.panel
    }

    /// The centre of the cutout, which is now the centre of a control rather
    /// than of a region containing several. The step-id switch that used to sit
    /// here, and the "enter tall regions from the top" rule that replaced it,
    /// were both corrections for anchors that were the wrong size.
    ///
    /// A step whose spotlight is deliberately a whole region — choosing an
    /// output is a choice among rows, so the list is what gets highlighted —
    /// names a control inside it instead. Without that the pointer sat on the
    /// centre of the device row, which is its mute button: a different control
    /// from the one the sentence tells you to click.
    private var pointerPosition: CGPoint {
        guard let rect = spotlightRect else {
            return CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
        }
        if let inner = markedControlFrame {
            return CGPoint(x: inner.midX, y: inner.midY)
        }
        return CGPoint(x: rect.midX, y: rect.midY)
    }

    /// The control named by `resolved?.pointerFrame`, when the step names one
    /// and it really is inside the highlight. Both where the mark goes and how
    /// big it is are read from here rather than each resolving the step for
    /// itself — a mark placed on one frame and sized from another is how a ring
    /// ends up sitting on the glyph it was supposed to enclose.
    private var markedControlFrame: CGRect? {
        guard let rect = spotlightRect, let inner = resolved?.pointerFrame else { return nil }
        // Only if it is actually under the cutout: outside it the mark would be
        // sitting on the scrim, indicating something dimmed out.
        guard rect.contains(CGPoint(x: inner.midX, y: inner.midY)) else { return nil }
        return inner
    }

    /// The mark's outer diameter. A hollow ring is a way of saying "this one",
    /// and at a fixed 15pt dropped on the 28pt device badge it said it by
    /// covering the badge: the ring and the device's own glyph composited into
    /// a struck-through disc, under a card reading "click a row to make that
    /// device the main output". The floor test that suppresses the mark on the
    /// AutoEQ wand cannot see this — the anchor is a 28pt badge inside a
    /// row-sized cutout, so the cutout is nowhere near its floor.
    ///
    /// Sized to enclose the named control instead, the same ring circles it and
    /// the glyph stays readable inside. A control too wide to encircle keeps the
    /// point-mark, which does not hide it either.
    private var markDiameter: CGFloat {
        guard let inner = markedControlFrame else { return Self.markSize }
        let enclosing = max(inner.width, inner.height) + Self.markClearance
        guard enclosing <= Self.maxEnclosingMark else { return Self.markSize }
        return max(Self.markSize, enclosing)
    }

    /// The ripple expands out of the mark and stops at the cutout's edge: past
    /// it the pulse would be drawing on the scrim, indicating something dimmed
    /// out. Every point-mark in the tour has room for the full travel, so this
    /// only bites where the mark already encloses its control and there is
    /// almost nowhere left to go.
    private var rippleScale: CGFloat {
        guard let rect = spotlightRect else { return 1 }
        let centre = pointerPosition
        let room = min(
            min(centre.x - rect.minX, rect.maxX - centre.x),
            min(centre.y - rect.minY, rect.maxY - centre.y)
        ) - markDiameter / 2
        let travel = max(0, min(Self.rippleTravel, room))
        return (markDiameter + travel * 2) / markDiameter
    }
}
