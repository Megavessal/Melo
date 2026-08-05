import Foundation

nonisolated enum UpdatePackageValidator {
    struct Inspection: Sendable {
        let manifest: DeveloperUpdateManifest
        let manifestDirectory: URL
        let extractionDirectory: URL
    }

    static func inspect(
        archiveURL: URL,
        workspace: URL,
        expectedBundleIdentifier: String,
        requireNewerBuild: Bool = true
    ) throws -> Inspection {
        guard archiveURL.pathExtension.lowercased() == "zip" else {
            throw DeveloperUpdateError.unsupportedFile
        }

        try validateArchivePaths(archiveURL)
        try? FileManager.default.removeItem(at: workspace)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try run("/usr/bin/ditto", arguments: ["-x", "-k", archiveURL.path, workspace.path])

        guard let manifestURL = findNamedFile("manifest.json", in: workspace) else {
            throw DeveloperUpdateError.manifestMissing
        }

        let data = try Data(contentsOf: manifestURL)
        let manifest: DeveloperUpdateManifest
        do {
            manifest = try JSONDecoder().decode(DeveloperUpdateManifest.self, from: data)
        } catch {
            throw DeveloperUpdateError.invalidManifest(error.localizedDescription)
        }

        try validate(
            manifest: manifest,
            expectedBundleIdentifier: expectedBundleIdentifier,
            requireNewerBuild: requireNewerBuild
        )

        return Inspection(
            manifest: manifest,
            manifestDirectory: manifestURL.deletingLastPathComponent(),
            extractionDirectory: workspace
        )
    }

    static func validate(
        manifest: DeveloperUpdateManifest,
        expectedBundleIdentifier: String,
        requireNewerBuild: Bool
    ) throws {
        guard manifest.schemaVersion == 1 else {
            throw DeveloperUpdateError.invalidManifest("unsupported manifest version")
        }
        guard manifest.bundleIdentifier == expectedBundleIdentifier else {
            throw DeveloperUpdateError.invalidManifest("bundle identifier does not match Melo")
        }
        guard manifest.build > 0, !manifest.version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DeveloperUpdateError.invalidManifest("version or build is missing")
        }

        if requireNewerBuild {
            let currentBuild = Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0") ?? 0
            guard manifest.build > currentBuild else {
                throw DeveloperUpdateError.notNewer(current: currentBuild, candidate: manifest.build)
            }
        }

        if let minimum = manifest.minimumMacOS,
           compareCurrentSystemVersion(to: minimum) == .orderedAscending {
            throw DeveloperUpdateError.incompatibleSystem(required: minimum)
        }
    }

    /// Confirms a finished bundle matches its manifest. Mismatches name the exact
    /// field that disagrees — forgetting to bump `CFBundleVersion` used to surface
    /// as an opaque "does not match the update manifest".
    static func validateBuiltApp(_ appURL: URL, manifest: DeveloperUpdateManifest) throws {
        guard appURL.pathExtension == "app", let bundle = Bundle(url: appURL) else {
            throw DeveloperUpdateError.invalidBundle("it is not a readable app bundle")
        }

        let identifier = bundle.bundleIdentifier ?? "(none)"
        guard identifier == manifest.bundleIdentifier else {
            throw DeveloperUpdateError.invalidBundle(
                "its bundle identifier is \(identifier) but the manifest says \(manifest.bundleIdentifier)"
            )
        }

        let builtBuild = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "(none)"
        guard builtBuild == String(manifest.build) else {
            throw DeveloperUpdateError.invalidBundle(
                "the built app is build \(builtBuild) but the manifest says build \(manifest.build)"
            )
        }

        let builtVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "(none)"
        guard builtVersion == manifest.version else {
            throw DeveloperUpdateError.invalidBundle(
                "the built app is version \(builtVersion) but the manifest says \(manifest.version)"
            )
        }

        // `--deep` is deprecated by Apple and re-verifies nested code the app's own
        // seal already covers. A bundle produced by a bare `xcodebuild` run with code
        // signing disabled fails here, so name that case instead of reporting a
        // generic tool failure.
        let signature = try runAndCapture(
            "/usr/bin/codesign",
            arguments: ["--verify", "--strict", appURL.path]
        )
        guard signature.status == 0 else {
            let detail = signature.output.trimmingCharacters(in: .whitespacesAndNewlines)
            if detail.contains("not signed") || detail.contains("code object is not signed") {
                throw DeveloperUpdateError.unsignedBundle
            }
            throw DeveloperUpdateError.invalidBundle(
                "its code signature did not verify: \(String(detail.prefix(200)))"
            )
        }
    }

    /// Reads only `manifest.json` out of an archive. Scanning a folder used to fully
    /// extract every ZIP in it — on a folder of a dozen 5 MB builds that is hundreds
    /// of megabytes of I/O on every check, including at launch.
    static func peekManifest(archiveURL: URL) throws -> DeveloperUpdateManifest {
        guard archiveURL.pathExtension.lowercased() == "zip" else {
            throw DeveloperUpdateError.unsupportedFile
        }
        let listing = try runAndCapture("/usr/bin/unzip", arguments: ["-Z1", archiveURL.path])
        guard listing.status == 0 else {
            throw DeveloperUpdateError.invalidManifest("archive cannot be read")
        }
        let entries = listing.output.split(whereSeparator: { $0.isNewline }).map(String.init)
        guard let entry = entries
            .filter({ $0.hasSuffix("manifest.json") && !$0.hasPrefix("__MACOSX/") })
            .min(by: { $0.count < $1.count })
        else {
            throw DeveloperUpdateError.manifestMissing
        }

        let extracted = try runAndCapture("/usr/bin/unzip", arguments: ["-p", archiveURL.path, entry])
        guard extracted.status == 0, let data = extracted.output.data(using: .utf8) else {
            throw DeveloperUpdateError.manifestMissing
        }
        do {
            return try JSONDecoder().decode(DeveloperUpdateManifest.self, from: data)
        } catch {
            throw DeveloperUpdateError.invalidManifest(error.localizedDescription)
        }
    }

    static func findApp(in directory: URL) -> URL? {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return nil }

        while let item = enumerator.nextObject() as? URL {
            if item.pathExtension == "app" && item.lastPathComponent == "Melo.app" {
                return item
            }
        }
        return nil
    }

    static func findNamedFile(_ name: String, in directory: URL) -> URL? {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        while let item = enumerator.nextObject() as? URL {
            if item.lastPathComponent == name { return item }
        }
        return nil
    }

    static func run(_ executable: String, arguments: [String], currentDirectory: URL? = nil) throws {
        let result = try runAndCapture(executable, arguments: arguments, currentDirectory: currentDirectory)
        guard result.status == 0 else {
            throw DeveloperUpdateError.toolFailed(result.output)
        }
    }

    static func runAndCapture(
        _ executable: String,
        arguments: [String],
        currentDirectory: URL? = nil,
        environment: [String: String]? = nil
    ) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory
        if let environment { process.environment = environment }

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    private static func validateArchivePaths(_ archiveURL: URL) throws {
        let listing = try runAndCapture("/usr/bin/unzip", arguments: ["-Z1", archiveURL.path])
        guard listing.status == 0 else {
            throw DeveloperUpdateError.invalidManifest("archive cannot be read")
        }
        for rawLine in listing.output.split(whereSeparator: { $0.isNewline }) {
            let line = String(rawLine)
            let components = line.split(separator: "/", omittingEmptySubsequences: false)
            if line.hasPrefix("/") || components.contains("..") {
                throw DeveloperUpdateError.invalidManifest("archive contains an unsafe path")
            }
        }
    }

    private static func compareCurrentSystemVersion(to required: String) -> ComparisonResult {
        let current = ProcessInfo.processInfo.operatingSystemVersion
        let currentString = "\(current.majorVersion).\(current.minorVersion).\(current.patchVersion)"
        return currentString.compare(required, options: .numeric)
    }
}
