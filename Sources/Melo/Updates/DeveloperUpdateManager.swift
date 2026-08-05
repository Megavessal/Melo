import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

@MainActor
final class DeveloperUpdateManager: ObservableObject {
    /// Developer updates build and install code on this Mac, so they exist only in
    /// developer builds. `MELO_DEV` is set by the Debug configuration and by
    /// `scripts/build-app.sh --dev`; a shipping build compiles the machinery out
    /// entirely rather than merely hiding its UI.
    static var isEnabled: Bool {
        #if MELO_DEV
        return true
        #else
        return false
        #endif
    }

    enum Status: Equatable {
        case idle
        case inspecting(String)
        case noNewerUpdate(String)
        case ready(DeveloperUpdateCandidate)
        case building(DeveloperUpdateCandidate)
        case installing(DeveloperUpdateCandidate)
        case failed(String)
    }

    @Published private(set) var status: Status = .idle
    @Published private(set) var watchedFolderName: String?
    @Published private(set) var lastBuildLogURL: URL?

    @Published var automaticallyChecksFolder: Bool {
        didSet { defaults.set(automaticallyChecksFolder, forKey: Keys.automaticFolderChecks) }
    }

    private enum Keys {
        static let folderBookmark = "developerUpdates.folderBookmark"
        static let automaticFolderChecks = "developerUpdates.automaticFolderChecks"
    }

    private let defaults: UserDefaults
    private let expectedBundleIdentifier: String
    private var activeTask: Task<Void, Never>?
    /// Incremented whenever a new operation starts. A cancelled task can still be
    /// mid-`await` when its replacement begins, and without this it would overwrite
    /// the newer operation's status with a stale one.
    private var generation = 0
    private var started = false

    init(defaults: UserDefaults = .standard, bundle: Bundle = .main) {
        self.defaults = defaults
        expectedBundleIdentifier = bundle.bundleIdentifier ?? "dev.local.Melo"
        automaticallyChecksFolder = defaults.object(forKey: Keys.automaticFolderChecks) as? Bool ?? false
        refreshFolderName()
    }

    func start() {
        guard Self.isEnabled, !started else { return }
        started = true
        if automaticallyChecksFolder, watchedFolderName != nil {
            checkRememberedFolder()
        }
    }

    // MARK: - Entry points

    func chooseUpdateFile() {
        guard Self.isEnabled else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose a Melo Developer Update"
        panel.message = "Choose a trusted Melo source or app update ZIP."
        panel.prompt = "Choose Update"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.zip]

        guard panel.runModal() == .OK, let url = panel.url else { return }
        inspectArchive(url, deleteAfterInstall: false)
    }

    func chooseFolderToCheck() {
        guard Self.isEnabled else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose a Melo Update Folder"
        panel.message = "Melo can remember this folder and look for its highest valid update build."
        panel.prompt = "Remember Folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let bookmark = try UpdateFolderBookmark.create(for: url)
            defaults.set(bookmark, forKey: Keys.folderBookmark)
            watchedFolderName = url.lastPathComponent
            checkRememberedFolder()
        } catch {
            status = .failed("Melo could not remember that folder.")
        }
    }

    func forgetFolder() {
        defaults.removeObject(forKey: Keys.folderBookmark)
        watchedFolderName = nil
        automaticallyChecksFolder = false
        if case .noNewerUpdate = status { status = .idle }
    }

    func checkRememberedFolder() {
        guard Self.isEnabled else { return }
        guard let bookmark = defaults.data(forKey: Keys.folderBookmark) else {
            status = .failed("Choose an update folder first.")
            return
        }

        let token = beginOperation()
        status = .inspecting(watchedFolderName ?? "folder")
        activeTask = Task { [weak self] in
            guard let self else { return }
            do {
                let folderURL = try UpdateFolderBookmark.resolve(bookmark)
                let didAccess = folderURL.startAccessingSecurityScopedResource()
                defer { if didAccess { folderURL.stopAccessingSecurityScopedResource() } }

                let bundleID = expectedBundleIdentifier
                // scanFolder collects its own per-archive failures rather than
                // throwing, so this detached task cannot throw.
                let scan = await Task.detached(priority: .utility) {
                    Self.scanFolder(folderURL, expectedBundleIdentifier: bundleID)
                }.value

                if let candidate = scan.best {
                    set(.ready(candidate), token)
                } else {
                    set(.noNewerUpdate(scan.summary), token)
                }
            } catch is CancellationError {
                set(.idle, token)
            } catch {
                set(.failed(Self.message(for: error)), token)
            }
        }
    }

    func buildAndInstallReadyUpdate() {
        guard Self.isEnabled, case let .ready(candidate) = status else { return }
        let token = beginOperation()
        lastBuildLogURL = nil
        status = .building(candidate)

        activeTask = Task { [weak self] in
            guard let self else { return }
            do {
                let workspace = try Self.workspaceDirectory(prefix: "build-\(candidate.manifest.build)")
                let logDirectory = try Self.logDirectory()
                let bundleID = expectedBundleIdentifier

                let result = try await Task.detached(priority: .userInitiated) {
                    let inspection = try UpdatePackageValidator.inspect(
                        archiveURL: candidate.archiveURL,
                        workspace: workspace,
                        expectedBundleIdentifier: bundleID
                    )
                    return try UpdateBuildCoordinator.prepare(
                        inspection: inspection,
                        logDirectory: logDirectory
                    )
                }.value

                guard generation == token else { return }
                lastBuildLogURL = result.logURL
                status = .installing(candidate)
                try UpdateInstallationCoordinator.install(
                    appURL: result.appURL,
                    manifest: candidate.manifest,
                    cleanupDirectory: workspace,
                    archiveToDelete: candidate.deleteArchiveAfterInstall ? candidate.archiveURL : nil
                )
            } catch is CancellationError {
                set(.idle, token)
            } catch DeveloperUpdateError.buildFailed(let logURL) {
                guard generation == token else { return }
                lastBuildLogURL = logURL
                status = .failed(DeveloperUpdateError.buildFailed(logURL: logURL).localizedDescription)
            } catch {
                set(.failed(Self.message(for: error)), token)
            }
        }
    }

    func revealLastBuildLog() {
        guard let lastBuildLogURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([lastBuildLogURL])
    }

    func cancel() {
        _ = beginOperation()
        activeTask = nil
        status = .idle
    }

    // MARK: - Operation bookkeeping

    private func beginOperation() -> Int {
        activeTask?.cancel()
        generation += 1
        return generation
    }

    private func set(_ newStatus: Status, _ token: Int) {
        guard generation == token else { return }
        status = newStatus
    }

    // MARK: - Inspection

    private func inspectArchive(_ url: URL, deleteAfterInstall: Bool) {
        let token = beginOperation()
        status = .inspecting(url.lastPathComponent)
        activeTask = Task { [weak self] in
            await self?.inspectArchiveAsync(url, deleteAfterInstall: deleteAfterInstall, token: token)
        }
    }

    private func inspectArchiveAsync(_ url: URL, deleteAfterInstall: Bool, token: Int) async {
        do {
            let workspace = try Self.workspaceDirectory(prefix: "inspect")
            defer { try? FileManager.default.removeItem(at: workspace) }
            let bundleID = expectedBundleIdentifier
            let manifest = try await Task.detached(priority: .utility) {
                try UpdatePackageValidator.inspect(
                    archiveURL: url,
                    workspace: workspace,
                    expectedBundleIdentifier: bundleID
                ).manifest
            }.value
            set(
                .ready(
                    DeveloperUpdateCandidate(
                        manifest: manifest,
                        archiveURL: url,
                        deleteArchiveAfterInstall: deleteAfterInstall
                    )
                ),
                token
            )
        } catch is CancellationError {
            set(.idle, token)
        } catch {
            set(.failed(Self.message(for: error)), token)
        }
    }

    private func refreshFolderName() {
        guard let bookmark = defaults.data(forKey: Keys.folderBookmark),
              let url = try? UpdateFolderBookmark.resolve(bookmark) else {
            watchedFolderName = nil
            return
        }
        watchedFolderName = url.lastPathComponent
    }

    // MARK: - Folder scanning

    nonisolated private struct FolderScan: Sendable {
        let best: DeveloperUpdateCandidate?
        let summary: String
    }

    /// Reads each archive's manifest without extracting it, and explains what it
    /// skipped. "No newer build" with no reason was the most common dead end here —
    /// a folder full of valid-but-older builds looked identical to a folder of
    /// broken ones, and every check re-extracted every ZIP in full.
    nonisolated private static func scanFolder(
        _ folderURL: URL,
        expectedBundleIdentifier: String
    ) -> FolderScan {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        let archives = files.filter { $0.pathExtension.lowercased() == "zip" }

        guard !archives.isEmpty else {
            return FolderScan(best: nil, summary: "That folder does not contain any ZIP archives.")
        }

        var best: DeveloperUpdateCandidate?
        var skipped: [String] = []

        for archive in archives {
            do {
                let manifest = try UpdatePackageValidator.peekManifest(archiveURL: archive)
                try UpdatePackageValidator.validate(
                    manifest: manifest,
                    expectedBundleIdentifier: expectedBundleIdentifier,
                    requireNewerBuild: true
                )
                let candidate = DeveloperUpdateCandidate(
                    manifest: manifest,
                    archiveURL: archive,
                    deleteArchiveAfterInstall: false
                )
                if let current = best {
                    if manifest.build > current.manifest.build { best = candidate }
                } else {
                    best = candidate
                }
            } catch {
                let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                skipped.append("\(archive.lastPathComponent): \(reason)")
            }
        }

        if best != nil {
            return FolderScan(best: best, summary: "")
        }

        let counted = "Melo checked \(archives.count) archive\(archives.count == 1 ? "" : "s")."
        guard !skipped.isEmpty else {
            return FolderScan(best: nil, summary: counted)
        }
        let detail = skipped.prefix(4).joined(separator: "\n")
        let more = skipped.count > 4 ? "\nand \(skipped.count - 4) more." : ""
        return FolderScan(best: nil, summary: counted + "\n" + detail + more)
    }

    // MARK: - Storage

    nonisolated private static func baseDirectory() throws -> URL {
        try UpdateStartupConfirmation.updateStorageDirectory()
            .appendingPathComponent("Developer", isDirectory: true)
    }

    nonisolated private static func workspaceDirectory(prefix: String) throws -> URL {
        let base = try baseDirectory().appendingPathComponent("Workspaces", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    }

    nonisolated private static func logDirectory() throws -> URL {
        let directory = try baseDirectory().appendingPathComponent("Build Logs", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    nonisolated private static func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
