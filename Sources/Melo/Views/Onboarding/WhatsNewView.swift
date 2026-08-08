import AppKit
import SwiftUI

/// Lists everything that changed since the user last saw this window, grouped by
/// version and newest first. Grouping matters: someone who skipped three
/// releases needs to see three releases, not one undifferentiated list of
/// changes with no sense of when any of it happened.
@MainActor
struct WhatsNewView: View {
    let notes: [MeloReleaseNote]
    /// True when this was reopened from Settings → About, which hands over the
    /// whole history rather than what was missed. The header used to claim
    /// these were "updates you have not seen yet" either way, which was false
    /// every single time someone asked for it deliberately.
    let showsFullHistory: Bool
    let onDone: () -> Void
    let onShowMe: () -> Void

    init(
        notes: [MeloReleaseNote],
        showsFullHistory: Bool = false,
        onDone: @escaping () -> Void,
        onShowMe: @escaping () -> Void
    ) {
        self.notes = notes
        self.showsFullHistory = showsFullHistory
        self.onDone = onDone
        self.onShowMe = onShowMe
    }

    /// Show Me only makes sense when at least one item has somewhere to point.
    private var hasTour: Bool {
        !WhatsNewCoordinator.tourSteps(for: notes).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxl) {
                    ForEach(notes) { note in
                        releaseSection(note)
                    }
                }
                .padding(.horizontal, DesignTokens.Spacing.xxl)
                .padding(.bottom, DesignTokens.Spacing.xl)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: .infinity)

            footer
        }
        // SwiftUI has no frame(width:minHeight:) overload — a fixed width has to
        // be expressed as equal min and max in the flexible-frame form.
        .frame(minWidth: 560, maxWidth: 560, minHeight: 520, maxHeight: .infinity)
        .background(.regularMaterial)
    }

    private var header: some View {
        VStack(spacing: DesignTokens.Spacing.sm2) {
            Image(nsImage: NSApp.applicationIconImage ?? NSImage())
                .resizable()
                .interpolation(.high)
                .frame(width: 64, height: 64)

            Text("What's New in Melo")
                .font(.system(size: 26, weight: .semibold, design: .rounded))
                .foregroundStyle(DesignTokens.Colors.textPrimary)

            Text(subtitle)
                .font(DesignTokens.Typography.Scale.body())
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, DesignTokens.Spacing.xxl)
        .padding(.horizontal, DesignTokens.Spacing.xxl)
        .padding(.bottom, DesignTokens.Spacing.xl)
        .frame(maxWidth: .infinity)
    }

    private var subtitle: String {
        if showsFullHistory {
            return notes.count > 1
                ? "Every change across the last \(notes.count) releases, newest first."
                : "Every change in this release."
        }
        return notes.count > 1
            ? "Here is everything that changed across the \(notes.count) updates you have not seen yet."
            : "Here is what changed in this update."
    }

    private func releaseSection(_ note: MeloReleaseNote) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                Text("Version \(note.version)")
                    .font(DesignTokens.Typography.Scale.caption2(.bold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.7)
                Text(note.headline)
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                ForEach(note.items) { item in
                    itemRow(item)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Version \(note.version). \(note.headline)")
    }

    private func itemRow(_ item: MeloReleaseNote.Item) -> some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.sm2) {
            Circle()
                .fill(Color.accentColor)
                .frame(width: 5, height: 5)
                .padding(.top, 7)

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                Text(item.title)
                    .font(DesignTokens.Typography.Scale.body(.medium))
                Text(item.detail)
                    .font(DesignTokens.Typography.Scale.body())
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("Done") { onDone() }
                .buttonStyle(.bordered)
            Spacer()
            if hasTour {
                Button("Show Me") { onShowMe() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(DesignTokens.Spacing.xl)
    }
}
