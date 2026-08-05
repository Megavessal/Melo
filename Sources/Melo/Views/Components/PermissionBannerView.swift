// Melo/Views/Components/PermissionBannerView.swift
import SwiftUI

struct PermissionBannerView: View {
    let permission: AudioRecordingPermission

    var body: some View {
        HStack(alignment: .center, spacing: DesignTokens.Spacing.sm) {
            if permission.status == .unknown, permission.isRequestPending {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: iconName)
                    .font(.body)
                    .foregroundStyle(iconColor)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(DesignTokens.Colors.textSecondary)

                Text(message)
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                if permission.status == .unavailable,
                   let failure = permission.lastFailureDescription,
                   !failure.isEmpty {
                    Text(failure)
                        .font(.caption2)
                        .foregroundStyle(DesignTokens.Colors.textTertiary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: DesignTokens.Spacing.xs)
            actionButtons
        }
        .padding(.horizontal, DesignTokens.Spacing.md)
        .padding(.vertical, DesignTokens.Spacing.sm)
        .background(DesignTokens.Colors.glassFillStrong, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(DesignTokens.Colors.menuBorder, lineWidth: 0.5)
        }
    }

    private var iconName: String {
        switch permission.status {
        case .unknown:
            return "waveform"
        case .authorized:
            return "checkmark.circle"
        case .denied:
            return "speaker.slash"
        case .unavailable:
            return "exclamationmark.triangle"
        }
    }

    private var iconColor: Color {
        switch permission.status {
        case .denied, .unavailable:
            return .orange
        case .unknown, .authorized:
            return DesignTokens.Colors.textTertiary
        }
    }

    private var title: String {
        switch permission.status {
        case .unknown where permission.isRequestPending:
            return "Ready for system audio"
        case .unknown:
            return "System audio is paused"
        case .authorized:
            return "System audio access is working"
        case .denied:
            return "System audio access denied"
        case .unavailable:
            return "System audio couldn't start"
        }
    }

    private var message: String {
        switch permission.status {
        case .unknown where permission.isRequestPending:
            return "Melo connects automatically when any app begins playing."
        case .unknown:
            return "Start Melo's audio engine when you're ready."
        case .authorized:
            return "Melo successfully started its system-audio engine."
        case .denied:
            return "Allow Melo in System Settings → Privacy & Security → Screen & System Audio Recording, then try again."
        case .unavailable:
            return "Melo couldn't start its system-audio engine. Check the system-audio setting, keep audio playing, and try again."
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        switch permission.status {
        case .unknown where permission.isRequestPending:
            EmptyView()

        case .unknown:
            Button("Start Audio") {
                permission.request()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

        case .denied, .unavailable:
            HStack(spacing: DesignTokens.Spacing.sm) {
                Button("Open System Settings") {
                    permission.openSystemAudioSettings()
                }
                .buttonStyle(.borderedProminent)

                Button("Retry") {
                    permission.request()
                }
                .buttonStyle(.bordered)
            }
            .controlSize(.small)

        case .authorized:
            EmptyView()
        }
    }
}
