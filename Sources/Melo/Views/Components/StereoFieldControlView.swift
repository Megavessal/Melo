// Melo/Views/Components/StereoFieldControlView.swift
import SwiftUI

/// Compact per-app stereo balance control shown beneath the expanded EQ.
struct StereoFieldControlView: View {
    @Binding var settings: StereoFieldSettings
    let onSettingsChanged: (StereoFieldSettings) -> Void

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { settings.isEnabled },
            set: { enabled in
                settings.isEnabled = enabled
                commit()
            }
        )
    }

    private var positionBinding: Binding<Double> {
        Binding(
            get: { Double(settings.position) },
            set: { position in
                settings.position = Float(position)
                commit()
            }
        )
    }

    private var positionLabel: String {
        let percent = Int((abs(settings.position) * 100).rounded())
        if percent == 0 { return "Center" }
        return settings.position < 0 ? "\(percent)% L" : "\(percent)% R"
    }

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Toggle("", isOn: enabledBinding)
                .toggleStyle(.switch)
                .scaleEffect(0.7)
                .labelsHidden()
                .accessibilityLabel("Enable Stereo Field")

            Label {
                Text("Stereo Field")
                    .font(DesignTokens.Typography.pickerText)
                    .foregroundStyle(DesignTokens.Colors.textPrimary)
            } icon: {
                Image(systemName: "arrow.left.and.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(DesignTokens.Colors.accentPrimary)
            }
            .labelStyle(.titleAndIcon)
            .frame(width: 92, alignment: .leading)

            Text("L")
                .font(DesignTokens.Typography.eqLabel)
                .foregroundStyle(DesignTokens.Colors.textTertiary)

            LiquidGlassSlider(
                value: positionBinding,
                in: Double(StereoFieldSettings.minimumPosition)...Double(StereoFieldSettings.maximumPosition),
                showUnityMarker: true
            )
            .frame(maxWidth: .infinity)
            .opacity(settings.isEnabled ? 1 : 0.35)
            .allowsHitTesting(settings.isEnabled)
            .accessibilityLabel("Stereo balance")
            .accessibilityValue(positionLabel)

            Text("R")
                .font(DesignTokens.Typography.eqLabel)
                .foregroundStyle(DesignTokens.Colors.textTertiary)

            Button {
                settings.position = 0
                commit()
            } label: {
                Text(positionLabel)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(settings.position == 0
                        ? DesignTokens.Colors.textTertiary
                        : DesignTokens.Colors.accentPrimary)
                    .frame(width: 48)
                    .padding(.vertical, 3)
                    .background {
                        Capsule()
                            .fill(DesignTokens.Colors.pickerBackground)
                    }
            }
            .buttonStyle(.meloHover)
            .disabled(!settings.isEnabled || settings.position == 0)
            .help("Center stereo balance")
            .accessibilityLabel("Center stereo balance")
        }
        .padding(.horizontal, DesignTokens.Spacing.md)
        .padding(.vertical, DesignTokens.Spacing.sm)
        .background {
            RoundedRectangle(cornerRadius: DesignTokens.Dimensions.rowRadius)
                .fill(DesignTokens.Colors.recessedBackground)
        }
        .padding(.horizontal, 2)
        .animation(DesignTokens.Animation.quick, value: settings.isEnabled)
    }

    private func commit() {
        settings = settings.normalized
        onSettingsChanged(settings)
    }
}
