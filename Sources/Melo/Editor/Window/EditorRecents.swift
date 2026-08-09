import AppKit
import Foundation
import OSLog

/// One thing Melo Edit opened before.
///
/// Everything needed to draw the row is stored, rather than re-probed on load:
/// five `AudioFileIO.probe` calls on a window that is being put on screen is
/// disk work in the one place the user is watching for the window to appear.
struct EditorRecent: Codable, Equatable, Identifiable, Sendable {
    var url: URL
    var displayName: String
    var formatDescription: String
    var duration: TimeInterval
    var openedAt: Date
    var kind: Kind

    var id: URL { url }

    /// Where the sound came from, reduced to the three things a row has to tell
    /// them apart. Stored rather than derived, because the row is drawn without
    /// the document that produced it.
    enum Kind: String, Codable, Sendable {
        case file
        case link
        case recording

        /// The same three glyphs the entry cards use, which is the point: the
        /// card that says "Record this Mac" is `record.circle`, so the row that
        /// came from it needs no label to be read as a recording. The vocabulary
        /// is taught on the same screen it is used.
        var symbolName: String {
            switch self {
            case .file: return "waveform"
            case .link: return "link"
            case .recording: return "record.circle"
            }
        }

        /// Whether the file lives in the folder Melo keeps, rather than
        /// somewhere the user put it.
        var isKeptByMelo: Bool {
            self != .file
        }
    }
}

/// The last five files Melo Edit opened.
///
/// ## Why this is its own file on disk
///
/// `settings.json` is Melo's source of truth for *settings*, and this is not a
/// setting — it is a cache of what the user did, it is discardable, and losing
/// it costs nothing. Putting it in `SettingsManager.Settings` would mean editing
/// a file this piece does not own and bumping a schema version that every other
/// stored value shares. It sits beside `settings.json` in the same Application
/// Support directory instead, so an erase-and-reinstall clears both together.
///
/// ## What gets remembered
///
/// Everything with a durable home, which since `EditorSourceStore` landed is
/// three of the four origins.
///
/// This list originally held `.file` sources only, and the reason was that a
/// link extraction and a recording both lived in `FileManager.temporaryDirectory`
/// — offering to reopen one was offering to reopen something macOS was entitled
/// to have deleted. That premise is gone: `EditorStore.openSource` now
/// moves both into `EditorSourceStore.directory` before anything reads the path,
/// and `document.source.url` is where the audio actually lives.
///
/// Keeping the old rule would have been the worse half of the bug the move was
/// made to fix. Someone records forty minutes, closes the window, reopens it —
/// the file is safe on disk now, but the only screen that could offer it back
/// deliberately forgot it, so it may as well not be. A recording is the *most*
/// important thing this list can hold, because it is the one entry that exists
/// nowhere else.
///
/// `.file` is remembered by its **original** URL, where the user put it.
/// `.extractedFromLink` and `.systemRecording` are remembered by the durable URL
/// Melo moved them to. `.meloTheme` is not remembered at all — it has a card of
/// its own on the same screen, and a recent row for it would be the same door
/// twice.
///
/// ## Files that have moved
///
/// Filtered out of `visible` rather than deleted from the stored list. A file on
/// an external drive is not gone, it is unplugged, and pruning it on the one
/// launch where the drive was detached would lose it for good.
///
/// ## Nothing here touches the disk on the main thread
///
/// This type is `@MainActor` and every disk call it makes is `Task.detached`.
/// That is not tidiness. `FileManager.fileExists(atPath:)` against a sleeping
/// external drive or a vanished network share blocks for **seconds** while the
/// volume spins up or the mount times out, and this ran once per remembered
/// entry, synchronously, from the window's `onAppear` and from Settings ›
/// Everyday. Melo beachballed. The thread that answers "is that drive awake" is
/// not allowed to be the thread that draws.
///
/// The visible cost is that the list arrives a moment after the window does. It
/// shows exactly what it showed before — the remembered entries whose files are
/// on disk — it just does not make the user wait for the answer.
@MainActor
final class EditorRecents: ObservableObject {
    static let shared = EditorRecents()

    /// Five. Enough to hold a working session, few enough that the list stays a
    /// glance rather than a thing to read.
    static let limit = 5

    /// Everything remembered, newest first, including anything currently
    /// unreachable.
    @Published private(set) var all: [EditorRecent] = []

    /// What the empty state draws: the remembered entries whose files were on
    /// disk the last time `refreshAvailability()` answered.
    ///
    /// Derived, never assigned from outside: `all` filtered by `reachable`.
    /// Two published arrays that have to agree is the defect class this
    /// project's anchor records, so only `republish()` writes it.
    @Published private(set) var visible: [EditorRecent] = []

    /// Whether `EditorSourceStore.directory` holds anything.
    ///
    /// Drives one line on the empty state, and only that line. It is computed
    /// here rather than in a view because this type already makes exactly one
    /// batched trip to disk per window show, and `FileManager` in a `body` runs
    /// as often as SwiftUI feels like evaluating it.
    @Published private(set) var hasKeptSources = false

    private let storeURL: URL
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Melo",
        category: "EditorRecents"
    )

    /// The URLs the last completed availability pass found on disk. Empty until
    /// that pass answers, which is why `visible` starts empty and fills in.
    private var reachable: Set<URL> = []
    /// One pass at a time. Opening the window and opening Settings in the same
    /// second must not queue two sweeps of the same unplugged drive.
    private var availabilityWork: Task<Void, Never>?

    /// - Parameter directory: overridable so the snapshot harness and tests can
    ///   point at a scratch location instead of the user's real list.
    init(directory: URL? = nil) {
        let base = directory ?? Self.defaultBaseDirectory()
        self.storeURL = base.appendingPathComponent("cutting-room-recents.json")
        load()
    }

    /// Mirrors `SettingsManager.defaultBaseDirectory()`, including its refusal to
    /// force-unwrap: `urls(for:in:)` returns an empty array when the domain is
    /// unavailable, and turning that into a launch crash is a defect this
    /// project has already paid for once.
    private static func defaultBaseDirectory() -> URL {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("Melo")
    }

    /// Records a source, if it is one that can be reopened. Re-opening something
    /// already in the list moves it to the front rather than duplicating it.
    func remember(_ source: EditorSource) {
        let kind: EditorRecent.Kind
        let url: URL

        switch source.origin {
        case .file(let originalURL):
            kind = .file
            // Where the user put it, not wherever a copy ended up.
            url = originalURL
        case .extractedFromLink:
            kind = .link
            url = source.url
        case .systemRecording:
            kind = .recording
            url = source.url
        case .meloTheme:
            // Its own card, on the same screen. See the type comment.
            return
        }

        let entry = EditorRecent(
            url: url,
            displayName: source.displayName,
            formatDescription: source.formatDescription,
            duration: source.duration,
            openedAt: Date(),
            kind: kind
        )

        var updated = all.filter { $0.url != url }
        updated.insert(entry, at: 0)
        all = Array(updated.prefix(Self.limit))
        // This file was just opened, so it is reachable — say so now rather
        // than letting the row blink out and back while the sweep runs.
        reachable.insert(url)
        republish()
        refreshAvailability()
        save()
    }

    /// Drops one entry. The file is untouched — this list is a memory of what
    /// was opened, and forgetting is not deleting. Nothing in this type removes
    /// audio from disk, deliberately: see the standing decision recorded in
    /// `EditorSourceStore`.
    func forget(_ recent: EditorRecent) {
        all.removeAll { $0.url == recent.url }
        // Immediately, not after a disk round trip: the row the user just
        // dismissed has to leave the list under their hand.
        republish()
        refreshAvailability()
        save()
    }

    /// Shows one remembered file in Finder.
    func reveal(_ recent: EditorRecent) {
        NSWorkspace.shared.activateFileViewerSelecting([recent.url])
    }

    /// Whether the folder Melo keeps recordings and link audio in holds
    /// anything.
    ///
    /// `static`, because two screens ask and only one of them has a reason to
    /// hold this object. The empty state reads it through `hasKeptSources`,
    /// which is published and refreshed on the same batched disk pass as the
    /// recents filter; Settings › Everyday awaits this directly on appear,
    /// because a Settings tab has no business observing a recents list to find
    /// out whether a folder is empty.
    ///
    /// `async` and off the actor. It was a synchronous `contentsOfDirectory`
    /// read from a view's `onAppear`, which is a directory enumeration on the
    /// thread that draws — see the type comment.
    nonisolated static func keptSourcesExist() async -> Bool {
        await Task.detached(priority: .userInitiated) {
            let contents = (try? FileManager().contentsOfDirectory(
                at: EditorSourceStore.directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? []
            return !contents.isEmpty
        }.value
    }

    /// Opens the folder Melo keeps recordings and link audio in.
    ///
    /// `EditorSourceStore.directory` rather than a path spelled out again here.
    /// A second constant naming the same folder is a second constant to be wrong
    /// on the day the first one moves.
    func revealKeptSources() {
        let directory = EditorSourceStore.directory
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        NSWorkspace.shared.open(directory)
    }

    /// Starts a fresh check of which remembered files are actually reachable,
    /// and returns immediately. Called when the window is about to show rather
    /// than from a view body, because it is disk work and a view body can run
    /// many times a second.
    ///
    /// **Returns before the answer arrives, on purpose.** Each entry costs a
    /// `fileExists`, and one of those against a sleeping external drive or a
    /// dead network share blocks for seconds. `visible` and `hasKeptSources`
    /// update when the disk answers; until then the list shows what the last
    /// pass found, which on a cold start is nothing.
    func refreshAvailability() {
        #if MELO_DEV
        // A pinned fixture outranks everything. The root view calls this on
        // appear, and the seeded entries name files that do not exist, so
        // without this the harness would blank its own fixture — the same
        // failure `EditorStore.setForSnapshot` guards against.
        if snapshotPinned { return }
        #endif
        let entries = all
        availabilityWork?.cancel()
        availabilityWork = Task { [weak self] in
            let found = await Self.reachableURLs(among: entries)
            // Independent of the list above. The folder can hold more than five
            // recordings, or hold one after the list has been forgotten, and the
            // person looking for audio they made is exactly the person for whom
            // those two cases are the same case.
            let kept = await Self.keptSourcesExist()
            guard !Task.isCancelled, let self else { return }
            #if MELO_DEV
            if self.snapshotPinned { return }
            #endif
            self.reachable = found
            self.hasKeptSources = kept
            self.republish()
        }
    }

    /// The one place `visible` is written. `all` is what is remembered,
    /// `reachable` is what the last disk pass found, and `visible` is the
    /// intersection in `all`'s order.
    private func republish() {
        visible = all.filter { reachable.contains($0.url) }
    }

    /// The blocking part, off the actor and off the main thread.
    ///
    /// A fresh `FileManager` rather than `.default`: `.default` is documented
    /// thread-safe for these calls, but the shared instance is reached from the
    /// main actor all over this app and a private one costs nothing.
    private nonisolated static func reachableURLs(among entries: [EditorRecent]) async -> Set<URL> {
        await Task.detached(priority: .userInitiated) {
            let manager = FileManager()
            return Set(
                entries.lazy
                    .filter { manager.fileExists(atPath: $0.url.path) }
                    .map(\.url)
            )
        }.value
    }

    // MARK: - Persistence

    /// Reads the stored list without blocking the caller.
    ///
    /// This is reached from `init`, and `init` is reached the first time a
    /// window or a Settings tab touches `EditorRecents.shared` — which is
    /// during a window show. `Data(contentsOf:)` there is a synchronous read on
    /// the thread that draws, for a list that is a cache. The list appears a
    /// moment later instead.
    private func load() {
        let location = storeURL
        Task { [weak self] in
            let decoded = await Task.detached(priority: .userInitiated) { () -> [EditorRecent]? in
                guard let data = try? Data(contentsOf: location) else { return [] }
                return try? JSONDecoder().decode([EditorRecent].self, from: data)
            }.value

            guard let self else { return }
            #if MELO_DEV
            // A scene may have seeded the list while this was in flight.
            if self.snapshotPinned { return }
            #endif
            if let decoded {
                self.all = Array(decoded.prefix(Self.limit))
            } else {
                // A list that will not decode is a list worth throwing away. It
                // is a cache; the alternative is refusing to remember anything
                // again until someone deletes a file by hand.
                self.logger.warning("Recents list could not be read; starting a new one")
            }
            self.refreshAvailability()
        }
    }

    #if MELO_DEV
    private var snapshotPinned = false

    /// Seeds the list for a snapshot scene, without writing to disk. The empty
    /// state looks materially different with recents above the four cards and
    /// without them, and which one a frame showed would otherwise depend on
    /// whatever the machine running the harness had opened that morning.
    /// - Parameter hasKeptSources: `nil` derives it from the entries, which is
    ///   almost always what a scene means. A fixture holding a recording and a
    ///   link extraction is a fixture in which Melo *is* keeping files, and a
    ///   bare `false` default made the seeded state contradict itself — the
    ///   first empty-state frame listed a recording above a line saying nothing
    ///   was being kept, so the line did not draw at all.
    func setForSnapshot(_ entries: [EditorRecent], hasKeptSources: Bool? = nil) {
        snapshotPinned = true
        availabilityWork?.cancel()
        all = Array(entries.prefix(Self.limit))
        // Through `reachable` rather than assigning `visible`, so the one
        // invariant — visible is all ∩ reachable — holds in the harness too.
        reachable = Set(all.map(\.url))
        republish()
        self.hasKeptSources = hasKeptSources ?? all.contains { $0.kind.isKeptByMelo }
    }
    #endif

    /// Written synchronously, on the main actor, and that is deliberate. This
    /// runs at most once per file opened and writes five short records;
    /// `SettingsManager`'s debounce and serial writer queue exist because it is
    /// written on every slider drag, which is not this.
    private func save() {
        do {
            try FileManager.default.createDirectory(
                at: storeURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try JSONEncoder().encode(all).write(to: storeURL, options: .atomic)
        } catch {
            logger.warning("Could not save the recents list: \(error.localizedDescription, privacy: .public)")
        }
    }
}
