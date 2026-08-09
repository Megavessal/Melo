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

    /// The one rule that turns an app's identity into the key Melo saves under.
    ///
    /// Static and shared, because it is now applied to apps Melo has never seen
    /// run: `InstalledApp` builds a key for an application bundle sitting on
    /// disk, and `Melo` has to still be reading that same key when the thing
    /// finally launches and arrives here as an `AudioApp`. Two copies of this
    /// three-line rule is how a mute set before launch would silently apply to
    /// nothing — no crash, no error, just an app that comes up loud.
    ///
    /// Deliberately not the process id. A relaunched app keeps its bundle
    /// identifier and gets a new pid every time; something started and stopped
    /// over and over during testing would otherwise lose its settings on every
    /// run, which is the worst possible case for the one feature that exists to
    /// quiet it.
    static func persistenceIdentifier(
        bundleID: String?,
        executablePath: String?,
        name: String
    ) -> String {
        if let bundleID, !bundleID.isEmpty {
            return bundleID
        }
        if let executablePath, !executablePath.isEmpty {
            return "executable:\(URL(fileURLWithPath: executablePath).standardizedFileURL.path)"
        }
        return "name:\(name)"
    }

    var persistenceIdentifier: String {
        Self.persistenceIdentifier(
            bundleID: bundleID,
            executablePath: executablePath,
            name: name
        )
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: AudioApp, rhs: AudioApp) -> Bool {
        lhs.id == rhs.id
    }
}
