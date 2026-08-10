// Melo/Editor/Window/EditorShortcutSheet.swift
//
// ⌘/ — every key this window binds, in one searchable list.
//
// The frame's words: thirty shortcuts nobody can list is thirty shortcuts
// nobody uses. That is the whole argument for this file existing, and it is
// also the argument for the one structural rule in it: **every row here is
// generated from `EditorShortcut`.** There is no array of titles, no hand-typed
// "⌘X", and nothing to update when a binding changes. A sheet written by hand
// beside a matcher written by hand is two lists that drift, and the drift is
// invisible until someone presses a key this promised.
//
// `scripts/verify-editor-keys.py` asserts the generation actually happened —
// every case in the enum reaches a row — because "it is generated" is a claim
// about a loop, and a loop with a filter in it is still a loop.

import SwiftUI

@MainActor
struct EditorShortcutSheet: View {

    @Binding var isPresented: Bool

    @State private var query = ""

    private static let sheetWidth: CGFloat = 560
    private static let listHeight: CGFloat = 420

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if matches.isEmpty {
                empty
            } else {
                list
            }
            Divider()
            footer
        }
        .frame(width: Self.sheetWidth)
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            Text("Keys")
                .font(DesignTokens.Typography.Scale.title2())
            // No prose under the title. Everything this sheet has to say is in
            // the list; a paragraph explaining that shortcuts are shortcuts is
            // the thing the anchor's release-notes entry is about.
            TextField("Search", text: $query)
                .textFieldStyle(.roundedBorder)
                .font(DesignTokens.Typography.Scale.body())
        }
        .padding(DesignTokens.Spacing.lg)
    }

    // MARK: List

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.lg) {
                ForEach(groups, id: \.section) { group in
                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                        Text(group.section.rawValue.uppercased())
                            .font(DesignTokens.Typography.sectionHeader)
                            .tracking(DesignTokens.Typography.sectionHeaderTracking)
                            .foregroundStyle(DesignTokens.Colors.sectionHeaderText)
                            .padding(.bottom, DesignTokens.Spacing.xxs)
                        ForEach(group.shortcuts, id: \.self) { shortcut in
                            row(shortcut)
                        }
                    }
                }
            }
            .padding(.horizontal, DesignTokens.Spacing.lg)
            .padding(.vertical, DesignTokens.Spacing.md)
        }
        .frame(height: Self.listHeight)
    }

    private func row(_ shortcut: EditorShortcut) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.md) {
            Text(shortcut.title)
                .font(DesignTokens.Typography.Scale.body())
                .foregroundStyle(DesignTokens.Colors.textPrimary)
            Spacer(minLength: DesignTokens.Spacing.md)
            // Alternatives read left to right with "or" between them, because a
            // row showing "S  ⌘T" with nothing between reads as a chord.
            HStack(spacing: DesignTokens.Spacing.xs) {
                ForEach(Array(shortcut.printedStrokes.enumerated()), id: \.offset) { index, stroke in
                    if index > 0 {
                        Text("or")
                            .font(DesignTokens.Typography.Scale.caption())
                            .foregroundStyle(DesignTokens.Colors.textTertiary)
                    }
                    keyCap(stroke.display)
                }
            }
        }
        .padding(.vertical, DesignTokens.Spacing.xxs)
    }

    private func keyCap(_ text: String) -> some View {
        Text(text)
            .font(DesignTokens.Typography.Scale.body(.medium))
            .monospaced()
            .foregroundStyle(DesignTokens.Colors.textPrimary)
            .padding(.horizontal, DesignTokens.Spacing.xs2)
            .padding(.vertical, DesignTokens.Spacing.xxs)
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.Dimensions.buttonRadius, style: .continuous)
                    .fill(DesignTokens.Colors.pickerBackground)
            )
    }

    private var empty: some View {
        Text("No key does that.")
            .font(DesignTokens.Typography.Scale.body())
            .foregroundStyle(DesignTokens.Colors.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, DesignTokens.Spacing.lg)
            .frame(height: Self.listHeight, alignment: .top)
            .padding(.top, DesignTokens.Spacing.md)
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            // The hold is the one binding whose shape a key cap cannot show, so
            // it is said once in words rather than by inventing a glyph for it.
            Text("B is held, not pressed.")
                .font(DesignTokens.Typography.Scale.caption())
                .foregroundStyle(DesignTokens.Colors.textTertiary)
            Spacer()
            // Escape closes it, ⌘/ does not. An attached sheet is its own
            // window and `EditorKeyCommandView.handle` refuses events from any
            // other, which is the guard that lets the search field above take a
            // bare S — so the monitor genuinely cannot see a second ⌘/.
            //
            // *Rejected:* a zero-sized hidden `Button` carrying
            // `.keyboardShortcut("/", modifiers: .command)`, which is the usual
            // trick. Whether SwiftUI registers a shortcut on a view it has
            // culled is not something this run could render and look at, and an
            // unverified close key on a sheet whose whole subject is which keys
            // work would be a poor thing to ship on a guess.
            Button("Done") { isPresented = false }
                .keyboardShortcut(.cancelAction)
        }
        .padding(DesignTokens.Spacing.lg)
    }

    // MARK: Search

    private var groups: [Group] { Self.groups(matching: query) }

    private var matches: [EditorShortcut] { groups.flatMap(\.shortcuts) }

    /// One printed section and the rows under it.
    struct Group: Equatable, Sendable {
        var section: EditorShortcut.Section
        var shortcuts: [EditorShortcut]
    }

    /// **What the sheet draws, as a value.**
    ///
    /// Pulled out of `body` so `scripts/verify-editor-keys.py` can assert the
    /// generation claim this file is built on — that every entry in the table
    /// reaches a row — by running it rather than by reading it. `body` above
    /// draws exactly this and nothing else, and the verify script's structural
    /// half checks that `EditorShortcut.allCases` is named here and nowhere
    /// else in the file, because a second enumeration in `body` would make an
    /// assertion about this function true and useless.
    ///
    /// Every token has to appear somewhere in the entry's `searchText`, so
    /// "cmd x" narrows rather than widens. Substring rather than prefix: the
    /// useful queries are "delete", "loop", "zoom", and a prefix match would
    /// miss "forward delete" for "delete". Sections keep their declared order
    /// and empty ones are dropped, so a search never prints a heading with
    /// nothing under it.
    nonisolated static func groups(matching query: String) -> [Group] {
        let tokens = query
            .lowercased()
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .map(String.init)
        let matched = EditorShortcut.allCases.filter { shortcut in
            guard !tokens.isEmpty else { return true }
            let text = shortcut.searchText
            return tokens.allSatisfy { text.contains($0) }
        }
        return EditorShortcut.Section.allCases.compactMap { section in
            let rows = matched.filter { $0.section == section }
            return rows.isEmpty ? nil : Group(section: section, shortcuts: rows)
        }
    }
}
