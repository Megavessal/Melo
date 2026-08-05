// Melo/Views/Components/DropdownMenu.swift
import SwiftUI

/// A reusable dropdown menu component with height restriction support
struct DropdownMenu<Item: Identifiable, Label: View, ItemContent: View>: View where Item.ID: Hashable {
    let items: [Item]
    let selectedItem: Item?
    let maxVisibleItems: Int?
    let width: CGFloat
    let popoverWidth: CGFloat?
    let onSelect: (Item) -> Void
    @ViewBuilder let label: (Item?) -> Label
    @ViewBuilder let itemContent: (Item, Bool) -> ItemContent

    @State private var isExpanded = false
    @State private var isButtonHovered = false

    @Environment(\.appearancePreference) private var appearancePreference

    // Configuration
    private let itemHeight: CGFloat = 26
    private let itemSpacing: CGFloat = 2
    private let verticalPadding: CGFloat = 12  // 6 top + 6 bottom
    private let cornerRadius: CGFloat = 8

    private var effectivePopoverWidth: CGFloat {
        popoverWidth ?? width
    }

    private var menuHeight: CGFloat {
        let itemCount = CGFloat(items.count)
        let totalSpacing = itemSpacing * Swift.max(0, itemCount - 1)
        if let maxItems = maxVisibleItems {
            let visibleCount = min(itemCount, CGFloat(maxItems))
            let visibleSpacing = itemSpacing * Swift.max(0, visibleCount - 1)
            return visibleCount * itemHeight + visibleSpacing + verticalPadding
        }
        return itemCount * itemHeight + totalSpacing + verticalPadding
    }

    // MARK: - Trigger Button
    private var triggerButton: some View {
        Button {
            withAnimation(DesignTokens.Animation.present) {
                isExpanded.toggle()
            }
        } label: {
            HStack {
                label(selectedItem)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)

                Spacer(minLength: 4)

                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? -180 : 0))
                    .animation(DesignTokens.Animation.present, value: isExpanded)
            }
            .padding(.horizontal, DesignTokens.Spacing.sm)
            .padding(.vertical, 4)
            .frame(width: width)
            .contentShape(Rectangle())
        }
        .buttonStyle(.meloHover)
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

    // MARK: - Body
    var body: some View {
        triggerButton
            .background(
                PopoverHost(
                    isPresented: $isExpanded,
                    preferredColorScheme: appearancePreference.swiftUIColorScheme,
                    nsAppearance: appearancePreference.nsAppearance
                ) {
                    DropdownContentView(
                        items: items,
                        selectedItem: selectedItem,
                        width: effectivePopoverWidth,
                        menuHeight: menuHeight,
                        itemHeight: itemHeight,
                        itemSpacing: itemSpacing,
                        cornerRadius: cornerRadius,
                        onSelect: { item in
                            onSelect(item)
                            withAnimation(DesignTokens.Animation.present) {
                                isExpanded = false
                            }
                        },
                        onDismiss: {
                            withAnimation(DesignTokens.Animation.present) {
                                isExpanded = false
                            }
                        },
                        itemContent: itemContent
                    )
                }
            )
    }
}

// MARK: - Dropdown Content View

private struct DropdownContentView<Item: Identifiable, ItemContent: View>: View where Item.ID: Hashable {
    let items: [Item]
    let selectedItem: Item?
    let width: CGFloat
    let menuHeight: CGFloat
    let itemHeight: CGFloat
    let itemSpacing: CGFloat
    let cornerRadius: CGFloat
    let onSelect: (Item) -> Void
    let onDismiss: () -> Void
    @ViewBuilder let itemContent: (Item, Bool) -> ItemContent

    /// Keyboard cursor, separate from `selectedItem`: an open menu can be walked
    /// without committing, exactly like an AppKit menu, and the committed value
    /// stays visible while you look around.
    @State private var highlightedIndex: Int?
    @FocusState private var isFocused: Bool

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(spacing: itemSpacing) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    DropdownMenuItem(
                        item: item,
                        isSelected: selectedItem?.id == item.id,
                        isHighlighted: index == highlightedIndex,
                        itemHeight: itemHeight,
                        onSelect: onSelect,
                        itemContent: itemContent
                    )
                    .id(item.id)
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 5)
            .scrollTargetLayout()
        }
        .scrollIndicators(.hidden)
        .scrollPosition(id: .constant(scrollTargetID), anchor: .center)
        .frame(width: width, height: menuHeight)
        .background(
            VisualEffectBackground(material: .menu, blendingMode: .behindWindow)
                .clipShape(DesignTokens.Dimensions.Shape.custom(cornerRadius))
        )
        .overlay {
            DesignTokens.Dimensions.Shape.custom(cornerRadius)
                .strokeBorder(DesignTokens.Colors.glassBorder, lineWidth: 0.5)
        }
        // A floating menu with only a hairline border reads as painted onto
        // the window behind it. Native AppKit menus cast a pronounced shadow;
        // this is what separates a popover from a panel drawn in place.
        .meloElevation(DesignTokens.Elevation.floating)
        // Focusable so the panel receives key events at all; without this the
        // menu opens and the keyboard keeps driving whatever was behind it.
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onAppear {
            isFocused = true
            highlightedIndex = items.firstIndex { $0.id == selectedItem?.id }
        }
        .onKeyPress(.downArrow) { moveHighlight(by: 1) }
        .onKeyPress(.upArrow) { moveHighlight(by: -1) }
        .onKeyPress(.return) { activateHighlighted() }
        .onKeyPress(.space) { activateHighlighted() }
        .onKeyPress(.escape) {
            onDismiss()
            return .handled
        }
    }

    private var scrollTargetID: Item.ID? {
        if let highlightedIndex, items.indices.contains(highlightedIndex) {
            return items[highlightedIndex].id
        }
        return selectedItem?.id
    }

    private func moveHighlight(by delta: Int) -> KeyPress.Result {
        guard !items.isEmpty else { return .ignored }
        guard let current = highlightedIndex else {
            // First arrow press enters the list from the end you pressed toward.
            highlightedIndex = delta > 0 ? 0 : items.count - 1
            return .handled
        }
        highlightedIndex = min(max(current + delta, 0), items.count - 1)
        return .handled
    }

    private func activateHighlighted() -> KeyPress.Result {
        guard let index = highlightedIndex, items.indices.contains(index) else { return .ignored }
        onSelect(items[index])
        return .handled
    }
}

// MARK: - Dropdown Menu Item (with hover tracking)

private struct DropdownMenuItem<Item: Identifiable, ItemContent: View>: View where Item.ID: Hashable {
    let item: Item
    let isSelected: Bool
    var isHighlighted: Bool = false
    let itemHeight: CGFloat
    let onSelect: (Item) -> Void
    @ViewBuilder let itemContent: (Item, Bool) -> ItemContent

    @State private var isHovered = false

    var body: some View {
        Button {
            onSelect(item)
        } label: {
            itemContent(item, isSelected)
                .font(DesignTokens.Typography.Scale.footnote())
                .foregroundStyle(.primary)
                .padding(.horizontal, DesignTokens.Spacing.sm)
                .frame(height: itemHeight)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    DesignTokens.Dimensions.Shape.xs
                        .fill(isHovered ? Color.accentColor.opacity(0.15) : Color.clear)
                )
                // Ring, not fill: the pointer may be resting on a different row
                // than the one Return will choose, and both states have to be
                // legible at once.
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
        .whenHovered { isHovered = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Grouped Dropdown Menu

/// A dropdown menu with section headers for grouped/categorized items
struct GroupedDropdownMenu<Section: Identifiable & Hashable, Item: Identifiable, Label: View, ItemContent: View>: View
    where Item.ID: Hashable {

    let sections: [Section]
    let itemsForSection: (Section) -> [Item]
    let sectionTitle: (Section) -> String
    let selectedItem: Item?
    let maxHeight: CGFloat
    let width: CGFloat
    let popoverWidth: CGFloat?
    let onSelect: (Item) -> Void
    @ViewBuilder let label: (Item?) -> Label
    @ViewBuilder let itemContent: (Item, Bool) -> ItemContent

    @State private var isExpanded = false
    @State private var isButtonHovered = false

    @Environment(\.appearancePreference) private var appearancePreference

    // Configuration
    private let itemHeight: CGFloat = 22
    private let sectionHeaderHeight: CGFloat = 24
    private let cornerRadius: CGFloat = 8

    private var effectivePopoverWidth: CGFloat {
        popoverWidth ?? width
    }

    // MARK: - Trigger Button
    private var triggerButton: some View {
        Button {
            withAnimation(DesignTokens.Animation.present) {
                isExpanded.toggle()
            }
        } label: {
            HStack {
                label(selectedItem)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)

                Spacer(minLength: 4)

                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? -180 : 0))
                    .animation(DesignTokens.Animation.present, value: isExpanded)
            }
            .padding(.horizontal, DesignTokens.Spacing.sm)
            .padding(.vertical, 4)
            .frame(width: width)
            .contentShape(Rectangle())
        }
        .buttonStyle(.meloHover)
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

    // MARK: - Body
    var body: some View {
        triggerButton
            .background(
                PopoverHost(
                    isPresented: $isExpanded,
                    preferredColorScheme: appearancePreference.swiftUIColorScheme,
                    nsAppearance: appearancePreference.nsAppearance
                ) {
                    GroupedDropdownContentView(
                        sections: sections,
                        itemsForSection: itemsForSection,
                        sectionTitle: sectionTitle,
                        selectedItem: selectedItem,
                        width: effectivePopoverWidth,
                        maxHeight: maxHeight,
                        itemHeight: itemHeight,
                        sectionHeaderHeight: sectionHeaderHeight,
                        cornerRadius: cornerRadius,
                        onSelect: { item in
                            onSelect(item)
                            withAnimation(DesignTokens.Animation.present) {
                                isExpanded = false
                            }
                        },
                        onDismiss: {
                            withAnimation(DesignTokens.Animation.present) {
                                isExpanded = false
                            }
                        },
                        itemContent: itemContent
                    )
                }
            )
    }
}

// MARK: - Grouped Dropdown Content View

private struct GroupedDropdownContentView<Section: Identifiable & Hashable, Item: Identifiable, ItemContent: View>: View
    where Item.ID: Hashable {

    let sections: [Section]
    let itemsForSection: (Section) -> [Item]
    let sectionTitle: (Section) -> String
    let selectedItem: Item?
    let width: CGFloat
    let maxHeight: CGFloat
    let itemHeight: CGFloat
    let sectionHeaderHeight: CGFloat
    let cornerRadius: CGFloat
    let onSelect: (Item) -> Void
    let onDismiss: () -> Void
    @ViewBuilder let itemContent: (Item, Bool) -> ItemContent

    @State private var highlightedID: Item.ID?
    @FocusState private var isFocused: Bool

    /// Section headers are not selectable, so the arrow keys walk this flattened
    /// list instead of the rendered tree.
    private var flattenedItems: [Item] {
        sections.flatMap(itemsForSection)
    }

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(sections) { section in
                    // Section header
                    Text(sectionTitle(section))
                        .font(DesignTokens.Typography.Scale.caption(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, DesignTokens.Spacing.sm2)
                        .padding(.top, section.id == sections.first?.id ? 2 : DesignTokens.Spacing.sm)
                        .padding(.bottom, 2)
                        .frame(height: sectionHeaderHeight, alignment: .bottomLeading)

                    // Items in section
                    ForEach(itemsForSection(section)) { item in
                        DropdownMenuItem(
                            item: item,
                            isSelected: selectedItem?.id == item.id,
                            isHighlighted: highlightedID == item.id,
                            itemHeight: itemHeight,
                            onSelect: onSelect,
                            itemContent: itemContent
                        )
                    }
                }
            }
            .padding(5)
        }
        .scrollIndicators(.hidden)
        .frame(width: width)
        .frame(maxHeight: maxHeight)
        .background(
            VisualEffectBackground(material: .menu, blendingMode: .behindWindow)
                .clipShape(DesignTokens.Dimensions.Shape.custom(cornerRadius))
        )
        .overlay {
            DesignTokens.Dimensions.Shape.custom(cornerRadius)
                .strokeBorder(DesignTokens.Colors.glassBorder, lineWidth: 0.5)
        }
        // A floating menu with only a hairline border reads as painted onto
        // the window behind it. Native AppKit menus cast a pronounced shadow;
        // this is what separates a popover from a panel drawn in place.
        .meloElevation(DesignTokens.Elevation.floating)
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onAppear {
            isFocused = true
            highlightedID = selectedItem?.id
        }
        .onKeyPress(.downArrow) { moveHighlight(by: 1) }
        .onKeyPress(.upArrow) { moveHighlight(by: -1) }
        .onKeyPress(.return) { activateHighlighted() }
        .onKeyPress(.space) { activateHighlighted() }
        .onKeyPress(.escape) {
            onDismiss()
            return .handled
        }
    }

    private func moveHighlight(by delta: Int) -> KeyPress.Result {
        let items = flattenedItems
        guard !items.isEmpty else { return .ignored }
        guard let current = highlightedID,
              let index = items.firstIndex(where: { $0.id == current }) else {
            highlightedID = (delta > 0 ? items.first : items.last)?.id
            return .handled
        }
        let next = min(max(index + delta, 0), items.count - 1)
        highlightedID = items[next].id
        return .handled
    }

    private func activateHighlighted() -> KeyPress.Result {
        guard let current = highlightedID,
              let item = flattenedItems.first(where: { $0.id == current }) else { return .ignored }
        onSelect(item)
        return .handled
    }
}
