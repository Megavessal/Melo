import Foundation
import os

/// Carries the preferences Melo wrote under its old bundle identifier into the
/// domain the renamed app reads.
///
/// Melo shipped through build 299 as `dev.local.Melo`, a placeholder. macOS keys
/// `UserDefaults.standard` by bundle identifier and nothing else, so renaming the
/// app to `io.github.megavessal.Melo` pointed every read at an empty domain while
/// `~/Library/Preferences/dev.local.Melo.plist` sat untouched beside it. Measured
/// on a real install before the rename, that file held `SUEnableAutomaticChecks`,
/// `SUAutomaticallyUpdate`, `SUHasLaunchedBefore`, `SULastCheckTime`,
/// `SUSkippedVersion`, `SUUpdateGroupIdentifier`, `installLocation.deferredForBuild`,
/// `melo.audio-unit-profiles.v1` and `updates.skippedUpdate`. Without this the
/// upgrade reads as a first launch: Sparkle re-asks questions the user already
/// answered, a skipped version comes back, the deferred move-to-Applications
/// prompt returns, and every saved audio-unit profile is gone.
///
/// `~/Library/Application Support/Melo/settings.json` is *not* affected —
/// `SettingsManager.defaultBaseDirectory()` builds that path from the literal
/// "Melo", not from the bundle identifier — so the main settings file needs no
/// migration and is deliberately not touched here.
///
/// Copy, not move. Leaving the old plist where it is costs nothing, keeps the
/// upgrade recoverable by hand if this is wrong, and is the reason
/// `AppSupportCoordinator.eraseAllDataAndRestart` has to delete both domains:
/// erasing only the new one would leave this migration free to restore
/// everything the user just asked to be rid of.
enum LegacyDefaultsMigration {
    static let legacyDomain = "dev.local.Melo"

    /// Written into the *destination* domain, so "has this run" is answered by
    /// the same store the copy writes to. A flag kept anywhere else could say
    /// yes about a domain that had since been erased.
    static let completionKey = "migration.legacyDefaultsDomain.v1"

    enum Outcome: Equatable {
        /// The flag was already set. Nothing was read and nothing was written.
        case alreadyDone
        /// No legacy plist, or an empty one — a fresh install. The flag is still
        /// set, so this lookup happens once per install rather than every launch.
        case nothingToCopy
        /// Keys actually written, in the order they were written.
        case copied([String])
    }

    /// Must run before anything reads `UserDefaults.standard`. In `MeloApp.init`
    /// that means before `SparkleUpdateController()`, which reads `SUSkippedVersion`
    /// and the Sparkle check settings in its own initialiser.
    ///
    /// - Parameters:
    ///   - destination: The store to copy into. Writes land in this object's
    ///     application domain.
    ///   - destinationDomain: The name of that application domain. Read
    ///     separately from `destination` because `object(forKey:)` searches the
    ///     whole defaults chain — NSGlobalDomain, the argument domain, the
    ///     registration domain — and a key found there is not a key this app has
    ///     stored. Answering "does the new domain already have this?" with the
    ///     search chain would skip real keys and drop them on the floor.
    @discardableResult
    static func runIfNeeded(
        into destination: UserDefaults = .standard,
        destinationDomain: String = Bundle.main.bundleIdentifier ?? "io.github.megavessal.Melo",
        legacyDomain: String = LegacyDefaultsMigration.legacyDomain,
        logger: Logger? = Logger(subsystem: "io.github.megavessal.Melo", category: "DefaultsMigration")
    ) -> Outcome {
        // A no-op second run is the whole contract: this is called from an
        // initialiser that runs on every launch, and a re-copy would resurrect
        // values the user changed after the first one.
        guard destination.object(forKey: completionKey) as? Bool != true else {
            return .alreadyDone
        }

        guard destinationDomain != legacyDomain else {
            // The identifiers are the same, so there is nothing to move and the
            // loop below would read and rewrite the domain it is standing in.
            destination.set(true, forKey: completionKey)
            return .nothingToCopy
        }

        let legacy = destination.persistentDomain(forName: legacyDomain) ?? [:]
        guard !legacy.isEmpty else {
            destination.set(true, forKey: completionKey)
            logger?.info("No legacy preferences domain to migrate.")
            return .nothingToCopy
        }

        let existing = destination.persistentDomain(forName: destinationDomain) ?? [:]
        var copied: [String] = []
        // Sorted so a failure part-way through is reproducible rather than
        // dependent on dictionary ordering.
        for key in legacy.keys.sorted() {
            // A key the new domain already holds was written by this build and
            // is newer than the one in the old plist. The old value must not win.
            guard existing[key] == nil, key != completionKey else { continue }
            destination.set(legacy[key], forKey: key)
            copied.append(key)
        }

        destination.set(true, forKey: completionKey)
        logger?.info("Migrated \(copied.count, privacy: .public) preference key(s) from \(legacyDomain, privacy: .public).")
        return .copied(copied)
    }
}
