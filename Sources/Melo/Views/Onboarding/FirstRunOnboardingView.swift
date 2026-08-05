import AppKit
import SwiftUI

@MainActor
struct FirstRunOnboardingView: View {
    @Bindable var settings: SettingsManager
    @Bindable var accessibility: AccessibilityPermissionService
    @Bindable var audioPrimer: FirstRunAudioPrimer
    let onClose: (Bool) -> Void

    @State private var page = 0

    private let pageCount = 4

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button("Skip") { complete(startTour: false, skipped: true) }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .padding(18)
            }

            // Fixed-height pages clipped at large accessibility text sizes, and
            // the `.unavailable` branch injects an arbitrary-length system
            // message with no ceiling on it.
            ScrollView(.vertical) {
                Group {
                    switch page {
                    case 0: welcomePage
                    case 1: audioAccessPage
                    case 2: accessibilityPage
                    default: tourPage
                    }
                }
                .id(page)
                .transition(.opacity.combined(with: .scale(scale: 0.985)))
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: .infinity)

            HStack(spacing: 8) {
                ForEach(0..<pageCount, id: \.self) { index in
                    Capsule()
                        .fill(index == page ? Color.accentColor : Color.secondary.opacity(0.25))
                        .frame(width: index == page ? 22 : 7, height: 7)
                        .animation(DesignTokens.Animation.quick, value: page)
                }
            }
            .padding(.bottom, 12)

            HStack {
                if page > 0 {
                    Button("Back") { move(to: page - 1) }
                        .buttonStyle(.bordered)
                }
                Spacer()
                if page < pageCount - 1 {
                    Button("Continue") { move(to: page + 1) }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("Show Me Around") { complete(startTour: true, skipped: false) }
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding(20)
        }
        // SwiftUI has no frame(width:minHeight:) overload — a fixed width has to be
        // expressed as equal min and max in the flexible-frame form.
        .frame(minWidth: 590, maxWidth: 590, minHeight: 470, maxHeight: .infinity)
        .background(.regularMaterial)
        .onDisappear {
            audioPrimer.cancel()
        }
    }

    private var welcomePage: some View {
        onboardingPage(
            customIcon: AnyView(
                Image(nsImage: NSApplication.shared.applicationIconImage ?? NSImage())
                    .resizable()
                    .scaledToFit()
                    .frame(width: 94, height: 94)
                    .shadow(color: .black.opacity(0.24), radius: 16, y: 8)
            ),
            title: "Melo",
            message: "Control each app’s volume and choose where it plays—right from the menu bar.",
            detail: "Melo lives in the menu bar and stays out of the way."
        )
    }

    private var audioAccessPage: some View {
        onboardingPage(
            symbol: audioAccessSymbol,
            title: audioAccessTitle,
            message: "To control apps separately, macOS asks you to allow system audio. Melo will play a short sound so the request appears now, not later.",
            detail: "Melo uses this access only while a feature needs it."
        ) {
            audioAccessActions
        }
    }

    private var accessibilityPage: some View {
        onboardingPage(
            symbol: accessibility.isTrustedCached ? "checkmark.shield.fill" : "keyboard.badge.ellipsis",
            title: accessibility.isTrustedCached ? "Volume Keys Are Ready" : "Let Volume Keys Control Melo",
            message: "Allow Accessibility so your Mac’s volume keys can adjust Melo.",
            detail: "This permission is used for volume keys and optional play/pause controls. You can remove it later in System Settings."
        ) {
            if accessibility.isTrustedCached {
                Label("Ready", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(DesignTokens.Typography.Scale.headline())
            } else {
                Button("Allow Accessibility") { accessibility.requestAccess() }
                    .buttonStyle(.borderedProminent)
                Button("Open System Settings") { accessibility.openSystemSettings() }
                    .buttonStyle(.bordered)
            }
        }
    }

    private var tourPage: some View {
        onboardingPage(
            symbol: "cursorarrow.motionlines",
            title: "Take a Quick Tour",
            message: "Melo will open from the menu bar and point out the controls you’ll use most.",
            detail: "It takes about a minute. You can skip at any time."
        )
    }

    @ViewBuilder
    private var audioAccessActions: some View {
        switch audioPrimer.state {
        case .idle, .preparing:
            Button("Play Melo Sound") { audioPrimer.start() }
                .buttonStyle(.borderedProminent)
        case .waitingForMacOS:
            HStack(spacing: 9) {
                ProgressView()
                    .controlSize(.small)
                Text("Waiting for macOS…")
                    .font(DesignTokens.Typography.Scale.body(.medium))
                    .foregroundStyle(.secondary)
            }
        case .ready:
            Label("Audio Access Ready", systemImage: "checkmark.circle.fill")
                .font(DesignTokens.Typography.Scale.headline())
                .foregroundStyle(.green)
            Button("Play Again") { audioPrimer.start() }
                .buttonStyle(.bordered)
        case .permissionNeeded:
            Button("Open System Settings") { audioPrimer.openSystemSettings() }
                .buttonStyle(.borderedProminent)
            Button("Try Again") { audioPrimer.start() }
                .buttonStyle(.bordered)
        case .unavailable(let message):
            VStack(spacing: 8) {
                Text(message)
                    .font(DesignTokens.Typography.Scale.caption())
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 330)
                Button("Try Again") { audioPrimer.start() }
                    .buttonStyle(.bordered)
            }
        }
    }

    private var audioAccessSymbol: String {
        switch audioPrimer.state {
        case .ready: return "checkmark.waveform"
        case .permissionNeeded, .unavailable: return "waveform.badge.exclamationmark"
        default: return "waveform.circle.fill"
        }
    }

    private var audioAccessTitle: String {
        switch audioPrimer.state {
        case .ready: return "App Controls Are Ready"
        case .permissionNeeded: return "Allow System Audio"
        default: return "Set Up App Controls"
        }
    }

    private func onboardingPage<Actions: View>(
        symbol: String,
        title: String,
        message: String,
        detail: String,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        onboardingPage(
            customIcon: AnyView(
                Image(systemName: symbol)
                    .font(.system(size: 44, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.tint)
                    .frame(width: 86, height: 86)
                    .background(Circle().fill(.tint.opacity(0.12)))
            ),
            title: title,
            message: message,
            detail: detail,
            actions: actions
        )
    }

    private func onboardingPage(
        symbol: String,
        title: String,
        message: String,
        detail: String
    ) -> some View {
        onboardingPage(symbol: symbol, title: title, message: message, detail: detail) {
            EmptyView()
        }
    }

    private func onboardingPage<Actions: View>(
        customIcon: AnyView,
        title: String,
        message: String,
        detail: String,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        VStack(spacing: 18) {
            customIcon

            Text(title)
                .font(.system(size: 28, weight: .semibold, design: .rounded))

            Text(message)
                .font(.system(size: 16, weight: .medium))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 430)

            Text(detail)
                .font(DesignTokens.Typography.Scale.body())
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 410)

            HStack(spacing: DesignTokens.Spacing.sm2) { actions() }
                .padding(.top, DesignTokens.Spacing.xs)
        }
        .padding(.horizontal, 38)
        .padding(.vertical, DesignTokens.Spacing.xl)
        // `maxHeight: .infinity` inside a ScrollView collapses to the ideal
        // height; a minimum keeps short pages optically centred instead.
        .frame(maxWidth: .infinity, minHeight: 300)
    }

    private func onboardingPage(
        customIcon: AnyView,
        title: String,
        message: String,
        detail: String
    ) -> some View {
        onboardingPage(customIcon: customIcon, title: title, message: message, detail: detail) {
            EmptyView()
        }
    }

    private func move(to newPage: Int) {
        withAnimation(DesignTokens.Animation.quick) {
            page = min(pageCount - 1, max(0, newPage))
        }
    }

    private func complete(startTour: Bool, skipped: Bool) {
        var appSettings = settings.appSettings
        appSettings.onboardingVersionCompleted = MeloExperienceVersion.onboarding
        appSettings.guidedTourPending = startTour
        if skipped {
            appSettings.guidedTourVersionCompleted = MeloExperienceVersion.guidedTour
        }
        settings.appSettings = appSettings
        // Setup is done and the user has seen what Melo does, so a notification
        // prompt now has context. Deferred from launch on purpose.
        if appSettings.showDeviceDisconnectAlerts {
            NotificationAuthorization.requestIfNeeded()
        }
        onClose(startTour)
    }
}
