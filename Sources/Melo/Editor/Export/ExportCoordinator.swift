// Melo/Editor/Export/ExportCoordinator.swift
//
// Running an export as an `EditorJob`: render, encode, say what is happening
// in words while it happens, cancel cleanly, and never leave a truncated file
// wearing the right name.
//
// The job goes into `CuttingRoomStore.jobs` like every other long operation,
// so one strip shows decode, analysis, re-render, extraction, recording and
// export together.

import AppKit
import Foundation
import UserNotifications
import os

private let exportLogger = Logger(subsystem: "io.github.megavessal.Melo", category: "Export")

/// How the two long stages divide the bar. Both fractions are real; the split
/// between them is a guess about relative cost, and the remaining-time readout
/// corrects for a bad guess because it measures the bar's own rate rather than
/// trusting these.
///
/// File scope rather than nested in the coordinator: the worker that reads
/// them is `nonisolated`, and a type nested in a `@MainActor` class inherits
/// that isolation.
private enum ExportWeight {
    static let prepare = 0.02
    static let render = 0.60
    static let encode = 0.36
}

/// What landed on disk.
private struct ExportProduct: Sendable {
    var url: URL
    var format: AudioFormatKind
    var byteCount: Int64
}

// MARK: - Outcome

/// What was written, and what it did to the sound. The three comparison lines
/// are the moment the feature justifies itself: without them "make it better"
/// is unfalsifiable.
struct ExportOutcome: Identifiable, Equatable {
    let id: UUID
    /// The job still sitting in `store.jobs` holding this card on screen.
    var jobID: UUID
    var url: URL
    var format: AudioFormatKind
    var byteCount: Int64
    /// Measured at import, before a single move was applied. `nil` when the
    /// file was never analysed.
    var before: AnalysisReport?
    /// Measured from the file that was just written. `nil` while the
    /// measurement is running, or if it could not be taken.
    var after: AnalysisReport?
    var isMeasuring: Bool
    var sourceDuration: TimeInterval
    var outputDuration: TimeInterval?
    var destination: Destination?
    /// True when the sound being exported was Melo's own theme. The one case
    /// where an export has somewhere to go inside the app rather than only
    /// onto disk.
    var isThemeExport: Bool
}

// MARK: - Where it goes

/// Resolving the file the export writes to. Apart from the sheet so the sheet
/// can show the name the user will actually end up with.
enum ExportDestination {

    /// The folder Melo offers first: next to the original, and Downloads when
    /// there is no original to sit beside.
    static func defaultFolder(for source: EditorSource) -> URL {
        if case .file(let originalURL) = source.origin {
            let folder = originalURL.deletingLastPathComponent()
            if FileManager.default.fileExists(atPath: folder.path) { return folder }
        }
        return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
    }

    /// A URL nothing is standing on. Finder's own behaviour: keep the name, add
    /// a number. The editor promised never to touch the original file, and this
    /// is where that promise is kept.
    static func unique(_ url: URL) -> URL {
        guard FileManager.default.fileExists(atPath: url.path) else { return url }
        let folder = url.deletingLastPathComponent()
        let stem = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        for attempt in 2...999 {
            let candidate = folder
                .appendingPathComponent("\(stem) \(attempt)")
                .appendingPathExtension(ext)
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return folder
            .appendingPathComponent("\(stem) \(UUID().uuidString.prefix(6))")
            .appendingPathExtension(ext)
    }

    /// Strips what a file name cannot carry without mangling the rest.
    static func sanitise(_ name: String) -> String {
        let cleaned = name
            .components(separatedBy: CharacterSet(charactersIn: ":/\\"))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Untitled" : cleaned
    }
}

// MARK: - Coordinator

@MainActor
final class ExportCoordinator: ObservableObject {

    static let shared = ExportCoordinator()

    /// The last export that landed. Held apart from the job list because it is
    /// a result, not a progress row: it carries the before-and-after and the
    /// way back to the file.
    @Published private(set) var outcome: ExportOutcome?

    /// The most recent rendering of the Melo theme this session, so the export
    /// sheet can still offer to adopt it after the result card has gone.
    @Published private(set) var lastThemeExportURL: URL?

    private var measurement: Task<Void, Never>?
    private var dismissal: Task<Void, Never>?
    private var hasEverExported = false

    // MARK: Starting

    /// Renders, encodes and moves the result into place. Returns immediately;
    /// the window stays live and the returned job carries the progress.
    @discardableResult
    func start(
        document: EditorDocument,
        settings: ExportSettings,
        revealWhenDone: Bool,
        store: CuttingRoomStore
    ) -> EditorJob {
        let finalURL = ExportDestination.unique(settings.destinationURL)
        var resolved = settings
        resolved.destinationURL = finalURL

        let job = store.makeJob(
            stage: "Getting ready",
            detail: finalURL.lastPathComponent,
            fraction: nil,
            isCancellable: true
        )

        // The first export is when a "your export is done" alert becomes
        // relevant, which is when Melo asks. Not at launch.
        if !hasEverExported {
            hasEverExported = true
            NotificationAuthorization.requestIfNeeded()
        }

        let engine = store.renderEngine
        let enabledMoves = document.moves.filter(\.isEnabled).count
        let sourceDuration = ExportSizeEstimate.estimatedDuration(
            source: document.source,
            moves: document.moves
        )
        let report = Self.sink(for: job)

        let task = Task { [weak self] in
            do {
                let product = try await Self.run(
                    document: document,
                    settings: resolved,
                    engine: engine,
                    job: job,
                    enabledMoves: enabledMoves,
                    sourceDuration: sourceDuration,
                    report: report
                )
                self?.finish(
                    job: job,
                    product: product,
                    document: document,
                    reveal: revealWhenDone,
                    engine: engine
                )
            } catch is CancellationError {
                // `cancel()` on an already-cancelled job is a no-op, so this is
                // only reached when the task was cancelled some other way.
                job.cancel()
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                let recovery = (error as? LocalizedError)?.recoverySuggestion
                job.setStage("Export failed", detail: [message, recovery].compactMap { $0 }.joined(separator: " "))
                job.fail(message)
                exportLogger.error("Export failed: \(message, privacy: .public)")
            }
        }

        job.attach(task)
        return job
    }

    func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Closes the result card and lets its job leave the strip.
    func dismissOutcome(store: CuttingRoomStore) {
        if let jobID = outcome?.jobID,
           let job = store.jobs.first(where: { $0.id == jobID }) {
            store.retire(job)
        }
        outcome = nil
        dismissal?.cancel()
        dismissal = nil
    }

    // MARK: Finishing

    private func finish(
        job: EditorJob,
        product: ExportProduct,
        document: EditorDocument,
        reveal: Bool,
        engine: RenderEngine
    ) {
        // Stage before finish: `setStage` only writes while the job is running.
        job.setStage("Saved", detail: product.url.lastPathComponent)
        job.finish()

        // The finishing moment. One tick, the same performer the sliders use.
        Haptics.commit()

        let isTheme = document.source.origin == .meloTheme
        if isTheme { lastThemeExportURL = product.url }

        dismissal?.cancel()
        outcome = ExportOutcome(
            id: UUID(),
            jobID: job.id,
            url: product.url,
            format: product.format,
            byteCount: product.byteCount,
            before: document.analysis,
            after: nil,
            isMeasuring: true,
            sourceDuration: document.source.duration,
            outputDuration: nil,
            destination: document.destination,
            isThemeExport: isTheme
        )

        if reveal { self.reveal(product.url) }
        notifyIfAway(product: product)
        measureResult(product: product, engine: engine)
    }

    /// Re-measures the file that was actually written, so the card can put
    /// before against after. Runs after the export is already reported as
    /// finished: the file is on disk either way, and nobody should wait on a
    /// measurement to be told it saved.
    private func measureResult(product: ExportProduct, engine: RenderEngine) {
        measurement?.cancel()
        measurement = Task { @MainActor [weak self] in
            let measured = await Self.measure(url: product.url, engine: engine)
            guard let self, self.outcome?.url == product.url else { return }
            self.outcome?.after = measured?.report
            self.outcome?.outputDuration = measured?.duration
            self.outcome?.isMeasuring = false
            self.scheduleDismissal()
        }
    }

    /// The card is a result, not a notification, so it stays long enough to
    /// read three lines and then gets out of the way.
    private func scheduleDismissal() {
        dismissal?.cancel()
        dismissal = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(24))
            guard !Task.isCancelled else { return }
            self?.dismissOutcome(store: .shared)
        }
    }

    private nonisolated static func measure(
        url: URL,
        engine: RenderEngine
    ) async -> (report: AnalysisReport, duration: TimeInterval)? {
        do {
            let source = try AudioFileIO.probe(url)
            let document = EditorDocument(source: source)
            let report = try await engine.analyse(document)
            return (report, source.duration)
        } catch {
            exportLogger.error("Could not measure the export: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Only when Melo is not the app in front. If the window is open and the
    /// strip has just said "Saved", a system banner saying it again is noise.
    private func notifyIfAway(product: ExportProduct) {
        guard !NSApp.isActive else { return }
        let content = UNMutableNotificationContent()
        content.title = "Export finished"
        let folder = product.url.deletingLastPathComponent().lastPathComponent
        content.body = "\(product.url.lastPathComponent) is in \(folder)."
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(
                identifier: "melo.export.\(UUID().uuidString)",
                content: content,
                trigger: nil
            )
        )
    }

    // MARK: - The work

    /// `EditorJob.fractionSink` coalesces, but maps one stage's fraction
    /// straight onto the job. An export has two stages, so this remaps into the
    /// overall bar and does its own coalescing — a stage change always gets
    /// through, because that is the line the user is reading.
    private nonisolated static func sink(for job: EditorJob) -> @Sendable (JobProgress) -> Void {
        let throttle = ProgressThrottle()
        return { progress in
            guard throttle.shouldSend(progress.fraction, stage: progress.stage) else { return }
            Task { @MainActor in
                job.setStage(progress.stage, detail: progress.detail)
                job.setFraction(progress.fraction)
            }
        }
    }

    /// `nonisolated` on purpose: rendering and encoding are the two places a
    /// long export could freeze the window, and an async function that is not
    /// actor-isolated does not run on its caller's actor.
    private nonisolated static func run(
        document: EditorDocument,
        settings: ExportSettings,
        engine: RenderEngine,
        job: EditorJob,
        enabledMoves: Int,
        sourceDuration: TimeInterval,
        report: @escaping @Sendable (JobProgress) -> Void
    ) async throws -> ExportProduct {

        try Task.checkCancellation()

        // 1. Render.
        let renderStage = enabledMoves > 0
            ? "Applying \(enabledMoves) move\(enabledMoves == 1 ? "" : "s")"
            : "Rendering the sound"
        report(
            JobProgress(
                stage: renderStage,
                detail: nil,
                fraction: ExportWeight.prepare,
                isCancellable: true
            )
        )

        let block = try await engine.render(document, range: nil) { fraction in
            report(
                JobProgress(
                    stage: renderStage,
                    detail: EditorFormat.elapsedOfTotal(fraction * sourceDuration, sourceDuration),
                    fraction: ExportWeight.prepare + ExportWeight.render * fraction,
                    isCancellable: true
                )
            )
        }

        try Task.checkCancellation()
        guard !job.isCancelled else { throw CancellationError() }

        // 2. Encode, into a temporary file on the same volume as the
        //    destination, so a cancelled or failed export never leaves a
        //    truncated file wearing the right name.
        let finalURL = settings.destinationURL
        let scratch = try FileManager.default.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: finalURL,
            create: true
        )
        defer { try? FileManager.default.removeItem(at: scratch) }

        let tempURL = scratch.appendingPathComponent(finalURL.lastPathComponent)
        var tempSettings = settings
        tempSettings.destinationURL = tempURL

        let encodeStage = "Writing \(settings.format.displayName)"
        report(
            JobProgress(
                stage: encodeStage,
                detail: finalURL.lastPathComponent,
                fraction: ExportWeight.prepare + ExportWeight.render,
                isCancellable: true
            )
        )

        // The sink's return value is the stop button. Returning a constant
        // `true` would make Stop a lie again on a long encode, which is the
        // whole reason `ProgressSink` reports a `Bool`. `job.isCancelled` is an
        // atomic, so `ffmpeg`'s output-parsing thread can read it as safely as
        // the encode loop can.
        try await AudioFileIO.encode(block, settings: tempSettings, progress: { fraction in
            report(
                JobProgress(
                    stage: encodeStage,
                    detail: finalURL.lastPathComponent,
                    fraction: ExportWeight.prepare + ExportWeight.render + ExportWeight.encode * fraction,
                    isCancellable: true
                )
            )
            return !job.isCancelled
        })

        try Task.checkCancellation()
        guard !job.isCancelled else { throw CancellationError() }

        // 3. Move it into place.
        report(
            JobProgress(
                stage: "Putting it in place",
                detail: finalURL.lastPathComponent,
                fraction: ExportWeight.prepare + ExportWeight.render + ExportWeight.encode,
                isCancellable: false
            )
        )

        if FileManager.default.fileExists(atPath: finalURL.path) {
            _ = try FileManager.default.replaceItemAt(finalURL, withItemAt: tempURL)
        } else {
            try FileManager.default.moveItem(at: tempURL, to: finalURL)
        }

        let attributes = try? FileManager.default.attributesOfItem(atPath: finalURL.path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        return ExportProduct(url: finalURL, format: settings.format, byteCount: size)
    }

}

// MARK: - Snapshot seeding

#if MELO_DEV
extension ExportCoordinator {
    /// The finished-export card has no seam a click can reach in a rendered
    /// frame, and it is where the before-and-after lives. Same file as the
    /// `private(set)` it writes, which is the only place that is allowed to.
    func setForSnapshot(_ outcome: ExportOutcome?) {
        measurement?.cancel()
        dismissal?.cancel()
        self.outcome = outcome
    }
}

extension ExportOutcome {
    /// A four-minute podcast pulled from −22.4 LUFS to the destination's −16,
    /// with the true peak brought under the ceiling and a little silence
    /// trimmed off each end.
    static func snapshotSample(jobID: UUID) -> ExportOutcome {
        func report(lufs: Double, peak: Double) -> AnalysisReport {
            AnalysisReport(
                integratedLUFS: lufs,
                truePeakDBTP: peak,
                loudnessRangeLU: 7.4,
                peakDBFS: peak - 0.2,
                noiseFloorDBFS: -61.5,
                dcOffset: 0.0004,
                clippedSampleCount: 0,
                spectralTiltDBPerOctave: -2.1,
                leadingSilence: 0.8,
                trailingSilence: 1.6,
                interiorSilences: [],
                isEffectivelyMono: false,
                measuredAt: Date()
            )
        }
        return ExportOutcome(
            id: UUID(),
            jobID: jobID,
            url: URL(fileURLWithPath: "/Users/you/Music/morning-show-ep41.m4a"),
            format: .m4aAAC,
            byteCount: 7_940_000,
            before: report(lufs: -22.4, peak: -0.2),
            after: report(lufs: -16.1, peak: -1.0),
            isMeasuring: false,
            sourceDuration: 250,
            outputDuration: 247.6,
            destination: DestinationCatalogue.all.first,
            isThemeExport: false
        )
    }
}
#endif

// MARK: - Progress throttle

/// The render engine and the encoder both report from arbitrary executors, and
/// both can report thousands of times a second. Every report becomes a hop to
/// the main actor, so this drops the ones nobody could see: a move smaller than
/// a pixel of bar, or a second report inside the same frame. A change of stage
/// is never dropped.
private final class ProgressThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var lastFraction: Double = -1
    private var lastAt: CFAbsoluteTime = 0
    private var lastStage = ""

    func shouldSend(_ fraction: Double?, stage: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if stage != lastStage {
            lastStage = stage
            lastFraction = fraction ?? -1
            lastAt = CFAbsoluteTimeGetCurrent()
            return true
        }
        guard let fraction else { return true }
        let now = CFAbsoluteTimeGetCurrent()
        let moved = abs(fraction - lastFraction) >= 0.004
        let stale = now - lastAt >= 1.0 / 30.0
        guard (moved && stale) || fraction >= 1 else { return false }
        lastFraction = fraction
        lastAt = now
        return true
    }
}
