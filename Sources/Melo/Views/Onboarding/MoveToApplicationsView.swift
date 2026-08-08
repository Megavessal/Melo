import AppKit
import SwiftUI

/// The drag-to-Applications picture people already know from a disk image, with a
/// button so nobody has to actually perform the drag. The app icon is a real drag
/// source, so dragging it into a Finder window works too — but the button is the
/// path that also relaunches Melo from its new home, so it is the prominent one.
@MainActor
struct MoveToApplicationsView: View {
    let destinationName: String
    let isTranslocated: Bool
    let onMove: () -> Void
    let onDismiss: () -> Void

    private var appIcon: NSImage {
        NSApplication.shared.applicationIconImage ?? NSImage()
    }

    private var applicationsIcon: NSImage {
        NSWorkspace.shared.icon(forFile: "/Applications")
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: DesignTokens.Spacing.sm)
            header
            Spacer(minLength: DesignTokens.Spacing.lg)
            dragIllustration
            Spacer(minLength: DesignTokens.Spacing.lg)
            explanation
            Spacer(minLength: DesignTokens.Spacing.lg)
            actions
        }
        .padding(DesignTokens.Spacing.xl)
        .frame(minWidth: 520, maxWidth: 520, minHeight: 380, maxHeight: .infinity)
        .background(.regularMaterial)
    }

    private var header: some View {
        VStack(spacing: DesignTokens.Spacing.xs2) {
            Text(isTranslocated ? "Melo needs to move" : "Keep Melo in Applications")
                .font(DesignTokens.Typography.Scale.title2())
            Text(
                isTranslocated
                    ? "macOS is running Melo from a temporary, read-only copy it made when you opened the download."
                    : "Melo is running from outside your \(destinationName) folder."
            )
            .font(DesignTokens.Typography.Scale.footnote())
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var dragIllustration: some View {
        HStack(spacing: DesignTokens.Spacing.xl) {
            iconTile(
                image: appIcon,
                caption: "Melo",
                isDraggable: true
            )

            Image(systemName: "arrow.right")
                .font(DesignTokens.Typography.Scale.title3(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)

            iconTile(
                image: applicationsIcon,
                caption: destinationName,
                isDraggable: false
            )
        }
        .padding(.vertical, DesignTokens.Spacing.sm)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Drag Melo into your \(destinationName) folder")
    }

    private func iconTile(image: NSImage, caption: String, isDraggable: Bool) -> some View {
        VStack(spacing: DesignTokens.Spacing.sm) {
            iconImage(image, isDraggable: isDraggable)
            Text(caption)
                .font(DesignTokens.Typography.Scale.caption(.medium))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func iconImage(_ image: NSImage, isDraggable: Bool) -> some View {
        let icon = Image(nsImage: image)
            .resizable()
            .scaledToFit()
            .frame(width: 88, height: 88)

        if isDraggable {
            icon
                .onDrag {
                    // Finder accepts a file URL provider and performs the copy
                    // itself, so the familiar drag works even though the button is
                    // the better path.
                    NSItemProvider(contentsOf: Bundle.main.bundleURL) ?? NSItemProvider()
                }
                .help("Drag Melo to your \(destinationName) folder")
        } else {
            icon
        }
    }

    private var explanation: some View {
        Text(
            isTranslocated
                ? "Settings and updates cannot be saved from there, so nothing you change now will survive. Melo will copy itself to \(destinationName) and reopen from there."
                : "Melo replaces itself in place when it updates, which only works from a permanent folder. Melo will copy itself to \(destinationName) and reopen from there — it takes a second and nothing is lost."
        )
        .font(DesignTokens.Typography.Scale.footnote())
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: 400)
    }

    private var actions: some View {
        // Stacks rather than truncating: "Move to Applications" at .large plus a
        // second button already fills a 520pt window at the default text size.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: DesignTokens.Spacing.sm) { actionButtons }
            VStack(spacing: DesignTokens.Spacing.sm) { actionButtons }
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        if !isTranslocated {
            Button("Not Now") { onDismiss() }
                .buttonStyle(.bordered)
                .controlSize(.large)
        }
        Button("Move to \(destinationName)") { onMove() }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
    }
}
