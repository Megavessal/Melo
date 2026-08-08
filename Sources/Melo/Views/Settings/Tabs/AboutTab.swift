// Melo/Views/Settings/Tabs/AboutTab.swift
import AppKit
import SwiftUI

@MainActor
struct AboutTab: View {
    @Bindable var appSupport: AppSupportCoordinator
    /// The section the Guide sent the reader here to see. No default: dropping
    /// it at the call site is then a build error rather than a tab that quietly
    /// opens at the top again.
    let sectionTarget: SettingsSectionTarget?

    private var versionShort: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
    }

    private var yearText: String {
        let startYear = 2026
        let currentYear = Calendar.current.component(.year, from: .now)
        return startYear == currentYear ? "\(startYear)" : "\(startYear)-\(currentYear)"
    }

    /// No `guidedSectionScroll` here, unlike the tabs that own a `ScrollView`.
    /// This page is one screenful and does not scroll, so there is nowhere to
    /// travel to — the anchors' other half, the mark, is the whole answer. A
    /// `scrollPosition` binding with no scroll view to bind to would be a
    /// modifier that satisfies a grep and moves nothing.
    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage ?? NSImage())
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 96, height: 96)

                Text("Melo")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(DesignTokens.Colors.textPrimary)

                Text("Version \(versionShort) (\(buildNumber))")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)

                Button("What's New in Melo") { appSupport.showWhatsNew() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .padding(.top, DesignTokens.Spacing.xs)
            }
            .settingsSectionAnchor("About Melo", target: sectionTarget)

            Spacer()

            // Grouped so the mark covers both links at once: the catalog's
            // "License and Source" entry names the licence *and* the upstream
            // project, and they are two separate rows here.
            VStack(spacing: 0) {
                AboutLinkChip(
                    label: "Open source foundation",
                    icon: "star",
                    hoverIcon: "star.fill",
                    hoverColor: .yellow,
                    url: URL(string: "https://github.com/ronitsingh10/FineTune")!
                )

                footer
                    .padding(.top, 16)
                    .padding(.bottom, 16)
            }
            .settingsSectionAnchor("License and Source", target: sectionTarget)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Button {
                NSWorkspace.shared.open(DesignTokens.Links.license)
            } label: {
                Text("GPL-3.0")
            }
            .buttonStyle(.meloHover)

            Text("·")
            Text("Melo modifications \(yearText) · Based on FineTune by Ronit Singh")
        }
        .font(.system(size: 10))
        .foregroundStyle(.tertiary)
    }
}
