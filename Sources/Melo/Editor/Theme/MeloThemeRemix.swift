// Melo/Editor/Theme/MeloThemeRemix.swift
//
// The bundled theme, handed to the user to cut up.
//
// **A naming collision worth reading once.** Two unrelated things in this
// project are called "the Melo theme". This file is about
// `Resources/MeloTheme.m4a`, the ninety-second boom-bap song. The *other* one
// is `MeloVisualTheme` / `GeneratedMeloTheme` in `Views/DesignSystem/`, which
// is the colour system for the popup backdrop and has nothing to do with any of
// this. Nothing here touches it, and `scripts/verify-theme-studio.py` guards it
// closely enough that an accidental edit there fails the build for reasons that
// look nothing like an audio change.

import AVFoundation
import Foundation
import os

/// Resolves the bundled theme into something editable and opens it.
enum MeloThemeRemix {

    // MARK: - The song, measured

    /// The theme is exactly 32 bars, per the render that produced it
    /// (`Melo 3.0`: "Trimmed to exactly 32 bars with the last bar's decay
    /// wrapped over the start").
    static let barCount = 32

    /// Measured 2026-08-09 with `afinfo Resources/MeloTheme.m4a`: 4,286,511
    /// valid frames at 48 kHz = **89.3023 s**, which is 128 beats at 86.00 BPM
    /// to within half a millisecond. So: 32 bars of 4/4 at 86 BPM, one bar
    /// every 2.7907 s.
    ///
    /// Nothing below hardcodes this. It is the sanity value for
    /// `looksLikeTheTheme(_:)` and the fallback when a duration is not
    /// available yet; every real position is derived from the duration the
    /// decoder actually reports, so re-rendering the track at a different
    /// length moves the cuts with it instead of leaving them behind.
    static let measuredDuration: TimeInterval = 89.3023

    /// One bar of a theme that is `duration` long.
    ///
    /// Proportional rather than absolute, which is what makes it safe: bar 8 of
    /// this is a quarter of the way in whatever the file turns out to be.
    nonisolated static func barLength(in duration: TimeInterval) -> TimeInterval {
        guard duration.isFinite, duration > 0 else { return 0 }
        return duration / Double(barCount)
    }

    /// The time of a bar *line* — `bar` counts lines, not bars, so 0 is the very
    /// start, 8 is the downbeat of the ninth bar, and 32 is the end.
    nonisolated static func time(atBar bar: Int, in duration: TimeInterval) -> TimeInterval {
        let clamped = min(max(bar, 0), barCount)
        return barLength(in: duration) * Double(clamped)
    }

    /// Whether a duration is close enough to the bundled theme that the bar
    /// arithmetic above means what it says. Two percent either way covers an
    /// encoder's priming and remainder frames without covering a different song.
    nonisolated static func looksLikeTheTheme(_ duration: TimeInterval) -> Bool {
        guard duration.isFinite, duration > 0 else { return false }
        return abs(duration - measuredDuration) / measuredDuration <= 0.02
    }

    // MARK: - Getting at it

    private static let logger = Logger(
        subsystem: "io.github.megavessal.Melo",
        category: "MeloThemeRemix"
    )

    /// The song as it ships. `nil` only if the resource fell out of the build
    /// phase, which `scripts/verify-apple-refinement.py` already fails on.
    nonisolated static var bundledURL: URL? {
        Bundle.main.url(forResource: "MeloTheme", withExtension: "m4a")
    }

    /// `~/Library/Application Support/Melo/Cutting Room`, alongside the
    /// `Melo/AutoEQ` directory the profile loader already writes into.
    nonisolated static var workingDirectory: URL {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support")
        return support
            .appendingPathComponent("Melo")
            .appendingPathComponent("Cutting Room")
    }

    /// A writable copy of the theme, made if it is not already there.
    ///
    /// **The copy is the whole trick.** The bundled resource lives inside the
    /// app bundle, which is code-signed and must never be written to; handing
    /// its URL to the editor would work right up until something wrote a file
    /// beside it. The name carries a space because it becomes the document's
    /// display name.
    ///
    /// Call this rather than `bundledURL` from anything that opens the theme —
    /// this is the seam `CuttingRoomStore.openMeloTheme()` is meant to use.
    nonisolated static func preparedSourceURL() throws -> URL {
        guard let bundled = bundledURL else { throw Failure.themeMissingFromBundle }

        let destination = workingDirectory.appendingPathComponent("Melo Theme.m4a")
        let manager = FileManager.default

        // Reuse the copy when it is byte-for-byte the same size as the one that
        // shipped. Anything else — an update carrying a new render, a truncated
        // write from a previous run — gets replaced rather than trusted.
        if manager.fileExists(atPath: destination.path),
           let existing = try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           let shipped = try? bundled.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           existing == shipped {
            return destination
        }

        do {
            try manager.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
            if manager.fileExists(atPath: destination.path) {
                try manager.removeItem(at: destination)
            }
            try manager.copyItem(at: bundled, to: destination)
        } catch {
            logger.error("Could not stage the theme for editing: \(error.localizedDescription, privacy: .public)")
            throw Failure.couldNotStage(error.localizedDescription)
        }
        return destination
    }

    /// Opens the Cutting Room on the theme.
    ///
    /// The window comes up first and the store reports its own failure through
    /// the same path every other open uses — a button that shows nothing when
    /// staging fails is the dead-button signature this project has already
    /// measured once.
    @MainActor
    static func openInCuttingRoom() {
        CuttingRoomWindowController.shared.show()
        Task { await CuttingRoomStore.shared.openMeloTheme() }
    }

    // MARK: - Failures

    enum Failure: LocalizedError, Equatable {
        case themeMissingFromBundle
        case couldNotStage(String)

        var errorDescription: String? {
            switch self {
            case .themeMissingFromBundle:
                "Melo's theme is missing from this build."
            case let .couldNotStage(reason):
                "Melo could not make a copy of its theme to edit. \(reason)"
            }
        }
    }
}
