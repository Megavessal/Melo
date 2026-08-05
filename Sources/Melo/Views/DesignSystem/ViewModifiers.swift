// Melo/Views/DesignSystem/ViewModifiers.swift
import SwiftUI

// MARK: - Elevation

/// Applies a two-layer shadow from `DesignTokens.Elevation`.
///
/// The contact shadow is tight and sits directly under the element; the
/// ambient shadow is wide and soft. Stacking them is what makes a surface
/// read as floating a specific distance above what's behind it, rather than
/// as an image with a drop shadow. Both layers are pure black at low alpha —
/// tinted shadows read as glows and cheapen the effect.
struct MeloElevationModifier: ViewModifier {
    let shadow: DesignTokens.Elevation.Shadow
    let isActive: Bool

    func body(content: Content) -> some View {
        content
            .shadow(
                color: .black.opacity(isActive ? shadow.contactOpacity : 0),
                radius: shadow.contactRadius,
                y: shadow.contactY
            )
            .shadow(
                color: .black.opacity(isActive ? shadow.ambientOpacity : 0),
                radius: shadow.ambientRadius,
                y: shadow.ambientY
            )
    }
}

extension View {
    /// - Parameters:
    ///   - shadow: One of the `DesignTokens.Elevation` presets.
    ///   - isActive: Set `false` to collapse the shadow to nothing while
    ///     keeping the modifier in the view tree, so elevation can animate
    ///     in and out without a structural change.
    func meloElevation(
        _ shadow: DesignTokens.Elevation.Shadow,
        isActive: Bool = true
    ) -> some View {
        modifier(MeloElevationModifier(shadow: shadow, isActive: isActive))
    }
}

// MARK: - Universal Pointer Hover Button Style

/// Gives plain custom buttons the same unmistakable pointer affordance as
/// native macOS controls. Bordered/system buttons keep their native hover.
struct MeloHoverButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        MeloHoverButtonBody(configuration: configuration)
    }

    private struct MeloHoverButtonBody: View {
        let configuration: Configuration
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .background {
                    DesignTokens.Dimensions.Shape.sm
                        .fill(isHovered ? DesignTokens.Colors.hoverSurface : Color.clear)
                }
                .overlay {
                    DesignTokens.Dimensions.Shape.sm
                        .strokeBorder(
                            isHovered ? DesignTokens.Colors.glassRowBorderHover : Color.clear,
                            lineWidth: 0.5
                        )
                }
                .meloElevation(DesignTokens.Elevation.hover, isActive: isHovered && !configuration.isPressed)
                // 0.96 is a large enough jump to read as the whole control
                // lurching. 0.975 registers as pressure without the label
                // visibly resampling — the point is to feel the press, not
                // to watch it.
                .scaleEffect(configuration.isPressed ? 0.975 : 1)
                .contentShape(Rectangle())
                .onHover { hovering in
                    isHovered = hovering
                }
                .animation(DesignTokens.Animation.hover, value: isHovered)
                .animation(DesignTokens.Animation.press, value: configuration.isPressed)
        }
    }
}

extension ButtonStyle where Self == MeloHoverButtonStyle {
    static var meloHover: MeloHoverButtonStyle { MeloHoverButtonStyle() }
}

// MARK: - Hoverable Row Modifier (flat-rest, hover-active per System Settings pattern)

struct HoverableRowModifier: ViewModifier {
    let isFocused: Bool
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, DesignTokens.Spacing.sm)
            .padding(.vertical, DesignTokens.Spacing.xs2)
            // Flat at rest; hover reveals hoverSurface. Keyboard focus draws an
            // accent ring instead of the same fill — rendering the two identically
            // meant a keyboard user could not tell where they were, because the
            // pointer happening to rest elsewhere produced the exact same highlight.
            .background(
                DesignTokens.Dimensions.Shape.sm
                    .fill(isHovered ? DesignTokens.Colors.hoverSurface : Color.clear)
                    .allowsHitTesting(false)
            )
            .overlay(
                DesignTokens.Dimensions.Shape.sm
                    .strokeBorder(isFocused ? Color.accentColor : Color.clear, lineWidth: 2)
                    .allowsHitTesting(false)
            )
            .onHover { hovering in
                isHovered = hovering
            }
            .animation(DesignTokens.Animation.hover, value: isHovered)
            .animation(DesignTokens.Animation.hover, value: isFocused)
    }
}

// MARK: - Section Header Style Modifier

struct SectionHeaderStyleModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(DesignTokens.Typography.sectionHeader)
            .foregroundStyle(DesignTokens.Colors.sectionHeaderText)
            .tracking(DesignTokens.Typography.sectionHeaderTracking)
            .textCase(.uppercase)
    }
}

// MARK: - Percentage Text Style Modifier

struct PercentageTextModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(DesignTokens.Typography.percentage)
            .foregroundStyle(DesignTokens.Colors.textSecondary)
            .frame(width: DesignTokens.Dimensions.percentageWidth, alignment: .trailing)
    }
}

// MARK: - Icon Button Style Modifier (Vibrancy-aware)

struct IconButtonStyleModifier: ViewModifier {
    let isActive: Bool
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .foregroundStyle(foregroundColor)
            .symbolRenderingMode(.hierarchical)  // Better vibrancy support
            .frame(minWidth: DesignTokens.Dimensions.minTouchTarget,
                   minHeight: DesignTokens.Dimensions.minTouchTarget)
            .contentShape(Rectangle())
            .onHover { hovering in
                isHovered = hovering
            }
            .animation(DesignTokens.Animation.hover, value: isHovered)
    }

    private var foregroundColor: Color {
        if isActive {
            return DesignTokens.Colors.mutedIndicator
        } else if isHovered {
            return DesignTokens.Colors.interactiveHover
        } else {
            return DesignTokens.Colors.interactiveDefault
        }
    }
}

// MARK: - Glass Button Style Modifier

/// Button styling for glass aesthetic with vibrancy
struct GlassButtonStyleModifier: ViewModifier {
    @State private var isHovered = false
    @State private var isPressed = false

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, DesignTokens.Spacing.sm)
            .padding(.vertical, DesignTokens.Spacing.xs)
            .background {
                Capsule()
                    .fill(.ultraThinMaterial)
            }
            .overlay {
                Capsule()
                    .strokeBorder(
                        isHovered ? DesignTokens.Colors.glassBorderHover : DesignTokens.Colors.glassBorder,
                        lineWidth: 0.5
                    )
            }
            // Hover used to scale to 1.02. Growing on hover is a web
            // convention; on macOS it reads as the button inflating and it
            // resamples the label every frame. Lifting the element with a
            // shadow conveys the same "this is live" signal and matches how
            // native controls behave.
            .meloElevation(DesignTokens.Elevation.hover, isActive: isHovered && !isPressed)
            .scaleEffect(isPressed ? 0.975 : 1.0)
            .onHover { hovering in
                isHovered = hovering
            }
            .animation(DesignTokens.Animation.hover, value: isHovered)
            .animation(DesignTokens.Animation.press, value: isPressed)
    }
}

// MARK: - Vibrancy Icon Modifier

/// Applies proper vibrancy styling to SF Symbols
struct VibrancyIconModifier: ViewModifier {
    let style: VibrancyStyle

    enum VibrancyStyle {
        case primary   // Full brightness
        case secondary // Slightly muted
        case tertiary  // More muted
    }

    func body(content: Content) -> some View {
        content
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(foregroundColor)
    }

    private var foregroundColor: Color {
        switch style {
        case .primary:
            return .primary
        case .secondary:
            return .secondary
        case .tertiary:
            return DesignTokens.Colors.textTertiary
        }
    }
}

// MARK: - View Extensions

extension View {
    /// Applies hoverable row styling (forwards to floatingGlassRow)
    func hoverableRow(isFocused: Bool = false) -> some View {
        modifier(HoverableRowModifier(isFocused: isFocused))
    }

    /// Applies section header text styling (uppercase, spaced, tertiary color)
    func sectionHeaderStyle() -> some View {
        modifier(SectionHeaderStyleModifier())
    }

    /// Applies percentage display styling (monospace, secondary, fixed width)
    func percentageStyle() -> some View {
        modifier(PercentageTextModifier())
    }

    /// Applies icon button styling with hover state (vibrancy-aware)
    func iconButtonStyle(isActive: Bool = false) -> some View {
        modifier(IconButtonStyleModifier(isActive: isActive))
    }

    /// Applies glass button styling
    func glassButtonStyle() -> some View {
        modifier(GlassButtonStyleModifier())
    }

    /// Applies vibrancy styling to SF Symbol icons
    func vibrancyIcon(_ style: VibrancyIconModifier.VibrancyStyle = .secondary) -> some View {
        modifier(VibrancyIconModifier(style: style))
    }
}

// MARK: - Previews

#Preview("Floating Glass Row") {
    VStack(spacing: 8) {
        HStack {
            Image(systemName: "music.note")
                .vibrancyIcon()
            Text("Spotify")
            Spacer()
            Text("75%")
                .percentageStyle()
        }
        .hoverableRow()

        HStack {
            Image(systemName: "video")
                .vibrancyIcon()
            Text("Zoom")
            Spacer()
            Text("100%")
                .percentageStyle()
        }
        .hoverableRow()
    }
    .padding()
    .darkGlassBackground()
    .environment(\.colorScheme, .dark)
}

#Preview("Section Header") {
    VStack(alignment: .leading, spacing: 16) {
        Text("Output Devices")
            .sectionHeaderStyle()

        Text("Apps")
            .sectionHeaderStyle()
    }
    .padding()
    .darkGlassBackground()
    .environment(\.colorScheme, .dark)
}

#Preview("Percentage Text") {
    HStack {
        Text("100%").percentageStyle()
        Text("75%").percentageStyle()
        Text("0%").percentageStyle()
    }
    .padding()
    .darkGlassBackground()
    .environment(\.colorScheme, .dark)
}

#Preview("Icon Button Styles") {
    HStack(spacing: 16) {
        Button { } label: {
            Image(systemName: "speaker.wave.2.fill")
        }
        .iconButtonStyle(isActive: false)

        Button { } label: {
            Image(systemName: "speaker.slash.fill")
        }
        .iconButtonStyle(isActive: true)

        Button { } label: {
            Image(systemName: "slider.vertical.3")
        }
        .iconButtonStyle(isActive: false)
    }
    .padding()
    .darkGlassBackground()
    .environment(\.colorScheme, .dark)
}

#Preview("Glass Button") {
    HStack(spacing: 16) {
        Button { } label: {
            Label("Settings", systemImage: "gear")
        }
        .glassButtonStyle()

        Button { } label: {
            Label("Quit", systemImage: "power")
        }
        .glassButtonStyle()
    }
    .padding()
    .darkGlassBackground()
    .environment(\.colorScheme, .dark)
}

#Preview("Vibrancy Icons") {
    HStack(spacing: 20) {
        VStack {
            Image(systemName: "headphones")
                .font(.title)
                .vibrancyIcon(.primary)
            Text("Primary")
                .font(.caption)
        }

        VStack {
            Image(systemName: "headphones")
                .font(.title)
                .vibrancyIcon(.secondary)
            Text("Secondary")
                .font(.caption)
        }

        VStack {
            Image(systemName: "headphones")
                .font(.title)
                .vibrancyIcon(.tertiary)
            Text("Tertiary")
                .font(.caption)
        }
    }
    .padding()
    .darkGlassBackground()
    .environment(\.colorScheme, .dark)
}
