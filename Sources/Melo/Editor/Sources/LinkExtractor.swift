// Melo/Editor/Sources/LinkExtractor.swift
import Foundation

// MARK: - What we learned about the page

/// What `yt-dlp` can tell us about a link before anything is downloaded, so the
/// user can confirm they got the right thing rather than watch a progress bar and
/// find out afterwards.
struct LinkPreview: Sendable, Equatable {
    var title: String
    var siteName: String
    var uploader: String?
    var duration: TimeInterval?
    /// A local file `yt-dlp` wrote. Nil when the site offered none, when the second
    /// call failed, or when the user is offline — always optional, never load-bearing.
    var thumbnailFileURL: URL?
    var isLive: Bool
}

/// The finished download. `fileURL` is inside a scratch directory this type used
/// to also carry; nothing read it, and Melo does not delete the user's audio
/// (see `CLAUDE.md`, "What this project deliberately does not do"), so the
/// caller has no use for the enclosing folder.
struct ExtractedAudio: Sendable, Equatable {
    var fileURL: URL
    var pageURL: URL
    var siteName: String
    /// The title, cleaned for display. No extension, matching `EditorSource.displayName`.
    var displayName: String
}

/// A progress report shaped to become a `JobProgress` without translation.
struct LinkExtractionUpdate: Sendable, Equatable {
    var fraction: Double?
    var stage: String
    var detail: String?
}

// MARK: - Failures

/// Only the failures that actually happen. Each one says what a person can do next,
/// because "extraction failed (exit 1)" is the same as no message at all.
enum LinkExtractionFailure: LocalizedError, Equatable {
    case toolMissing(ExternalTool)
    case notAWebLink
    case unavailable
    case signInRequired
    case geoBlocked
    case toolOutdated
    case unsupportedSite
    case noNetwork
    case noFormatAvailable
    case nothingDownloaded
    case needsFFmpeg(fileExtension: String)
    case cancelled
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .toolMissing(let tool):
            return "\(tool.missingDescription) \(tool.missingRecovery)"
        case .notAWebLink:
            return "That isn't a web link. Paste the page address you'd open in a browser."
        case .unavailable:
            return "The site won't serve that one — it's private, removed, or age-gated."
        case .signInRequired:
            return "The site wants a signed-in account for this. Melo can't sign in for you."
        case .geoBlocked:
            return "The site blocks this one in your region."
        case .toolOutdated:
            return "yt-dlp is too old for this site. Update it with brew upgrade yt-dlp."
        case .unsupportedSite:
            return "yt-dlp doesn't know this site."
        case .noNetwork:
            return "No connection. Melo couldn't reach the site."
        case .noFormatAvailable:
            return "There's no audio on that page that Melo can take."
        case .nothingDownloaded:
            return "yt-dlp finished but left no audio behind."
        case .needsFFmpeg(let fileExtension):
            // Melo ships ffmpeg, so reaching this means the app is missing the
            // copy it was built with — not that the user is missing a tool.
            return "That came down as .\(fileExtension), and Melo's own ffmpeg isn't there to convert it. Reinstalling Melo puts it back."
        case .cancelled:
            return "Stopped."
        case .failed(let message):
            return message
        }
    }
}

// MARK: - The extractor

/// Runs `yt-dlp` to pull the audio out of a page.
///
/// Arguments are always an array. The user's URL is never interpolated into a string
/// and is always preceded by `--`, so a link that begins with a dash cannot be read
/// as a flag. There is no shell anywhere in this file.
struct LinkExtractor: Sendable {
    let runner: any ToolProcessRunning
    let locate: @Sendable (ExternalTool) -> URL?

    init(
        runner: any ToolProcessRunning = SystemToolProcessRunner(),
        locate: @escaping @Sendable (ExternalTool) -> URL? = { ExternalToolLocator.locate($0) }
    ) {
        self.runner = runner
        self.locate = locate
    }

    // MARK: Preview

    /// Asks `yt-dlp` what is on the page without downloading it.
    func preview(_ pageURL: URL) async throws -> LinkPreview {
        guard Self.isWebLink(pageURL) else { throw LinkExtractionFailure.notAWebLink }
        guard let ytdlp = locate(.ytdlp) else { throw LinkExtractionFailure.toolMissing(.ytdlp) }

        let result: ToolProcessResult
        do {
            result = try await runner.run(
                executable: ytdlp,
                arguments: Self.previewArguments(for: pageURL),
                workingDirectory: nil,
                onLine: nil
            )
        } catch is CancellationError {
            throw LinkExtractionFailure.cancelled
        } catch {
            throw LinkExtractionFailure.failed(error.localizedDescription)
        }

        guard result.didSucceed else {
            throw Self.classify(result)
        }

        var preview = try Self.parsePreview(json: result.standardOutput, pageURL: pageURL)
        preview.thumbnailFileURL = await fetchThumbnail(for: pageURL, using: ytdlp)
        return preview
    }

    /// A best-effort second call. `yt-dlp` fetches the image itself, so Melo's own
    /// network surface stays at exactly one disclosed client (`AutoEQFetcher`) and the
    /// only host Melo contacts on the user's behalf is still none. Any failure here
    /// produces no thumbnail and no error.
    private func fetchThumbnail(for pageURL: URL, using ytdlp: URL) async -> URL? {
        guard let scratch = try? Self.makeScratchDirectory(prefix: "Thumb") else { return nil }

        guard let result = try? await runner.run(
            executable: ytdlp,
            arguments: Self.thumbnailArguments(for: pageURL),
            workingDirectory: scratch,
            onLine: nil
        ), result.didSucceed else {
            try? FileManager.default.removeItem(at: scratch)
            return nil
        }

        guard let image = Self.pickThumbnail(in: scratch) else {
            try? FileManager.default.removeItem(at: scratch)
            return nil
        }
        return image
    }

    // MARK: Extraction

    /// Downloads the audio into a fresh scratch directory and returns the file.
    ///
    /// Cancelling the surrounding task terminates `yt-dlp` and removes the scratch
    /// directory; nothing is left running and nothing is left on disk.
    func extractAudio(
        from pageURL: URL,
        progress: @escaping @Sendable (LinkExtractionUpdate) -> Void
    ) async throws -> ExtractedAudio {
        guard Self.isWebLink(pageURL) else { throw LinkExtractionFailure.notAWebLink }
        guard let ytdlp = locate(.ytdlp) else { throw LinkExtractionFailure.toolMissing(.ytdlp) }

        let ffmpeg = locate(.ffmpeg)
        let scratch = try Self.makeScratchDirectory(prefix: "Link")

        progress(LinkExtractionUpdate(fraction: nil, stage: "Finding it", detail: nil))

        let result: ToolProcessResult
        do {
            result = try await runner.run(
                executable: ytdlp,
                arguments: Self.downloadArguments(for: pageURL, ffmpeg: ffmpeg),
                workingDirectory: scratch,
                onLine: { line in
                    guard let update = Self.parseProgress(line.text) else { return }
                    progress(update)
                }
            )
        } catch is CancellationError {
            try? FileManager.default.removeItem(at: scratch)
            throw LinkExtractionFailure.cancelled
        } catch {
            try? FileManager.default.removeItem(at: scratch)
            throw LinkExtractionFailure.failed(error.localizedDescription)
        }

        guard result.didSucceed else {
            try? FileManager.default.removeItem(at: scratch)
            throw result.wasKilledBySignal ? LinkExtractionFailure.cancelled : Self.classify(result)
        }

        guard let file = Self.pickDownloadedAudio(in: scratch) else {
            try? FileManager.default.removeItem(at: scratch)
            throw LinkExtractionFailure.nothingDownloaded
        }

        let fileExtension = file.pathExtension.lowercased()
        guard Self.isDecodableByAVFoundation(fileExtension) else {
            try? FileManager.default.removeItem(at: scratch)
            throw LinkExtractionFailure.needsFFmpeg(fileExtension: fileExtension)
        }

        progress(LinkExtractionUpdate(fraction: 1, stage: "Almost there", detail: nil))

        return ExtractedAudio(
            fileURL: file,
            pageURL: pageURL,
            siteName: Self.siteName(from: pageURL, extractorKey: nil),
            displayName: file.deletingPathExtension().lastPathComponent
        )
    }
}

// MARK: - Arguments

extension LinkExtractor {
    /// Flags every invocation carries.
    ///
    /// `--ignore-config` is deliberate: without it, Melo executes whatever is in the
    /// user's `yt-dlp.conf`, which can redirect the output path out of the scratch
    /// directory, add post-processors Melo did not ask for, or run arbitrary
    /// `--exec` commands. Melo runs the tool, not the user's configuration file.
    static let sharedArguments: [String] = [
        "--ignore-config",
        "--no-playlist",
        "--no-color",
        "--no-warnings",
        "--socket-timeout", "20"
    ]

    static func previewArguments(for pageURL: URL) -> [String] {
        sharedArguments + [
            "--dump-single-json",
            "--skip-download",
            "--",
            pageURL.absoluteString
        ]
    }

    /// Writes into the process's working directory, so no output-path flag is needed
    /// and nothing depends on a `yt-dlp` version that has `--paths`.
    static func thumbnailArguments(for pageURL: URL) -> [String] {
        sharedArguments + [
            "--skip-download",
            "--write-thumbnail",
            "--no-write-info-json",
            "-o", "thumbnail.%(ext)s",
            "--",
            pageURL.absoluteString
        ]
    }

    /// Two shapes, because `--extract-audio` is a post-processor that shells out to
    /// ffmpeg and simply fails without it.
    ///
    /// With ffmpeg: take the best audio and let ffmpeg put it in an m4a, which
    /// AVFoundation always opens.
    ///
    /// Without ffmpeg: no post-processing at all, and the format selector asks for a
    /// container macOS can decode *first*, falling back to whatever exists. That
    /// fallback can still land on webm/opus, which is caught after the download and
    /// reported as `needsFFmpeg` rather than a decode failure three screens later.
    ///
    /// **`--ffmpeg-location` is not optional now that Melo bundles the binary.**
    /// yt-dlp finds its post-processor on its own `PATH`, and
    /// `Melo.app/Contents/Helpers` is on nobody's `PATH`. Passing the located
    /// executable is the difference between "Melo has an ffmpeg" and "yt-dlp can use
    /// it" — without the flag, a user with no Homebrew ffmpeg would take the
    /// `--extract-audio` branch and get *ffprobe and ffmpeg not found* from a machine
    /// that is carrying one. Only `ffmpeg` is bundled, not `ffprobe`; yt-dlp probes
    /// the codec with `ffmpeg -i` when the prober is absent.
    static func downloadArguments(for pageURL: URL, ffmpeg: URL?) -> [String] {
        var arguments = sharedArguments + [
            "--newline",
            "--progress",
            "--progress-template", progressTemplate,
            "-o", "%(title)s.%(ext)s"
        ]

        if let ffmpeg {
            arguments += [
                "--ffmpeg-location", ffmpeg.path,
                "-f", "bestaudio/best",
                "--extract-audio",
                "--audio-format", "m4a",
                "--audio-quality", "0"
            ]
        } else {
            arguments += [
                "-f", "bestaudio[ext=m4a]/bestaudio[ext=mp3]/bestaudio[ext=mp4]/bestaudio/best"
            ]
        }

        arguments += ["--", pageURL.absoluteString]
        return arguments
    }

    /// A format Melo controls, so progress parsing does not depend on yt-dlp's own
    /// human-readable bar staying the same shape between releases. The default bar is
    /// still parsed as a fallback.
    static let progressTemplate = "download:[melo] %(progress._percent_str)s %(progress._eta_str)s"
}

// MARK: - Progress parsing

extension LinkExtractor {
    /// Turns one line of yt-dlp output into a progress update, or nil when the line
    /// says nothing the user needs.
    static func parseProgress(_ rawLine: String) -> LinkExtractionUpdate? {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return nil }

        if line.hasPrefix("[melo]") {
            let fields = line.dropFirst("[melo]".count)
                .split(separator: " ", omittingEmptySubsequences: true)
                .map(String.init)
            let fraction = fields.first.flatMap(parsePercent)
            let eta = fields.count > 1 ? parseETA(fields[1]) : nil
            return LinkExtractionUpdate(
                fraction: fraction,
                stage: "Pulling the audio",
                detail: progressDetail(fraction: fraction, eta: eta)
            )
        }

        // yt-dlp's own bar, for a build that ignored the template.
        if line.hasPrefix("[download]"), let percentRange = line.range(of: "%") {
            let head = line[line.startIndex..<percentRange.upperBound]
            guard let token = head.split(separator: " ").last.map(String.init),
                  let fraction = parsePercent(token) else { return nil }
            let eta = line.range(of: "ETA ").map { String(line[$0.upperBound...]).split(separator: " ").first.map(String.init) ?? "" }
            return LinkExtractionUpdate(
                fraction: fraction,
                stage: "Pulling the audio",
                detail: progressDetail(fraction: fraction, eta: eta.flatMap(parseETA))
            )
        }

        if line.hasPrefix("[ExtractAudio]") || line.hasPrefix("[Merger]") || line.hasPrefix("[VideoConvertor]") {
            return LinkExtractionUpdate(fraction: nil, stage: "Converting", detail: nil)
        }

        if line.hasPrefix("[FixupM4a]") || line.hasPrefix("[Fixup") || line.hasPrefix("[MoveFiles]") {
            return LinkExtractionUpdate(fraction: nil, stage: "Almost there", detail: nil)
        }

        if line.hasPrefix("[info]") || line.contains("Extracting URL") {
            return LinkExtractionUpdate(fraction: nil, stage: "Finding it", detail: nil)
        }

        return nil
    }

    /// `" 42.7%"` and `"42.7%"` and `"  0.0%"` all mean the same thing.
    static func parsePercent(_ token: String) -> Double? {
        let trimmed = token.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasSuffix("%") else { return nil }
        guard let value = Double(trimmed.dropLast()) else { return nil }
        return min(max(value / 100, 0), 1)
    }

    /// yt-dlp prints `00:42`, `01:02:03`, or `Unknown`.
    static func parseETA(_ token: String) -> TimeInterval? {
        let trimmed = token.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != "Unknown", trimmed != "NA" else { return nil }
        let parts = trimmed.split(separator: ":").map(String.init)
        guard !parts.isEmpty, parts.count <= 3 else { return nil }
        var seconds: TimeInterval = 0
        for part in parts {
            guard let value = Double(part) else { return nil }
            seconds = seconds * 60 + value
        }
        return seconds
    }

    static func progressDetail(fraction: Double?, eta: TimeInterval?) -> String? {
        var pieces: [String] = []
        if let fraction {
            pieces.append("\(Int((fraction * 100).rounded()))%")
        }
        if let eta, eta > 0 {
            pieces.append(eta < 60 ? "\(Int(eta.rounded()))s left" : "\(Int((eta / 60).rounded()))m left")
        }
        return pieces.isEmpty ? nil : pieces.joined(separator: " · ")
    }
}

// MARK: - Failure classification

extension LinkExtractor {
    /// Reads yt-dlp's diagnostics and picks the one sentence that helps.
    ///
    /// Order is deliberate: the specific reasons come before the generic ones, because
    /// a geo-block and a removed video both print "Unable to download webpage" further
    /// down and would otherwise both be reported as a network problem.
    static func classify(_ result: ToolProcessResult) -> LinkExtractionFailure {
        if result.wasKilledBySignal { return .cancelled }

        let haystack = (result.standardError + "\n" + result.standardOutput).lowercased()

        func mentions(_ needles: [String]) -> Bool {
            needles.contains { haystack.contains($0) }
        }

        if mentions([
            "ffmpeg not found", "ffprobe and ffmpeg not found",
            "ffprobe/avprobe and ffmpeg/avconv not found",
            "you have requested merging of multiple formats but ffmpeg is not installed"
        ]) {
            return .needsFFmpeg(fileExtension: "webm")
        }

        if mentions([
            "please update", "confirm you are on the latest version",
            "nsig extraction failed", "signature extraction failed",
            "unable to extract yt initial data", "player response",
            "this version of yt-dlp"
        ]) {
            return .toolOutdated
        }

        if mentions([
            "sign in to confirm", "requires authentication", "login required",
            "members-only", "join this channel", "use --cookies",
            "--cookies-from-browser", "premieres in", "requested content is not available"
        ]) {
            return .signInRequired
        }

        if mentions([
            "not available in your country", "not available from your location",
            "geo restricted", "geo-restricted", "blocked it in your country",
            "the uploader has not made this video available in your country",
            "not available in your region"
        ]) {
            return .geoBlocked
        }

        if mentions([
            "video unavailable", "private video", "this video is private",
            "has been removed", "account associated with this video has been terminated",
            "this content isn't available", "no longer available",
            "http error 404", "http error 410", "does not exist"
        ]) {
            return .unavailable
        }

        if mentions(["unsupported url", "is not a valid url", "no suitable extractor"]) {
            return .unsupportedSite
        }

        if mentions(["requested format is not available", "no video formats found", "only images are available"]) {
            return .noFormatAvailable
        }

        if mentions([
            "nodename nor servname", "temporary failure in name resolution",
            "network is unreachable", "connection refused", "getaddrinfo",
            "no address associated with hostname", "urlopen error",
            "connection reset by peer", "read timed out", "timed out"
        ]) {
            return .noNetwork
        }

        return .failed(lastErrorLine(result.standardError) ?? "yt-dlp gave up on that one.")
    }

    /// The last `ERROR:` line, which is the one that stopped it. Falls back to the
    /// last non-empty line so a tool that formats errors differently still says
    /// something real rather than an exit code.
    static func lastErrorLine(_ standardError: String) -> String? {
        let lines = standardError
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        let errors = lines.filter { $0.uppercased().hasPrefix("ERROR") }
        guard let raw = errors.last ?? lines.last else { return nil }

        var message = raw
        for prefix in ["ERROR: ", "ERROR:", "error: "] where message.hasPrefix(prefix) {
            message = String(message.dropFirst(prefix.count))
            break
        }
        return message.isEmpty ? nil : message
    }
}

// MARK: - Reading the page metadata

extension LinkExtractor {
    static func parsePreview(json: String, pageURL: URL) throws -> LinkPreview {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LinkExtractionFailure.failed("yt-dlp answered with something Melo couldn't read.")
        }

        let title = (object["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let uploader = (object["uploader"] as? String) ?? (object["channel"] as? String)
        let duration = object["duration"] as? Double
        let extractorKey = (object["extractor_key"] as? String) ?? (object["extractor"] as? String)

        return LinkPreview(
            title: (title?.isEmpty == false ? title! : pageURL.lastPathComponent),
            siteName: siteName(from: pageURL, extractorKey: extractorKey),
            uploader: uploader?.isEmpty == false ? uploader : nil,
            duration: (duration ?? 0) > 0 ? duration : nil,
            thumbnailFileURL: nil,
            isLive: (object["is_live"] as? Bool) ?? false
        )
    }

    /// The extractor key when yt-dlp gives one (`"Youtube"`, `"SoundCloud"`), and the
    /// host with its `www.` stripped otherwise.
    static func siteName(from pageURL: URL, extractorKey: String?) -> String {
        if let key = extractorKey?.trimmingCharacters(in: .whitespaces),
           !key.isEmpty, key.lowercased() != "generic" {
            return key
        }
        guard var host = pageURL.host else { return "the web" }
        if host.hasPrefix("www.") { host = String(host.dropFirst(4)) }
        return host
    }
}

// MARK: - Files on disk

extension LinkExtractor {
    /// Containers AVFoundation opens on macOS. Anything else — webm, ogg, opus, mkv —
    /// means the ffmpeg post-processor did not run, and saying so is more useful than
    /// a decode failure.
    static let avFoundationExtensions: Set<String> = [
        "m4a", "mp4", "m4b", "mp3", "aac", "wav", "aiff", "aif", "aifc", "caf", "flac", "alac", "mov"
    ]

    static func isDecodableByAVFoundation(_ fileExtension: String) -> Bool {
        avFoundationExtensions.contains(fileExtension.lowercased())
    }

    private static let nonAudioExtensions: Set<String> = [
        "part", "ytdl", "json", "jpg", "jpeg", "png", "webp", "gif", "vtt", "srt",
        "description", "annotations", "temp", "info"
    ]

    private static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "webp", "gif"]

    /// Every extraction gets its own empty directory, so "the largest file that isn't
    /// scaffolding" is exact rather than a guess. This is why no `--print filepath`
    /// flag is used: it would add a yt-dlp version dependency to buy nothing.
    static func pickDownloadedAudio(in directory: URL) -> URL? {
        candidates(in: directory)
            .filter { !nonAudioExtensions.contains($0.pathExtension.lowercased()) }
            .max { fileSize($0) < fileSize($1) }
    }

    static func pickThumbnail(in directory: URL) -> URL? {
        candidates(in: directory)
            .filter { imageExtensions.contains($0.pathExtension.lowercased()) }
            .max { fileSize($0) < fileSize($1) }
    }

    /// Normalised on the way out. Measured this session: `temporaryDirectory` hands
    /// back `/var/folders/…` and `contentsOfDirectory` returns children under
    /// `/private/var/folders/…`, so without this the file's own parent and the scratch
    /// directory it came from are different strings for the same directory.
    private static func candidates(in directory: URL) -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return contents.map { $0.resolvingSymlinksInPath() }
    }

    private static func fileSize(_ url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }

    static func makeScratchDirectory(prefix: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeloEditor", isDirectory: true)
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.resolvingSymlinksInPath()
    }
}

// MARK: - Input validation

extension LinkExtractor {
    /// The one place user input is checked. A scheme that is not http or https never
    /// reaches `yt-dlp`, so a pasted `file:` or `javascript:` URL cannot become an
    /// argument to a subprocess.
    static func isWebLink(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return false
        }
        guard let host = url.host, !host.isEmpty else { return false }
        return true
    }

    /// Turns whatever is on the clipboard into a link, or nil. Tolerates surrounding
    /// whitespace and a bare `youtu.be/…` with no scheme, because that is what people
    /// copy out of a share sheet.
    static func webLink(fromPastedText text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(" "), trimmed.count < 2048 else { return nil }

        if let url = URL(string: trimmed), isWebLink(url) { return url }

        let separator = ":" + String(repeating: "/", count: 2)
        guard !trimmed.contains(separator), trimmed.contains("."), !trimmed.hasPrefix(".") else { return nil }
        guard let url = URL(string: "https" + separator + trimmed), isWebLink(url) else { return nil }
        return url
    }
}
