// Melo/Views/Components/AutoEQPicker.swift
import SwiftUI

/// Icon-only button that opens a popover for selecting AutoEQ headphone correction profiles.
/// Follows the same pattern as the EQ toggle button in `AppRowControls`.
struct AutoEQPicker: View {
    let profileManager: AutoEQProfileManager
    let profileName: String?
    let selection: AutoEQSelection?
    let favoriteIDs: Set<String>
    let onSelect: (AutoEQProfile?) -> Void
    let onImport: () -> Void
    let onToggleFavorite: (String) -> Void
    let importError: String?
    var isCorrectionEnabled: Bool = false
    var onCorrectionToggle: ((Bool) -> Void)?
    var preampEnabled: Bool = true
    var onPreampToggle: (() -> Void)?

    @State private var isExpanded = false
    @State private var isButtonHovered = false

    @Environment(\.appearancePreference) private var appearancePreference

    // MARK: - Layout Constants

    private let popoverWidth: CGFloat = 260

    // MARK: - Network Disclosure

    /// Melo's only outbound request, said where it happens.
    ///
    /// The catalog and every profile come from raw.githubusercontent.com, and
    /// until now nothing in the app said so — for an app that sells itself on
    /// keeping audio local, an undisclosed request is a broken promise even
    /// though it carries no user data. It reads here rather than only in
    /// Settings › Privacy because this popover is where the request is caused;
    /// a line in a tab nobody opened would document the behaviour without
    /// disclosing it to the person triggering it.
    static let networkDisclosure =
        "Profiles come from the open-source AutoEQ project on GitHub, "
        + "downloaded when you open this panel. Nothing about you is sent."

    // MARK: - Computed

    private var iconColor: Color {
        if isExpanded {
            return DesignTokens.Colors.accentPrimary
        } else if selection != nil || profileName != nil {
            // Dim when profile assigned but correction disabled
            return isCorrectionEnabled
                ? DesignTokens.Colors.accentPrimary
                : DesignTokens.Colors.interactiveDefault
        } else if isButtonHovered {
            return DesignTokens.Colors.interactiveHover
        }
        return DesignTokens.Colors.interactiveDefault
    }

    // MARK: - Body

    var body: some View {
        triggerButton
            .background(
                PopoverHost(
                    isPresented: $isExpanded,
                    preferredColorScheme: appearancePreference.swiftUIColorScheme,
                    nsAppearance: appearancePreference.nsAppearance
                ) {
                    popoverContent
                }
            )
    }

    // MARK: - Trigger Button

    private var triggerButton: some View {
        Button {
            withAnimation(DesignTokens.Animation.present) {
                isExpanded.toggle()
            }
        } label: {
            Image(systemName: "wand.and.sparkles")
                .font(.system(size: 16))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(iconColor)
                .frame(
                    minWidth: DesignTokens.Dimensions.minTouchTarget,
                    minHeight: DesignTokens.Dimensions.minTouchTarget
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.meloHover)
        .onHover { isButtonHovered = $0 }
        .help(isExpanded ? "Close AutoEQ" : "AutoEQ correction")
        .animation(DesignTokens.Animation.hover, value: isButtonHovered)
        // The guided tour's AutoEQ step points here. The anchor has to sit on
        // the button rather than on `AutoEQPicker` as a whole: the picker's
        // body puts `PopoverHost` — an NSViewRepresentable with no intrinsic
        // size — in its background, which inflates the composite's bounds to
        // the whole device row, so a spotlight on it highlighted the row.
        .guidedTourTarget(.autoEQ)
    }

    // MARK: - Popover Content

    private var popoverContent: some View {
        VStack(spacing: 0) {
            AutoEQSearchPanel(
                profileManager: profileManager,
                favoriteIDs: favoriteIDs,
                selectedProfileID: selection?.profileID,
                onSelect: { profile in
                    onSelect(profile)
                    withAnimation(DesignTokens.Animation.present) {
                        isExpanded = false
                    }
                },
                onDismiss: {
                    withAnimation(DesignTokens.Animation.present) {
                        isExpanded = false
                    }
                },
                onImport: {
                    isExpanded = false
                    onImport()
                },
                onToggleFavorite: onToggleFavorite,
                importErrorMessage: importError,
                isCorrectionEnabled: isCorrectionEnabled,
                onCorrectionToggle: onCorrectionToggle,
                preampEnabled: preampEnabled,
                onPreampToggle: onPreampToggle
            )
            disclosureFooter
        }
        .frame(width: popoverWidth)
        // The catalog refresh lives here, not in `AutoEQProfileManager.init`,
        // so the request happens with the disclosure above it on screen.
        .task { await profileManager.prepareCatalog() }
        .background(
            VisualEffectBackground(material: .menu, blendingMode: .behindWindow)
                .clipShape(DesignTokens.Dimensions.Shape.custom(8))
        )
        .overlay {
            DesignTokens.Dimensions.Shape.custom(8)
                .strokeBorder(DesignTokens.Colors.glassBorder, lineWidth: 0.5)
        }
    }

    private var disclosureFooter: some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.xs) {
            Image(systemName: "globe")
                .font(.system(size: 9))
                .foregroundStyle(DesignTokens.Colors.textTertiary)
            Text(Self.networkDisclosure)
                .font(.system(size: 9))
                .foregroundStyle(DesignTokens.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DesignTokens.Spacing.sm)
        .padding(.vertical, DesignTokens.Spacing.xs)
        .accessibilityElement(children: .combine)
    }
}
