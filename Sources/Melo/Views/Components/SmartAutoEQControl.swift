import SwiftUI

/// Prominent local content-analysis control for Melo's adaptive tonal balancer.
/// Each live app is analyzed independently inside its own audio tap.
struct SmartAutoEQControl: View {
    let settings: AdaptiveAudioSettings
    let onSettingsChange: (AdaptiveAudioSettings) -> Void

    private enum Selection: Hashable {
        case off
        case intensity(AdaptiveAudioIntensity)
    }

    private var selection: Selection {
        settings.enabled && settings.contentAwareEQEnabled
            ? .intensity(settings.intensity)
            : .off
    }

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(selection == .off ? 0.10 : 0.20))
                Image(systemName: selection == .off ? "sparkles" : "waveform.badge.magnifyingglass")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(selection == .off ? DesignTokens.Colors.textSecondary : Color.accentColor)
            }
            .frame(width: 26, height: 26)

            VStack(alignment: .leading, spacing: 1) {
                Text("Smart Sound")
                    .font(.system(size: 11, weight: .semibold))
                Text("Adapts each app locally for speech, music, and cinematic audio")
                    .font(.system(size: 9))
                    .foregroundStyle(DesignTokens.Colors.textTertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: DesignTokens.Spacing.sm)

            HStack(spacing: 2) {
                selectionButton("Off", selection: .off)
                ForEach(AdaptiveAudioIntensity.allCases) { intensity in
                    selectionButton(intensity.description, selection: .intensity(intensity))
                }
            }
            .padding(2)
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.Dimensions.buttonRadius + 2)
                    .fill(DesignTokens.Colors.pickerBackground)
            )
        }
        .padding(.horizontal, DesignTokens.Spacing.sm)
        .padding(.vertical, 7)
        .background {
            RoundedRectangle(cornerRadius: DesignTokens.Dimensions.rowRadius)
                .fill(DesignTokens.Colors.glassFillStrong.opacity(0.55))
        }
        .overlay {
            RoundedRectangle(cornerRadius: DesignTokens.Dimensions.rowRadius)
                .strokeBorder(DesignTokens.Colors.glassRowBorderHover, lineWidth: 0.5)
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func selectionButton(_ label: String, selection target: Selection) -> some View {
        let selected = selection == target
        Button {
            var updated = settings
            switch target {
            case .off:
                updated.contentAwareEQEnabled = false
                if !updated.smartNormalizationEnabled {
                    updated.enabled = false
                }
            case .intensity(let intensity):
                updated.enabled = true
                updated.contentAwareEQEnabled = true
                updated.intensity = intensity
            }
            onSettingsChange(updated)
        } label: {
            Text(label)
                .font(.system(size: 9, weight: selected ? .semibold : .medium))
                .foregroundStyle(selected ? DesignTokens.Colors.textPrimary : DesignTokens.Colors.textSecondary)
                .padding(.horizontal, 7)
                .frame(height: 22)
                .background {
                    if selected {
                        RoundedRectangle(cornerRadius: DesignTokens.Dimensions.buttonRadius)
                            .fill(Color.accentColor.opacity(0.18))
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.meloHover)
        .accessibilityLabel("Smart Sound \(label)")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help(target == .off ? "Turn off content-aware EQ" : "Use \(label.lowercased()) adaptive correction")
    }
}

#Preview("Smart Auto EQ") {
    PreviewContainer {
        SmartAutoEQControl(
            settings: {
                var settings = AdaptiveAudioSettings()
                settings.enabled = true
                settings.contentAwareEQEnabled = true
                settings.smartNormalizationEnabled = true
                settings.intensity = .medium
                return settings
            }(),
            onSettingsChange: { _ in }
        )
        .frame(width: 560)
    }
}
