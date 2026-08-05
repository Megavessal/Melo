import AppKit
import Foundation

nonisolated enum UpdateStartupConfirmation {
    /// Passed to a staged bundle so the installer can prove it launches *before*
    /// the running copy is replaced. Handled as the very first thing the app does.
    static let preflightArgument = "--melo-preflight"

    static func markerURL(for build: Int) throws -> URL {
        try updateStorageDirectory()
            .appendingPathComponent("startup-\(build).ok", isDirectory: false)
    }

    /// One-time value the installer writes before relaunching. The new build echoes
    /// it into the marker, which proves *this* bundle started rather than a leftover
    /// copy or a rolled-back version that happens to share a build number.
    static func tokenURL(for build: Int) throws -> URL {
        try updateStorageDirectory()
            .appendingPathComponent("startup-\(build).token", isDirectory: false)
    }

    /// Must run before any UI, audio, permission, or framework work. A bundle that
    /// cannot link — the classic "Sparkle.framework was never embedded" failure —
    /// dies in dyld before reaching this point and exits non-zero, which is exactly
    /// the signal the installer is looking for.
    static func handlePreflightAndExitIfNeeded() {
        guard CommandLine.arguments.contains(preflightArgument) else { return }
        exit(0)
    }

    static func confirmCurrentBuild() {
        let build = Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0") ?? 0
        guard build > 0, let marker = try? markerURL(for: build) else { return }

        var payload = "Melo build \(build) launched at \(Date().ISO8601Format())"
        if let tokenURL = try? tokenURL(for: build),
           let token = try? String(contentsOf: tokenURL, encoding: .utf8) {
            payload = token.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        try? (payload + "\n").write(to: marker, atomically: true, encoding: .utf8)
    }

    static func updateStorageDirectory() throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = support.appendingPathComponent("Melo/Updates", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

@MainActor
enum UpdateInstallationCoordinator {
    /// Seconds the installer waits for the running copy to exit before giving up.
    /// It never moves a live bundle: doing so leaves Launch Services pointing at a
    /// path the process no longer occupies, which is what made updates reopen the
    /// old version and then roll back.
    private static let quitTimeoutSeconds = 60.0
    /// Seconds the new build has to confirm startup before it is rolled back.
    private static let confirmTimeoutSeconds = 150.0
    private static let preflightTimeoutSeconds = 20.0

    static func install(
        appURL: URL,
        manifest: DeveloperUpdateManifest,
        cleanupDirectory: URL?,
        archiveToDelete: URL?
    ) throws {
        let currentApp = Bundle.main.bundleURL
        guard currentApp.pathExtension == "app" else {
            throw DeveloperUpdateError.installationUnavailable
        }
        let parent = currentApp.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parent.path) else {
            throw DeveloperUpdateError.installationUnavailable
        }

        let storage = try UpdateStartupConfirmation.updateStorageDirectory()
        let installRoot = storage.appendingPathComponent("install-\(manifest.build)", isDirectory: true)
        try? FileManager.default.removeItem(at: installRoot)
        try FileManager.default.createDirectory(at: installRoot, withIntermediateDirectories: true)

        // Stage beside the current app so the swap is two atomic renames on one
        // volume rather than a copy that can fail halfway and leave no app at all.
        let incoming = parent.appendingPathComponent("Melo.incoming.app", isDirectory: true)
        try? FileManager.default.removeItem(at: incoming)
        try UpdatePackageValidator.run("/usr/bin/ditto", arguments: [appURL.path, incoming.path])

        do {
            try UpdatePackageValidator.validateBuiltApp(incoming, manifest: manifest)
            try preflight(incoming)
        } catch {
            try? FileManager.default.removeItem(at: incoming)
            try? FileManager.default.removeItem(at: installRoot)
            throw error
        }

        let token = UUID().uuidString
        let tokenURL = try UpdateStartupConfirmation.tokenURL(for: manifest.build)
        try (token + "\n").write(to: tokenURL, atomically: true, encoding: .utf8)

        let marker = try UpdateStartupConfirmation.markerURL(for: manifest.build)
        try? FileManager.default.removeItem(at: marker)

        let backup = parent.appendingPathComponent("Melo.previous.app", isDirectory: true)
        let scriptURL = storage.appendingPathComponent("install-developer-update-\(manifest.build).sh")
        let logURL = storage.appendingPathComponent("install-developer-update-\(manifest.build).log")

        let script = swapScript(
            version: manifest.version,
            build: manifest.build,
            oldPID: ProcessInfo.processInfo.processIdentifier,
            logPath: logURL.path,
            currentPath: currentApp.path,
            incomingPath: incoming.path,
            backupPath: backup.path,
            markerPath: marker.path,
            tokenPath: tokenURL.path,
            installRootPath: installRoot.path,
            cleanupPath: cleanupDirectory?.path ?? "",
            archivePath: archiveToDelete?.path ?? ""
        )

        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [scriptURL.path]
        try process.run()

        // A vetoed or stalled termination would leave the installer waiting and then
        // aborting, so guarantee the process actually goes away.
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { exit(0) }
        NSApplication.shared.terminate(nil)
    }

    // MARK: - Preflight

    /// Launches the staged binary with `--melo-preflight` and requires a clean exit.
    /// This is the single highest-value reliability check: a bundle missing an
    /// embedded framework, built for the wrong architecture, or otherwise unable to
    /// start fails here — while the working copy is still untouched — instead of
    /// after the swap, where the only recovery was a slow rollback.
    private static func preflight(_ stagedApp: URL) throws {
        let executableName = (Bundle(url: stagedApp)?
            .object(forInfoDictionaryKey: "CFBundleExecutable") as? String) ?? "Melo"
        let binary = stagedApp.appendingPathComponent("Contents/MacOS/\(executableName)")
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            throw DeveloperUpdateError.preflightFailed("it has no runnable Melo binary")
        }

        let process = Process()
        process.executableURL = binary
        process.arguments = [UpdateStartupConfirmation.preflightArgument]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            throw DeveloperUpdateError.preflightFailed(error.localizedDescription)
        }

        let deadline = Date().addingTimeInterval(preflightTimeoutSeconds)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            throw DeveloperUpdateError.preflightFailed("it did not finish starting up")
        }

        guard process.terminationStatus == 0 else {
            let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw DeveloperUpdateError.preflightFailed(summarize(output))
        }
    }

    private static func summarize(_ output: String) -> String {
        let notable = output
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter {
                $0.contains("Library not loaded")
                    || $0.hasPrefix("Reason:")
                    || $0.contains("no suitable image found")
                    || $0.contains("bad CPU type")
            }
        if let first = notable.first { return String(first.prefix(240)) }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "it could not start on this Mac" : String(trimmed.prefix(240))
    }

    // MARK: - Swap script

    private static func swapScript(
        version: String,
        build: Int,
        oldPID: Int32,
        logPath: String,
        currentPath: String,
        incomingPath: String,
        backupPath: String,
        markerPath: String,
        tokenPath: String,
        installRootPath: String,
        cleanupPath: String,
        archivePath: String
    ) -> String {
        let quitTicks = Int(quitTimeoutSeconds / 0.25)
        let confirmTicks = Int(confirmTimeoutSeconds / 0.25)

        return """
        #!/bin/zsh
        set -u
        exec >> \(shellQuote(logPath)) 2>&1
        echo "=== Melo \(version) (build \(build)) — $(date) ==="

        OLD_PID=\(oldPID)
        CURRENT=\(shellQuote(currentPath))
        INCOMING=\(shellQuote(incomingPath))
        BACKUP=\(shellQuote(backupPath))
        MARKER=\(shellQuote(markerPath))
        TOKEN=\(shellQuote(tokenPath))
        INSTALL_ROOT=\(shellQuote(installRootPath))
        CLEANUP=\(shellQuote(cleanupPath))
        ARCHIVE=\(shellQuote(archivePath))
        LSREG=/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister

        # 1. Never touch a live bundle. Moving a running .app leaves Launch Services
        #    pointing at a path the process no longer occupies, so `open` reactivates
        #    the old copy, the new build never starts, and the update "fails".
        for i in {1..\(quitTicks)}; do
          kill -0 "$OLD_PID" 2>/dev/null || break
          sleep 0.25
        done
        if kill -0 "$OLD_PID" 2>/dev/null; then
          echo "Previous Melo (pid $OLD_PID) is still running; aborting with nothing changed"
          rm -rf "$INCOMING"
          rm -f "$TOKEN"
          exit 3
        fi

        if [[ ! -d "$INCOMING" ]]; then
          echo "Staged update is missing; nothing was changed"
          rm -f "$TOKEN"
          exit 1
        fi

        rm -rf "$BACKUP"
        rm -f "$MARKER"

        # 2. Two atomic renames on one volume — at no point is there no Melo.app.
        if ! mv "$CURRENT" "$BACKUP"; then
          echo "Could not move the current Melo aside"
          rm -rf "$INCOMING"
          rm -f "$TOKEN"
          exit 1
        fi
        if ! mv "$INCOMING" "$CURRENT"; then
          echo "Could not move the update into place; restoring the previous version"
          mv "$BACKUP" "$CURRENT"
          [[ -x "$LSREG" ]] && "$LSREG" -f "$CURRENT" 2>/dev/null
          /usr/bin/open -n "$CURRENT"
          rm -f "$TOKEN"
          exit 1
        fi

        xattr -cr "$CURRENT" 2>/dev/null || true

        # 3. Refresh the Launch Services record. A stale one is the difference between
        #    launching the new bundle and silently reopening the cached old one.
        [[ -x "$LSREG" ]] && "$LSREG" -f "$CURRENT" 2>/dev/null

        EXPECTED=$(cat "$TOKEN" 2>/dev/null | tr -d '[:space:]')
        /usr/bin/open -n "$CURRENT" || echo "open reported a failure; still waiting for startup"

        # 4. The new build echoes the one-time token, which a leftover or rolled-back
        #    copy sharing a build number cannot do.
        for i in {1..\(confirmTicks)}; do
          if [[ -f "$MARKER" ]]; then
            GOT=$(cat "$MARKER" 2>/dev/null | tr -d '[:space:]')
            if [[ "$GOT" == "$EXPECTED" ]]; then
              echo "New Melo build confirmed startup"
              rm -rf "$BACKUP"
              rm -rf "$INSTALL_ROOT"
              rm -f "$TOKEN"
              if [[ -n "$CLEANUP" ]]; then rm -rf "$CLEANUP"; fi
              if [[ -n "$ARCHIVE" ]]; then rm -f "$ARCHIVE"; fi
              rm -f "$0"
              exit 0
            fi
          fi
          sleep 0.25
        done

        echo "New Melo build did not confirm startup; rolling back"
        /usr/bin/pkill -x Melo 2>/dev/null || true
        sleep 1.5
        rm -rf "$CURRENT"
        mv "$BACKUP" "$CURRENT"
        [[ -x "$LSREG" ]] && "$LSREG" -f "$CURRENT" 2>/dev/null
        /usr/bin/open -n "$CURRENT"
        rm -rf "$INSTALL_ROOT"
        rm -f "$TOKEN"
        if [[ -n "$CLEANUP" ]]; then rm -rf "$CLEANUP"; fi
        exit 2
        """
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
