// Melo/Models/DisplayableApp.swift
import AppKit
import UniformTypeIdentifiers

/// Represents an app that can be displayed in the UI:
/// - active: Core Audio has exposed a capturable process object
/// - openInactive: the app is open but has not initialized/started Core Audio
/// - pinnedInactive: the app is closed but the user keeps its controls visible
enum DisplayableApp: Identifiable {
    case active(AudioApp)
    case openInactive(AudioApp)
    case pinnedInactive(PinnedAppInfo)

    var id: String {
        switch self {
        case .active(let app):
            return app.persistenceIdentifier
        case .openInactive(let app):
            return app.persistenceIdentifier
        case .pinnedInactive(let info):
            return info.persistenceIdentifier
        }
    }

    /// Whether this represents a pinned-but-inactive app.
    /// Note: Active apps may also be pinned - check the pinned list directly for that case.
    var isPinnedInactive: Bool {
        switch self {
        case .active, .openInactive:
            return false
        case .pinnedInactive:
            return true
        }
    }

    var isActive: Bool {
        switch self {
        case .active:
            return true
        case .openInactive, .pinnedInactive:
            return false
        }
    }

    /// Whether the underlying application process is currently open, regardless
    /// of whether Core Audio has made it capturable yet.
    var isOpen: Bool {
        switch self {
        case .active, .openInactive:
            return true
        case .pinnedInactive:
            return false
        }
    }

    var displayName: String {
        switch self {
        case .active(let app):
            return app.name
        case .openInactive(let app):
            return app.name
        case .pinnedInactive(let info):
            return info.displayName
        }
    }

    var icon: NSImage {
        switch self {
        case .active(let app):
            return app.icon
        case .openInactive(let app):
            return app.icon
        case .pinnedInactive(let info):
            return Self.loadIcon(bundleID: info.bundleID)
        }
    }

    /// Loads the app icon from a bundle ID, or returns a generic placeholder.
    static func loadIcon(bundleID: String?) -> NSImage {
        if let bundleID,
           let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return NSWorkspace.shared.icon(forFile: appURL.path)
        }
        return NSWorkspace.shared.icon(for: .applicationBundle)
    }

    /// Pure merge used by the engine and tests. Open placeholders are removed as
    /// soon as a matching live audio app appears, preserving the same stable row
    /// identity and saved settings through that transition.
    static func merged(
        activeApps: [AudioApp],
        openApps: [AudioApp],
        pinnedAppInfo: [PinnedAppInfo],
        isPinned: (String) -> Bool,
        isIgnored: (String) -> Bool
    ) -> [DisplayableApp] {
        let visibleActive = activeApps.filter { !isIgnored($0.persistenceIdentifier) }
        let activeIdentifiers = Set(visibleActive.map(\.persistenceIdentifier))

        // NSWorkspace can report multiple instances of the same app. Mixer state
        // is app-scoped, so retain one deterministic placeholder per identifier.
        var openByIdentifier: [String: AudioApp] = [:]
        for app in openApps
            where !activeIdentifiers.contains(app.persistenceIdentifier)
                && !isIgnored(app.persistenceIdentifier) {
            if let existing = openByIdentifier[app.persistenceIdentifier], existing.id < app.id {
                continue
            }
            openByIdentifier[app.persistenceIdentifier] = app
        }
        let visibleOpen = Array(openByIdentifier.values)
        let openIdentifiers = Set(visibleOpen.map(\.persistenceIdentifier))

        let closedPinned = pinnedAppInfo.filter {
            !activeIdentifiers.contains($0.persistenceIdentifier)
                && !openIdentifiers.contains($0.persistenceIdentifier)
                && !isIgnored($0.persistenceIdentifier)
        }

        let byName: (AudioApp, AudioApp) -> Bool = {
            let comparison = $0.name.localizedCaseInsensitiveCompare($1.name)
            if comparison == .orderedSame {
                return $0.persistenceIdentifier < $1.persistenceIdentifier
            }
            return comparison == .orderedAscending
        }

        let pinnedActive = visibleActive
            .filter { isPinned($0.persistenceIdentifier) }
            .sorted(by: byName)
            .map(DisplayableApp.active)
        let pinnedOpen = visibleOpen
            .filter { isPinned($0.persistenceIdentifier) }
            .sorted(by: byName)
            .map(DisplayableApp.openInactive)
        let pinnedClosed = closedPinned
            .sorted {
                let comparison = $0.displayName.localizedCaseInsensitiveCompare($1.displayName)
                if comparison == .orderedSame {
                    return $0.persistenceIdentifier < $1.persistenceIdentifier
                }
                return comparison == .orderedAscending
            }
            .map(DisplayableApp.pinnedInactive)
        let unpinnedActive = visibleActive
            .filter { !isPinned($0.persistenceIdentifier) }
            .sorted(by: byName)
            .map(DisplayableApp.active)
        let unpinnedOpen = visibleOpen
            .filter { !isPinned($0.persistenceIdentifier) }
            .sorted(by: byName)
            .map(DisplayableApp.openInactive)

        return pinnedActive + pinnedOpen + pinnedClosed + unpinnedActive + unpinnedOpen
    }
}
