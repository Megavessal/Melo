import Foundation

nonisolated struct DeveloperUpdateManifest: Codable, Sendable, Equatable {
    enum PackageType: String, Codable, Sendable {
        case source
        case binary
    }

    let schemaVersion: Int
    let version: String
    let build: Int
    let bundleIdentifier: String
    let packageType: PackageType
    let minimumMacOS: String?
    let sourceSubdirectory: String?
    let releaseNotes: String?

    init(
        schemaVersion: Int = 1,
        version: String,
        build: Int,
        bundleIdentifier: String,
        packageType: PackageType,
        minimumMacOS: String? = nil,
        sourceSubdirectory: String? = nil,
        releaseNotes: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.version = version
        self.build = build
        self.bundleIdentifier = bundleIdentifier
        self.packageType = packageType
        self.minimumMacOS = minimumMacOS
        self.sourceSubdirectory = sourceSubdirectory
        self.releaseNotes = releaseNotes
    }
}

nonisolated struct DeveloperUpdateCandidate: Sendable, Equatable, Identifiable {
    let manifest: DeveloperUpdateManifest
    let archiveURL: URL
    let deleteArchiveAfterInstall: Bool

    var id: String { "\(manifest.bundleIdentifier)-\(manifest.build)-\(archiveURL.path)" }
}

nonisolated enum DeveloperUpdateError: LocalizedError, Sendable {
    case invalidURL
    case insecureURL
    case unsupportedFile
    case manifestMissing
    case invalidManifest(String)
    case notNewer(current: Int, candidate: Int)
    case incompatibleSystem(required: String)
    case buildToolsMissing
    case buildCommandMissing
    case sourceUpdatesUnavailable
    case buildFailed(logURL: URL)
    case appMissing
    case invalidBundle(String)
    case unsignedBundle
    case installationUnavailable
    case preflightFailed(String)
    case toolFailed(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "That link is not valid."
        case .insecureURL:
            return "Developer updates must use a secure HTTPS link."
        case .unsupportedFile:
            return "Choose a Melo update ZIP file."
        case .manifestMissing:
            return "This archive does not contain a Melo update manifest."
        case .invalidManifest(let reason):
            return "This update package is not valid: \(reason)"
        case .notNewer(let current, let candidate):
            return "Build \(candidate) is not newer than the installed build \(current)."
        case .incompatibleSystem(let required):
            return "This update requires macOS \(required) or later."
        case .buildToolsMissing:
            return "Full Xcode is required to build this developer update."
        case .buildCommandMissing:
            return "This source package has no Build Melo.command or scripts/build-app.sh, so Melo cannot build it safely."
        case .sourceUpdatesUnavailable:
            return "This copy of Melo does not build source updates."
        case .buildFailed(let logURL):
            return "The update did not compile. A build log was saved at \(logURL.path)."
        case .appMissing:
            return "The build finished without producing Melo.app."
        case .invalidBundle(let reason):
            return "The update was rejected because \(reason)."
        case .unsignedBundle:
            return "The built app is not code signed. Build it with Build Melo.command, which signs the app and embeds its frameworks."
        case .installationUnavailable:
            return "Melo cannot replace itself from its current location. Move Melo to a writable folder such as Applications and try again."
        case .preflightFailed(let reason):
            return "The update was not installed because \(reason). Your current version of Melo was left untouched."
        case .toolFailed(let message):
            return message.isEmpty ? "A required update tool failed." : message
        case .cancelled:
            return "The update was cancelled."
        }
    }
}
