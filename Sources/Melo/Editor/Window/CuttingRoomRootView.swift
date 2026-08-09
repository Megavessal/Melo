import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Where a sound came from, in a line.
///
/// Lengths are **not** here. `EditorFormat.timecode` is the one place a number
/// becomes a time string, and the transport reads from it — a second
/// implementation in this file would let the header and the playhead disagree
/// about the same sound by a rounding mode.
enum CuttingRoomFormat {
    /// One short line under the file's name, or nothing.
    ///
    /// `nil` for a plain file on purpose: "From a file" is a label that tells the
    /// reader what they already know, and the format chip beside it is carrying
    /// the information. The other three origins are each something the name
    /// alone does not say.
    static func originLine(_ origin: EditorSource.Origin) -> String? {
        switch origin {
        case .file:
            return nil
        case .extractedFromLink(_, let siteName):
            return "From \(siteName)"
        case .systemRecording(let startedAt):
            return "Recorded here at \(startedAt.formatted(date: .omitted, time: .shortened))"
        case .meloTheme:
            return "Melo’s own theme"
        }
    }
}

/// The Melo mark in a themed disc, at whatever size the caller needs.
///
/// The same treatment as the menu-bar popup's header badge, which is where the
/// user has seen it a hundred times before they ever open this window. That is
/// the whole point of using it here rather than an SF Symbol: the Cutting Room
/// has to read as part of Melo on the first frame.
struct CuttingRoomMark: View {
    var size: CGFloat = 30

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [Color.accentColor, Color.accentColor.opacity(0.55)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            Image(nsImage: MenuBarIconImage.meloMark.nsImage() ?? NSImage())
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: size * 0.71, height: size * 0.50)
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// The Cutting Room, assembled.
///
/// Owns the header row, the sidebar container, the split between them, and the
/// window-wide drop target. Owns none of the panes: `EditorWaveformView`,
/// `EditorTransportBar`, `DestinationPicker`, `AnalysisSummaryView`,
/// `MoveStackView`, `JobProgressStrip` and the three sheets each own their own
/// contents and are called here through their `init(store:)` seams.
///
/// Constructible with nothing but a store, so a frame can be rendered without a
/// window ever existing.
@MainActor
struct CuttingRoomRootView: View {
    @ObservedObject private var store: CuttingRoomStore

    /// Optional because the contract's pinned initialiser is `init(store:)` and
    /// the snapshot harness uses it. Without a `SettingsManager` the window
    /// still draws — it just wears the system accent and the system appearance
    /// instead of the theme the user picked.
    private let settings: SettingsManager?
    private let recents: CuttingRoomRecents

    @State private var showExport = false
    @State private var showLinkImport = false
    @State private var showSystemRecord = false
    @State private var isDropTargeted = false

    /// Which sidebar pane is open. See `sidebar`.
    @State private var expandedSection: SidebarSection = .destination

    #if MELO_DEV
    /// Set by a snapshot scene to hold one pane open. `syncSidebarSection()`
    /// stands down when it is non-nil, so `onAppear` cannot undo the fixture.
    @State private var pinnedSection: SidebarSection?
    #endif

    /// The window is `.fullSizeContentView`, so the SwiftUI content starts at the
    /// very top of the frame and the traffic lights are drawn on top of it. The
    /// standard macOS titlebar is 28pt; reading `contentLayoutRect` would be
    /// exact but needs a window, and this view has to lay out without one.
    private static let titleBarInset: CGFloat = 28

    /// Fixed at 320. Not resizable: a draggable divider is
    /// a preference to store, a state to restore and a thing to get wrong, and
    /// the three panes in it are all fixed-width content.
    private static let sidebarWidth: CGFloat = 320

    init(store: CuttingRoomStore) {
        self.init(store: store, settings: nil)
    }

    init(store: CuttingRoomStore, settings: SettingsManager?) {
        _store = ObservedObject(wrappedValue: store)
        self.settings = settings
        self.recents = .shared
        _expandedSection = State(initialValue: Self.defaultSection(for: store))
    }

    /// Derived at construction, not in `onAppear`.
    ///
    /// A document that is already open when this view is built — a reopened
    /// session, and every snapshot scene — must show the stack on the very first
    /// layout pass. Leaving that to `onAppear` makes the correct frame depend on
    /// a lifecycle callback the render harness is under no obligation to run,
    /// which is exactly the kind of dependency that produces a frame nobody can
    /// explain. `onAppear` still calls `syncSidebarSection()`, for a store that
    /// gains a document between construction and appearance.
    private static func defaultSection(for store: CuttingRoomStore) -> SidebarSection {
        (store.document?.moves.isEmpty == false) ? .stack : .destination
    }

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: Self.titleBarInset)

            if let message = store.lastError {
                errorBanner(message)
            }

            if isEmpty {
                CuttingRoomEmptyState(
                    onOpenFile: openFile,
                    onPasteLink: { showLinkImport = true },
                    onRecord: { showSystemRecord = true },
                    onRemixTheme: { MeloThemeRemix.openInCuttingRoom() },
                    onOpenRecent: { recent in
                        Task { await store.open(recent.url) }
                    },
                    recents: recents
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                editor
            }

            // `JobProgressStrip` owns what this looks like and when a finished
            // job leaves the list; this only decides that an empty list draws
            // no strip and no rule above one.
            if !store.jobs.isEmpty {
                Divider()
                JobProgressStrip(store: store)
            }
        }
        .frame(minWidth: 820, minHeight: 520)
        .background(
            WindowAppearanceBridge(appearance: resolvedAppearance)
                .frame(width: 0, height: 0)
        )
        .meloThemeBackground(
            theme: visualTheme,
            customAccentHex: settings?.appSettings.customAccentHex ?? "#0A84FF",
            generatedTheme: settings?.appSettings.generatedTheme
        )
        .tint(themeAccent)
        .preferredColorScheme(resolvedColorScheme)
        .overlay(dropAffordance)
        // Anywhere in the window, not only over the empty state. Someone who has
        // one sound open and wants to work on a different one should not have to
        // find a particular rectangle to drop it on.
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            // One sound, not a session: extra files in the drag are ignored
            // rather than queued. The URL goes to the same `store.open` the file
            // picker uses, so a dropped thing that is not audio fails exactly
            // where a picked one does, instead of needing a second error path
            // that says the same sentence.
            Task { await store.open(url) }
            return true
        } isTargeted: { targeted in
            withAnimation(DesignTokens.Animation.present) {
                isDropTargeted = targeted
            }
        }
        .cuttingRoomKeyCommands(
            store: store,
            onExport: { showExport = true },
            onOpenFile: openFile,
            onPasteLink: { showLinkImport = true },
            onRecord: { showSystemRecord = true }
        )
        .sheet(isPresented: $showExport) {
            ExportSheet(store: store, isPresented: $showExport)
        }
        .sheet(isPresented: $showLinkImport) {
            LinkImportSheet(store: store, isPresented: $showLinkImport)
        }
        .sheet(isPresented: $showSystemRecord) {
            SystemRecordSheet(store: store, isPresented: $showSystemRecord)
        }
        .onAppear {
            recents.refreshAvailability()
            syncSidebarSection()
        }
        .onChange(of: store.document?.source.id) { _, _ in
            syncSidebarSection()
            guard let source = store.document?.source else { return }
            recents.remember(source)
        }
        // The one automatic switch, and only on the empty-to-populated edge:
        // pressing "Fix it again" fills the stack, and what the reader wants at
        // that moment is to see what Melo just did. Every later change leaves
        // the accordion where they put it.
        .onChange(of: hasMoves) { had, has in
            #if MELO_DEV
            if pinnedSection != nil { return }
            #endif
            if !had, has {
                withAnimation(DesignTokens.Animation.panel) {
                    expandedSection = .stack
                }
            }
        }
    }

    private var isEmpty: Bool {
        store.document == nil
    }

    /// Whether the stack has anything in it. Named rather than inlined into the
    /// `onChange` above, where a closure parameter called `isEmpty` would have
    /// shadowed the property directly above this one.
    private var hasMoves: Bool {
        !(store.document?.moves.isEmpty ?? true)
    }

    // MARK: - The editor

    private var editor: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                header
                Divider()
                // The waveform gets the room and no inset. It is a drawing of the
                // whole sound, and a drawing of the whole sound that stops 16pt
                // short of the edge is a drawing of most of it.
                EditorWaveformView(store: store)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // Top rather than centre, and over the waveform rather than
                    // above it. The card is an offer, not a step: it has to be
                    // impossible to miss and equally possible to ignore, and a
                    // centred card sits on the part of the drawing someone is
                    // about to click. It renders nothing unless the open sound is
                    // the theme with an untouched stack, so this costs one
                    // `nil` check in every other case.
                    .overlay(alignment: .top) {
                        MeloThemeWelcome(store: store)
                            .padding(DesignTokens.Spacing.lg)
                    }
                Divider()
                EditorTransportBar(store: store)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            sidebar
        }
    }

    private var header: some View {
        HStack(spacing: DesignTokens.Spacing.md) {
            CuttingRoomMark(size: 30)

            VStack(alignment: .leading, spacing: 1) {
                Text(store.document?.source.displayName ?? "Cutting Room")
                    // Rounded, because that is the house display voice, and the
                    // scale does not carry a design. Same call the popup header
                    // makes for the word "Melo", one step up.
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                    // A long name is most recognisable at both ends: podcast
                    // exports are all prefix and episode number.
                    .truncationMode(.middle)
                    .accessibilityAddTraits(.isHeader)

                if let source = store.document?.source,
                   let origin = CuttingRoomFormat.originLine(source.origin) {
                    Text(origin)
                        .font(DesignTokens.Typography.Scale.caption2(.medium))
                        .foregroundStyle(DesignTokens.Colors.textTertiary)
                        .lineLimit(1)
                }
            }

            if let source = store.document?.source {
                formatChip(source.formatDescription)

                Text(EditorFormat.timecode(source.duration))
                    .font(DesignTokens.Typography.Scale.footnote(.medium))
                    .monospacedDigit()
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
                    .accessibilityLabel("Length \(EditorFormat.timecode(source.duration))")
            }

            Spacer(minLength: DesignTokens.Spacing.sm)

            sourceMenu

            Button("Export") {
                showExport = true
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .help("Export (⌘E)")
        }
        .padding(.horizontal, DesignTokens.Spacing.lg)
        .padding(.vertical, DesignTokens.Spacing.sm2)
        .frame(minHeight: 56)
    }

    /// The four ways in, still available once a sound is open.
    ///
    /// This is a correction to a one-way door, and the door was closed on two
    /// clauses the owner asked for by name. `CuttingRoomEmptyState` draws the
    /// only other Paste-a-link and Record-this-Mac controls in the app, and it
    /// renders only while `store.document == nil` — which, after the first open,
    /// never happens again: `close()` has no caller outside the snapshot
    /// harness, and the store is a `static let` that lives as long as the app.
    /// The header carried an Open button, so a *file* was reachable; a link and
    /// a recording were reachable exactly once per launch, and quitting Melo was
    /// the way back to them.
    ///
    /// One menu rather than four buttons in the title row, and the same four
    /// doors in the same order and the same glyphs as the empty state's cards —
    /// so the second time someone looks for "Record this Mac" it is where they
    /// already learned it, wearing what they already recognise.
    ///
    /// No `keyboardShortcut` on these items on purpose. `cuttingRoomKeyCommands`
    /// is the single owner of keys in this window, and a menu item carrying the
    /// same equivalent would either double-fire or be silently swallowed by the
    /// local monitor depending on dispatch order. The shortcuts are in `.help`.
    private var sourceMenu: some View {
        Menu {
            Button("Open a File…", systemImage: "folder") { openFile() }
            Button("Paste a Link…", systemImage: "link") { showLinkImport = true }
            Button("Record This Mac…", systemImage: "record.circle") { showSystemRecord = true }
            Divider()
            Button("Remix the Melo Theme", systemImage: "music.quarternote.3") {
                MeloThemeRemix.openInCuttingRoom()
            }
            Divider()
            // The same one-way door, one turn further out. `Recent` and the
            // "Melo keeps your recordings and link audio" line live on the empty
            // state too, so without a way back to it they were also reachable
            // once per launch — and recents has no other route anywhere in the
            // app. This is the only caller of `close()` outside the harness.
            //
            // Nothing is lost by closing: `close()` writes the session sidecar
            // first, and reopening the same file restores its stack. So no
            // confirmation, for the same reason Revert has none.
            Button("Close This Sound", systemImage: "xmark.circle") {
                store.close()
            }
        } label: {
            Image(systemName: "waveform.badge.plus")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .font(DesignTokens.Typography.Scale.body(.regular))
        .symbolRenderingMode(.hierarchical)
        .foregroundStyle(DesignTokens.Colors.interactiveDefault)
        .frame(minHeight: DesignTokens.Dimensions.minTouchTarget)
        .help("Open another sound — file, link, recording, or the Melo theme (⌘O, ⌘L, ⌘R)")
        .accessibilityLabel("Open another sound")
    }

    /// A badge, not a row, so it carries a resting fill. `glassFillStrong` is the
    /// token for exactly this — emphasised badges and inserts — and is not the
    /// resting-fill-on-a-row that this project has settled against.
    private func formatChip(_ text: String) -> some View {
        Text(text)
            .font(DesignTokens.Typography.Scale.caption(.medium))
            .monospacedDigit()
            .foregroundStyle(DesignTokens.Colors.textSecondary)
            .lineLimit(1)
            .padding(.horizontal, DesignTokens.Spacing.sm)
            .padding(.vertical, DesignTokens.Spacing.xs)
            .background(Capsule().fill(DesignTokens.Colors.glassFillStrong))
            .overlay(Capsule().strokeBorder(DesignTokens.Colors.glassBorder, lineWidth: 0.5))
            .accessibilityLabel("Format, \(text)")
    }

    // MARK: - Sidebar

    /// The three panes the sidebar holds, and the accordion's state.
    enum SidebarSection: String, CaseIterable, Identifiable, Sendable {
        case destination
        case analysis
        case stack

        var id: Self { self }

        var title: String {
            switch self {
            case .destination: return "Where’s it going?"
            case .analysis: return "What I found"
            case .stack: return "The stack"
            }
        }
    }

    /// One pane open at a time, and the open one takes every point that is left.
    ///
    /// ## Why an accordion, when the contract drew three stacked sections
    ///
    /// Because three stacked sections do not fit and never could. Measured off
    /// the first rendered frame at the size the window opens at: the sidebar has
    /// **612pt** (640 less the titlebar) and the three panes want roughly
    /// **550 + 620 + 400 = 1570pt**. A plain `VStack` handed a third of the
    /// height it asked for does not clip politely — it overflows in *both*
    /// directions, so `cutting-room-loaded-dark` lost "WHERE'S IT GOING?" off the
    /// top of the window and the whole move stack off the bottom. The stack is
    /// the document; the one pane every other piece feeds was not on screen.
    ///
    /// *Rejected:* wrapping the sidebar in one `ScrollView`. It stops the
    /// overflow, but it puts `MoveStackView`'s own scroll view inside another
    /// one, and reordering rows by dragging is the interaction this feature is
    /// built around. *Rejected:* trimming the analysis pane to a compact table
    /// — at 8 rows of 28pt it saves 340pt, and 550 + 284 is still more than 612
    /// with nothing left for the stack. *Rejected:* opening taller, which fails
    /// the same arithmetic at every height a laptop has and at the 520 minimum.
    ///
    /// What this buys beyond fitting: the sidebar cannot overflow at *any*
    /// window size, because three headers are fixed and exactly one body absorbs
    /// whatever remains.
    private var sidebar: some View {
        VStack(spacing: 0) {
            ForEach(SidebarSection.allCases) { section in
                if section != .destination {
                    Divider()
                }

                sidebarHeader(section)

                if expandedSection == section {
                    Divider()
                    sidebarBody(section)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
        }
        .frame(width: Self.sidebarWidth)
    }

    /// Always visible, for all three, so the stack never stops being something
    /// the reader knows is there. A collapsed header carries its pane's answer
    /// rather than only its name — and that summary is read off the *document*,
    /// so this file does not start knowing how another piece draws itself.
    private func sidebarHeader(_ section: SidebarSection) -> some View {
        let isExpanded = expandedSection == section

        // The accessory sits *beside* the disclosure button rather than inside
        // it. A button nested in a button gets its clicks eaten by the outer
        // one, which would make Revert to Original toggle the accordion.
        return HStack(spacing: 0) {
            Button {
                withAnimation(DesignTokens.Animation.panel) {
                    expandedSection = section
                }
            } label: {
                HStack(spacing: DesignTokens.Spacing.sm) {
                    Image(systemName: "chevron.down")
                        .font(DesignTokens.Typography.Scale.caption2(.bold))
                        .foregroundStyle(DesignTokens.Colors.textTertiary)
                        .rotationEffect(.degrees(isExpanded ? 0 : -90))
                        .accessibilityHidden(true)

                    SectionHeader(title: section.title)

                    Spacer(minLength: DesignTokens.Spacing.sm)

                    if !isExpanded, let summary = summary(for: section) {
                        Text(summary)
                            .font(DesignTokens.Typography.Scale.caption())
                            .monospacedDigit()
                            .foregroundStyle(DesignTokens.Colors.textTertiary)
                            .lineLimit(1)
                    }
                }
                .padding(.leading, DesignTokens.Spacing.lg)
                .padding(.trailing, DesignTokens.Spacing.sm)
                .frame(height: 38)
                .contentShape(Rectangle())
            }
            // The popup's own "Audio" disclosure is this control, so it is this
            // button style.
            .buttonStyle(.meloHover)
            .accessibilityLabel(section.title)
            .accessibilityValue(isExpanded ? "Showing" : (summary(for: section) ?? "Hidden"))

            if section == .stack, isExpanded, hasMoves {
                revertButton
            }
        }
    }

    /// The control the shipped Guide has been describing to people who could not
    /// find it.
    ///
    /// `CuttingRoomStore.revertToOriginal()` had **no caller anywhere in
    /// `Sources/`**, while `SettingsGuide.swift:1217` tells readers "Revert to
    /// Original empties the stack and leaves the file exactly as it arrived" —
    /// and the Guide is indexed and searchable, so people go looking for it by
    /// that name. A documented control that does not exist is this project's own
    /// recorded worst pattern, so the label here is the Guide's exact words
    /// rather than a shorter paraphrase.
    ///
    /// In the stack's header because that is the pane the Guide entry is about,
    /// and only while the stack is open and has something in it — there is
    /// nothing to revert otherwise.
    ///
    /// No confirmation. `revertToOriginal()` goes through `mutate` with
    /// recording on, so ⌘Z puts every move back; a modal asking "are you sure"
    /// about a reversible act trains people to dismiss modals.
    private var revertButton: some View {
        Button("Revert to Original") {
            store.revertToOriginal()
        }
        .buttonStyle(.meloHover)
        .font(DesignTokens.Typography.Scale.caption(.medium))
        .foregroundStyle(DesignTokens.Colors.interactiveDefault)
        .padding(.trailing, DesignTokens.Spacing.md)
        .frame(height: 38)
        .contentShape(Rectangle())
        .help("Empty the stack and leave the file exactly as it arrived. Undo puts it back.")
    }

    @ViewBuilder
    private func sidebarBody(_ section: SidebarSection) -> some View {
        switch section {
        case .destination:
            // Scrolled here rather than by the pane: six destinations with the
            // chosen one expanded is about 550pt, which fits at most window
            // heights and not at the minimum.
            ScrollView {
                DestinationPicker(store: store)
                    .padding(.horizontal, DesignTokens.Spacing.md)
                    .padding(.vertical, DesignTokens.Spacing.sm)
            }
        case .analysis:
            ScrollView {
                AnalysisSummaryView(store: store)
                    .padding(.horizontal, DesignTokens.Spacing.md)
                    .padding(.vertical, DesignTokens.Spacing.sm)
            }
        case .stack:
            // No `ScrollView` here. `MoveStackView` has its own, and its rows are
            // reordered by dragging them — a drag inside a nested scroller is the
            // one interaction that must not be made ambiguous.
            //
            // `settings` is threaded, not just held. It is the same manager this
            // view reads for the theme, and it is the only route by which the
            // equalizer inspector can offer "Save to Melo": with `nil` that row
            // is absent rather than broken.
            MoveStackView(store: store, settings: settings)
                .padding(.horizontal, DesignTokens.Spacing.md)
                .padding(.top, DesignTokens.Spacing.sm)
        }
    }

    /// What a collapsed header says. Read from `EditorDocument`, which every
    /// piece shares, rather than from the pane that is currently hidden.
    private func summary(for section: SidebarSection) -> String? {
        guard let document = store.document else { return nil }
        switch section {
        case .destination:
            return document.destination?.title ?? "Not chosen"
        case .analysis:
            guard let analysis = document.analysis else { return "Not measured" }
            return "\(EditorFormat.number(analysis.integratedLUFS, places: 1)) LUFS"
        case .stack:
            let count = document.moves.count
            return count == 1 ? "1 move" : "\(count) moves"
        }
    }

    /// Which pane a freshly opened document opens on.
    ///
    /// A stack that already has moves in it — a reopened session, or the theme
    /// with a starter applied — is the thing to show. Otherwise the destination
    /// picker, because choosing one is the novice's first move and that pane is
    /// where "Fix it again" lives.
    private func syncSidebarSection() {
        #if MELO_DEV
        if pinnedSection != nil { return }
        #endif
        expandedSection = hasMoves ? .stack : .destination
    }

    // MARK: - When something did not work

    /// `CuttingRoomStore.lastError` had no reader. The store's own comment says a
    /// failure's sentence belongs there rather than in a progress row that stays
    /// on screen — and `retire(_:)` pulls the failed job straight back out of
    /// `jobs`, so without this a file that will not open produces a strip that
    /// flashes and nothing else. It is drawn here rather than in a pane because
    /// the failure is usually *about* there being no pane yet: a bad drop, a bad
    /// pick, a link that came back empty.
    ///
    /// Above the content and full width, so it is the same banner whether the
    /// window is showing the empty state or a sound.
    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.sm) {
            Image(systemName: "exclamationmark.triangle")
                .font(DesignTokens.Typography.Scale.body())
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.orange)
                .accessibilityHidden(true)

            Text(message)
                .font(DesignTokens.Typography.Scale.footnote(.medium))
                .foregroundStyle(DesignTokens.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: DesignTokens.Spacing.sm)

            Button("Dismiss", systemImage: "xmark") {
                store.clearError()
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.meloHover)
            .font(DesignTokens.Typography.Scale.caption(.semibold))
            .foregroundStyle(DesignTokens.Colors.interactiveDefault)
            .frame(
                minWidth: DesignTokens.Dimensions.minTouchTarget,
                minHeight: DesignTokens.Dimensions.minTouchTarget
            )
            .contentShape(Rectangle())
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, DesignTokens.Spacing.md)
        .padding(.vertical, DesignTokens.Spacing.sm)
        .background(DesignTokens.Colors.glassFillStrong, in: DesignTokens.Dimensions.Shape.md)
        .overlay {
            DesignTokens.Dimensions.Shape.md
                .strokeBorder(DesignTokens.Colors.menuBorder, lineWidth: 0.5)
        }
        .padding(.horizontal, DesignTokens.Spacing.lg)
        .padding(.bottom, DesignTokens.Spacing.sm)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Something went wrong. \(message)")
    }

    // MARK: - Drop affordance

    /// Shown while a drag is over the window, so the answer to "will this take
    /// it" arrives before the mouse button comes up rather than after.
    @ViewBuilder
    private var dropAffordance: some View {
        if isDropTargeted {
            ZStack {
                Color.accentColor.opacity(0.06)

                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(
                        Color.accentColor,
                        style: StrokeStyle(lineWidth: 2, dash: [7, 5])
                    )
                    .padding(DesignTokens.Spacing.sm)

                Text("Drop it.")
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.accentColor)
            }
            .allowsHitTesting(false)
            .transition(.opacity)
            .accessibilityHidden(true)
        }
    }

    // MARK: - Opening

    private func openFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = AudioFileIO.importableTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = "Open"
        panel.message = "Pick a sound to work on."

        let handle: @MainActor (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            Task { await store.open(url) }
        }

        // Attached to the Cutting Room when there is one, so the picker belongs
        // to the window that asked for it. `hostWindow` is nil in the snapshot
        // harness and in a preview, where the free-standing panel is correct.
        if let window = CuttingRoomWindowController.shared.hostWindow, window.isVisible {
            panel.beginSheetModal(for: window) { response in
                MainActor.assumeIsolated { handle(response) }
            }
        } else {
            panel.begin { response in
                MainActor.assumeIsolated { handle(response) }
            }
        }
    }

    // MARK: - Theme

    private var visualTheme: MeloVisualTheme {
        settings?.appSettings.visualTheme ?? .systemAccent
    }

    private var themeAccent: Color {
        visualTheme.accentColor(
            customHex: settings?.appSettings.customAccentHex ?? "#0A84FF",
            generatedTheme: settings?.appSettings.generatedTheme
        )
    }

    private var resolvedColorScheme: ColorScheme? {
        guard let settings else { return nil }
        return visualTheme.resolvedColorScheme(appearance: settings.appSettings.appearance)
    }

    /// `.preferredColorScheme` only changes how SwiftUI resolves colours. The
    /// window keeps its own `NSAppearance`, which is what decides whether an
    /// `NSVisualEffectView` renders light or dark glass — so without this bridge
    /// a light-locked Cutting Room would draw light text on dark material.
    private var resolvedAppearance: NSAppearance? {
        guard let settings else { return nil }
        return visualTheme.prefersDarkAppearance
            ? visualTheme.resolvedNSAppearance
            : settings.appSettings.appearance.nsAppearance
    }
}

#if MELO_DEV
extension CuttingRoomRootView {
    /// Seeds the one state of this view that no other seam can reach.
    ///
    /// The loaded and empty screens both come from the store —
    /// `CuttingRoomStore.setForSnapshot(document:waveform:)` gives one, an
    /// untouched store gives the other — so neither needs an initialiser here.
    /// The drop affordance does: it exists only while a drag is over the window,
    /// the harness cannot drag, and it is the one piece of feedback that decides
    /// whether dropping a file feels like something the window invited.
    ///
    /// `dropTargeted` carries no default. With one, this initialiser would be
    /// ambiguous with `init(store:settings:)` at every call site that passes
    /// only those two.
    ///
    /// `recents` is overridable so a frame can show the recents list without
    /// depending on whatever the machine running the harness happened to open.
    /// `sidebarSection` pins the accordion so all three panes are renderable
    /// from the one loaded scene. Left `nil` it follows `syncSidebarSection()`,
    /// which is what a real window does.
    init(
        store: CuttingRoomStore,
        settings: SettingsManager?,
        dropTargeted: Bool,
        recents: CuttingRoomRecents = .shared,
        sidebarSection: SidebarSection? = nil
    ) {
        _store = ObservedObject(wrappedValue: store)
        self.settings = settings
        self.recents = recents
        _isDropTargeted = State(initialValue: dropTargeted)
        _pinnedSection = State(initialValue: sidebarSection)
        _expandedSection = State(initialValue: sidebarSection ?? Self.defaultSection(for: store))
    }
}
#endif
