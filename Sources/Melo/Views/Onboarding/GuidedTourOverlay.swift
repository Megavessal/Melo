import AppKit
import SwiftUI

enum GuidedTourTarget: Hashable {
    case devices
    case apps
    case smartAudio
    case equalizer
    case search
    case settings
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
    func guidedTourTarget(_ target: GuidedTourTarget) -> some View {
        anchorPreference(key: GuidedTourTargetPreferenceKey.self, value: .bounds) {
            [target: $0]
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
}

/// Full-bleed scrim with the highlighted control cut out of it. Filled and
/// hit-tested with the even-odd rule so the cutout is a genuine gap in both.
private struct SpotlightScrim: Shape {
    let cutout: CGRect?
    let cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path(rect)
        if let cutout {
            path.addPath(
                Path(roundedRect: cutout, cornerRadius: cornerRadius, style: .continuous)
            )
        }
        return path
    }
}

@MainActor
struct GuidedTourOverlay: View {
    @Bindable var coordinator: GuidedTourCoordinator
    let anchors: [GuidedTourTarget: Anchor<CGRect>]
    let geometry: GeometryProxy

    @State private var pointerPulse = false
    /// Seeded with the old hardcoded value so the first frame is placed
    /// sensibly; replaced by the measured height on the same layout pass.
    @State private var measuredCardHeight: CGFloat = 188

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let cardWidth: CGFloat = 316
    private static let cardCornerRadius: CGFloat = 16
    private static let spotlightCornerRadius: CGFloat = 13

    private var targetFrame: CGRect? {
        switch coordinator.step {
        case .appList, .appControls:
            anchors[.apps].map { geometry[$0] }
        case .devices, .autoEQ:
            anchors[.devices].map { geometry[$0] }
        case .smartAudio:
            anchors[.smartAudio].map { geometry[$0] }
        case .equalizer:
            anchors[.equalizer].map { geometry[$0] }
                ?? anchors[.apps].map { geometry[$0] }
        case .search:
            anchors[.search].map { geometry[$0] }
        case .settings:
            anchors[.settings].map { geometry[$0] }
        }
    }

    var body: some View {
        ZStack {
            dimmingLayer
                .ignoresSafeArea()

            calloutCard

            if targetFrame != nil {
                pointer
            }
        }
        .onAppear { pointerPulse = !reduceMotion }
        .accessibilityElement(children: .contain)
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

    private var spotlightRect: CGRect? {
        guard let frame = targetFrame else { return nil }
        let width = max(52, frame.width + 12)
        let height = max(38, frame.height + 10)
        return CGRect(
            x: frame.midX - width / 2,
            y: frame.midY - height / 2,
            width: width,
            height: height
        )
    }

    /// The card is content-sized: its height depends on how far the step's copy
    /// wraps. It used to be positioned against a hardcoded 188pt, so any step
    /// that wrapped past three lines had its Back/Next/Finish row clamped off
    /// the bottom edge and clipped. The height is measured and fed back, with a
    /// ceiling and a scroll fallback for the extreme case (long copy plus a
    /// large accessibility text size on a short popup).
    private var calloutCard: some View {
        ScrollView(.vertical) {
            calloutContent
                .padding(DesignTokens.Spacing.lg)
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.height
                } action: { height in
                    measuredCardHeight = height
                }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(width: Self.cardWidth, height: resolvedCardHeight)
        .background(
            .regularMaterial,
            in: DesignTokens.Dimensions.Shape.custom(Self.cardCornerRadius)
        )
        .overlay(
            DesignTokens.Dimensions.Shape.custom(Self.cardCornerRadius)
                .strokeBorder(.white.opacity(0.14), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.30), radius: 20, y: 8)
        .position(calloutPosition)
    }

    private var calloutContent: some View {
        let content = copy(for: coordinator.step)
        return VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                    Text(content.eyebrow)
                        .font(DesignTokens.Typography.Scale.caption2(.bold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                        .tracking(0.7)
                    Text(content.title)
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                }
                Spacer()
                Button("Skip Tour") { coordinator.skip() }
                    .buttonStyle(.plain)
                    .font(DesignTokens.Typography.Scale.caption(.medium))
                    .foregroundStyle(.secondary)
            }

            Text(content.message)
                .font(DesignTokens.Typography.Scale.body())
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                if coordinator.step.rawValue > 0 {
                    Button("Back") { coordinator.back() }
                        .buttonStyle(.bordered)
                }
                Spacer()
                Button(coordinator.isLastStep ? "Finish" : "Next") {
                    if coordinator.isLastStep {
                        coordinator.finish()
                    } else {
                        coordinator.next()
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    /// Leaves a 12pt margin top and bottom so the card can never be taller
    /// than the popup it is drawn inside.
    private var maxCardHeight: CGFloat {
        max(140, geometry.size.height - 24)
    }

    private var resolvedCardHeight: CGFloat {
        min(max(measuredCardHeight, 120), maxCardHeight)
    }

    /// Uses the actual macOS arrow-cursor artwork rather than a large hand SF
    /// Symbol. Its rendered size is close to the standard pointer and the motion
    /// is limited to two points so it demonstrates a target without distracting.
    private var pointer: some View {
        Image(nsImage: NSCursor.arrow.image)
            .resizable()
            .interpolation(.high)
            .frame(width: 16, height: 20)
            .shadow(color: .black.opacity(0.48), radius: 2, y: 1)
            .offset(x: pointerPulse ? 1.5 : -0.5, y: pointerPulse ? -1.5 : 0.5)
            .animation(pointerAnimation, value: pointerPulse)
            .position(pointerPosition)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    /// A loop that never stops is precisely the motion Reduce Motion exists to
    /// remove, and it ran for the whole tour. Under the setting the pointer
    /// simply rests on its target. Not routed through `DesignTokens.Animation`
    /// because the token scale has no repeating curve by design.
    private var pointerAnimation: SwiftUI.Animation? {
        reduceMotion
            ? nil
            : .easeInOut(duration: 0.92).repeatForever(autoreverses: true)
    }

    private var calloutPosition: CGPoint {
        guard let frame = targetFrame else {
            return CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
        }

        let cardWidth = Self.cardWidth
        let cardHeight = resolvedCardHeight
        let horizontalPadding = DesignTokens.Spacing.md
        let verticalPadding = DesignTokens.Spacing.md
        let roomBelow = geometry.size.height - frame.maxY
        let proposedY = roomBelow > cardHeight + 22
            ? frame.maxY + cardHeight / 2 + 14
            : frame.minY - cardHeight / 2 - 14
        let y = min(
            geometry.size.height - cardHeight / 2 - verticalPadding,
            max(cardHeight / 2 + verticalPadding, proposedY)
        )
        let x = min(
            geometry.size.width - cardWidth / 2 - horizontalPadding,
            max(cardWidth / 2 + horizontalPadding, geometry.size.width / 2)
        )
        return CGPoint(x: x, y: y)
    }

    private var pointerPosition: CGPoint {
        guard let frame = targetFrame else {
            return CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
        }

        switch coordinator.step {
        case .appList:
            return CGPoint(x: frame.minX + frame.width * 0.34, y: frame.minY + min(72, frame.height * 0.28))
        case .appControls:
            return CGPoint(x: frame.maxX - 48, y: frame.minY + min(82, frame.height * 0.34))
        case .devices:
            return CGPoint(x: frame.minX + frame.width * 0.70, y: frame.minY + min(54, frame.height * 0.30))
        case .autoEQ:
            return CGPoint(x: frame.minX + frame.width * 0.52, y: frame.minY + min(78, frame.height * 0.46))
        case .smartAudio:
            return CGPoint(x: frame.minX + frame.width * 0.80, y: frame.midY)
        case .equalizer:
            return CGPoint(x: frame.maxX - 42, y: frame.minY + min(58, frame.height * 0.28))
        case .search:
            return CGPoint(x: frame.midX, y: frame.midY)
        case .settings:
            return CGPoint(x: frame.midX, y: frame.midY)
        }
    }

    private func copy(for step: GuidedTourCoordinator.Step) -> (eyebrow: String, title: String, message: String) {
        let total = GuidedTourCoordinator.Step.allCases.count
        let number = step.rawValue + 1
        let eyebrow = "\(number) of \(total)"

        switch step {
        case .appList:
            return (
                eyebrow,
                "Each app gets its own volume",
                "Play audio in an app, then move only that app’s slider. Other apps and your main output stay where they are."
            )
        case .appControls:
            return (
                eyebrow,
                "More controls live inside each row",
                "Expand an app to mute it, route it to one or several devices, raise it beyond 100%, adjust stereo balance, and open its equalizer."
            )
        case .devices:
            return (
                eyebrow,
                "Choose speakers, displays, or headphones",
                "Select the main output here. Melo remembers your device priority and restores preferred devices when they reconnect."
            )
        case .autoEQ:
            return (
                eyebrow,
                "AutoEQ corrects supported headphones",
                "The wand beside a supported output searches headphone profiles and applies measured correction. This is device correction, separate from an app’s creative EQ."
            )
        case .smartAudio:
            return (
                eyebrow,
                "Smart Sound adapts automatically",
                "This control can smooth loudness, protect transients, and make gentle content-aware adjustments. Start at Low or Medium and compare before using High."
            )
        case .equalizer:
            return (
                eyebrow,
                "EQ changes the tone of one app",
                "Use a preset or move the ten frequency bands. The switch bypasses the curve without deleting it, and custom curves can be saved as presets."
            )
        case .search:
            return (
                eyebrow,
                "Search finds actions, not only labels",
                "Open search with this button or ⌘K. Natural phrases such as ‘quiet apps,’ ‘headphones,’ ‘updates,’ or ‘volume keys’ lead to the relevant control."
            )
        case .settings:
            return (
                eyebrow,
                "Settings holds the deeper options",
                "Use Settings for themes, shortcuts, updates, accessibility, quiet-app behavior, diagnostics, and replaying this tutorial."
            )
        }
    }
}
