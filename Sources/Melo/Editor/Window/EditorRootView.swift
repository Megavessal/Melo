import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Where a sound came from, in a line.
///
/// Lengths are **not** here. `EditorFormat.timecode` is the one place a number
/// becomes a time string, and the transport reads from it — a second
/// implementation in this file would let the header and the playhead disagree
/// about the same sound by a rounding mode.
enum EditorOriginFormat {
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
/// the whole point of using it here rather than an SF Symbol: Melo Edit
/// has to read as part of Melo on the first frame.
struct EditorMark: View {
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

/// Melo Edit, assembled.
///
/// Owns the header row, the sidebar container, the split between them, and the
/// window-wide drop target. Owns none of the panes: `EditorWaveformView`,
/// `EditorTransportBar`, `DestinationPicker`, `AnalysisSummaryView`,
/// `ChainPanelView`, `JobProgressStrip` and the three sheets each own their own
/// contents and are called here through their `init(store:)` seams.
///
/// Constructible with nothing but a store, so a frame can be rendered without a
/// window ever existing.
@MainActor
struct EditorRootView: View {
    @ObservedObject private var store: EditorStore

    /// Optional because the contract's pinned initialiser is `init(store:)` and
    /// the snapshot harness uses it. Without a `SettingsManager` the window
    /// still draws — it just wears the system accent and the system appearance
    /// instead of the theme the user picked.
    private let settings: SettingsManager?
    private let recents: EditorRecents

    @State private var showExport = false
    @State private var showLinkImport = false
    @State private var showSystemRecord = false
    @State private var isDropTargeted = false

    /// The window is `.fullSizeContentView`, so the SwiftUI content starts at the
    /// very top of the frame and the traffic lights are drawn on top of it. The
    /// standard macOS titlebar is 28pt; reading `contentLayoutRect` would be
    /// exact but needs a window, and this view has to lay out without one.
    private static let titleBarInset: CGFloat = 28

    /// Fixed at 320. Not resizable: a draggable divider is
    /// a preference to store, a state to restore and a thing to get wrong, and
    /// the three panes in it are all fixed-width content.
    private static let sidebarWidth: CGFloat = 320

    /// A docked panel's header strip.
    ///
    /// 28, down from 38. `minTouchTarget` rather than a smaller number chosen
    /// by eye: the header is the full 320pt of the pane, so the target is
    /// enormous horizontally and the only dimension that can be got wrong is
    /// this one. Three headers at 38 cost 114pt of a 612pt pane before anything
    /// was shown; at 28 they cost 84, which is 30pt back — most of a row of the
    /// Chain.
    private static let headerHeight: CGFloat = DesignTokens.Dimensions.minTouchTarget

    /// The accent stripe down the left edge of an open panel's header.
    ///
    /// VEGAS puts a colour band on the left of every track header and it is the
    /// single cheapest thing in that screenshot: it says which strip belongs to
    /// which lane without a word or a border. Here there is one colour, the
    /// user's accent, and it marks *open* — with three panels able to be open at
    /// once, "which of these is showing" is a question the pane now has to
    /// answer at a glance.
    private static let openStripeWidth: CGFloat = 2

    init(store: EditorStore) {
        self.init(store: store, settings: nil)
    }

    init(store: EditorStore, settings: SettingsManager?) {
        _store = ObservedObject(wrappedValue: store)
        self.settings = settings
        self.recents = .shared
    }

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: Self.titleBarInset)

            if let message = store.lastError {
                errorBanner(message)
            }

            if isEmpty {
                EditorEmptyState(
                    onOpenFile: openFile,
                    onPasteLink: { showLinkImport = true },
                    onRecord: { showSystemRecord = true },
                    onRemixTheme: { MeloThemeRemix.openInEditor() },
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
            // The first file in the drag, and only the first. It goes to the
            // same `store.open` the file picker uses, so a dropped thing that
            // is not audio fails exactly where a picked one does instead of
            // needing a second error path that says the same sentence — and so
            // a drop onto an open document adds a track, because that rule
            // lives in `openSource`, which is the one funnel every file the
            // user brings in goes through.
            //
            // Extra files are dropped rather than queued. That was "one sound,
            // not a session" when it was written and it is no longer; it is now
            // just an unbuilt case. Adding four tracks from one gesture is a
            // real thing to want and it needs a loop and a decision about what
            // happens when the third file fails to decode, which is more than a
            // comment here can settle.
            Task { await store.open(url) }
            return true
        } isTargeted: { targeted in
            withAnimation(DesignTokens.Animation.present) {
                isDropTargeted = targeted
            }
        }
        .editorKeyCommands(
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
        }
        // There is no longer an `onChange(of: store.document?.source.id)` here
        // resetting which panels are open, and its absence is the feature.
        // Opening a document sets `store.openPanels` from that document's own
        // sidecar — see `EditorStore.replaceDocument` — so the pane is already
        // right on the first layout pass, in the harness as well as in a real
        // window. The old `syncSidebarSection()` existed to do in a lifecycle
        // callback what the store now does in the open itself, and a frame that
        // depends on `onAppear` having run is a frame nobody can explain.
        //
        // Recents is about *every* file that arrives, which is not the same
        // event and used to be folded into the one above.
        //
        // `document.source` is the transitional first-source accessor, so a
        // file that arrived as a second lane never changed it and was never
        // remembered — and a recording layered onto an open document is
        // precisely the entry that exists nowhere else on disk. The store
        // publishes `lastAddedSource` on both paths for this, rather than
        // calling `EditorRecents` itself: `verify-editor-wiring.py` compiles
        // Core without the UI layer, so Core reaching into Window breaks the
        // check that proves the store is reached at all.
        .onChange(of: store.lastAddedSource?.id) { _, _ in
            guard let source = store.lastAddedSource else { return }
            recents.remember(source)
        }
        // The one thing that opens a panel nobody pressed, and only on the
        // empty-to-populated edge: pressing "Fix it again" fills the Chain, and
        // what the reader wants at that moment is to see what Melo just did.
        //
        // **It now opens the Chain rather than switching to it**, which is the
        // whole difference the docked panels make here. Under the accordion this
        // line shut whichever panel the reader was working in — usually the
        // destination picker they had just pressed the button in — so the act of
        // showing them the result took away the control that produced it. It
        // adds and never removes, and it does nothing at all when the Chain is
        // already open.
        .onChange(of: hasMoves) { had, has in
            guard !had, has, !openPanels.contains(.chain) else { return }
            withAnimation(DesignTokens.Animation.panel) {
                store.toggleOpenPanel(.chain)
            }
        }
    }

    private var isEmpty: Bool {
        store.document == nil
    }

    /// Whether the Chain has anything in it. Named rather than inlined into the
    /// `onChange` above, where a closure parameter called `isEmpty` would have
    /// shadowed the property directly above this one.
    private var hasMoves: Bool {
        !(store.document?.moves.isEmpty ?? true)
    }

    // MARK: - The editor

    /// Panels that meet.
    ///
    /// Every `Divider()` in this split is now `hairline`, which is the same
    /// change the docked pane made one method down and for the same reason:
    /// `Divider()` resolves to the system separator at full strength and cannot
    /// be told otherwise, so the window's rules were AppKit's. Four separators
    /// in one window drawn by two different mechanisms is also how a pane ends
    /// up looking bolted on — the reason the right-hand side and this side had
    /// to be done together.
    ///
    /// No spacing anywhere and nothing rounded. The header, the timeline, the
    /// transport, Full's clip strip and the pane are five regions that touch,
    /// separated by one point each.
    private var editor: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                header
                hairline
                timelineArea
                hairline
                EditorTransportBar(store: store)

                // No hairline above this one. The transport bar and the clip
                // strip are one 44pt band that Full splits in two — see the
                // arithmetic on `EditorTransportBar.height` — and a separator
                // between them would be a line the band does not have room for
                // and would read as two regions rather than one.
                if store.mode.shows(.transportRow) {
                    EditorClipStrip(store: store)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            verticalHairline

            sidebar
        }
    }

    // MARK: - The timeline

    /// One track by default, and it grows.
    ///
    /// **This branch is the governing decision made structural.** A document
    /// with one track takes the first arm and gets exactly the window this app
    /// shipped with — the waveform pane, full width between two dividers, no
    /// header column, no geometry reader, no scroller. Not "a multitrack layout
    /// that happens to have one row in it": the same view tree as before, so
    /// the frames of the single-track window cannot move because a feature
    /// nobody has used yet exists.
    ///
    /// Add a second track and the column appears beside the lanes, in place.
    /// Nothing switches mode and nothing is hidden — `EditorDocument
    /// .isMultitrack` is the whole condition.
    @ViewBuilder
    private var timelineArea: some View {
        if store.document?.isMultitrack == true {
            multitrackTimeline
        } else {
            waveformPane
        }
    }

    /// The waveform gets the room and no inset. It is a drawing of the whole
    /// sound, and a drawing of the whole sound that stops 16pt short of the
    /// edge is a drawing of most of it.
    private var waveformPane: some View {
        EditorWaveformView(store: store)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Top rather than centre, and over the waveform rather than above
            // it. The card is an offer, not a step: it has to be impossible to
            // miss and equally possible to ignore, and a centred card sits on
            // the part of the drawing someone is about to click. It renders
            // nothing unless the open sound is the theme with an untouched
            // Chain, so this costs one `nil` check in every other case.
            .overlay(alignment: .top) {
                MeloThemeWelcome(store: store)
                    .padding(DesignTokens.Spacing.lg)
            }
    }

    /// The header column, a rule, and the lanes — one row, one height, no
    /// scrollers.
    ///
    /// **Neither side scrolls vertically, and that is the agreement rather
    /// than an oversight.** The lanes divide the timeline pane between the
    /// tracks and stop at a floor; the header column reserves the same ruler
    /// band above and scroll strip below and divides what is left the same way,
    /// so row *n* is level with lane *n* because both are one flexible share of
    /// one height. Two scroll views that must agree about an offset would be
    /// the same class of bug as two lane heights, wearing a delay — and a
    /// single scroller around both is not available while the ruler is drawn
    /// *inside* the timeline pane, because it would scroll away with the lanes.
    ///
    /// Past the floor — roughly four tracks at the 520pt minimum window, more
    /// in a normal one — both sides clip at the bottom. Fixing that properly is
    /// a shared scroller with the ruler hoisted out of `EditorWaveformView`,
    /// which is a seam this piece does not own.
    ///
    /// It also costs nothing in the harness: no `ScrollView` means every
    /// multitrack scene is renderable on the `ImageRenderer` path, which cannot
    /// draw scrolled content at all.
    private var multitrackTimeline: some View {
        HStack(spacing: 0) {
            TrackHeaderColumn(store: store)
            Divider()
            waveformPane
        }
    }

    private var header: some View {
        HStack(spacing: DesignTokens.Spacing.md) {
            EditorMark(size: 30)

            VStack(alignment: .leading, spacing: 1) {
                titleLine

                if let source = store.document?.source,
                   let origin = EditorOriginFormat.originLine(source.origin) {
                    Text(origin)
                        .font(DesignTokens.Typography.Scale.caption2(.medium))
                        .foregroundStyle(DesignTokens.Colors.textTertiary)
                        .lineLimit(1)
                }
            }

            if let document = store.document {
                formatChip(document.source.formatDescription)

                // **`document.duration`, not `source.duration`.** The length
                // beside the name is a claim about what is on the timeline, and
                // the first source's length stopped being that the moment a
                // second lane could exist — a four-minute file with a six-minute
                // music bed under it would have read "4:00" while the ruler read
                // six. `EditorDocument.duration` is the end of the last clip on
                // any track, and for the one-file document it is bit-for-bit the
                // source's length, so nothing about the single-track window
                // moves.
                Text(EditorFormat.timecode(document.duration))
                    .font(DesignTokens.Typography.Scale.footnote(.medium))
                    .monospacedDigit()
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
                    .accessibilityLabel("Length \(EditorFormat.timecode(document.duration))")
            }

            Spacer(minLength: DesignTokens.Spacing.sm)

            // Left of the source menu and left of Export, which puts it at the
            // start of the controls cluster rather than at the end. Deliberate:
            // the two things to its right *do* something to the sound, and this
            // does something to the window. A control that only changes what is
            // drawn should not be the neighbour of the one that writes a file.
            EditorModeSwitch(store: store)

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

    /// "morning-show-ep41", and "+3" once there is more than one source.
    ///
    /// The name stays the name of the thing they opened, because that is what
    /// they will recognise, and the count says plainly that it is no longer the
    /// whole story. `document.source` is the transitional first-source
    /// accessor and it was being presented as the document's name — four
    /// differently-named lanes under one file's title.
    ///
    /// *Rejected:* a project name. Melo has no such concept, and inventing one
    /// gives it somewhere to be typed, somewhere to be stored and something to
    /// migrate. *Rejected:* showing nothing once there are several, which loses
    /// the one label the window has.
    ///
    /// **`layoutPriority(1)` on the count is the whole trick.** Without it a
    /// long first name eats the "+3" before it eats itself, and the one element
    /// that says "there is more here than this" is the one that disappears
    /// exactly when the name is long enough to need it. The name keeps middle
    /// truncation — podcast exports are all shared prefix and episode number,
    /// so both ends carry the information.
    private var titleLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.xs) {
            Text(store.document?.source.displayName ?? "Melo Edit")
                // Rounded, because that is the house display voice, and the
                // scale does not carry a design. Same call the popup header
                // makes for the word "Melo", one step up.
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .truncationMode(.middle)

            if extraSourceCount > 0 {
                Text("+\(extraSourceCount)")
                    .font(DesignTokens.Typography.Scale.caption(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(DesignTokens.Colors.textTertiary)
                    .lineLimit(1)
                    .layoutPriority(1)
                    .help(extraSourceDescription)
            }
        }
        // One element, so VoiceOver says the sentence rather than reading a
        // name and then the two characters "+3".
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenTitle)
        .accessibilityAddTraits(.isHeader)
    }

    /// How many sounds are on the timeline beyond the one the window is named
    /// after. Counts *sources*, not tracks: two lanes cut from one file are one
    /// sound in two places, and calling that "+1" would be telling the user
    /// something arrived that never did.
    private var extraSourceCount: Int {
        max((store.document?.sources.count ?? 0) - 1, 0)
    }

    /// "3 more sounds", "one more sound".
    private var extraSourceDescription: String {
        extraSourceCount == 1 ? "one more sound" : "\(extraSourceCount) more sounds"
    }

    private var spokenTitle: String {
        let name = store.document?.source.displayName ?? "Melo Edit"
        guard extraSourceCount > 0 else { return name }
        return "\(name), and \(extraSourceDescription)"
    }

    /// The four ways in, still available once a sound is open — and, now that
    /// bringing audio in adds a track instead of replacing the document, the
    /// place where the user is told that before it happens.
    ///
    /// This is a correction to a one-way door, and the door was closed on two
    /// clauses the owner asked for by name. `EditorEmptyState` draws the
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
    /// ## Why only the first item was renamed
    ///
    /// `openSource` adds a track when a document is already open, so the first
    /// three of these produce a lane rather than a replacement. Exactly one of
    /// them said otherwise: **"Open"** is the verb macOS uses for "put
    /// something else in this window", and a user who picks Open and gets a
    /// second lane has been surprised. It is now "Add a File…".
    ///
    /// **"Remix the Melo Theme" is the exception and still replaces**, scoped
    /// out of the add rule in `openSource` — layering the theme under someone's
    /// podcast is not what anybody presses that button for, and the theme
    /// welcome card's gate would stop meaning anything. Its label is unchanged:
    /// "Remix" does not promise either behaviour, the divider above it already
    /// separates it from the three that add, and nothing is lost when it
    /// replaces because `replaceDocument` writes the outgoing sidecar first.
    ///
    /// "Paste a Link…" and "Record This Mac…" were left alone, and that is a
    /// judgement rather than an oversight. Neither verb means replace — pasting
    /// and recording both *make new audio*, which is what actually happens —
    /// and both are the empty state's exact words, which is the recognition
    /// this menu was built on. Renaming them to match a pattern would cost that
    /// and buy nothing a user was going to get wrong. "Record a Recording of
    /// This Mac" is also not a sentence in Melo's voice.
    ///
    /// The menu is only ever drawn with a document open — `header` renders only
    /// inside `editor`, which is the non-empty arm — so this wording is not
    /// conditional on `store.document`. A branch that can never be taken is
    /// worse than none: nothing exercises it and nothing can prove it right.
    ///
    /// No `keyboardShortcut` on these items on purpose. `editorKeyCommands`
    /// is the single owner of keys in this window, and a menu item carrying the
    /// same equivalent would either double-fire or be silently swallowed by the
    /// local monitor depending on dispatch order. The shortcuts are in `.help`.
    private var sourceMenu: some View {
        Menu {
            Button("Add a File…", systemImage: "folder") { openFile() }
            Button("Paste a Link…", systemImage: "link") { showLinkImport = true }
            Button("Record This Mac…", systemImage: "record.circle") { showSystemRecord = true }
            Divider()
            Button("Remix the Melo Theme", systemImage: "music.quarternote.3") {
                MeloThemeRemix.openInEditor()
            }
            Divider()
            // The way to a lane with nothing in it, and the only one of these
            // that does not bring audio — hence "Empty", which it did not need
            // before the three items above started adding tracks too.
            //
            // A menu item on purpose. The governing decision is that a freshly
            // opened file shows one lane and no add-track button competing for
            // attention with the sound; a line in a menu the user opens is not
            // competing for anything. Once there are two lanes the column
            // carries the same control at the head of the header stack.
            Button("Add an Empty Track", systemImage: "rectangle.stack.badge.plus") {
                // `_ =` because `withAnimation` infers its result type from the
                // closure, and `addTrack()` returns the new id.
                withAnimation(DesignTokens.Animation.panel) {
                    _ = store.addTrack()
                }
            }
            .disabled(store.document == nil)
            Divider()
            // The same one-way door, one turn further out. `Recent` and the
            // "Melo keeps your recordings and link audio" line live on the empty
            // state too, so without a way back to it they were also reachable
            // once per launch — and recents has no other route anywhere in the
            // app. This is the only caller of `close()` outside the harness.
            //
            // Nothing is lost by closing: `close()` writes the session sidecar
            // first, and reopening the same file restores its Chain. So no
            // confirmation, for the same reason Revert has none.
            //
            // **The only thing here that empties the window.** The three doors
            // at the top add a lane and the theme swaps the document; this is
            // the one that leaves nothing behind, which is what "close" already
            // means to everybody before they read it.
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
        .help("Add a sound as a new track — file, link, recording (⌘O, ⌘L, ⌘R)")
        .accessibilityLabel("Add a sound as a new track")
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

    // MARK: - The docked panels

    /// Which panels are open, resolved.
    ///
    /// `store.openPanels` is the record and this is the policy: `nil` there
    /// means no sidecar had an opinion, and the answer to that is
    /// `EditorPanel.defaults(forMoveCount:)`. Reading it as a pure function of
    /// the store, rather than mirroring it into `@State` and syncing, is what
    /// makes the panes correct on the very first layout pass — in the render
    /// harness, which runs no lifecycle callbacks it is not obliged to, as much
    /// as in a real window. The previous accordion needed `onAppear` and an
    /// `onChange` to reach the same state and carried a `#if MELO_DEV` pin so
    /// the harness could get around them.
    private var openPanels: Set<EditorPanel> {
        store.openPanels ?? EditorPanel.defaults(
            forMoveCount: store.document?.moves.count ?? 0
        )
    }

    /// Panels butted edge to edge, each header the full width of the pane and
    /// the whole of it the button.
    ///
    /// ## What replaced the accordion, and what the accordion was solving
    ///
    /// It was solving arithmetic. Measured off the first rendered frame at the
    /// size the window opens at: the pane has **612pt** (640 less the titlebar)
    /// and the three bodies want roughly **550 + 620 + 400 = 1570pt**. A plain
    /// `VStack` handed a third of the height it asked for does not clip
    /// politely — it overflows in *both* directions, so an early
    /// `cutting-room-loaded-dark` lost "WHERE'S IT GOING?" off the top of the
    /// window and the whole Chain off the bottom.
    ///
    /// That arithmetic has not changed, so the fix has not either: **every open
    /// body is `maxHeight: .infinity` and therefore takes one equal share of
    /// whatever the headers leave**, and each of the three already scrolls
    /// inside itself. Two open at 612pt is 84 of headers and 264 each; three is
    /// 176 each, which is tight and is the user's own choice rather than
    /// something the layout did to them. Nothing can overflow at any window
    /// size, which is the property the accordion bought and this keeps.
    ///
    /// *Rejected:* one `ScrollView` around the whole pane. It stops the
    /// overflow, but it puts `ChainPanelView`'s own scroll view inside another
    /// one, and reordering rows by dragging is the interaction the Chain is
    /// built around. *Rejected:* letting an open panel keep its natural height
    /// and scrolling past — same nesting, plus a Chain whose bottom is off
    /// screen while the analysis panel above it shows white space.
    ///
    /// **The `Spacer` is conditional, and that is not tidiness.** A `Spacer` is
    /// as flexible as a `maxHeight: .infinity` body, so an unconditional one
    /// would be a fourth claimant on the leftover height: one open panel would
    /// get half the pane and the other half would be blank. It is here only to
    /// stop three shut headers being centred vertically in an empty column,
    /// which is the one case where nothing else is flexible at all.
    private var sidebar: some View {
        VStack(spacing: 0) {
            ForEach(drawnPanels) { panel in
                hairline
                panelHeader(panel)

                if openPanels.contains(panel) {
                    hairline
                    panelBody(panel)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }

            hairline

            if drawnPanels.allSatisfy({ !openPanels.contains($0) }) {
                Spacer(minLength: 0)
            }
        }
        .frame(width: Self.sidebarWidth)
    }

    /// Which panels this mode paints, in order.
    ///
    /// **The mode filters what is drawn and never what is stored.** A reader
    /// who had Master open, switched to Simple, and switched back gets Master
    /// open again, because `store.openPanels` was never touched — the set still
    /// contains `.master`, `openPanels.contains` still answers yes, and this
    /// list is the only thing that changed. Pruning the stored set instead
    /// would be a mode that quietly edits state on the way past, which is the
    /// same class of defect as a mode that edits the document.
    ///
    /// It is also why the `Spacer` condition above asks whether any *drawn*
    /// panel is open rather than whether the set is empty: in Simple with only
    /// Master open, the set is not empty and the column has nothing flexible in
    /// it, which is exactly the case the spacer exists for.
    private var drawnPanels: [EditorPanel] {
        EditorPanel.allCases.filter { panel in
            panel != .master || store.mode.shows(.master)
        }
    }

    /// One point of separator, always, in place of a gap.
    ///
    /// `Divider()` was here and is not a hairline — it takes the ambient
    /// spacing of whatever stack it is in, which in a `spacing: 0` `VStack` is
    /// nothing, but it also resolves to the system separator at full strength
    /// and cannot be told otherwise. This is a token, so the pane's rules are
    /// the pane's rules and not AppKit's.
    private var hairline: some View {
        Rectangle()
            .fill(DesignTokens.Colors.panelSeparator)
            .frame(height: 1)
            .accessibilityHidden(true)
    }

    /// The same line stood on end, for the boundary between the timeline column
    /// and the docked pane. One token, two orientations — a second colour for
    /// the vertical case is how the one seam a user looks at most ends up a
    /// different weight from every other seam in the window.
    private var verticalHairline: some View {
        Rectangle()
            .fill(DesignTokens.Colors.panelSeparator)
            .frame(width: 1)
            .accessibilityHidden(true)
    }

    /// The header is the whole button, and there is nothing else in it.
    ///
    /// **This is the correction the owner asked for by name.** The old header
    /// was a `Button` beside a second button, and the comment there explained
    /// that Revert to Original had to sit *outside* the disclosure or the outer
    /// button would eat its clicks. That is a true fact about SwiftUI and it was
    /// the wrong conclusion: it left a header where part of the strip opened the
    /// panel and part of it did something else, and the reader has no way to
    /// know which part is which. Revert now lives in the Chain's own control
    /// strip — see `ChainPanelView` — and the header has exactly one meaning
    /// across its full 320pt.
    ///
    /// The chevron stays. It is not the target any more, so its only job is to
    /// say that the strip is pressable at all, which a flat band of text does
    /// not.
    private func panelHeader(_ panel: EditorPanel) -> some View {
        PanelHeaderButton(
            title: panel.title,
            summary: summary(for: panel),
            isOpen: openPanels.contains(panel),
            height: Self.headerHeight,
            stripeWidth: Self.openStripeWidth
        ) {
            withAnimation(DesignTokens.Animation.panel) {
                store.toggleOpenPanel(panel)
            }
        }
    }

    @ViewBuilder
    private func panelBody(_ panel: EditorPanel) -> some View {
        switch panel {
        case .destination:
            // Scrolled here rather than by the pane: six destinations with the
            // chosen one expanded is about 550pt, which fits at most window
            // heights and not at the minimum — and now never gets the whole
            // pane to itself when a second panel is open beside it.
            ScrollView {
                DestinationPicker(store: store)
                    .padding(.horizontal, DesignTokens.Spacing.sm)
                    .padding(.vertical, DesignTokens.Spacing.xs2)
            }
        case .analysis:
            ScrollView {
                AnalysisSummaryView(store: store)
                    .padding(.horizontal, DesignTokens.Spacing.sm)
                    .padding(.vertical, DesignTokens.Spacing.xs2)
            }
        case .chain:
            // No `ScrollView` here. `ChainPanelView` has its own, and its rows
            // are reordered by dragging them — a drag inside a nested scroller
            // is the one interaction that must not be made ambiguous.
            //
            // `settings` is threaded, not just held. It is the same manager this
            // view reads for the theme, and it is the only route by which the
            // equalizer inspector can offer "Save to Melo": with `nil` that row
            // is absent rather than broken.
            ChainPanelView(store: store, settings: settings)
                .padding(.horizontal, DesignTokens.Spacing.sm)
                .padding(.top, DesignTokens.Spacing.xs2)
        case .master:
            // Scrolled like the other two short panels rather than left to
            // overflow: four lines and a meter is about 90pt, which fits at
            // every window height *until* all four panels are open at 520, and
            // the pane's whole arrangement is that no body may overflow.
            ScrollView {
                MasterPanelView(store: store)
                    .padding(.horizontal, DesignTokens.Spacing.sm)
                    .padding(.vertical, DesignTokens.Spacing.xs2)
            }
        }
    }

    /// What a shut header says. Read from `EditorDocument`, which every piece
    /// shares, rather than from the panel that is currently hidden.
    private func summary(for panel: EditorPanel) -> String? {
        guard let document = store.document else { return nil }
        switch panel {
        case .destination:
            return document.destination?.title ?? "Not chosen"
        case .analysis:
            guard let analysis = document.analysis else { return "Not measured" }
            return "\(EditorFormat.number(analysis.integratedLUFS, places: 1)) LUFS"
        case .chain:
            let count = document.moves.count
            return count == 1 ? "1 move" : "\(count) moves"
        case .master:
            // The mix's peak, which is the number somebody shuts this panel
            // still wanting. Not the LUFS — "What I found" two headers up
            // already says that, and two headers carrying different loudness
            // numbers for the same window is how a reader decides one of them
            // is wrong.
            return EditorLevelReading.label(EditorLevelReading.forMix(store.waveform).peakDB)
        }
    }

    // MARK: - When something did not work

    /// `EditorStore.lastError` had no reader. The store's own comment says a
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

        // Attached to the Melo Edit window when there is one, so the picker belongs
        // to the window that asked for it. `hostWindow` is nil in the snapshot
        // harness and in a preview, where the free-standing panel is correct.
        if let window = EditorWindowController.shared.hostWindow, window.isVisible {
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
    /// a light-locked Melo Edit would draw light text on dark material.
    private var resolvedAppearance: NSAppearance? {
        guard let settings else { return nil }
        return visualTheme.prefersDarkAppearance
            ? visualTheme.resolvedNSAppearance
            : settings.appSettings.appearance.nsAppearance
    }
}

// MARK: - The header that is the whole button

/// A docked panel's header strip: full width, square edges, one press target.
///
/// Its own type because it needs `@State` for hover, and because
/// `.buttonStyle(.meloHover)` is wrong here in three separate ways that are
/// each worth naming rather than rediscovering. It fills a
/// `DesignTokens.Dimensions.Shape.sm` — a **rounded** rect — which is the
/// floating-card look the VEGAS frame explicitly refuses; it draws a hairline
/// border on all four sides, so a hovered header would gain edges the
/// separators above and below already provide; and it applies a 0.975
/// `scaleEffect` on press, which on a strip that spans the full pane shows as
/// the panel's own edges shrinking away from the window's. That style is right
/// for the popup's rows, which is what it was built for.
///
/// So: a square hover wash, no border, no scale. The press feedback is the
/// panel opening, which is not subtle.
private struct PanelHeaderButton: View {
    let title: String
    /// What the panel would say if it were open — the destination's name, the
    /// measured loudness, the move count. Shown only while shut, because open
    /// the panel says it itself and a header repeating its own body is noise.
    let summary: String?
    let isOpen: Bool
    let height: CGFloat
    let stripeWidth: CGFloat
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: DesignTokens.Spacing.xs2) {
                Image(systemName: "chevron.down")
                    .font(DesignTokens.Typography.Scale.caption2(.bold))
                    .foregroundStyle(DesignTokens.Colors.textTertiary)
                    .rotationEffect(.degrees(isOpen ? 0 : -90))
                    // A fixed column, so the title starts at the same x whether
                    // the chevron is pointing down or right. Rotation does not
                    // change a glyph's bounds, but the glyph is not square and
                    // its ink is not centred in them.
                    .frame(width: 10)
                    .accessibilityHidden(true)

                SectionHeader(title: title)

                Spacer(minLength: DesignTokens.Spacing.xs)

                if !isOpen, let summary {
                    Text(summary)
                        .font(DesignTokens.Typography.Scale.caption())
                        .monospacedDigit()
                        .foregroundStyle(DesignTokens.Colors.textTertiary)
                        .lineLimit(1)
                }
            }
            // Tighter than the old 16pt lead. The stripe is drawn in the first
            // two points of the strip, so the text has to clear it without
            // opening a gap the eye reads as an indent.
            .padding(.leading, DesignTokens.Spacing.sm)
            .padding(.trailing, DesignTokens.Spacing.sm)
            .frame(maxWidth: .infinity, minHeight: height, alignment: .leading)
            .background { background }
            // The whole strip, including the space the `Spacer` opens up. Without
            // this the gap between the title and the summary is not a target and
            // the header is a button with a hole in the middle of it.
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(DesignTokens.Animation.hover, value: isHovered)
        .accessibilityLabel(title)
        .accessibilityValue(isOpen ? "Showing" : (summary ?? "Hidden"))
        // Says what pressing does, which the label and value between them do
        // not: a reader who hears "Showing" still has to guess whether the
        // control that says it will shut the panel or do something else.
        .accessibilityHint(isOpen ? "Hides this panel" : "Shows this panel")
        .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder
    private var background: some View {
        ZStack(alignment: .leading) {
            Rectangle()
                .fill(isOpen
                      ? DesignTokens.Colors.panelHeaderFillOpen
                      : DesignTokens.Colors.panelHeaderFill)

            if isHovered {
                Rectangle().fill(DesignTokens.Colors.hoverSurface)
            }

            if isOpen {
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(width: stripeWidth)
            }
        }
        .allowsHitTesting(false)
    }
}

#if MELO_DEV
extension EditorRootView {
    /// Seeds the one state of this view that no other seam can reach.
    ///
    /// The loaded and empty screens both come from the store —
    /// `EditorStore.setForSnapshot(document:waveform:)` gives one, an
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
    ///
    /// There is no `sidebarSection` parameter any more. It pinned the accordion
    /// because the accordion's state was `@State` on this view and the harness
    /// had no other way in; which panels are open now lives on the store, where
    /// `EditorStore.setOpenPanelsForSnapshot` reaches it — one fewer piece of
    /// view state that only the harness knows how to seed, and one fewer way for
    /// a frame to show a pane the app cannot produce.
    init(
        store: EditorStore,
        settings: SettingsManager?,
        dropTargeted: Bool,
        recents: EditorRecents = .shared
    ) {
        _store = ObservedObject(wrappedValue: store)
        self.settings = settings
        self.recents = recents
        _isDropTargeted = State(initialValue: dropTargeted)
    }
}
#endif
