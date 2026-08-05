// Melo/Views/EQSliderView.swift
import SwiftUI
import AppKit

struct EQSliderView: View {
    let frequency: String
    @Binding var gain: Float
    let range: ClosedRange<Float> = -12...12

    // Local state for smooth visual updates
    @State private var localGain: Float = 0
    @State private var isDragging: Bool = false
    /// Flat is the one position on an EQ band that means something specific,
    /// and it's the position users try hardest to return to. Ticking there
    /// makes it findable without watching the dB readout.
    @State private var detents = DetentTracker(values: [0], tolerance: 0.2)
    @FocusState private var isFocused: Bool

    /// One arrow-key step, in dB. Option quarters it, matching the precision
    /// modifier used by the volume sliders.
    private var keyStep: Float {
        NSEvent.modifierFlags.contains(.option) ? 0.25 : 1
    }

    private var accessibilityBandLabel: String {
        "\(frequency) hertz band"
    }

    // Use design tokens for slider style variant support
    private var trackWidth: CGFloat { DesignTokens.Dimensions.sliderTrackHeight }
    private var thumbSize: CGFloat { DesignTokens.Dimensions.sliderThumbSize }
    private let tickCount = 5  // Number of tick marks
    private let tickWidth: CGFloat = 3
    private let tickGap: CGFloat = 3
    private let verticalPadding: CGFloat = 8

    private func formatGain(_ gain: Float) -> String {
        let rounded = Int(gain.rounded())
        return rounded >= 0 ? "+\(rounded)dB" : "\(rounded)dB"
    }

    /// Applies a gain change from the keyboard or VoiceOver and reports the
    /// flat detent.
    private func adjust(by delta: Float) {
        let next = min(max(localGain + delta, range.lowerBound), range.upperBound)
        guard next != localGain else { return }
        localGain = next
        gain = next
        if detents.crossed(Double(next)) {
            Haptics.detent()
        } else {
            Haptics.step()
        }
    }

    private func handleArrowKey(_ keyPress: KeyPress) -> KeyPress.Result {
        switch keyPress.key {
        case .upArrow:
            adjust(by: keyStep)
            return .handled
        case .downArrow:
            adjust(by: -keyStep)
            return .handled
        default:
            return .ignored
        }
    }

    var body: some View {
        VStack(spacing: DesignTokens.Spacing.xs) {
            GeometryReader { geo in
                // Thumb travels within padded range
                let travelHeight = geo.size.height - (verticalPadding * 2)
                let normalizedGain = CGFloat((localGain - range.lowerBound) / (range.upperBound - range.lowerBound))
                let thumbY = verticalPadding + travelHeight * (1 - normalizedGain)

                Color.clear
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                if !isDragging {
                                    // Don't tick against the value left over
                                    // from the previous gesture.
                                    detents.reset()
                                }
                                isDragging = true
                                // Map touch to padded range
                                let normalizedY = (value.location.y - verticalPadding) / travelHeight
                                let normalized = 1 - normalizedY
                                let clamped = min(max(normalized, 0), 1)
                                let newGain = Float(clamped) * (range.upperBound - range.lowerBound) + range.lowerBound
                                localGain = newGain
                                gain = newGain
                                if detents.crossed(Double(newGain)) {
                                    Haptics.detent()
                                }
                            }
                            .onEnded { _ in
                                isDragging = false
                                detents.reset()
                            }
                    )
                    .scrollWheelStep($gain, in: range)
                    .overlay {
                        // All visuals - no hit testing
                        ZStack {
                            // Tick marks on LEFT side
                            VStack(spacing: 0) {
                                ForEach(0..<tickCount, id: \.self) { index in
                                    if index > 0 { Spacer() }
                                    Rectangle()
                                        .fill(DesignTokens.Colors.textTertiary.opacity(0.4))
                                        .frame(width: tickWidth, height: 1)
                                }
                            }
                            .frame(height: travelHeight)
                            .offset(x: -(trackWidth / 2 + tickGap + tickWidth / 2))

                            // Tick marks on RIGHT side
                            VStack(spacing: 0) {
                                ForEach(0..<tickCount, id: \.self) { index in
                                    if index > 0 { Spacer() }
                                    Rectangle()
                                        .fill(DesignTokens.Colors.textTertiary.opacity(0.4))
                                        .frame(width: tickWidth, height: 1)
                                }
                            }
                            .frame(height: travelHeight)
                            .offset(x: trackWidth / 2 + tickGap + tickWidth / 2)

                            // Track (full height)
                            DesignTokens.Dimensions.Shape.custom(2)
                                .fill(DesignTokens.Colors.sliderTrack)
                                .frame(width: trackWidth)

                            // Center line (0 dB marker) - spans across ticks
                            Rectangle()
                                .fill(DesignTokens.Colors.unityMarker)
                                .frame(width: trackWidth + (tickGap + tickWidth) * 2, height: 1.5)

                            // Knob-style thumb (themed background with center dot)
                            ZStack {
                                Circle()
                                    .fill(DesignTokens.Colors.thumbBackground)
                                Circle()
                                    .fill(DesignTokens.Colors.thumbDot)
                                    .frame(width: thumbSize * 0.35, height: thumbSize * 0.35)
                            }
                            .frame(width: thumbSize, height: thumbSize)
                            .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
                            .position(x: geo.size.width / 2, y: thumbY)

                            // dB value label (appears during drag)
                            if isDragging {
                                Text(formatGain(localGain))
                                    .font(DesignTokens.Typography.Scale.caption2(.medium).monospacedDigit())
                                    .foregroundStyle(DesignTokens.Colors.textPrimary)
                                    .fixedSize()
                                    .position(x: geo.size.width / 2, y: thumbY - thumbSize / 2 - 10)
                            }
                        }
                        .allowsHitTesting(false)
                    }
            }

            VStack(spacing: 0) {
                Text(frequency)
                    .font(DesignTokens.Typography.eqLabel)
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
                Text("Hz")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.Colors.textTertiary)
            }
        }
        .focusable()
        .focused($isFocused)
        .onKeyPress(phases: [.down, .repeat], action: handleArrowKey)
        .overlay {
            DesignTokens.Dimensions.Shape.xs
                .strokeBorder(DesignTokens.Colors.accentPrimary, lineWidth: 2)
                .opacity(isFocused ? 1 : 0)
                .allowsHitTesting(false)
        }
        // Ten bands used to be a wall of unlabelled graphics to VoiceOver:
        // reachable, unnamed, and unadjustable.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityBandLabel)
        .accessibilityValue(formatGain(localGain))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment:
                adjust(by: 1)
            case .decrement:
                adjust(by: -1)
            @unknown default:
                break
            }
        }
        .onAppear {
            localGain = gain  // Initialize from binding
        }
        .onChange(of: gain) { _, newValue in
            localGain = newValue  // Sync from external changes
        }
    }
}

#Preview {
    HStack(spacing: 8) {
        EQSliderView(frequency: "32", gain: .constant(6))
        EQSliderView(frequency: "1k", gain: .constant(0))
        EQSliderView(frequency: "16k", gain: .constant(-6))
    }
    .frame(width: 120, height: 120)
    .padding()
    .darkGlassBackground()
    .environment(\.colorScheme, .dark)
}
