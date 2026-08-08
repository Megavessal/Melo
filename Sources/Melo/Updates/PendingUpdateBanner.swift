import SwiftUI

/// How a waiting update announces itself inside Melo's own popup.
///
/// Melo used to announce one by inserting a *second* menu bar extra of its own
/// accord, and to treat that extra as the load-bearing channel. Apple's HIG is
/// explicit that the menu bar belongs to the person, not the app — "let people,
/// not your app, decide whether to put your menu bar extra in the menu bar" —
/// and equally explicit that an app must not depend on one being visible, since
/// the system hides extras when the bar is crowded. Melo did both at once, and
/// the icon the user *had* chosen said nothing about the update at all.
///
/// So the update lives on the surfaces the user already opted into: a badge on
/// Melo's own menu bar icon, its context menu, this banner, and the Updates
/// tab. Nothing new appears in the menu bar.
struct PendingUpdateBanner: View {
    let update: SparkleUpdateController.PendingUpdate
    let onInstall: () -> Void
    let onReleaseNotes: (() -> Void)?
    let onRemindLater: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: DesignTokens.Spacing.sm) {
                Image(systemName: update.isCritical
                      ? "exclamationmark.arrow.trianglehead.2.clockwise.rotate.90"
                      : "arrow.down.circle.fill")
                    .font(.body)
                    .foregroundStyle(update.isCritical ? Color.orange : Color.accentColor)

                VStack(alignment: .leading, spacing: 2) {
                    // `textPrimary`, not `textSecondary`. This is the headline
                    // of the one item in the popup that expires, and it was
                    // drawn a full step *below* the device rows underneath it —
                    // so the thing with a deadline was the quietest text on the
                    // surface. The supporting line below it stays tertiary;
                    // that is where the hierarchy belongs.
                    Text("\(update.displayName) is available")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(DesignTokens.Colors.textPrimary)
                    Text(detail)
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(DesignTokens.Colors.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: DesignTokens.Spacing.xs)
            }

            HStack(spacing: 6) {
                Button("Update Now", action: onInstall)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)

                if let onReleaseNotes {
                    Button("What’s New", action: onReleaseNotes)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }

                // "Remind Me Later" rather than only "Skip". Skipping is the
                // permanent answer and lives in Settings → Updates; the answer
                // a busy person actually wants is this one, and when it was
                // missing the permanent one was the only way to get quiet.
                // Worded exactly as the status-item menu and Settings → Updates
                // word it: one action must not have three names.
                Button("Remind Me Later", action: onRemindLater)
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, DesignTokens.Spacing.md)
        .padding(.vertical, DesignTokens.Spacing.sm)
        .background(DesignTokens.Colors.glassFillStrong, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(DesignTokens.Colors.menuBorder, lineWidth: 0.5)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(update.displayName) is available. \(detail)")
    }

    private var detail: String {
        var parts: [String] = []
        if update.isCritical {
            parts.append("Important update")
        }
        // "Downloads", not just a size. The version is already named above, so
        // Update Now reads as if the bits were here; they are not, and the
        // press needs the internet. Settings → Updates argues the same point in
        // the same words.
        if update.downloadBytes > 0 {
            let size = ByteCountFormatter.string(fromByteCount: update.downloadBytes, countStyle: .file)
            parts.append("Downloads \(size)")
        } else {
            parts.append("Downloads over the internet")
        }
        parts.append("Melo quits and reopens itself to finish")
        return parts.joined(separator: " • ")
    }
}

