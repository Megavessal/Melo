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

    private var window: UnpromptedWindowPanel?
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
            window.presentUnprompted()
            return
        }

        // Opens by itself a moment after launch, so it is subject to the same
        // activation refusal first-run setup is — and the answer here is a
        // privacy decision, so a window whose "Don't Share" button cannot be
        // clicked is the worst version of that bug. See `UnpromptedWindowPanel`.
        let window = UnpromptedWindowPanel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 320),
            styleMask: UnpromptedWindowPanel.styleMask(),
            backing: .buffered,
            defer: false
        )
        window.title = "Help Improve Melo"

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
        // The window takes its height from the view, not the other way round.
        // A hard-coded 320pt content height on a window that cannot resize is
        // what shipped the truncation: the layout needed more room than that,
        // and SwiftUI settles a height deficit by clipping whichever `Text` is
        // allowed to compress — which cut the body copy off mid-word.
        let hosting = NSHostingController(rootView: view)
        hosting.sizingOptions = [.preferredContentSize]
        window.contentViewController = hosting
        window.setContentSize(hosting.view.fittingSize)
        window.center()

        let observer = AnalyticsConsentCloseObserver { [weak self] in
            self?.record(.denied)
            self?.window = nil
        }
        window.delegate = observer
        closeObserver = observer

        self.window = window
        window.presentUnprompted()
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
///
/// The second paragraph names every field by name on purpose. It is the longest
/// thing here and it stays long: "we respect your privacy" is a shorter sentence
/// and a worse one, because the specificity is the whole claim. Words come out
/// of the sentence around it, never out of either list.
///
/// Not `private`, so `SnapshotScenes` can construct it. This prompt had no
/// frame in the harness at all, which is how a sentence that was cut off
/// mid-word reached a user: nobody reviewing the release could see it.
@MainActor
struct AnalyticsConsentPromptView: View {
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

            Text("Melo can send anonymous usage notes, so the next version improves the parts you actually use.")
                .font(.system(size: 14, weight: .medium))
                .multilineTextAlignment(.center)
                // Without this the paragraph is the flexible one in the stack,
                // so it is what gets clipped when the window is a pixel short.
                // That is not a layout it should ever be allowed to choose.
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 380)

            Text("Sent: Melo’s version, your macOS version, and which buttons were pressed. Never the names of your apps, your audio devices, or your Mac. Change it any time in Settings › General.")
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
        // Width only. The height was pinned at 320 to match a hard-coded window
        // frame, which is the constraint that truncated the copy; the window
        // now measures this view instead.
        .frame(width: 460)
        .background(.regularMaterial)
    }
}
