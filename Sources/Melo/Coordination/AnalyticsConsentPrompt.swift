// Melo/Coordination/AnalyticsConsentPrompt.swift
import AppKit
import SwiftUI

/// Closing the window with the title-bar button is an answer: no. Without this,
/// consent stays `.unasked` and the same window reappears at every launch,
/// which is exactly the nag an opt-in model is supposed to avoid. It mirrors
/// `WhatsNewWindowCloseObserver` and `OnboardingWindowCloseObserver`.
@MainActor
private final class AnalyticsConsentCloseObserver: NSObject, NSWindowDelegate {
    let onClose: () -> Void

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }
}

/// The one-time ask for people who were already using Melo before this release.
///
/// They must not be shown first-run setup again just to be asked one question,
/// so `MeloExperienceVersion.onboarding` is deliberately left alone and this
/// small window carries the question instead. It is shown at most once: every
/// way out of it — either button, or the close box — writes a definite answer.
@MainActor
final class AnalyticsConsentPrompt {
    private let settings: SettingsManager

    private var window: NSWindow?
    private var closeObserver: AnalyticsConsentCloseObserver?

    init(settings: SettingsManager) {
        self.settings = settings
    }

    /// - Parameters:
    ///   - suppressedByOnboarding: true when first-run setup is about to appear
    ///     or is on screen. New users are asked *inside* setup, so this prompt
    ///     has nothing to do for them and must not stack a second window on top.
    ///   - suppressedByWhatsNew: true when release notes are on screen. Two
    ///     windows at one launch is the point at which people stop reading
    ///     either of them, and this question can wait a launch.
    ///
    /// Following `WhatsNewCoordinator.showIfNeeded(suppressedByOnboarding:)`
    /// rather than adding a delay: whether another window is up is a fact the
    /// caller already has, and guessing it from a timer is how this ordering
    /// breaks silently later.
    func showIfNeeded(suppressedByOnboarding: Bool, suppressedByWhatsNew: Bool) {
        guard settings.appSettings.analyticsConsent == .unasked else { return }
        // Only existing installs reach this. A fresh install has setup pending,
        // and setup answers the question itself.
        guard settings.appSettings.onboardingVersionCompleted >= MeloExperienceVersion.onboarding else { return }
        guard !suppressedByOnboarding else { return }
        guard !suppressedByWhatsNew else { return }
        present()
    }

    private func present() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 320),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Help Improve Melo"
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.center()

        let view = AnalyticsConsentPromptView(
            onShare: { [weak self, weak window] in
                self?.record(.granted)
                window?.close()
            },
            onDecline: { [weak self, weak window] in
                self?.record(.denied)
                window?.close()
            }
        )
        window.contentViewController = NSHostingController(rootView: view)
        window.isReleasedWhenClosed = false

        let observer = AnalyticsConsentCloseObserver { [weak self] in
            self?.record(.denied)
            self?.window = nil
        }
        window.delegate = observer
        closeObserver = observer

        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Never overwrites an answer that already exists — the close observer and a
    /// button press both fire when a button dismisses the window, and the button
    /// is the one that must win.
    private func record(_ consent: AnalyticsConsent) {
        guard settings.appSettings.analyticsConsent == .unasked else { return }
        var appSettings = settings.appSettings
        appSettings.analyticsConsent = consent
        settings.appSettings = appSettings
        TelemetryService.shared.refreshConsent()
    }
}

/// One question, two buttons, one line saying exactly what leaves the machine,
/// and where to change it. Anything longer gets dismissed unread, and a consent
/// screen that is dismissed unread has not collected consent.
@MainActor
private struct AnalyticsConsentPromptView: View {
    let onShare: () -> Void
    let onDecline: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "chart.bar.doc.horizontal")
                .font(.system(size: 40, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)
                .frame(width: 78, height: 78)
                .background(Circle().fill(.tint.opacity(0.12)))

            Text("Help Improve Melo?")
                .font(.system(size: 24, weight: .semibold, design: .rounded))

            Text("Melo can send anonymous notes about which features get used, so the next version improves the parts you actually reach for.")
                .font(.system(size: 14, weight: .medium))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)

            Text("Collected: Melo’s version, your macOS version, and which buttons were pressed. Never the names of your apps, your audio devices, or your Mac. You can change this any time in Settings › General.")
                .font(DesignTokens.Typography.Scale.caption())
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 380)

            HStack(spacing: DesignTokens.Spacing.sm2) {
                Button("Share Anonymous Usage", action: onShare)
                    .buttonStyle(.borderedProminent)
                Button("Don’t Share", action: onDecline)
                    .buttonStyle(.bordered)
            }
            .padding(.top, DesignTokens.Spacing.xs)
        }
        .padding(.horizontal, 30)
        .padding(.vertical, DesignTokens.Spacing.xl)
        .frame(minWidth: 460, maxWidth: 460, minHeight: 320, maxHeight: .infinity)
        .background(.regularMaterial)
    }
}
