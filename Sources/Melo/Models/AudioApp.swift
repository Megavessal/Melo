// Melo/Models/AudioApp.swift
import AppKit
import AudioToolbox

struct AudioApp: Identifiable, Hashable {
    let id: pid_t
    let processObjectIDs: [AudioObjectID]
    let name: String
    let icon: NSImage
    let bundleID: String?
    /// The executable path gives bundle-less apps a stable identity across launches.
    /// Bundle identifiers remain the preferred key so existing Melo settings continue
    /// to load unchanged.
    let executablePath: String?
    let isHelperBacked: Bool

    init(
        id: pid_t,
        processObjectIDs: [AudioObjectID],
        name: String,
        icon: NSImage,
        bundleID: String?,
        executablePath: String? = nil,
        isHelperBacked: Bool = false
    ) {
        self.id = id
        self.processObjectIDs = processObjectIDs
        self.name = name
        self.icon = icon
        self.bundleID = bundleID
        self.executablePath = executablePath
        self.isHelperBacked = isHelperBacked
    }

    var persistenceIdentifier: String {
        if let bundleID, !bundleID.isEmpty {
            return bundleID
        }
        if let executablePath, !executablePath.isEmpty {
            return "executable:\(URL(fileURLWithPath: executablePath).standardizedFileURL.path)"
        }
        return "name:\(name)"
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: AudioApp, rhs: AudioApp) -> Bool {
        lhs.id == rhs.id
    }
}
