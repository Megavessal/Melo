// Melo/Views/Components/MuteButton.swift
import SwiftUI

/// A mute button with pulse animation on toggle. Unmuted wave bucket mirrors
/// TahoeStyleHUD.waveIconName so the popup, menu-bar icon, and on-screen HUD agree.
struct MuteButton: View {
    let isMuted: Bool
    let levelFraction: Double
    let action: () -> Void

    init(isMuted: Bool, levelFraction: Double = 1.0, action: @escaping () -> Void) {
        self.isMuted = isMuted
        self.levelFraction = levelFraction
        self.action = action
    }

    var body: some View {
        BaseMuteButton(
            isMuted: isMuted,
            mutedIcon: "speaker.slash.fill",
            unmutedIcon: VolumeBucket.bucket(for: Float(levelFraction)).symbolName,
            layoutReferenceIcon: "speaker.wave.3.fill",
            mutedHelp: "Unmute",
            unmutedHelp: "Mute",
            action: action
        )
    }
}

/// A mute button for input devices (microphones)
/// Shows mic when unmuted, mic.slash when muted
struct InputMuteButton: View {
    let isMuted: Bool
    let action: () -> Void

    var body: some View {
        BaseMuteButton(
            isMuted: isMuted,
            mutedIcon: "mic.slash.fill",
            unmutedIcon: "mic.fill",
            layoutReferenceIcon: nil,
            mutedHelp: "Unmute microphone",
            unmutedHelp: "Mute microphone",
            action: action
        )
    }
}

// MARK: - Base Implementation

/// Shared mute button implementation with configurable icons
private struct BaseMuteButton: View {
    let isMuted: Bool
    let mutedIcon: String
    let unmutedIcon: String
    let layoutReferenceIcon: String?
    let mutedHelp: String
    let unmutedHelp: String
    let action: () -> Void

    @State private var isPulsing = false
    @State private var isHovered = false

    var body: some View {
        Button {
            // Tick on the tap, not on `isMuted` changing: mute state also
            // arrives from media keys and other apps, and those must not buzz
            // the trackpad.
            Haptics.step()
            action()
        } label: {
            ZStack {
                if let layoutReferenceIcon {
                    // Keeps the button width stable across wave-bucket changes.
                    Image(systemName: layoutReferenceIcon)
                        .opacity(0)
                }
                Image(systemName: isMuted ? mutedIcon : unmutedIcon)
            }
            // 14pt is between `body` and `title3` on the scale; kept raw
            // because the glyph is sized to the 28pt hit target, not to text.
            .font(.system(size: 14))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(buttonColor)
            .scaleEffect(isPulsing ? 1.1 : 1.0)
            .frame(
                minWidth: DesignTokens.Dimensions.minTouchTarget,
                minHeight: DesignTokens.Dimensions.minTouchTarget
            )
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
            .contentShape(Rectangle())
        }
        .buttonStyle(MuteButtonPressStyle())
        .onHover { hovering in
            isHovered = hovering
        }
        .help(isMuted ? mutedHelp : unmutedHelp)
        .accessibilityLabel(isMuted ? mutedHelp : unmutedHelp)
        .animation(DesignTokens.Animation.toggle, value: isPulsing)
        .animation(DesignTokens.Animation.hover, value: isHovered)
        .onChange(of: isMuted) { _, _ in
            isPulsing = true
            Task {
                try? await Task.sleep(for: .seconds(0.25))
                isPulsing = false
            }
        }
    }

    private var buttonColor: Color {
        if isMuted {
            return DesignTokens.Colors.mutedIndicator
        } else if isHovered {
            return DesignTokens.Colors.interactiveHover
        } else {
            return DesignTokens.Colors.interactiveDefault
        }
    }
}

/// Internal button style for press feedback
private struct MuteButtonPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1.0)
            .animation(DesignTokens.Animation.toggle, value: configuration.isPressed)
    }
}

// MARK: - Previews

#Preview("Mute Button States") {
    ComponentPreviewContainer {
        HStack(spacing: DesignTokens.Spacing.lg) {
            VStack {
                MuteButton(isMuted: false) {}
                Text("Unmuted")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack {
                MuteButton(isMuted: true) {}
                Text("Muted")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

#Preview("Input Mute Button States") {
    ComponentPreviewContainer {
        HStack(spacing: DesignTokens.Spacing.lg) {
            VStack {
                InputMuteButton(isMuted: false) {}
                Text("Unmuted")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack {
                InputMuteButton(isMuted: true) {}
                Text("Muted")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

#Preview("Mute Button Interactive") {
    struct InteractivePreview: View {
        @State private var isMuted = false

        var body: some View {
            ComponentPreviewContainer {
                VStack(spacing: DesignTokens.Spacing.md) {
                    MuteButton(isMuted: isMuted) {
                        isMuted.toggle()
                    }

                    Text(isMuted ? "Muted" : "Playing")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
    return InteractivePreview()
}
