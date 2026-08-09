// Melo/Editor/Theme/MeloThemeExport.swift
//
// Where a finished remix of the theme goes.
//
// Saving it as a file is the ordinary answer and export already does it. This
// is the other one: the user's version becomes the theme **Melo itself plays**,
// so the edit has somewhere to live instead of sitting in Downloads.
//
// ─────────────────────────────────────────────────────────────────────────────
// SCOPE, AND PLEASE DO NOT "FINISH THE JOB"
//
// This replaces exactly one sound: `MeloTheme.m4a`, the ninety seconds that
// setup's last page and Settings › Replay Tutorial play. One load site,
// `FirstRunOnboardingView.swift`, goes through `MeloThemePlayback.currentURL`.
//
// It must **not** replace `MeloJingle.m4a` at `FirstRunAudioPrimer.swift:38`.
// That clip is played deliberately to raise the macOS system-audio permission
// sheet, and it plays *while the sheet is on screen*. Whatever the user
// recorded, remixed or reversed is a bad surprise at the single worst moment in
// the app — the one where they are deciding whether to trust it with their
// audio. The primer keeps the bundled jingle, always.
// ─────────────────────────────────────────────────────────────────────────────

import AVFoundation
import Foundation
import SwiftUI
import os

/// Which file Melo plays when it plays its theme.
///
/// The single indirection point. Callers ask this instead of asking the bundle,
/// and it answers with the user's version when there is one and the bundled
/// song when there is not.
enum MeloThemePlayback {

    /// Just the file name, stored in Melo's own directory. A full path would
    /// go stale the moment the user moved or deleted the file they exported;
    /// a name inside a directory Melo owns cannot.
    private static let adoptedFileKey = "MeloAdoptedThemeFilename"

    /// `~/Library/Application Support/Melo/Theme`
    nonisolated static var directory: URL {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support")
        return support
            .appendingPathComponent("Melo")
            .appendingPathComponent("Theme")
    }

    /// The user's adopted theme, if they have one and it is still on disk.
    nonisolated static var adoptedURL: URL? {
        guard let name = UserDefaults.standard.string(forKey: adoptedFileKey),
              !name.isEmpty,
              // Defensive because this string is round-tripped through defaults:
              // a name carrying a path separator would escape the directory.
              !name.contains("/")
        else { return nil }
        let url = directory.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// **The theme Melo plays.** Ask this, not the bundle.
    ///
    /// `nil` only when there is no adopted file *and* the bundled resource is
    /// missing from the build, which `scripts/verify-apple-refinement.py`
    /// already fails on.
    nonisolated static var currentURL: URL? {
        adoptedURL ?? MeloThemeRemix.bundledURL
    }

    nonisolated static var isPlayingUserVersion: Bool { adoptedURL != nil }

    fileprivate nonisolated static func setAdoptedFileName(_ name: String?) {
        if let name {
            UserDefaults.standard.set(name, forKey: adoptedFileKey)
        } else {
            UserDefaults.standard.removeObject(forKey: adoptedFileKey)
        }
    }
}

/// Adopting a rendered file as Melo's theme, and putting the original back.
enum MeloThemeExport {

    private static let logger = Logger(
        subsystem: "io.github.megavessal.Melo",
        category: "MeloThemeExport"
    )

    /// Three minutes.
    ///
    /// Setup decodes the theme whole into one `AVAudioPCMBuffer` so it can loop
    /// on the render thread without a completion handler
    /// (`OnboardingVolumeDemo.prepare()`). Three minutes of 48 kHz stereo float
    /// is roughly 69 MB resident for as long as the setup window is open, which
    /// is a real cost and the reason there is a limit at all. The bundled theme
    /// is ninety seconds, so this is twice as much room as the thing it
    /// replaces.
    static let maximumDuration: TimeInterval = 180

    /// Makes `url` the theme Melo plays.
    ///
    /// The file is copied into Melo's own directory, so deleting the export
    /// later does not silently break setup. This is a real boundary — the file
    /// came from the user — so it is opened and measured before anything is
    /// written or any preference changes.
    @discardableResult
    nonisolated static func adopt(_ url: URL) throws -> URL {
        // Adopting the file that is already adopted. The sweep below empties
        // the directory before it copies, so without this the source would be
        // deleted and the copy would fail — leaving no theme at all.
        if let current = MeloThemePlayback.adoptedURL,
           current.standardizedFileURL == url.standardizedFileURL {
            return current
        }

        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw Failure.unreadable(url.lastPathComponent)
        }

        let rate = file.processingFormat.sampleRate
        guard file.length > 0, rate > 0 else { throw Failure.empty(url.lastPathComponent) }
        let duration = Double(file.length) / rate
        guard duration <= maximumDuration else { throw Failure.tooLong(duration) }

        let manager = FileManager.default
        let name = "Your Theme.\(url.pathExtension.isEmpty ? "m4a" : url.pathExtension)"
        let destination = MeloThemePlayback.directory.appendingPathComponent(name)

        do {
            try manager.createDirectory(
                at: MeloThemePlayback.directory,
                withIntermediateDirectories: true
            )
            // Clear out any previously adopted file, whatever it was called, so
            // switching from a .wav to an .m4a does not leave the old one lying
            // around pretending to be current.
            for stale in (try? manager.contentsOfDirectory(
                at: MeloThemePlayback.directory,
                includingPropertiesForKeys: nil
            )) ?? [] {
                try? manager.removeItem(at: stale)
            }
            try manager.copyItem(at: url, to: destination)
        } catch {
            logger.error("Could not adopt a theme: \(error.localizedDescription, privacy: .public)")
            throw Failure.couldNotSave(error.localizedDescription)
        }

        MeloThemePlayback.setAdoptedFileName(name)
        return destination
    }

    /// Puts the bundled song back. Deletes the copy — keeping it would mean a
    /// file the user cannot see and did not ask Melo to hold on to.
    nonisolated static func revertToBundledTheme() {
        if let adopted = MeloThemePlayback.adoptedURL {
            try? FileManager.default.removeItem(at: adopted)
        }
        MeloThemePlayback.setAdoptedFileName(nil)
    }

    enum Failure: LocalizedError, Equatable {
        case unreadable(String)
        case empty(String)
        case tooLong(TimeInterval)
        case couldNotSave(String)

        var errorDescription: String? {
            switch self {
            case let .unreadable(name):
                "Melo can't open \(name)."
            case let .empty(name):
                "\(name) has no audio in it."
            case let .tooLong(duration):
                "\(EditorFormat.timecode(duration)) is too long for a theme. Three minutes is the limit."
            case let .couldNotSave(reason):
                "Melo couldn't keep a copy of your theme. \(reason)"
            }
        }
    }
}

// MARK: - The offer

/// The row that offers it, ready to be dropped into the export sheet.
///
/// Lives here rather than in `Editor/Export/` because the behaviour, the
/// preference and the scope note above are all one thing and splitting them is
/// how the jingle ends up replaced by accident.
@MainActor
struct MeloThemeAdoptionRow: View {
    /// The rendered file, once export has written one. `nil` disables the
    /// offer rather than hiding it, so the row does not appear and disappear
    /// while a render runs.
    let renderedURL: URL?

    @State private var isPlayingUserVersion = MeloThemePlayback.isPlayingUserVersion
    @State private var failure: String?

    init(renderedURL: URL?) {
        self.renderedURL = renderedURL
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            HStack(spacing: DesignTokens.Spacing.sm) {
                Image(systemName: "music.note.house")
                    .font(DesignTokens.Typography.Scale.body())
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
                    .frame(width: DesignTokens.Dimensions.iconSizeSmall)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                    Text(isPlayingUserVersion ? "Melo is playing your version" : "Make it Melo's theme")
                        .font(DesignTokens.Typography.Scale.headline())
                        .foregroundStyle(DesignTokens.Colors.textPrimary)
                    Text(isPlayingUserVersion
                         ? "Setup and Replay Tutorial play this instead of the original."
                         : "Setup and Replay Tutorial will play this instead of the original.")
                        .font(DesignTokens.Typography.Scale.caption())
                        .foregroundStyle(DesignTokens.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: DesignTokens.Spacing.sm)

                if isPlayingUserVersion {
                    Button("Put the original back") { revert() }
                        .font(DesignTokens.Typography.Scale.footnote())
                        .buttonStyle(.link)
                        .frame(minHeight: DesignTokens.Dimensions.minTouchTarget)
                } else {
                    Button("Use it") { adopt() }
                        .font(DesignTokens.Typography.Scale.footnote())
                        .disabled(renderedURL == nil)
                        .frame(minHeight: DesignTokens.Dimensions.minTouchTarget)
                }
            }
            .padding(.horizontal, DesignTokens.Spacing.sm)
            .padding(.vertical, DesignTokens.Spacing.xs2)

            if let failure {
                Text(failure)
                    .font(DesignTokens.Typography.Scale.caption())
                    .foregroundStyle(DesignTokens.Colors.mutedIndicator)
                    .padding(.horizontal, DesignTokens.Spacing.sm)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .contentShape(Rectangle())
        .animation(DesignTokens.Animation.hover, value: isPlayingUserVersion)
    }

    private func adopt() {
        guard let renderedURL else { return }
        do {
            try MeloThemeExport.adopt(renderedURL)
            failure = nil
            isPlayingUserVersion = true
        } catch {
            failure = error.localizedDescription
        }
    }

    private func revert() {
        MeloThemeExport.revertToBundledTheme()
        failure = nil
        isPlayingUserVersion = false
    }
}
