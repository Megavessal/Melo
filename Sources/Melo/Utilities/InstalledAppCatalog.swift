// Melo/Utilities/InstalledAppCatalog.swift
import AppKit
import Foundation

/// An application bundle on this Mac that Melo has never seen make a sound.
///
/// Carries only what is needed to key a setting and to name a row. No icon:
/// every surface that shows one of these draws an SF Symbol, and loading three
/// hundred icons to rank a search would be the expensive half of the feature.
nonisolated struct InstalledApp: Identifiable, Hashable, Sendable {
    let name: String
    let bundleID: String?
    let executablePath: String?

    /// The same key a running app is saved under — see
    /// `AudioApp.persistenceIdentifier(bundleID:executablePath:name:)`, which
    /// this calls rather than reimplements. If these two ever disagree, a
    /// volume set before launch applies to nothing and says nothing.
    var persistenceIdentifier: String {
        AudioApp.persistenceIdentifier(
            bundleID: bundleID,
            executablePath: executablePath,
            name: name
        )
    }

    var id: String { persistenceIdentifier }
}

/// Finds an app by name before it has ever played a sound.
///
/// **Why a directory scan.** Melo's existing two sources both require the app
/// to exist as a process: `AudioObjectID.readProcessList()` needs it to have
/// reached Core Audio, and `NSWorkspace.runningApplications` — which
/// `AudioProcessMonitor.discoverOpenApps` uses for the open-but-silent rows —
/// needs it to be launched. Neither can answer "quiet this before it opens",
/// which is the whole request. Scanning the application folders is the only
/// public source that can name something that is not running.
///
/// Rejected, with reasons:
///
/// - **`LSCopyApplicationURLsForBundleIdentifier`** resolves an identifier you
///   already hold. It cannot enumerate, so it cannot answer a partial name
///   typed into a search box — which is the input this feature actually gets.
/// - **Spotlight (`NSMetadataQuery` for `com.apple.application-bundle`)** has
///   the widest reach: apps anywhere on disk, on external volumes, in a Steam
///   library. It is also asynchronous, needs a live query object and
///   notification plumbing owned by something longer-lived than a popup, and
///   returns nothing at all when indexing is off or incomplete — a search that
///   silently finds less on some Macs than others is worse than one whose
///   coverage is written down. It remains the natural upgrade if the folders
///   below prove too narrow.
/// - **`NSWorkspace.runningApplications` alone** is what Melo already does.
///
/// **What this misses**, stated rather than discovered later: an app outside
/// the folders below — dropped in `~/Downloads`, kept in a project directory,
/// installed by a game launcher, or on an external volume; a command-line tool
/// with no bundle; an agent or background-only app (deliberately, matching the
/// `activationPolicy == .regular` filter the running-app list already applies);
/// and anything past `bundleLimit`. All of those are still reachable the moment
/// they make a sound, exactly as before — this only widens the door, it does
/// not narrow any existing one.
nonisolated enum InstalledAppCatalog {
    /// Where ordinary Mac applications live. Depth 2 rather than a deep
    /// traversal so a wrapper folder — `Godot/Godot.app`, `Setapp/…`,
    /// `Utilities/…` — is found while nothing ever descends into a bundle.
    static var searchRoots: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            home.appendingPathComponent("Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
        ]
    }

    /// A scan is bounded so a folder full of app bundles cannot turn a
    /// keystroke into a disk crawl. Well above a normal Mac's install count.
    static let bundleLimit = 800

    // MARK: - Scanning

    /// Reads the application folders. Synchronous and blocking; call it through
    /// `scanned()` from anything with a UI.
    static func scan(roots: [URL] = searchRoots, maximumDepth: Int = 2) -> [InstalledApp] {
        var byIdentifier: [String: InstalledApp] = [:]
        var seenBundles = 0
        let ownBundleID = Bundle.main.bundleIdentifier

        func visit(_ directory: URL, depth: Int) {
            guard depth <= maximumDepth, seenBundles < bundleLimit else { return }
            let contents = (try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey, .localizedNameKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            )) ?? []

            for url in contents {
                guard seenBundles < bundleLimit else { return }
                if url.pathExtension.lowercased() == "app" {
                    seenBundles += 1
                    guard let app = read(bundleAt: url), app.bundleID != ownBundleID else { continue }
                    // One row per identifier: a Mac with two copies of the same
                    // app has one mixer profile, so it must have one entry.
                    if byIdentifier[app.persistenceIdentifier] == nil {
                        byIdentifier[app.persistenceIdentifier] = app
                    }
                } else if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    visit(url, depth: depth + 1)
                }
            }
        }

        for root in roots {
            visit(root, depth: 1)
        }

        return byIdentifier.values.sorted {
            let comparison = $0.name.localizedCaseInsensitiveCompare($1.name)
            if comparison == .orderedSame {
                return $0.persistenceIdentifier < $1.persistenceIdentifier
            }
            return comparison == .orderedAscending
        }
    }

    /// The scan, off the main thread. A popup must not stall on a disk read.
    static func scanned(roots: [URL] = searchRoots) async -> [InstalledApp] {
        await Task.detached(priority: .utility) { scan(roots: roots) }.value
    }

    /// One bundle's identity, or `nil` if it is not a user-facing application.
    ///
    /// `Info.plist` is read directly rather than through `Bundle(url:)`, which
    /// keeps every bundle it is handed alive in a process-wide table for the
    /// rest of the run. Three hundred of those to answer one search is a cost
    /// with no matching benefit.
    static func read(bundleAt url: URL) -> InstalledApp? {
        let plistURL = url.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plistURL, options: [.mappedIfSafe]),
              let info = (try? PropertyListSerialization.propertyList(
                  from: data, options: [], format: nil
              )) as? [String: Any] else {
            return nil
        }

        // Agents and background-only bundles have no interface and are not what
        // anyone means by "an app". The running-app list already excludes them
        // by requiring `activationPolicy == .regular`; this is the same rule
        // read from disk, so the two lists cannot disagree about what counts.
        if truthy(info["LSUIElement"]) || truthy(info["LSBackgroundOnly"]) {
            return nil
        }

        let bundleID = (info["CFBundleIdentifier"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let executable = info["CFBundleExecutable"] as? String
        let executablePath = executable.map {
            url.appendingPathComponent("Contents/MacOS/\($0)").path
        }

        // `localizedName` is what Finder shows and what `NSRunningApplication`
        // reports, so an app found here is named the same as the same app found
        // running. It also drops the ".app".
        let localized = (try? url.resourceValues(forKeys: [.localizedNameKey]))?.localizedName
        let fallback = url.deletingPathExtension().lastPathComponent
        var name = (localized ?? fallback).trimmingCharacters(in: .whitespacesAndNewlines)
        if name.hasSuffix(".app") {
            name = String(name.dropLast(4))
        }
        guard !name.isEmpty else { return nil }

        // Nothing to key a setting on is not a candidate: it would save under
        // "name:Whatever" and the running app would too, but only by accident.
        guard (bundleID?.isEmpty == false) || (executablePath?.isEmpty == false) else {
            return nil
        }

        return InstalledApp(name: name, bundleID: bundleID, executablePath: executablePath)
    }

    private static func truthy(_ value: Any?) -> Bool {
        if let flag = value as? Bool { return flag }
        if let number = value as? NSNumber { return number.boolValue }
        if let text = value as? String {
            return ["1", "true", "yes"].contains(text.lowercased())
        }
        return false
    }

    // MARK: - Matching

    /// The one installed app a phrase names, or `nil`.
    ///
    /// `IntentSearch.mention` rather than `IntentSearch.score`, for the reason
    /// `ConsumerCommandPalette.bestMatchingApp` gives: `score` gates on a result
    /// accounting for half of what was typed, which an app's name in a sentence
    /// never does. The question here is the reversed one — does this phrase name
    /// this app — and `mention` is that question.
    ///
    /// **One app, not a list.** Every match contributes rows to a palette whose
    /// whole failure mode is burying the answer in near-misses; this project has
    /// already measured a search made worse by widening it. `excluding` is the
    /// other half of that: an app Melo already lists, or one the user hid, has
    /// commands of its own, and offering a second set for it would be two rows
    /// claiming to do the same thing with different words.
    static func bestMatch(
        in catalog: [InstalledApp],
        for query: String,
        excluding known: Set<String>
    ) -> InstalledApp? {
        catalog
            .lazy
            .filter { !known.contains($0.persistenceIdentifier) }
            .map { (app: $0, score: mentionScore(of: $0, in: query)) }
            .filter { $0.score >= namingThreshold }
            .max { $0.score < $1.score }?
            .app
    }

    /// How strongly a phrase has to name an app before it counts as naming it.
    ///
    /// `IntentSearch.mention` is tuned for a handful of running apps. Pointed at
    /// three hundred installed ones it fires on any single word that happens to
    /// be in a long product name, and those matches displace real answers.
    /// Measured on this Mac by `scripts/verify-app-search.py`, before the
    /// threshold existed: **three of twenty-one** existing palette queries lost
    /// their top result — "youtube" to a browser extension called *Auto HD FPS
    /// for YouTube* (110), "settings" to *System Settings* (125), and "clear
    /// voices" to *Voice Memos* (125), whose "Voice" is a fuzzy match for
    /// "voices". Every one of those is one word of a name the user did not type.
    ///
    /// 200 is where that behaviour stops and real naming survives: a one-word
    /// app scores 350 when the query contains it outright ("mute godot"), and a
    /// multi-word app needs at least two of its words ("adobe photoshop", 233).
    /// What it costs, stated: a one-word app reached only through a typo —
    /// "godott" scores 150 — is no longer found. Under-offering is the right
    /// direction for a list whose job is to put the answer first.
    static let namingThreshold = 200

    /// The bundle identifier's **last component** is matched as well as the
    /// display name, so "vscode" reaches an app called "Code".
    ///
    /// The last component only. A whole reverse-DNS identifier is mostly
    /// "com.apple.…", which dilutes the word-count ratio `mention` scores on and
    /// hands three matching tokens to any query containing "com": measured, the
    /// full-identifier form is what let `com.apple.systempreferences` be reached
    /// by the bare word "settings".
    static func mentionScore(of app: InstalledApp, in query: String) -> Int {
        var best = IntentSearch.mention(of: app.name, in: query)
        if let shortName = app.bundleID?.split(separator: ".").last, !shortName.isEmpty {
            best = max(best, IntentSearch.mention(of: String(shortName), in: query))
        }
        return best
    }
}
