import Foundation

nonisolated enum UpdateBuildCoordinator {
    struct Result: Sendable {
        let appURL: URL
        let logURL: URL
    }

    static func prepare(
        inspection: UpdatePackageValidator.Inspection,
        logDirectory: URL
    ) throws -> Result {
        try FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        let logURL = logDirectory.appendingPathComponent(
            "Melo-build-\(inspection.manifest.build)-\(Int(Date().timeIntervalSince1970)).log"
        )

        switch inspection.manifest.packageType {
        case .binary:
            guard let appURL = UpdatePackageValidator.findApp(in: inspection.extractionDirectory) else {
                throw DeveloperUpdateError.appMissing
            }
            try UpdatePackageValidator.validateBuiltApp(appURL, manifest: inspection.manifest)
            return Result(appURL: appURL, logURL: logURL)

        case .source:
            #if !MELO_DEV
            // Source packages compile and run code from inside the archive. Shipping
            // builds have no such path at all — this is not merely hidden UI.
            throw DeveloperUpdateError.sourceUpdatesUnavailable
            #else
            guard FileManager.default.fileExists(atPath: "/usr/bin/xcodebuild") ||
                    FileManager.default.fileExists(atPath: "/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild") else {
                throw DeveloperUpdateError.buildToolsMissing
            }

            let sourceRoot = try resolveSourceRoot(for: inspection)
            let buildCommand = sourceRoot.appendingPathComponent("Build Melo.command")
            let scriptCommand = sourceRoot.appendingPathComponent("scripts/build-app.sh")

            // Only the project's own build script is used. A bare `xcodebuild` run
            // neither embeds Sparkle.framework nor signs the result, so it reliably
            // produced a bundle that died in dyld at launch — the update installed,
            // failed to start, and rolled back a minute later.
            // `--dev` keeps the developer-update tools in the build being produced.
            // Without it the first source update would install a shipping build and
            // the loop would end there.
            let invocation: (String, [String])
            if FileManager.default.fileExists(atPath: buildCommand.path) {
                invocation = ("/bin/bash", [buildCommand.path, "--dev"])
            } else if FileManager.default.fileExists(atPath: scriptCommand.path) {
                invocation = ("/bin/bash", [scriptCommand.path, "--dev"])
            } else {
                throw DeveloperUpdateError.buildCommandMissing
            }

            let status = try runBuild(
                executable: invocation.0,
                arguments: invocation.1,
                currentDirectory: sourceRoot,
                logURL: logURL
            )
            guard status == 0 else {
                throw DeveloperUpdateError.buildFailed(logURL: logURL)
            }

            guard let appURL = preferredBuiltApp(in: sourceRoot) else {
                throw DeveloperUpdateError.appMissing
            }
            try UpdatePackageValidator.validateBuiltApp(appURL, manifest: inspection.manifest)
            return Result(appURL: appURL, logURL: logURL)
            #endif
        }
    }

    private static func resolveSourceRoot(
        for inspection: UpdatePackageValidator.Inspection
    ) throws -> URL {
        let root: URL
        if let subdirectory = inspection.manifest.sourceSubdirectory,
           !subdirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            root = inspection.manifestDirectory.appendingPathComponent(subdirectory, isDirectory: true)
        } else {
            root = inspection.manifestDirectory
        }

        let standardizedRoot = root.standardizedFileURL
        let standardizedExtraction = inspection.extractionDirectory.standardizedFileURL
        guard standardizedRoot.path == standardizedExtraction.path ||
                standardizedRoot.path.hasPrefix(standardizedExtraction.path + "/") else {
            throw DeveloperUpdateError.invalidManifest("source folder is outside the update package")
        }
        guard FileManager.default.fileExists(atPath: standardizedRoot.path) else {
            throw DeveloperUpdateError.invalidManifest("source folder is missing")
        }
        return standardizedRoot
    }

    private static func preferredBuiltApp(in sourceRoot: URL) -> URL? {
        let direct = sourceRoot.appendingPathComponent("outputs/Melo.app")
        if FileManager.default.fileExists(atPath: direct.path) { return direct }
        return UpdatePackageValidator.findApp(in: sourceRoot)
    }

    // Run Xcode in a separate process so the menu-bar UI remains responsive.
    private static func runBuild(
        executable: String,
        arguments: [String],
        currentDirectory: URL,
        logURL: URL
    ) throws -> Int32 {
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: logURL)
        defer { try? handle.close() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory
        var environment = ProcessInfo.processInfo.environment
        if environment["DEVELOPER_DIR"] == nil,
           FileManager.default.fileExists(atPath: "/Applications/Xcode.app/Contents/Developer") {
            environment["DEVELOPER_DIR"] = "/Applications/Xcode.app/Contents/Developer"
        }
        process.environment = environment
        process.standardOutput = handle
        process.standardError = handle
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
}
