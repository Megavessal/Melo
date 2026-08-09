// Melo/Editor/Core/EditorSession.swift
//
// The sidecar that makes the move stack survive closing the window. Reopening
// a file you were working on yesterday puts the stack back — which is the point
// of editing non-destructively at all. If the stack disappears with the window,
// it is just an undo history with extra steps.
//
// Lives in `~/Library/Application Support/Melo/CuttingRoom/`, beside the
// AutoEQ cache, and reaches that directory the same way `AutoEQFetcher` and
// `AutoEQProfileLoader` do.

import CryptoKit
import Foundation
import os

struct EditorSession: Codable, Equatable, Sendable {
    var moves: [Move]
    /// The destination's id, not the destination. Resolved through
    /// `DestinationCatalogue.all` on load, so a session restored next month
    /// gets that month's published targets rather than a frozen copy of the
    /// numbers from the day it was saved.
    var destinationID: String?
    /// Kept because measuring a long file is expensive and the file has not
    /// changed — `fingerprint` is what makes that safe to assume.
    var analysis: AnalysisReport?
    var fingerprint: Fingerprint
    var savedAt: Date

    /// Cheap evidence that the file on disk is still the file we measured.
    /// Size and modification date, not a content hash: hashing a 400 MB WAV on
    /// every open would cost more than everything the sidecar saves.
    struct Fingerprint: Codable, Equatable, Sendable {
        var byteCount: Int64
        var modifiedAt: Date

        static func of(_ url: URL) -> Fingerprint? {
            guard let values = try? url.resourceValues(
                forKeys: [.fileSizeKey, .contentModificationDateKey]
            ), let size = values.fileSize, let modified = values.contentModificationDate else {
                return nil
            }
            // **Floored to whole seconds, and this is load-bearing.** The
            // sidecar encodes this with `.iso8601`, which keeps whole seconds
            // and nothing finer, so an unfloored APFS mtime never survives its
            // own round trip and every sidecar is discarded on the next open.
            // See CLAUDE.md, "A `Codable` fingerprint that mixes `.iso8601`
            // with a filesystem timestamp is always unequal to itself".
            let seconds = modified.timeIntervalSince1970.rounded(.down)
            return Fingerprint(
                byteCount: Int64(size),
                modifiedAt: Date(timeIntervalSince1970: seconds)
            )
        }
    }
}

extension EditorSession {

    // There was a cap here — newest two hundred sidecars kept, oldest deleted
    // on write — and it is gone for the same reason the source prune is. A
    // sidecar is small, but it is the user's move stack, and silently dropping
    // the two-hundred-and-first is the same defect at a smaller scale. Two
    // hundred sessions is under 200 KB, so the cap was never buying storage;
    // it was buying tidiness at the price of somebody's work. Keeping it while
    // the directory twenty lines below is documented as deliberately unbounded
    // would have shipped two contradictory policies in one file.

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Melo",
        category: "EditorSession"
    )

    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Melo")
            .appendingPathComponent("CuttingRoom")
    }

    /// SHA-256 of the file's resolved absolute path.
    ///
    /// Keyed by path, which means renaming or moving the file loses its stack.
    /// The alternative — keying by a hash of the file's *contents* — survives a
    /// move but has to read the whole file before the editor can show anything,
    /// on every open, for a feature the user notices only when it works. The
    /// path is also what identifies the file everywhere else in the UI, so
    /// losing the stack on a rename is at least consistent with what the user
    /// just did. Hashed rather than escaped so the filename is a fixed length
    /// and reveals nothing about where the user keeps their audio.
    static func key(for url: URL) -> String {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        let digest = SHA256.hash(data: Data(path.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func fileURL(for url: URL) -> URL {
        directory.appendingPathComponent("\(key(for: url)).json")
    }

    // MARK: - Load

    /// The saved session for this file, or `nil` when there is none, when the
    /// file has changed underneath it, or when the sidecar cannot be read.
    /// Every one of those is the same answer to the caller: start clean.
    static func load(for url: URL) -> EditorSession? {
        let location = fileURL(for: url)
        guard let data = try? Data(contentsOf: location) else { return nil }
        guard let session = try? makeDecoder().decode(EditorSession.self, from: data) else {
            // Left on disk deliberately. This used to delete the file, which
            // reads as tidying up a corrupt sidecar but is really a schema
            // trap: add one non-optional field to `EditorSession` and every
            // sidecar written by every previous build fails to decode, so the
            // first open after the update erases every move stack the user has.
            // Ignoring it costs one failed decode and the next save overwrites
            // it anyway, because the key is the same.
            logger.warning("Ignoring an unreadable Cutting Room session")
            return nil
        }
        guard let current = Fingerprint.of(url), current == session.fingerprint else {
            logger.info("Cutting Room session ignored: the file changed since it was saved")
            return nil
        }
        return session
    }

    // MARK: - Save

    /// Writes the sidecar for `document`. Silent on failure by design: a
    /// sidecar that cannot be written must not interrupt an edit, and the user
    /// loses nothing they can see until they close the window.
    static func save(_ document: EditorDocument) {
        let url = document.source.url
        guard let fingerprint = Fingerprint.of(url) else { return }

        let session = EditorSession(
            moves: document.moves,
            destinationID: document.destination?.id,
            analysis: document.analysis,
            fingerprint: fingerprint,
            savedAt: Date()
        )

        do {
            try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
            let data = try makeEncoder().encode(session)
            try data.write(to: fileURL(for: url), options: .atomic)
        } catch {
            logger.error("Couldn't write the Cutting Room session: \(error.localizedDescription, privacy: .public)")
        }
    }

}

// MARK: - Durable sources

/// Where audio that Melo itself produced goes to live.
///
/// A link extraction and a system recording both land in
/// `FileManager.temporaryDirectory`, which macOS is entitled to empty whenever
/// it likes. The recording is the sharp case: the user made that audio, it
/// exists nowhere else, and nothing told them it was temporary. A temp path is
/// also exactly the kind of location that changes, and the sidecar is keyed on
/// the source path — the same failure the theme piece caught for the app
/// bundle, one directory along.
///
/// One rule, four origins, decided here rather than in the two callers that
/// happen to produce temporary files.
enum EditorSourceStore {

    /// A subdirectory of the sidecar folder, so one place in Application
    /// Support holds everything the Cutting Room owns.
    static var directory: URL {
        EditorSession.directory.appendingPathComponent("Sources")
    }

    // **This directory grows without bound, and that is the decision.**
    //
    // An age-based prune was written and removed. It deleted adopted sources
    // nobody had touched in thirty days, and the case for it was that an
    // unbounded folder of forty-minute recordings is its own quiet defect. It
    // is not: the file here may be the only copy of audio the user made, the
    // deletion is silent, and nobody discovers it at the moment it happens —
    // they discover it a month later when the thing is gone.
    //
    // `scripts/verify-unasked-actions.py` is a compiled, executed regression
    // gate this project already maintains against three things Melo used to do
    // without being asked, one of which was merely fetching a URL at launch.
    // Deleting the user's recording is an order of magnitude past that. Photos
    // does not delete your photos to save space.
    //
    // Nothing here may delete a source as a consequence of opening a document,
    // and no timer may do it either. If this folder ever needs emptying, the
    // user does it deliberately, from a UI that shows them what is in it — the
    // window owns reaching the folder from the empty state, beside recents.

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Melo",
        category: "EditorSourceStore"
    )

    /// The URL the editor should actually open, given where the audio came
    /// from. `.file` and `.meloTheme` already have durable homes — one is a
    /// file the user chose, the other is the staged copy
    /// `MeloThemeRemix.preparedSourceURL()` makes — so both are left exactly
    /// where they are.
    static func durableURL(for url: URL,
                           origin: EditorSource.Origin,
                           displayName: String?) -> URL {
        switch origin {
        case .file, .meloTheme:
            return url
        case .extractedFromLink, .systemRecording:
            return adopt(
                url,
                displayName: displayName ?? url.deletingPathExtension().lastPathComponent
            )
        }
    }

    /// Takes ownership of a file Melo wrote.
    ///
    /// **A move, not a copy**, and the deciding reason is not the obvious one.
    ///
    /// The obvious reasons are real: Melo produced this file, the caller hands
    /// it over and does not keep using it, and on one volume a rename is
    /// instant where copying forty minutes of audio is real time and a second
    /// copy of real disk.
    ///
    /// The deciding reason is that **a rename preserves the modification date
    /// and a copy resets it.** `EditorSession.Fingerprint` is size plus mtime.
    /// Copy this file instead of moving it and every adopted source looks
    /// changed the instant it arrives, so `load(for:)` discards the sidecar on
    /// the very next open — quietly breaking the exact thing adoption exists to
    /// protect. Anyone tempted to make this a copy for safety has to answer
    /// that first.
    ///
    /// Returns the original URL if the move fails. A recording that is still
    /// sitting in the temporary directory is worse than one that is not, but it
    /// is far better than refusing to open the thing the user just made.
    static func adopt(_ url: URL, displayName: String) -> URL {
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            let destination = directory.appendingPathComponent(
                adoptedName(for: url, displayName: displayName)
            )
            try manager.moveItem(at: url, to: destination)
            return destination
        } catch {
            logger.error("Couldn't adopt a source: \(error.localizedDescription, privacy: .public)")
            return url
        }
    }

    /// Legible, because the user may open this folder, and unique, because two
    /// recordings can start in the same second. The name on disk is not what
    /// the UI shows — `EditorSource.displayName` is — so the suffix costs
    /// nothing the user reads.
    private static func adoptedName(for url: URL, displayName: String) -> String {
        let permitted = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_"))
        let cleaned = displayName
            .components(separatedBy: permitted.inverted)
            .joined()
            .trimmingCharacters(in: .whitespaces)
        let stem = cleaned.isEmpty ? "Recording" : String(cleaned.prefix(60))
        let unique = UUID().uuidString.prefix(8).lowercased()
        let ext = url.pathExtension
        return ext.isEmpty ? "\(stem) \(unique)" : "\(stem) \(unique).\(ext)"
    }
}

// MARK: - Coders

// Built per call rather than cached in a `static let`: `JSONEncoder` is not
// `Sendable`, so a shared instance is a Swift 6 error, and constructing one is
// nothing next to the file write it precedes.

private func makeEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    // ISO-8601 so a sidecar written by one build reads in the next, and so the
    // file is legible if anyone ever opens it.
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return encoder
}

private func makeDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
}
