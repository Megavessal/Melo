// Melo/Views/Components/DevicePicker.swift
import SwiftUI

/// A styled device picker dropdown with "System" option and single/multi mode support
struct DevicePicker: View {
    /// Visual style for the trigger button.
    /// - `.full`: bordered material pill with icon + text + chevron (used in Settings).
    /// - `.iconOnly`: square borderless icon button with hover highlight (used in app rows).
    enum TriggerStyle {
        case full
        case iconOnly
    }

    let devices: [AudioDevice]
    var deviceIconOverrides: [String: String] = [:]
    let selectedDeviceUID: String  // For single mode
    let selectedDeviceUIDs: Set<String>  // For multi mode
    let isFollowingDefault: Bool
    let defaultDeviceUID: String?
    let mode: DeviceSelectionMode
    let onModeChange: (DeviceSelectionMode) -> Void
    let onDeviceSelected: (String) -> Void  // Single mode callback
    let onDevicesSelected: (Set<String>) -> Void  // Multi mode callback
    let onSelectFollowDefault: () -> Void
    let showModeToggle: Bool

    @State private var isExpanded = false
    @State private var isButtonHovered = false

    @Environment(\.appearancePreference) private var appearancePreference

    // Local state mirrors props for popover reactivity
    @State private var currentMode: DeviceSelectionMode = .single
    @State private var currentSelectedUIDs: Set<String> = []

    // Keyboard navigation. Held separately from the committed selection so an
    // open menu can be walked without changing where audio is going.
    @State private var highlightedID: String?
    @State private var typeSelectPrefix = ""
    @State private var typeSelectExpiry = Date.distantPast
    @FocusState private var menuFocused: Bool

    // Configuration
    let triggerWidth: CGFloat
    var triggerStyle: TriggerStyle = .full
    private let itemHeight: CGFloat = 26
    private let itemSpacing: CGFloat = 2
    private let cornerRadius: CGFloat = 8

    // MARK: - Popover Width

    /// The two subtitles the System Audio row can carry, held here so the
    /// string that is *measured* and the string that is *drawn* are the same
    /// object. A fit computed against copy that has since been reworded is a
    /// fit that clips, and nothing in a rendered frame could ever show it —
    /// the popover is an `NSPanel` and the harness never captures one.
    fileprivate static let followsDefaultSubtitle = "Follows macOS default"
    fileprivate static let multiModeSubtitle = "Not available in multi mode"

    /// Everything in a device row that is not the device's name.
    ///
    /// Itemised rather than rolled into one number, because the number is the
    /// thing that was wrong before: `popoverWidth` was a flat 210 with no
    /// record of what it was 210 *of*, so no one could tell whether a new
    /// column had eaten the margin. Left to right, and both sides where a
    /// padding is symmetric.
    private static let rowChrome: CGFloat =
        (5 * 2)                              // LazyVStack .padding(.horizontal, 5)
        + (8 * 2)                            // row .padding(.horizontal, 8)
        + 16                                 // selection indicator column
        + 16                                 // device icon column
        + 12                                 // default-device star: "star.fill" at 9pt
                                             // measures 12pt, and it is reserved on
                                             // every row so the width does not depend
                                             // on which output macOS currently prefers
        + (DesignTokens.Spacing.xs * 4)      // the four gaps between five children
        + DesignTokens.Spacing.xs            // the Spacer's own minimum

    /// Fits the popover to the names it is about to draw.
    ///
    /// 210 stays as the floor, so a Mac whose device names are short gets
    /// exactly the menu it had before; the ceiling is `DropdownWidth.ceiling`,
    /// and past it names truncate rather than the panel growing off-screen.
    ///
    /// Static, parameterised on the names, and not `private`, so
    /// `scripts/verify-app-search.py` can splice and execute *this* function
    /// rather than a restatement of it. A check that calls `DropdownWidth.fit`
    /// with its own arguments proves the policy and proves nothing about the
    /// picker — measured, by pinning this call to a 210 ceiling and watching
    /// every executed assertion stay green.
    static func popoverWidth(forDeviceNames names: [String]) -> CGFloat {
        DropdownWidth.fit(
            titles: names,
            titlePointSize: 11,
            subtitles: [followsDefaultSubtitle, multiModeSubtitle],
            subtitlePointSize: 10,
            chrome: rowChrome,
            minimum: 210
        )
    }

    private var popoverWidth: CGFloat {
        Self.popoverWidth(forDeviceNames: menuItems.map(\.name))
    }

    /// Menu item representation for unified dropdown
    enum MenuItem: Identifiable, Equatable {
        case systemAudio
        case device(AudioDevice)

        var id: String {
            switch self {
            case .systemAudio: return "__system_audio__"
            case .device(let device): return device.uid
            }
        }

        var name: String {
            switch self {
            case .systemAudio: return "System Audio"
            case .device(let device): return device.name
            }
        }
    }

    private var menuItems: [MenuItem] {
        [.systemAudio] + devices.map { .device($0) }
    }

    /// Selected devices intersected with the currently-rendered list.
    /// Filters out stale UIDs (disconnected device, sentinel) so the trigger
    /// badge stays in sync with what the popover actually shows.
    private var validMultiSelections: [AudioDevice] {
        devices.filter { selectedDeviceUIDs.contains($0.uid) }
    }

    /// Display text for trigger button
    private var triggerText: String {
        switch mode {
        case .single:
            return singleModeText
        case .multi:
            let count = validMultiSelections.count
            if count == 0 {
                return singleModeText
            }
            if count == 1 {
                return validMultiSelections[0].name
            }
            return "\(count) devices"
        }
    }

    /// Names the control rather than its current setting. Both triggers are
    /// icon-first — the icon-only one has no text at all — so without this
    /// VoiceOver announced the SF Symbol name and nothing else.
    private var pickerAccessibilityLabel: String { "Output device" }

    /// Text for single-mode display (also used as fallback for empty multi-mode)
    private var singleModeText: String {
        if isFollowingDefault {
            return "System Audio"
        } else if let device = devices.first(where: { $0.uid == selectedDeviceUID }) {
            return device.name
        }
        return "Select"
    }

    @ViewBuilder
    private var triggerIcon: some View {
        switch mode {
        case .single:
            singleModeIcon
        case .multi:
            let valid = validMultiSelections
            if let first = valid.first {
                multiModeIcon(firstDevice: first, count: valid.count)
            } else {
                // Multi mode set but nothing valid selected — show the multi glyph
                // so the user can always tell the app is on multi-routing.
                Image(systemName: "hifispeaker.2.fill")
                    .font(.system(size: 16))
                    .symbolRenderingMode(.hierarchical)
            }
        }
    }

    private func displayIcon(for device: AudioDevice) -> NSImage? {
        DeviceIconResolver.displayIcon(
            overrideSymbol: deviceIconOverrides[device.uid],
            automatic: device.icon,
            deviceName: device.name
        )
    }

    @ViewBuilder
    private func deviceIcon(_ device: AudioDevice) -> some View {
        if let icon = displayIcon(for: device) {
            Image(nsImage: icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 20, height: 20)
        } else {
            Image(systemName: "speaker.wave.2")
                .font(.system(size: 18))
                .symbolRenderingMode(.hierarchical)
        }
    }

    @ViewBuilder
    private var singleModeIcon: some View {
        if isFollowingDefault {
            Image(systemName: "speaker.wave.2.circle")
                .font(.system(size: 15))
                .symbolRenderingMode(.hierarchical)
        } else if let device = devices.first(where: { $0.uid == selectedDeviceUID }),
                  let icon = displayIcon(for: device) {
            Image(nsImage: icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 20, height: 20)
        } else {
            Image(systemName: "speaker.wave.2")
                .font(.system(size: 15))
                .symbolRenderingMode(.hierarchical)
        }
    }

    @ViewBuilder
    private func multiModeIcon(firstDevice: AudioDevice, count: Int) -> some View {
        deviceIcon(firstDevice)
            .overlay(alignment: .bottomTrailing) {
                Text("\(count)")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 0.5)
                    .background(
                        Capsule().fill(DesignTokens.Colors.accentPrimary)
                    )
                    .offset(x: 4, y: 3)
            }
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
                    dropdownContent
                }
            )
            .onChange(of: mode) { _, newMode in
                currentMode = newMode
            }
            .onChange(of: selectedDeviceUIDs) { _, newUIDs in
                currentSelectedUIDs = newUIDs
            }
            .onAppear {
                // Initialize local state from props
                currentMode = mode
                currentSelectedUIDs = selectedDeviceUIDs
            }
    }

    // MARK: - Trigger Button

    @ViewBuilder
    private var triggerButton: some View {
        switch triggerStyle {
        case .full:
            fullTriggerButton
        case .iconOnly:
            iconOnlyTriggerButton
        }
    }

    /// Bordered material pill with icon + text + chevron. Used in Settings rows.
    private var fullTriggerButton: some View {
        Button {
            withAnimation(DesignTokens.Animation.present) {
                isExpanded.toggle()
            }
        } label: {
            HStack(spacing: DesignTokens.Spacing.xs) {
                HStack(spacing: DesignTokens.Spacing.xs) {
                    triggerIcon
                    Text(triggerText)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity)

                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? -180 : 0))
                    .animation(DesignTokens.Animation.present, value: isExpanded)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, DesignTokens.Spacing.sm)
            .padding(.vertical, 4)
            .frame(width: triggerWidth)
            .contentShape(Rectangle())
        }
        .buttonStyle(.meloHover)
        // What the control is, and separately what it is currently set to —
        // rather than one derived string in which the device name is the only
        // thing spoken and nothing says what it is the name *of*.
        .accessibilityLabel(pickerAccessibilityLabel)
        .accessibilityValue(triggerText)
        .background {
            DesignTokens.Dimensions.Shape.sm
                .fill(.regularMaterial)
        }
        .overlay {
            DesignTokens.Dimensions.Shape.sm
                .strokeBorder(
                    isButtonHovered ? DesignTokens.Colors.glassRowBorderHover : DesignTokens.Colors.glassRowBorder,
                    lineWidth: 0.5
                )
        }
        .onHover { isButtonHovered = $0 }
        .animation(DesignTokens.Animation.hover, value: isButtonHovered)
    }

    /// Square borderless icon button with hover tint. Used in app rows where the
    /// routed device name lives in the row's subtitle slot, so the trigger needs
    /// to carry only the icon — minimum chrome, matching the EQ button rhythm.
    private var iconOnlyTriggerButton: some View {
        Button {
            withAnimation(DesignTokens.Animation.present) {
                isExpanded.toggle()
            }
        } label: {
            triggerIcon
                .frame(width: 28, height: 28)
                .background(
                    DesignTokens.Dimensions.Shape.sm
                        .fill(iconOnlyBackgroundFill)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.meloHover)
        .help(triggerText)
        .accessibilityLabel(pickerAccessibilityLabel)
        .accessibilityValue(triggerText)
        .onHover { isButtonHovered = $0 }
        .animation(DesignTokens.Animation.hover, value: isButtonHovered)
    }

    private var iconOnlyBackgroundFill: Color {
        if isExpanded {
            return Color.primary.opacity(0.12)
        } else if isButtonHovered {
            return Color.primary.opacity(0.08)
        } else {
            return Color.clear
        }
    }

    // MARK: - Dropdown Content

    private var dropdownContent: some View {
        VStack(spacing: 0) {
            // Mode toggle header (hidden for single-mode-only contexts like Settings)
            if showModeToggle {
                ModeToggle(mode: Binding(
                    get: { currentMode },
                    set: { newMode in
                        currentMode = newMode  // Update local state immediately
                        onModeChange(newMode)  // Notify parent
                        // States are independent - no copying between modes
                    }
                ))
                .padding(.horizontal, DesignTokens.Spacing.xs + 2)
                .padding(.top, DesignTokens.Spacing.xs + 2)
                .padding(.bottom, DesignTokens.Spacing.xs)

                Divider()
                    .padding(.horizontal, 6)
            }

            // Device list
            ScrollView(.vertical) {
                LazyVStack(spacing: itemSpacing) {
                    ForEach(menuItems) { item in
                        deviceRow(for: item)
                    }
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 5)
            }
            .scrollIndicators(.hidden)
            .frame(maxHeight: 220)
        }
        .frame(width: popoverWidth)
        .background(
            VisualEffectBackground(material: .menu, blendingMode: .behindWindow)
                .clipShape(DesignTokens.Dimensions.Shape.custom(cornerRadius))
        )
        .overlay {
            DesignTokens.Dimensions.Shape.custom(cornerRadius)
                .strokeBorder(DesignTokens.Colors.glassBorder, lineWidth: 0.5)
        }
        // Without an explicit focus the panel never sees a key event, so the
        // menu would open and the keyboard would keep driving the window behind it.
        .focusable()
        .focusEffectDisabled()
        .focused($menuFocused)
        .onAppear {
            menuFocused = true
            highlightedID = currentHighlightStart
        }
        .onKeyPress(.downArrow) { moveHighlight(by: 1) }
        .onKeyPress(.upArrow) { moveHighlight(by: -1) }
        .onKeyPress(.return) { activateHighlighted() }
        .onKeyPress(.space) { activateHighlighted() }
        .onKeyPress(.escape) {
            closeMenu()
            return .handled
        }
        .onKeyPress(characters: .alphanumerics, phases: .down) { press in
            typeSelect(press.characters)
        }
    }

    // MARK: - Keyboard Navigation

    /// System Audio is unselectable in multi mode, and a keyboard cursor that
    /// can land on a row Return will refuse feels broken.
    private var navigableItems: [MenuItem] {
        menuItems.filter { !(currentMode == .multi && $0.id == "__system_audio__") }
    }

    /// Open on whatever is already chosen, the way an AppKit pop-up does.
    private var currentHighlightStart: String? {
        if let match = navigableItems.first(where: { isItemSelected($0) }) {
            return match.id
        }
        return navigableItems.first?.id
    }

    private func moveHighlight(by delta: Int) -> KeyPress.Result {
        let items = navigableItems
        guard !items.isEmpty else { return .ignored }
        guard let current = highlightedID,
              let index = items.firstIndex(where: { $0.id == current }) else {
            highlightedID = (delta > 0 ? items.first : items.last)?.id
            return .handled
        }
        highlightedID = items[min(max(index + delta, 0), items.count - 1)].id
        return .handled
    }

    private func activateHighlighted() -> KeyPress.Result {
        guard let current = highlightedID,
              let item = navigableItems.first(where: { $0.id == current }) else { return .ignored }
        handleItemTap(item)
        return .handled
    }

    /// Type-select, as every native menu has: typing "ai" jumps to AirPods.
    /// The buffer expires so a pause starts a new word instead of extending a
    /// prefix the user has forgotten about.
    private func typeSelect(_ characters: String) -> KeyPress.Result {
        let now = Date()
        if now > typeSelectExpiry {
            typeSelectPrefix = ""
        }
        typeSelectPrefix += characters.lowercased()
        typeSelectExpiry = now.addingTimeInterval(0.9)

        let prefix = typeSelectPrefix
        guard let match = navigableItems.first(where: {
            $0.name.lowercased().hasPrefix(prefix)
        }) else {
            return .ignored
        }
        highlightedID = match.id
        return .handled
    }

    private func closeMenu() {
        withAnimation(DesignTokens.Animation.present) {
            isExpanded = false
        }
    }

    // MARK: - Device Row

    @ViewBuilder
    private func deviceRow(for item: MenuItem) -> some View {
        let isSystemAudio = item.id == "__system_audio__"
        let isDisabled = currentMode == .multi && isSystemAudio
        let isSelected = isItemSelected(item)

        DevicePickerRow(
            item: item,
            resolvedIcon: {
                if case .device(let device) = item {
                    return displayIcon(for: device)
                }
                return nil
            }(),
            isSelected: isSelected,
            isHighlighted: highlightedID == item.id,
            isDisabled: isDisabled,
            isMultiMode: currentMode == .multi,
            isDefaultDevice: {
                if case .device(let device) = item {
                    return device.uid == defaultDeviceUID
                }
                return false
            }(),
            onTap: {
                handleItemTap(item)
            }
        )
    }

    private func isItemSelected(_ item: MenuItem) -> Bool {
        switch currentMode {
        case .single:
            if case .systemAudio = item {
                return isFollowingDefault
            } else if case .device(let device) = item {
                return !isFollowingDefault && device.uid == selectedDeviceUID
            }
            return false
        case .multi:
            if case .device(let device) = item {
                return currentSelectedUIDs.contains(device.uid)
            }
            return false  // System Audio not selectable in multi mode
        }
    }

    private func handleItemTap(_ item: MenuItem) {
        switch currentMode {
        case .single:
            switch item {
            case .systemAudio:
                onSelectFollowDefault()
            case .device(let device):
                onDeviceSelected(device.uid)
            }
            closeMenu()

        case .multi:
            guard case .device(let device) = item else { return }
            var newSelection = currentSelectedUIDs
            if newSelection.contains(device.uid) {
                newSelection.remove(device.uid)
            } else {
                newSelection.insert(device.uid)
            }
            currentSelectedUIDs = newSelection  // Update local state immediately
            onDevicesSelected(newSelection)  // Notify parent
            // Stay open in multi mode
        }
    }
}

// MARK: - Device Picker Row

private struct DevicePickerRow: View {
    let item: DevicePicker.MenuItem
    let resolvedIcon: NSImage?
    let isSelected: Bool
    let isHighlighted: Bool
    let isDisabled: Bool
    let isMultiMode: Bool
    let isDefaultDevice: Bool
    let onTap: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: DesignTokens.Spacing.xs) {
                // Selection indicator
                selectionIndicator

                // Icon
                itemIcon

                // Text content
                itemText

                // Explicit minimum. A bare `Spacer()` takes the platform's
                // default spacing when it is not given one, which is a number
                // the width arithmetic above cannot see and therefore cannot
                // reserve — the class of hidden constant that made 210 wrong.
                Spacer(minLength: DesignTokens.Spacing.xs)

                // Default device star
                if isDefaultDevice {
                    Image(systemName: "star.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(DesignTokens.Colors.textTertiary)
                        .accessibilityHidden(true)
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(isDisabled ? DesignTokens.Colors.textQuaternary : .primary)
            .padding(.horizontal, 8)
            .frame(height: 26)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                DesignTokens.Dimensions.Shape.xs
                    .fill(isHovered && !isDisabled ? Color.accentColor.opacity(0.15) : Color.clear)
            )
            // Ring for the keyboard cursor, fill for the pointer. They can be on
            // different rows at the same time and both have to stay readable.
            .overlay(
                DesignTokens.Dimensions.Shape.xs
                    .strokeBorder(
                        isHighlighted ? Color.accentColor : Color.clear,
                        lineWidth: 1.5
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.meloHover)
        .disabled(isDisabled)
        .whenHovered { isHovered = $0 }
        // Selection is carried by the trait. Left to derive itself, the label
        // began with the state glyph's own name — "checkmark square fill,
        // AirPods Pro" — which is the redundancy Apple's criteria call out.
        .accessibilityLabel(accessibilityRowLabel)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// The row's spoken name: the device, plus the one fact the star conveys.
    private var accessibilityRowLabel: String {
        switch item {
        case .systemAudio:
            return isDisabled
                ? "System Audio, not available in multi mode"
                : "System Audio, follows the macOS default"
        case .device(let device):
            return isDefaultDevice
                ? "\(device.name), macOS default device"
                : device.name
        }
    }

    @ViewBuilder
    private var selectionIndicator: some View {
        if isMultiMode {
            // Checkbox for multi mode
            Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                .font(.system(size: 12))
                .foregroundStyle(isSelected ? DesignTokens.Colors.accentPrimary : DesignTokens.Colors.textTertiary)
                .frame(width: 16)
        } else {
            // Checkmark for single mode (only show when selected)
            if isSelected {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(DesignTokens.Colors.accentPrimary)
                    .frame(width: 16)
            } else {
                Spacer()
                    .frame(width: 16)
            }
        }
    }

    @ViewBuilder
    private var itemIcon: some View {
        switch item {
        case .systemAudio:
            Image(systemName: "speaker.wave.2.circle")
                .font(.system(size: 13))
                .frame(width: 16)
                .foregroundStyle(isDisabled ? DesignTokens.Colors.textQuaternary : DesignTokens.Colors.textSecondary)
        case .device:
            if let icon = resolvedIcon {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 16, height: 16)
                    .opacity(isDisabled ? 0.4 : 1.0)
            } else {
                Image(systemName: "speaker.wave.2")
                    .font(.system(size: 13))
                    .frame(width: 16)
            }
        }
    }

    @ViewBuilder
    private var itemText: some View {
        switch item {
        case .systemAudio:
            // Both lines are held to one line and truncate at the tail. The
            // row is a fixed 26pt tall, so an unlimited `Text` that wraps is
            // not gentler than an ellipsis — it is a second line clipped by
            // the frame, with no ellipsis to say so.
            VStack(alignment: .leading, spacing: 1) {
                Text("System Audio")
                    .lineLimit(1)
                    .truncationMode(.tail)
                if isDisabled {
                    Text(DevicePicker.multiModeSubtitle)
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(DesignTokens.Colors.textQuaternary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                } else {
                    Text(DevicePicker.followsDefaultSubtitle)
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(DesignTokens.Colors.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        case .device(let device):
            Text(device.name)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }
}

// MARK: - Routing Subtitle Helper

extension DevicePicker {
    static func routingSubtitle(
        devices: [AudioDevice],
        selectedDeviceUID: String,
        selectedDeviceUIDs: Set<String>,
        isFollowingDefault: Bool,
        mode: DeviceSelectionMode
    ) -> String? {
        switch mode {
        case .single:
            if isFollowingDefault { return nil }
            return devices.first(where: { $0.uid == selectedDeviceUID })?.name
        case .multi:
            let valid = devices.filter { selectedDeviceUIDs.contains($0.uid) }
            switch valid.count {
            case 0:  return "Multi"
            case 1:  return "Multi · \(valid[0].name)"
            default: return "Multi · \(valid.count) devices"
            }
        }
    }
}

// MARK: - Convenience Initializer for Backward Compatibility

extension DevicePicker {
    /// Convenience initializer for single-mode only usage (backward compatible)
    init(
        devices: [AudioDevice],
        deviceIconOverrides: [String: String] = [:],
        selectedDeviceUID: String,
        isFollowingDefault: Bool,
        defaultDeviceUID: String?,
        triggerWidth: CGFloat = 105,
        onDeviceSelected: @escaping (String) -> Void,
        onSelectFollowDefault: @escaping () -> Void
    ) {
        self.devices = devices
        self.deviceIconOverrides = deviceIconOverrides
        self.selectedDeviceUID = selectedDeviceUID
        self.selectedDeviceUIDs = []
        self.isFollowingDefault = isFollowingDefault
        self.defaultDeviceUID = defaultDeviceUID
        self.triggerWidth = triggerWidth
        self.mode = .single
        self.onModeChange = { _ in }
        self.onDeviceSelected = onDeviceSelected
        self.onDevicesSelected = { _ in }
        self.onSelectFollowDefault = onSelectFollowDefault
        self.showModeToggle = false
    }
}

// MARK: - Previews

#Preview("Device Picker - Single Mode") {
    ComponentPreviewContainer {
        VStack(spacing: DesignTokens.Spacing.md) {
            DevicePicker(
                devices: MockData.sampleDevices,
                selectedDeviceUID: MockData.sampleDevices[0].uid,
                isFollowingDefault: true,
                defaultDeviceUID: MockData.sampleDevices[0].uid,
                onDeviceSelected: { _ in },
                onSelectFollowDefault: {}
            )
        }
    }
}

#Preview("Device Picker - Multi Mode") {
    struct MultiModePreview: View {
        @State private var mode: DeviceSelectionMode = .multi
        @State private var selectedUIDs: Set<String> = []

        var body: some View {
            ComponentPreviewContainer {
                VStack(spacing: DesignTokens.Spacing.md) {
                    DevicePicker(
                        devices: MockData.sampleDevices,
                        selectedDeviceUID: MockData.sampleDevices[0].uid,
                        selectedDeviceUIDs: selectedUIDs,
                        isFollowingDefault: false,
                        defaultDeviceUID: MockData.sampleDevices[0].uid,
                        mode: mode,
                        onModeChange: { mode = $0 },
                        onDeviceSelected: { _ in },
                        onDevicesSelected: { selectedUIDs = $0 },
                        onSelectFollowDefault: {},
                        showModeToggle: true,
                        triggerWidth: 105
                    )

                    Text("Selected: \(selectedUIDs.count) devices")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
    return MultiModePreview()
}

#Preview("Device Picker - Interactive") {
    struct InteractivePreview: View {
        @State private var mode: DeviceSelectionMode = .single
        @State private var selectedUID: String = ""
        @State private var selectedUIDs: Set<String> = []
        @State private var isFollowingDefault = true

        var body: some View {
            ComponentPreviewContainer {
                VStack(spacing: DesignTokens.Spacing.md) {
                    DevicePicker(
                        devices: MockData.sampleDevices,
                        selectedDeviceUID: selectedUID,
                        selectedDeviceUIDs: selectedUIDs,
                        isFollowingDefault: isFollowingDefault,
                        defaultDeviceUID: MockData.sampleDevices[0].uid,
                        mode: mode,
                        onModeChange: { newMode in
                            mode = newMode
                            if newMode == .multi {
                                isFollowingDefault = false
                            }
                        },
                        onDeviceSelected: { uid in
                            selectedUID = uid
                            isFollowingDefault = false
                        },
                        onDevicesSelected: { uids in
                            selectedUIDs = uids
                        },
                        onSelectFollowDefault: {
                            isFollowingDefault = true
                        },
                        showModeToggle: true,
                        triggerWidth: 105
                    )

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Mode: \(mode == .single ? "Single" : "Multi")")
                        if mode == .single {
                            Text("Following default: \(isFollowingDefault ? "Yes" : "No")")
                            if !isFollowingDefault {
                                Text("Selected: \(selectedUID)")
                            }
                        } else {
                            Text("Selected: \(selectedUIDs.count) devices")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }
    return InteractivePreview()
}
