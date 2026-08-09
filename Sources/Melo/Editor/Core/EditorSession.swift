// Melo/Editor/Core/EditorSession.swift
//
// The sidecar that makes the move stack survive closing the window. Reopening
// a file you were working on yesterday puts the stack back — which is the point
// of editing non-destructively at all. If the stack disappears with the window,
// it is just an undo history with extra steps.
//
// Lives in `~/Library/Application Support/Melo/CuttingRoom/` — still the 3.1.0
// spelling, because it holds the user's saved move stacks and renaming the
// directory would orphan every one of them. Beside the
// AutoEQ cache, and reaches that directory the same way `AutoEQFetcher` and
// `AutoEQProfileLoader` do.

import CryptoKit
import Foundation
import os

struct EditorSession: Codable, Equatable, Sendable {
    /// **The 3.1.x key, and it stays.** In 3.2 this is the *master* list, which
    /// is exactly what the old flat list meant: moves applied to the whole
    /// sound. Two reasons it is still written rather than folded into `tracks`.
    /// One, downgrade is a path people take — every release from 2.9.0 on is
    /// still attached to the releases page — and a 3.1.x build reading a
    /// sidecar with no `moves` key fails the decode and silently discards the
    /// stack. Two, it is what a 3.1.x sidecar carries, so `restore(into:)` has
    /// one field to read on both sides of the migration.
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
    /// **Written, never read, and kept on purpose.** The sidecar's own file
    /// modification date carries the same fact, so an unreferenced-declaration
    /// sweep will keep finding this and proposing it for deletion. Do not take
    /// it: every Melo release from 2.9.0 on is still attached to the GitHub
    /// releases page, so downgrade is a path people actually take, and this key
    /// is not optional. A 3.1.0 install decoding a sidecar written without it
    /// fails the decode and **silently discards the user's move stack** — no
    /// crash, no error, just work that does not come back, which is the failure
    /// mode this project spends the most effort avoiding. Rejected 2026-08-09:
    /// removing it as a write-only member. One unread `Date` is the whole cost.
    var savedAt: Date

    // MARK: 3.2 — the timeline
    //
    // **Both optional, and that is the entire migration mechanism.** A 3.1.x
    // sidecar has neither key, decodes cleanly with both `nil`, and
    // `restore(into:)` reads that as "one track, one clip, moves on the
    // master". Adding either as non-optional would fail the decode of every
    // sidecar written by every previous build, so the first open after the
    // update would erase every move stack on the machine — the schema trap
    // `load(for:)` already carries a comment about, sprung from the other end.

    /// The whole source pool, because a clip refers to a source by id and a
    /// restored track means nothing without the file it points at. The primary
    /// file's entry is re-probed on load; the rest are taken as saved.
    var sources: [EditorSource]?
    /// The lanes, their clips, and their per-track and per-clip moves.
    var tracks: [Track]?

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
            logger.warning("Ignoring an unreadable Melo Edit session")
            return nil
        }
        guard let current = Fingerprint.of(url), current == session.fingerprint else {
            logger.info("Melo Edit session ignored: the file changed since it was saved")
            return nil
        }
        return session
    }

    // MARK: - Restore, across the 3.1 → 3.2 line

    /// Puts a saved session back onto a document that has just been opened.
    ///
    /// `document` arrives in the default shape — one source, one track, one
    /// clip covering the whole of it — and that shape is also the answer for
    /// every sidecar written before tracks existed. So the migration is not a
    /// conversion step with its own failure modes: it is the branch that leaves
    /// the default alone and puts `moves` on the master, which is what those
    /// moves always meant.
    ///
    /// **Nobody sees a notice**, and nobody loses a stack. Anything about the
    /// saved timeline that does not fit the file actually on disk falls back to
    /// that same branch rather than dropping the moves.
    func restore(into document: inout EditorDocument) {
        document.analysis = analysis
        document.destination = destinationID.flatMap { identifier in
            DestinationCatalogue.all.first { $0.id == identifier }
        }
        document.master = moves

        // 3.1.x, or a 3.2 sidecar saved with nothing on the timeline: the
        // default document is already right.
        guard let savedTracks = tracks, !savedTracks.isEmpty,
              let savedSources = sources, !savedSources.isEmpty else { return }

        // The freshly probed source is authoritative about the file — it was
        // just read, and `openSource` has already stamped the caller's origin
        // and display name onto it. The saved entry is authoritative about its
        // **id**, which is what every restored clip points at. Take both.
        let probed = document.source
        guard let index = savedSources.firstIndex(where: { $0.url == probed.url }) else {
            // The saved timeline does not mention the file we opened, so it
            // does not describe this document. Keep the moves, drop the layout.
            Self.logger.info("Melo Edit session had a timeline for a different file; kept the moves")
            return
        }

        var pool = savedSources
        var primary = probed
        primary.id = savedSources[index].id
        pool[index] = primary

        document.sources = pool
        document.tracks = savedTracks
    }

    // MARK: - Save

    /// Writes the sidecar for `document`. Silent on failure by design: a
    /// sidecar that cannot be written must not interrupt an edit, and the user
    /// loses nothing they can see until they close the window.
    static func save(_ document: EditorDocument) {
        let url = document.source.url
        guard let fingerprint = Fingerprint.of(url) else { return }

        let session = EditorSession(
            moves: document.master,
            destinationID: document.destination?.id,
            analysis: document.analysis,
            fingerprint: fingerprint,
            savedAt: Date(),
            sources: document.sources,
            tracks: document.tracks
        )

        do {
            try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
            let data = try makeEncoder().encode(session)
            try data.write(to: fileURL(for: url), options: .atomic)
        } catch {
            logger.error("Couldn't write the Melo Edit session: \(error.localizedDescription, privacy: .public)")
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
    /// Support holds everything Melo Edit owns.
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
