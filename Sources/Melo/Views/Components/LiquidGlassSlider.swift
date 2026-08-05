// Melo/Views/Components/LiquidGlassSlider.swift
import SwiftUI
import AppKit

/// A slider using native SwiftUI Slider for Liquid Glass effect on macOS 26+
/// Styled to match the minimal track appearance of device sliders.
///
/// Three things separate this from a stock slider:
///
/// 1. **The track has depth.** A flat capsule with a flat accent fill reads
///    as a progress bar. A recessed groove with a lit fill reads as a
///    control. The cost is two gradients.
/// 2. **The fill leads the thumb.** Value changes animate on
///    `Animation.track` — near-instant, critically damped — so the fill
///    stays glued to the cursor during a drag but still eases when the
///    value changes from a keyboard shortcut or media key.
/// 3. **Detents are felt, not just seen.** Unity gain gets a trackpad tick.
struct LiquidGlassSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let showUnityMarker: Bool
    /// What VoiceOver calls this control, e.g. "Spotify volume". Every call
    /// site should pass one: without it the slider is an unlabelled adjustable
    /// element and a VoiceOver user has no way to tell four identical sliders
    /// apart.
    let accessibilityTitle: String
    /// Overrides the spoken value for sliders whose position is not a plain
    /// percentage of the range (the app slider's position maps non-linearly
    /// onto 0–400% effective gain).
    let valueDescription: ((Double) -> String)?
    let onEditingChanged: ((Bool) -> Void)?

    @State private var isEditing = false
    @State private var isHovered = false
    @State private var detents: DetentTracker
    /// Value at the moment Option was first held during a drag. Fine-adjust is
    /// measured from here so the pointer keeps a fixed 4:1 relationship to the
    /// value for the whole modified drag.
    @State private var fineAnchor: Double?
    /// Set while this view is writing `value` itself, so the damping in
    /// `onChange` doesn't re-damp its own output and walk the value backwards.
    @State private var isApplyingFineAdjust = false

    /// Show thumb only when hovering or dragging
    private var showThumb: Bool {
        isHovered || isEditing
    }

    init(
        value: Binding<Double>,
        in range: ClosedRange<Double> = 0...1,
        showUnityMarker: Bool = false,
        accessibilityTitle: String = "Volume",
        valueDescription: ((Double) -> String)? = nil,
        onEditingChanged: ((Bool) -> Void)? = nil
    ) {
        self._value = value
        self.range = range
        self.showUnityMarker = showUnityMarker
        self.accessibilityTitle = accessibilityTitle
        self.valueDescription = valueDescription
        self.onEditingChanged = onEditingChanged

        // Unity sits at the midpoint of the range when a unity marker is
        // shown (100% at the centre of the 0–400% boost slider). The range
        // ends are detents too — they're where the value stops moving, and a
        // tick there tells you you've hit the limit without looking.
        let span = range.upperBound - range.lowerBound
        let midpoint = range.lowerBound + span / 2
        self._detents = State(
            initialValue: DetentTracker(
                values: showUnityMarker
                    ? [range.lowerBound, midpoint, range.upperBound]
                    : [range.lowerBound, range.upperBound],
                tolerance: max(span * 0.004, .ulpOfOne)
            )
        )
    }

    private let trackHeight: CGFloat = 4

    private var normalizedValue: Double {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        return min(max((value - range.lowerBound) / span, 0), 1)
    }

    // MARK: - Stepping

    /// One VoiceOver / arrow-key step: 5% of the range, matching the system
    /// volume key increment.
    private var coarseStep: Double {
        (range.upperBound - range.lowerBound) * 0.05
    }

    /// Option quarters the step, the macOS convention for precision dragging.
    /// Shift is deliberately not bound here: the popup used to make Shift
    /// *double* the step, which is the inverse of what Shift means elsewhere
    /// on the platform, so it now does nothing rather than the wrong thing.
    private static let fineFactor: Double = 0.25

    private static func optionHeld() -> Bool {
        NSEvent.modifierFlags.contains(.option)
    }

    private var spokenValue: String {
        if let valueDescription { return valueDescription(value) }
        return "\(Int((normalizedValue * 100).rounded()))%"
    }

    private func clamped(_ candidate: Double) -> Double {
        min(max(candidate, range.lowerBound), range.upperBound)
    }

    private func adjust(by delta: Double) {
        let next = clamped(value + delta)
        guard next != value else { return }
        value = next
        Haptics.step()
    }

    private func valueForX(_ x: CGFloat, width: CGFloat) -> Double {
        guard width > 0 else { return value }
        let fraction = min(max(Double(x / width), 0), 1)
        return range.lowerBound + fraction * (range.upperBound - range.lowerBound)
    }

    /// Drag handling for the part of the hit band the native Slider doesn't
    /// occupy. Writes raw positions; Option damping is applied centrally in
    /// `onChange(of: value)` so pointer and thumb drags behave identically.
    private func bandDrag(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { gesture in
                if !isEditing {
                    isEditing = true
                    detents.reset()
                    onEditingChanged?(true)
                }
                value = valueForX(gesture.location.x, width: width)
            }
            .onEnded { _ in
                isEditing = false
                fineAnchor = nil
                onEditingChanged?(false)
            }
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Full-height drag band. The native Slider draws about 10pt
                // tall, so without this the live area of every volume control
                // in the app is a 10pt ribbon — well under the 28pt HIG floor
                // and easy to miss when running down a dense row. It sits at
                // the bottom of the z-stack, so the thumb still owns its own
                // bounds and native drag behaviour is untouched.
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(bandDrag(width: geo.size.width))

                // Custom track overlay (always visible, hides native track)
                ZStack(alignment: .leading) {
                    // Recessed groove. The gradient is darkest at the top
                    // edge, where a real groove would catch the least light,
                    // with a hairline highlight along the bottom lip.
                    Capsule()
                        .fill(DesignTokens.Colors.sliderTrack)
                        .overlay {
                            Capsule()
                                .fill(
                                    LinearGradient(
                                        colors: [.black.opacity(0.10), .clear],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                )
                        }
                        .overlay {
                            Capsule()
                                .strokeBorder(
                                    LinearGradient(
                                        colors: [
                                            .black.opacity(0.06),
                                            .white.opacity(0.12)
                                        ],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    ),
                                    lineWidth: 0.5
                                )
                        }
                        .frame(height: trackHeight)

                    // Filled track. Same lit-from-above logic as the groove,
                    // so the two read as one physical object rather than a
                    // bar sitting on top of another bar.
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [
                                    DesignTokens.Colors.sliderFill.opacity(0.92),
                                    DesignTokens.Colors.sliderFill
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .overlay {
                            // Specular line along the top of the fill.
                            Capsule()
                                .fill(
                                    LinearGradient(
                                        colors: [.white.opacity(0.28), .clear],
                                        startPoint: .top,
                                        endPoint: .center
                                    )
                                )
                        }
                        .frame(
                            width: max(trackHeight, geo.size.width * normalizedValue),
                            height: trackHeight
                        )
                        .animation(DesignTokens.Animation.track, value: normalizedValue)
                }
                .frame(maxHeight: .infinity)
                .allowsHitTesting(false)

                // Unity marker at 50%. A soft notch rather than a hard tick —
                // it should register peripherally while dragging, not compete
                // with the fill.
                if showUnityMarker {
                    HStack {
                        Spacer()
                        Capsule()
                            .fill(DesignTokens.Colors.unityMarker)
                            .frame(width: 1.5, height: 8)
                            .opacity(showThumb ? 0.9 : 0.45)
                            .animation(DesignTokens.Animation.hover, value: showThumb)
                        Spacer()
                    }
                    .frame(maxHeight: .infinity)
                    .allowsHitTesting(false)
                }

                // Native SwiftUI Slider - gets Liquid Glass thumb on macOS 26+
                // Thumb only visible on hover/drag.
                Slider(value: $value, in: range) { editing in
                    isEditing = editing
                    if editing {
                        // Don't tick against a value left over from the last
                        // gesture on the first frame of this one.
                        detents.reset()
                    } else {
                        fineAnchor = nil
                    }
                    onEditingChanged?(editing)
                }
                .controlSize(.mini)
                .tint(.clear)  // Hide native track, we draw our own
                .opacity(showThumb ? 1 : 0.01)  // Nearly invisible when not hovered, but still interactive
                .shadow(
                    color: .black.opacity(
                        showThumb ? DesignTokens.Elevation.thumb.ambientOpacity : 0
                    ),
                    radius: DesignTokens.Elevation.thumb.ambientRadius,
                    y: DesignTokens.Elevation.thumb.ambientY
                )
                .animation(DesignTokens.Animation.hover, value: showThumb)
            }
        }
        .frame(height: DesignTokens.Dimensions.sliderHitHeight)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovered = hovering
        }
        .onChange(of: value) { _, newValue in
            if isApplyingFineAdjust {
                isApplyingFineAdjust = false
                if isEditing, detents.crossed(newValue) {
                    Haptics.detent()
                }
                return
            }
            // Only fire while the user is actually dragging. Volume changes
            // driven by media keys, another app, or a restored session
            // shouldn't buzz the trackpad.
            guard isEditing else {
                detents.reset()
                fineAnchor = nil
                return
            }
            if Self.optionHeld() {
                let anchor = fineAnchor ?? newValue
                if fineAnchor == nil { fineAnchor = anchor }
                let damped = clamped(anchor + (newValue - anchor) * Self.fineFactor)
                if damped != newValue {
                    isApplyingFineAdjust = true
                    value = damped
                    return
                }
            } else {
                fineAnchor = nil
            }
            if detents.crossed(newValue) {
                Haptics.detent()
            }
        }
        // One adjustable element rather than an unlabelled native Slider
        // buried inside a decorative stack. Before this, VoiceOver could
        // reach every volume control in Melo but set none of them.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityTitle)
        .accessibilityValue(spokenValue)
        .accessibilityAddTraits(.updatesFrequently)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment:
                adjust(by: coarseStep)
            case .decrement:
                adjust(by: -coarseStep)
            @unknown default:
                break
            }
        }
    }
}

// MARK: - Preview

#Preview("Liquid Glass Slider") {
    struct PreviewWrapper: View {
        @State private var value: Double = 0.5

        var body: some View {
            VStack(spacing: 30) {
                LiquidGlassSlider(
                    value: $value,
                    showUnityMarker: true,
                    accessibilityTitle: "Preview volume"
                )
                    .frame(width: 200)

                Text("\(Int(value * 200))%")
                    .foregroundStyle(.secondary)
            }
            .padding(40)
            .background(Color.black)
        }
    }
    return PreviewWrapper()
}
