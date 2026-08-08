import AppKit
import SwiftUI
import os

/// Offers to move Melo into the Applications folder when it is running from
/// somewhere else — a Downloads folder, a disk image, or the build output folder.
///
/// This matters more for Melo than for most apps. The in-app updater replaces the
/// running bundle in place, and it refuses to do so unless the *containing folder*
/// is writable and stable. An app left in `~/Downloads` also gets quarantined and
/// app-translocated by Gatekeeper, which puts it on a read-only random mount where
/// no update can ever land. Getting Melo into `/Applications` once removes a whole
/// class of update failures.
///
/// The offer is repeated after an update because an update preserves the app's
/// location: if it was in the wrong place before, it still is.
@MainActor
final class InstallLocationCoordinator {
    private static let logger = Logger(subsystem: "io.github.megavessal.Melo", category: "InstallLocation")

    private enum Keys {
        /// Stores the build the user last dismissed, so "Not Now" is honoured for
        /// this version but the offer returns after an update.
        static let deferredBuild = "installLocation.deferredForBuild"
    }

    private let defaults: UserDefaults
    private var window: NSWindow?
    private var closeObserver: InstallLocationWindowCloseObserver?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Where are we?

    static var currentBuild: Int {
        Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0") ?? 0
    }

    /// Gatekeeper runs quarantined apps from a read-only shadow mount. The bundle
    /// path looks normal to most code but nothing can be written next to it, so the
    /// updater can never work from here.
    static var isTranslocated: Bool {
        Bundle.main.bundleURL.path.contains("/AppTranslocation/")
    }

    static var isInApplicationsFolder: Bool {
        let path = Bundle.main.bundleURL.resolvingSymlinksInPath().path
        let userApplications = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Applications", isDirectory: true)
            .resolvingSymlinksInPath()
            .path
        return path.hasPrefix("/Applications/") || path.hasPrefix(userApplications + "/")
    }

    /// Prefers the system folder and falls back to the per-user one, which needs no
    /// administrator rights. Returning nil means neither is usable.
    static func preferredDestinationDirectory() -> URL? {
        let system = URL(fileURLWithPath: "/Applications", isDirectory: true)
        if FileManager.default.isWritableFile(atPath: system.path) { return system }

        let user = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Applications", isDirectory: true)
        if !FileManager.default.fileExists(atPath: user.path) {
            try? FileManager.default.createDirectory(at: user, withIntermediateDirectories: true)
        }
        if FileManager.default.isWritableFile(atPath: user.path) { return user }
        return nil
    }

    // MARK: - Presentation

    func showIfNeeded() {
        #if MELO_DEV
        // A developer build runs from the project's outputs folder by design.
        // Prompting there would fire after every single build and would move the
        // binary out from under the build-and-test loop.
        return
        #else
        guard !Self.isInApplicationsFolder else { return }
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }

        // Translocation is the one case worth interrupting for even if dismissed,
        // because nothing about updating or relaunching works from that mount.
        if !Self.isTranslocated {
            let deferred = defaults.integer(forKey: Keys.deferredBuild)
            guard deferred != Self.currentBuild else { return }
        }

        show()
        #endif
    }

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 380),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Move Melo to Applications"
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.center()

        let view = MoveToApplicationsView(
            destinationName: Self.preferredDestinationDirectory()?.lastPathComponent ?? "Applications",
            isTranslocated: Self.isTranslocated,
            onMove: { [weak self] in self?.moveToApplications() },
            onDismiss: { [weak self] in self?.dismiss(remembering: true) }
        )
        window.contentViewController = NSHostingController(rootView: view)
        window.isReleasedWhenClosed = false

        let observer = InstallLocationWindowCloseObserver { [weak self] in
            self?.rememberDismissal()
        }
        window.delegate = observer
        closeObserver = observer

        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func dismiss(remembering: Bool) {
        if remembering { rememberDismissal() }
        window?.close()
    }

    private func rememberDismissal() {
        defaults.set(Self.currentBuild, forKey: Keys.deferredBuild)
    }

    // MARK: - The move

    /// Copies the bundle into place first, while the app is still running and the
    /// source is guaranteed readable, then hands the swap and relaunch to a short
    /// script. Same shape as the update installer, and for the same reason: a
    /// running bundle must never be the thing being moved.
    private func moveToApplications() {
        guard let directory = Self.preferredDestinationDirectory() else {
            presentFailure("Melo could not write to your Applications folder.")
            return
        }

        let source = Bundle.main.bundleURL
        let destination = directory.appendingPathComponent("Melo.app", isDirectory: true)
        let incoming = directory.appendingPathComponent("Melo.incoming.app", isDirectory: true)

        do {
            try? FileManager.default.removeItem(at: incoming)
            try UpdatePackageValidator.run("/usr/bin/ditto", arguments: [source.path, incoming.path])
        } catch {
            try? FileManager.default.removeItem(at: incoming)
            presentFailure("Melo could not be copied to \(directory.lastPathComponent). \(Self.describe(error))")
            return
        }

        // Only remove the original when it is genuinely ours to remove. A
        // translocated mount is read-only, and a copy on a disk image is not the
        // user's to delete.
        let removeSource = !Self.isTranslocated
            && FileManager.default.isWritableFile(atPath: source.deletingLastPathComponent().path)

        do {
            let scriptURL = try Self.scriptURL()
            let logPath = try Self.logURL().path
            let script = Self.moveScript(
                oldPID: ProcessInfo.processInfo.processIdentifier,
                sourcePath: removeSource ? source.path : "",
                incomingPath: incoming.path,
                destinationPath: destination.path,
                logPath: logPath
            )
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: scriptURL.path
            )

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = [scriptURL.path]
            try process.run()
        } catch {
            try? FileManager.default.removeItem(at: incoming)
            presentFailure("Melo could not finish moving itself. \(Self.describe(error))")
            return
        }

        // The relaunch is the new copy's job; guarantee this one goes away so the
        // script is never left waiting on a process that refused to quit.
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { exit(0) }
        NSApplication.shared.terminate(nil)
    }

    private func presentFailure(_ message: String) {
        Self.logger.error("Move to Applications failed: \(message, privacy: .public)")
        let alert = NSAlert()
        alert.messageText = "Melo couldn’t move itself"
        alert.informativeText = message + "\n\nYou can drag Melo to your Applications folder in the Finder instead."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        if let window {
            alert.beginSheetModal(for: window, completionHandler: nil)
        } else {
            alert.runModal()
        }
    }

    private static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    private static func supportDirectory() throws -> URL {
        try UpdateStartupConfirmation.updateStorageDirectory()
    }

    private static func scriptURL() throws -> URL {
        try supportDirectory().appendingPathComponent("move-to-applications.sh")
    }

    private static func logURL() throws -> URL {
        try supportDirectory().appendingPathComponent("move-to-applications.log")
    }

    private static func moveScript(
        oldPID: Int32,
        sourcePath: String,
        incomingPath: String,
        destinationPath: String,
        logPath: String
    ) -> String {
        """
        #!/bin/zsh
        set -u
        exec >> \(quote(logPath)) 2>&1
        echo "=== Move Melo to Applications — $(date) ==="

        OLD_PID=\(oldPID)
        SOURCE=\(quote(sourcePath))
        INCOMING=\(quote(incomingPath))
        DESTINATION=\(quote(destinationPath))
        LSREG=/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister

        for i in {1..240}; do
          kill -0 "$OLD_PID" 2>/dev/null || break
          sleep 0.25
        done
        if kill -0 "$OLD_PID" 2>/dev/null; then
          echo "Melo is still running; leaving everything as it was"
          rm -rf "$INCOMING"
          exit 3
        fi

        if [[ ! -d "$INCOMING" ]]; then
          echo "Staged copy is missing; nothing was changed"
          exit 1
        fi

        rm -rf "$DESTINATION"
        if ! mv "$INCOMING" "$DESTINATION"; then
          echo "Could not put Melo in place"
          rm -rf "$INCOMING"
          exit 1
        fi

        xattr -cr "$DESTINATION" 2>/dev/null || true
        [[ -x "$LSREG" ]] && "$LSREG" -f "$DESTINATION" 2>/dev/null

        # Remove the old copy only after the new one is verifiably in place.
        if [[ -n "$SOURCE" && -d "$SOURCE" && "$SOURCE" != "$DESTINATION" ]]; then
          rm -rf "$SOURCE"
        fi

        /usr/bin/open -n "$DESTINATION"
        rm -f "$0"
        exit 0
        """
    }

    private static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// Closing the window with the title-bar button means the same thing as Not Now.
@MainActor
private final class InstallLocationWindowCloseObserver: NSObject, NSWindowDelegate {
    let onClose: () -> Void

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }
}
