// Melo/Views/Components/ModeToggle.swift
import SwiftUI

/// A segmented control for switching between single and multi device modes
struct ModeToggle: View {
    @Binding var mode: DeviceSelectionMode

    @State private var hoveredOption: DeviceSelectionMode?

    private let options: [(mode: DeviceSelectionMode, label: String)] = [
        (.single, "Single"),
        (.multi, "Multi")
    ]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.mode) { option in
                optionButton(option.mode, label: option.label)
            }
        }
        .background(
            DesignTokens.Dimensions.Shape.sm
                .fill(.regularMaterial)
        )
        .overlay {
            DesignTokens.Dimensions.Shape.sm
                .strokeBorder(DesignTokens.Colors.glassBorder, lineWidth: 0.5)
        }
    }

    @ViewBuilder
    private func optionButton(_ optionMode: DeviceSelectionMode, label: String) -> some View {
        let isSelected = mode == optionMode
        let isHovered = hoveredOption == optionMode

        Button {
            // Only tick when the selection actually moves; re-picking the
            // segment you're already on isn't a state change.
            if mode != optionMode {
                Haptics.step()
            }
            withAnimation(DesignTokens.Animation.present) {
                mode = optionMode
            }
        } label: {
            HStack(spacing: DesignTokens.Spacing.xs) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(DesignTokens.Typography.Scale.caption())
                    .foregroundStyle(isSelected ? DesignTokens.Colors.accentPrimary : DesignTokens.Colors.textTertiary)

                Text(label)
                    .font(DesignTokens.Typography.Scale.footnote(isSelected ? .medium : .regular))
                    .foregroundStyle(isSelected ? DesignTokens.Colors.textPrimary : DesignTokens.Colors.textSecondary)
            }
            .padding(.horizontal, DesignTokens.Spacing.sm)
            .padding(.vertical, DesignTokens.Spacing.xs2)
            .frame(maxWidth: .infinity)
            .background(
                DesignTokens.Dimensions.Shape.custom(
                    DesignTokens.Dimensions.innerRadius(
                        outer: DesignTokens.Dimensions.buttonRadius,
                        inset: 1
                    )
                )
                    .fill(isSelected ? Color.accentColor.opacity(0.15) : (isHovered ? DesignTokens.Colors.hoverSurface : Color.clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.meloHover)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isSelected ? AccessibilityTraits.isSelected : [])
        .whenHovered { hovering in
            withAnimation(DesignTokens.Animation.hover) {
                hoveredOption = hovering ? optionMode : nil
            }
        }
    }
}

// MARK: - Previews

#Preview("Mode Toggle - Single Selected") {
    ComponentPreviewContainer {
        VStack(spacing: DesignTokens.Spacing.lg) {
            ModeToggle(mode: .constant(.single))
            ModeToggle(mode: .constant(.multi))
        }
        .frame(width: 180)
    }
}

#Preview("Mode Toggle Interactive") {
    struct InteractivePreview: View {
        @State private var mode: DeviceSelectionMode = .single

        var body: some View {
            ComponentPreviewContainer {
                VStack(spacing: DesignTokens.Spacing.md) {
                    ModeToggle(mode: $mode)
                        .frame(width: 180)

                    Text("Current: \(mode == .single ? "Single" : "Multi")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
    return InteractivePreview()
}
