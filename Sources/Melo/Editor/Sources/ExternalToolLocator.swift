// Melo/Editor/Sources/ExternalToolLocator.swift
import Foundation
import Synchronization
import os

/// Finds `yt-dlp` and `ffmpeg` on the user's machine.
///
/// Melo detects these and never bundles them: both need updating every few weeks,
/// both carry their own licences, and a stale bundled copy is a broken feature that
/// looks installed.
///
/// The search order matters more than it looks. An app launched from Finder gets a
/// minimal `PATH` — `/usr/bin:/bin:/usr/sbin:/sbin` — which contains neither Homebrew
/// prefix, so a `PATH`-only lookup finds nothing for most people who have the tool.
/// The explicit prefixes below are the actual hit list.
enum ExternalToolLocator {
    private static let logger = Logger(subsystem: "io.github.megavessal.Melo", category: "ExternalTools")

    /// Positive results only. A miss is never cached, because the common case is
    /// that someone reads the install hint, runs `brew install`, and comes straight
    /// back to the same sheet — the next lookup has to see the new binary.
    private static let cache = Mutex<[String: URL]>([:])

    /// Homebrew on Apple silicon, Homebrew on Intel, MacPorts, and the `~/.local/bin`
    /// that `pipx install yt-dlp` and `pip install --user` write to.
    static var wellKnownDirectories: [String] {
        [
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "/usr/local/sbin",
            "/opt/local/bin",
            "/opt/local/sbin",
            "/usr/bin",
            (NSHomeDirectory() as NSString).appendingPathComponent(".local/bin")
        ]
    }

    // MARK: - Locating

    /// The absolute path to `tool`, or nil when it is not installed.
    static func locate(_ tool: ExternalTool) -> URL? {
        let key = tool.rawValue

        if let cached = cache.withLock({ $0[key] }) {
            // Re-validate rather than trust: `brew uninstall` during a session is
            // rarer than `brew install`, but a stale hit would spawn a dead path.
            if isRunnable(cached) { return cached }
            cache.withLock { $0[key] = nil }
        }

        guard let found = search(for: tool.executableName) else {
            logger.info("\(tool.executableName, privacy: .public) not found on this machine")
            return nil
        }

        cache.withLock { $0[key] = found }
        logger.info("Found \(tool.executableName, privacy: .public) at \(found.path, privacy: .public)")
        return found
    }

    /// Search order, in one place so it can be read: `PATH` first, because someone
    /// who has deliberately put a build on their `PATH` means it; then the prefixes.
    static func searchDirectories() -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []

        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for entry in path.split(separator: ":", omittingEmptySubsequences: true) {
            let directory = String(entry)
            if seen.insert(directory).inserted { ordered.append(directory) }
        }
        for directory in wellKnownDirectories where seen.insert(directory).inserted {
            ordered.append(directory)
        }
        return ordered
    }

    private static func search(for executableName: String) -> URL? {
        for directory in searchDirectories() {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent(executableName)
            if isRunnable(candidate) { return candidate.resolvingSymlinksInPath() }
        }
        return nil
    }

    private static func isRunnable(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else { return false }
        return FileManager.default.isExecutableFile(atPath: url.path)
    }

    // MARK: - Version

    /// What the UI says it found: `"2025.06.09"` for yt-dlp, `"7.1.1"` for ffmpeg.
    /// Nil when the tool is absent or answered with something unreadable — never a
    /// guess, because "yt-dlp is too old for this site" is a real error state and a
    /// made-up version would send someone chasing the wrong fix.
    static func version(
        of tool: ExternalTool,
        runner: any ToolProcessRunning = SystemToolProcessRunner()
    ) async -> String? {
        guard let executable = locate(tool) else { return nil }
        guard let result = try? await runner.run(
            executable: executable,
            arguments: versionArguments(for: tool),
            workingDirectory: nil,
            onLine: nil
        ), result.didSucceed else { return nil }

        return parseVersion(result.standardOutput, of: tool)
    }

    static func versionArguments(for tool: ExternalTool) -> [String] {
        switch tool {
        case .ytdlp: return ["--version"]
        case .ffmpeg: return ["-version"]
        }
    }

    /// yt-dlp prints a bare date-version on one line. ffmpeg prints a paragraph whose
    /// first line is `ffmpeg version 7.1.1 Copyright (c) …`; only the number is useful.
    static func parseVersion(_ output: String, of tool: ExternalTool) -> String? {
        guard let firstLine = output
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first?
            .trimmingCharacters(in: .whitespaces),
            !firstLine.isEmpty else { return nil }

        switch tool {
        case .ytdlp:
            return firstLine
        case .ffmpeg:
            let words = firstLine.split(separator: " ")
            guard let versionIndex = words.firstIndex(of: "version"),
                  words.index(after: versionIndex) < words.endIndex else { return firstLine }
            return String(words[words.index(after: versionIndex)])
        }
    }
}
