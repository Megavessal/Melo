// Melo/Editor/Views/Stack/MoveStackView.swift
import SwiftUI

/// The stack: everything Melo is doing to this sound, in order, in words.
///
/// This is the object that has to serve both audiences the brief names. It does
/// it by depth rather than by mode. A row is three short lines — what the move
/// is, what it is set to, and what Melo found that put it there — and it opens
/// onto the concrete numbers only when asked. Nobody has to look at the other
/// person's controls, and there is no "advanced" toggle deciding for them.
///
/// A disabled move stays on the list and goes grey. Turning one off and
/// listening is the reason a non-destructive stack is worth having at all, and
/// a move that vanished when it was switched off would make that impossible.
@MainActor
struct MoveStackView: View {
    @ObservedObject private var store: CuttingRoomStore

    /// Which row is disclosed. Private on purpose: expansion is a reading
    /// state, nothing outside this view acts on it, and nothing outside this
    /// view should.
    @State private var expandedMoveID: Move.ID?
    @State private var dropTargetIndex: Int?

    /// SwiftUI's own focus, which is the *mechanism* — it is what the Tab key
    /// and a click actually move. `store.selectedMoveID` is the *truth*, which
    /// is what the ring draws from and what ⌘⌫ deletes. Keeping the truth off
    /// `@FocusState` matters twice: `@FocusState` cannot be seeded by the
    /// harness, and it cannot be read from another pane at all.
    @FocusState private var keyboardFocus: Move.ID?

    /// Only the EQ inspector needs this, and only for "Save to Melo" and the
    /// user-preset list. It is carried as a parameter rather than read from an
    /// environment value or a singleton because the failure mode is silence: a
    /// missing environment injection gives the panel `nil`, and `nil` makes the
    /// save row *absent* rather than broken. A parameter puts that mistake in
    /// front of the compiler instead of in front of the user.
    private let settings: SettingsManager?

    init(store: CuttingRoomStore, settings: SettingsManager? = nil) {
        _store = ObservedObject(wrappedValue: store)
        self.settings = settings
    }

    /// How far a switched-off move's content drops. One constant, applied to
    /// every part of the row that carries meaning and to none of the controls:
    /// the switch and the chevron stay at full strength, because the switch is
    /// what you press to bring the move back and a control you have to squint
    /// at is a control that reads as unavailable rather than as off.
    ///
    /// 0.4 rather than a lighter touch because this has to survive a layer
    /// capture as well as a pair of eyes: it takes the row's mean ink from
    /// about 188 to about 75 against a background near 30, which is a contrast
    /// drop no viewer can miss and no measurement can call noise.
    private static let disabledOpacity: Double = 0.4

    private var moves: [Move] { store.document?.moves ?? [] }
    private var duration: TimeInterval { store.document?.source.duration ?? 0 }
    private var disabledCount: Int { moves.filter { !$0.isEnabled }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            controls

            if moves.isEmpty {
                MoveStackEmptyState(reason: emptyReason)
            } else {
                // The sidebar hands this pane whatever height is left, so the
                // list scrolls inside itself rather than pushing the two
                // sections above it off the top.
                ScrollView(.vertical) {
                    list
                }
                .scrollBounceBehavior(.basedOnSize)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .animation(DesignTokens.Animation.rowChange, value: moves.map(\.id))
        // The keyboard moved focus. Push it to the store so the ring and any
        // other pane agree on what is selected.
        //
        // Only when non-nil: SwiftUI drops focus to nil whenever the window
        // resigns key, and writing that through would clear the selection
        // every time the user clicked another app — which would then make ⌘⌫
        // silently do nothing on return.
        .onChange(of: keyboardFocus) { _, focused in
            if let focused, store.selectedMoveID != focused {
                store.selectedMoveID = focused
            }
        }
        // Selection moved from somewhere that is not this keyboard — the
        // harness, or the repair below. Bring real focus along so the next
        // arrow key continues from where the ring is.
        .onChange(of: store.selectedMoveID) { _, selected in
            if let selected, keyboardFocus != selected { keyboardFocus = selected }
        }
        .onChange(of: moves.map(\.id)) { previous, current in
            repairSelection(previous: previous, current: current)
        }
    }

    /// The section's own title is drawn by the sidebar that hosts this pane, so
    /// this is a control strip, not a header. A second "The stack" here is the
    /// kind of duplicate that only shows up once the window is composed.
    private var controls: some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            if disabledCount > 0 {
                Text("\(disabledCount) off")
                    .font(DesignTokens.Typography.Scale.caption())
                    .monospacedDigit()
                    .foregroundStyle(DesignTokens.Colors.textTertiary)
                    .padding(.leading, DesignTokens.Spacing.sm)
                    .accessibilityLabel("\(disabledCount) moves turned off")
            }

            Spacer(minLength: 0)

            AddMoveMenu(store: store)
        }
    }

    /// Why the stack is empty — **asked, not inferred**.
    ///
    /// This used to return `.nothingToFix` from three non-nil values. Those say
    /// the file has been measured against a destination; they say nothing about
    /// whether it needs anything. With a quiet file the picker offered eight
    /// moves while this pane, beside it, said there was nothing to do — and
    /// this is the screen the least knowledgeable user reads *first*, before
    /// pressing anything. Someone who believes it never presses the button and
    /// the whole destination path goes unused. It is the one sentence here that
    /// costs the feature rather than costing polish.
    ///
    /// So it calls the same pure function `DestinationPicker` calls, with the
    /// same three values off the same store. Same inputs, same output: the two
    /// panes cannot disagree. Uncached for the reason the picker gives for not
    /// caching either — it is microseconds, and a stale answer beside a live
    /// button is the defect this feature cannot afford. Only reached when the
    /// stack is empty.
    private var emptyReason: MoveStackEmptyState.Reason {
        guard let document = store.document else { return .noSource }
        guard let destination = document.destination else { return .noDestination }
        guard let report = document.analysis else { return .measuring }

        let proposal = MoveProposer.propose(
            for: report,
            destination: destination,
            source: document.source
        )
        guard proposal.isEmpty else { return .readyToFix(moveCount: proposal.count) }
        return .nothingToFix(destination: destination.title)
    }

    // MARK: - The list

    private var list: some View {
        LazyVStack(spacing: 0) {
            ForEach(Array(moves.enumerated()), id: \.element.id) { index, move in
                row(move, at: index)
            }
            // The last position needs a target too, or a move can be dragged
            // everywhere except the end of the stack.
            insertionLine(active: dropTargetIndex == moves.count)
                .frame(height: DesignTokens.Spacing.sm)
                .contentShape(Rectangle())
                .dropDestination(for: String.self) { items, _ in
                    accept(items, at: moves.count)
                } isTargeted: { targeted in
                    dropTargetIndex = targeted ? moves.count : nil
                }
        }
    }

    @ViewBuilder
    private func row(_ move: Move, at index: Int) -> some View {
        let isExpanded = expandedMoveID == move.id
        // The ring is drawn from the store, not from `@FocusState`, so the row
        // that ⌘⌫ will delete is exactly the row wearing the ring — from any
        // pane, and in a rendered frame where there is no key window to hold
        // real focus at all.
        let isFocused = store.selectedMoveID == move.id

        VStack(spacing: 0) {
            insertionLine(active: dropTargetIndex == index)

            ExpandableGlassRow(isExpanded: isExpanded, isFocused: isFocused) {
                rowHeader(move, isExpanded: isExpanded)
            } expandedContent: {
                MoveInspector(
                    move: move,
                    duration: duration,
                    settings: settings,
                    onChange: { kind in replace(kind, of: move) }
                )
                .padding(.top, DesignTokens.Spacing.xs2)
                .padding(.bottom, DesignTokens.Spacing.xxs)
            }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($keyboardFocus, equals: move.id)
        // Backspace and forward-delete both remove the focused row; on an Apple
        // keyboard the key labelled "delete" is the first of those.
        .onKeyPress(.delete) { remove(move); return .handled }
        .onKeyPress(.deleteForward) { remove(move); return .handled }
        .onKeyPress(.return) { toggleExpanded(move); return .handled }
        .contextMenu { menu(for: move, at: index) }
        .draggable(move.id.uuidString) {
            Text(move.kind.title)
                .font(DesignTokens.Typography.Scale.footnote(.medium))
                .padding(.horizontal, DesignTokens.Spacing.sm)
                .padding(.vertical, DesignTokens.Spacing.xs)
        }
        .dropDestination(for: String.self) { items, _ in
            accept(items, at: index)
        } isTargeted: { targeted in
            dropTargetIndex = targeted ? index : (dropTargetIndex == index ? nil : dropTargetIndex)
        }
    }

    /// Where a dragged row would land. Two points of accent, drawn in the gap
    /// so the rows do not shift while the pointer is moving over them.
    @ViewBuilder
    private func insertionLine(active: Bool) -> some View {
        Capsule()
            .fill(active ? Color.accentColor : Color.clear)
            .frame(height: 2)
            .padding(.horizontal, DesignTokens.Spacing.sm)
            .animation(DesignTokens.Animation.hover, value: active)
    }

    // MARK: - The row itself

    private func rowHeader(_ move: Move, isExpanded: Bool) -> some View {
        // Two bands, not one. The controls own the first; the rationale gets a
        // line of its own underneath at the row's **full** width.
        //
        // It used to live in the title's column, which is the toggle and the
        // chevron's leftovers — about 170pt of a 280pt row. Every sentence the
        // proposer writes ran past two lines there and ended in an ellipsis,
        // which is the worst of both: it spends the height of an explanation
        // and delivers half a sentence, and a reader who cannot finish it now
        // knows something was withheld. Out here the measure is ~260pt, which
        // is over 50% more text per line, and there is no line limit at all.
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
            HStack(alignment: .top, spacing: DesignTokens.Spacing.xs2) {
                HStack(alignment: .top, spacing: DesignTokens.Spacing.xs2) {
                    Image(systemName: move.kind.symbolName)
                        .font(DesignTokens.Typography.Scale.footnote(.medium))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(DesignTokens.Colors.interactiveDefault)
                        .frame(width: DesignTokens.Dimensions.iconSizeSmall)
                        .padding(.top, 2)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 1) {
                        // Words first. Whatever else a row shows, the first thing
                        // on it says what the move does.
                        Text(move.kind.title)
                            .font(DesignTokens.Typography.Scale.headline(.medium))
                            .foregroundStyle(DesignTokens.Colors.textPrimary)
                            .lineLimit(1)

                        // The numbers, in a fixed place directly under the title,
                        // because this is the line that changes when the
                        // inspector is used. `summary` is empty for `reverse`,
                        // which has no numbers — an empty Text would leave a
                        // blank line where a value belongs.
                        if !move.kind.summary.isEmpty {
                            Text(move.kind.summary)
                                .font(DesignTokens.Typography.Scale.caption())
                                .monospacedDigit()
                                .foregroundStyle(DesignTokens.Colors.textSecondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                }
                .opacity(move.isEnabled ? 1 : Self.disabledOpacity)

                Spacer(minLength: DesignTokens.Spacing.xs)

                Toggle("", isOn: enabled(move))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                    .frame(height: DesignTokens.Dimensions.rowContentHeight)
                    .accessibilityLabel("\(move.kind.title) on")

                if MoveInspector.hasInspector(move.kind) {
                    Image(systemName: "chevron.right")
                        .font(DesignTokens.Typography.Scale.caption2(.semibold))
                        .foregroundStyle(DesignTokens.Colors.textTertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 10, height: DesignTokens.Dimensions.rowContentHeight)
                        .accessibilityHidden(true)
                } else {
                    // Holds the column so rows without an inspector line up with
                    // rows that have one.
                    Color.clear.frame(width: 10, height: 1)
                }
            }

            // Shown only when the analysis wrote one. A hand-added move has no
            // finding behind it and gets no sentence — a rationale generated to
            // fill the slot would be wrong the moment the number above it
            // changed.
            if let rationale = move.rationale, !rationale.isEmpty {
                HStack(alignment: .top, spacing: DesignTokens.Spacing.xs2) {
                    // Sits in the same column as the move's own icon, so the
                    // sentence starts under the title rather than under nothing.
                    Image(systemName: "waveform")
                        .font(DesignTokens.Typography.Scale.caption2())
                        .foregroundStyle(DesignTokens.Colors.textTertiary)
                        .frame(width: DesignTokens.Dimensions.iconSizeSmall)
                        .padding(.top, 1)
                        .accessibilityHidden(true)

                    // No `lineLimit`. Whatever the proposer wrote is shown whole
                    // or the row is lying about what Melo did to the file.
                    Text(rationale)
                        .font(DesignTokens.Typography.Scale.caption())
                        .foregroundStyle(DesignTokens.Colors.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.bottom, 1)
                .opacity(move.isEnabled ? 1 : Self.disabledOpacity)
            }
        }
        .contentShape(Rectangle())
        // A click selects as well as discloses. Without this a pointer user
        // could open a row, press ⌘⌫, and delete a different one — the row
        // they were looking at and the row wearing the ring would be two
        // different rows.
        .onTapGesture {
            select(move)
            toggleExpanded(move)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(move.kind.title)
        .accessibilityValue(accessibilityValue(for: move))
    }

    private func accessibilityValue(for move: Move) -> String {
        var parts = move.kind.summary.isEmpty ? [] : [move.kind.summary]
        if !move.isEnabled { parts.append("off") }
        if let rationale = move.rationale, !rationale.isEmpty { parts.append(rationale) }
        return parts.joined(separator: ", ")
    }

    // MARK: - Menu

    @ViewBuilder
    private func menu(for move: Move, at index: Int) -> some View {
        Button(move.isEnabled ? "Turn off" : "Turn on") {
            store.setEnabled(!move.isEnabled, for: move.id)
        }

        Divider()

        Button("Move up") { reorder(from: index, to: index - 1) }
            .disabled(index == 0)

        Button("Move down") { reorder(from: index, to: index + 2) }
            .disabled(index >= moves.count - 1)

        Divider()

        Button("Delete", role: .destructive) { remove(move) }
    }

    // MARK: - Edits

    private func enabled(_ move: Move) -> Binding<Bool> {
        Binding(
            get: { move.isEnabled },
            set: { isOn in
                Haptics.step()
                store.setEnabled(isOn, for: move.id)
            }
        )
    }

    private func replace(_ kind: MoveKind, of move: Move) {
        var updated = move
        updated.kind = kind
        store.update(updated)
    }

    private func toggleExpanded(_ move: Move) {
        guard MoveInspector.hasInspector(move.kind) else { return }
        // ExpandableGlassRow carries a note asking callers to animate this
        // themselves — an `.animation(_, value: isExpanded)` inside the row
        // loops against its conditional content.
        withAnimation(DesignTokens.Animation.panel) {
            expandedMoveID = expandedMoveID == move.id ? nil : move.id
        }
    }

    private func select(_ move: Move) {
        store.selectedMoveID = move.id
        keyboardFocus = move.id
    }

    /// Deletion goes straight to the store and nothing else, so this view's own
    /// Delete key, its context menu and the window's ⌘⌫ are one code path with
    /// one behaviour. `repairSelection` below picks up the aftermath whichever door
    /// the delete came through.
    private func remove(_ move: Move) {
        store.remove(move.id)
    }

    /// A move left the stack. Move the ring to whatever took its place, so a
    /// held ⌘⌫ walks down the stack instead of deleting once and going inert,
    /// and collapse an inspector whose move no longer exists.
    ///
    /// Driven off the list rather than off the delete call because the delete
    /// can come from another pane entirely.
    private func repairSelection(previous: [Move.ID], current: [Move.ID]) {
        if let expanded = expandedMoveID, !current.contains(expanded) {
            expandedMoveID = nil
        }

        guard let selected = store.selectedMoveID, !current.contains(selected) else { return }
        guard !current.isEmpty else {
            store.selectedMoveID = nil
            keyboardFocus = nil
            return
        }
        // The row that slid up into the vacated position, or the new last row
        // when the deleted one was at the end.
        let vacated = previous.firstIndex(of: selected) ?? current.count
        store.selectedMoveID = current[min(vacated, current.count - 1)]
    }

    /// `toOffset` is the SwiftUI insertion index, measured before the source row
    /// is lifted out — which is why moving down is `index + 2` and not
    /// `index + 1`.
    private func reorder(from index: Int, to offset: Int) {
        guard moves.indices.contains(index) else { return }
        let clamped = min(max(offset, 0), moves.count)
        guard clamped != index, clamped != index + 1 else { return }
        withAnimation(DesignTokens.Animation.rowChange) {
            store.move(fromOffsets: IndexSet(integer: index), toOffset: clamped)
        }
    }

    private func accept(_ payload: [String], at index: Int) -> Bool {
        dropTargetIndex = nil
        guard let raw = payload.first,
              let draggedID = UUID(uuidString: raw),
              let from = moves.firstIndex(where: { $0.id == draggedID })
        else { return false }
        reorder(from: from, to: index)
        return true
    }
}

#if MELO_DEV
extension MoveStackView {
    /// Seeds the view's own `@State` so the harness can render surfaces that
    /// otherwise only exist after a click. Only the snapshot harness calls
    /// this; every real call site uses `init(store:)` above.
    ///
    /// Declared in an extension so that initialiser stays the one the window
    /// composes with, matching `MenuBarPopupView`'s seam.
    /// `expandedMoveID` carries no default on purpose: with one, this
    /// initialiser and `init(store:)` would both match a bare
    /// `MoveStackView(store:)` and the window's call site becomes an overload
    /// question nobody meant to ask.
    ///
    /// There is no `focusedMoveID` parameter any more. The focus ring reads
    /// `store.selectedMoveID`, so a scene sets that on the store directly and
    /// gets the ring — one fewer thing that can disagree with itself.
    init(
        store: CuttingRoomStore,
        expandedMoveID: Move.ID?,
        settings: SettingsManager? = nil,
        dropTargetIndex: Int? = nil
    ) {
        _store = ObservedObject(wrappedValue: store)
        self.settings = settings
        _expandedMoveID = State(initialValue: expandedMoveID)
        _dropTargetIndex = State(initialValue: dropTargetIndex)
    }
}
#endif
