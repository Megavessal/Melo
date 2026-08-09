// Melo/Editor/Export/JobProgressStrip.swift
//
// The progress surface for every long operation in Melo Edit, not only
// export: decoding an import, measuring loudness, re-rendering after an edit,
// extracting from a link, recording. One strip, several jobs, each with its
// stage, its detail line and a way to stop it.
//
// Two rules the rest of the piece hangs off:
//
//   * A determinate bar wherever a total is knowable, and an honest
//     indeterminate one where it is not. A bar that crawls to 90% and waits is
//     worse than a spinner.
//   * A re-render after an edit is a job too, and it is the one the user sees
//     most. It has to be quiet — hence `quietDelay` — but it has to be
//     visible, because an editor that silently stops answering the transport
//     for two seconds feels broken.

import SwiftUI

// MARK: - Tuning

/// The two timings that decide how loud the strip is.
///
/// Mutable so the snapshot harness can reach the states that only exist over
/// time. Nothing in the shipping app writes them.
@MainActor
enum JobStripTuning {
    /// How long a job has to have been running before its row appears. A
    /// re-render after a small edit usually finishes inside this, so the strip
    /// stays out of the way; anything slower than a blink shows up.
    static var quietDelay: TimeInterval = 0.25

    /// How long a finished or cancelled row stays before it retires itself. A
    /// failure never leaves on its own — its sentence is the only place the
    /// user can read what went wrong.
    static var settledLinger: TimeInterval = 3

    /// Stops the strip's three sources of perpetual work: the half-second
    /// clock, the indeterminate sweep, and the retirement loop.
    ///
    /// Set only by the snapshot harness. The harness closes a scene's window
    /// but never clears its `contentView`, so every hosting view it has ever
    /// staged stays alive and subscribed for the rest of the run — and a strip
    /// that animates forever therefore keeps generating SwiftUI transactions in
    /// ~150 leaked graphs at once. It cannot photograph motion anyway
    /// (`CLAUDE.md`, "what the render harness cannot see"), so the frame loses
    /// nothing and the run stops paying for it.
    static var freezeMotion = false

    #if MELO_DEV
    /// Snapshot scenes create their jobs and render in the same turn, so every
    /// row would sit at 0:00 with no remaining time against a real
    /// `EditorJob.startedAt`. Backdating one here is what makes "38 seconds in,
    /// about 20s left" renderable.
    static var snapshotStartDates: [UUID: Date] = [:]
    #endif
}

// MARK: - The strip

@MainActor
struct JobProgressStrip: View {

    @ObservedObject private var store: EditorStore
    @ObservedObject private var exports: ExportCoordinator

    init(store: EditorStore) {
        _store = ObservedObject(wrappedValue: store)
        _exports = ObservedObject(wrappedValue: ExportCoordinator.shared)
    }

    /// The half-second clock exists to move the elapsed and remaining
    /// readouts, and those only move while something is running. A settled
    /// strip that keeps ticking is a transaction every 500 ms for as long as
    /// the view is mounted, forever, for nothing.
    private var needsClock: Bool {
        !JobStripTuning.freezeMotion && store.jobs.contains { $0.state == .running }
    }

    var body: some View {
        if needsClock {
            // Anchored to a fixed instant rather than `.now` so the same frame
            // renders the same way twice.
            TimelineView(.periodic(from: Date(timeIntervalSince1970: 0), by: 0.5)) { context in
                content(at: context.date)
            }
        } else {
            content(at: Date())
        }
    }

    @ViewBuilder
    private func content(at now: Date) -> some View {
        Group {
            let rows = visible(at: now)

            // Nothing worth showing takes no room. A job can be in the list
            // and not on screen — a re-render inside the quiet delay, or a
            // finished one on its way out — and a padded empty band under a
            // rule would be the strip announcing itself for no reason.
            if rows.isEmpty {
                Color.clear.frame(height: 0)
            } else {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                    ForEach(rows, id: \.id) { job in
                        if let outcome = exports.outcome, outcome.jobID == job.id {
                            ExportResultRow(outcome: outcome) {
                                exports.reveal(outcome.url)
                            } onDismiss: {
                                exports.dismissOutcome(store: store)
                            }
                        } else {
                            JobRow(job: job, now: now, startedAt: started(job)) {
                                store.retire(job)
                            }
                        }
                    }
                }
                .padding(.horizontal, DesignTokens.Spacing.lg)
                .padding(.vertical, DesignTokens.Spacing.sm2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .animation(DesignTokens.Animation.rowChange, value: store.jobs.map(\.id))
            }
        }
        // Keyed on the settled set, so the loop starts when something settles
        // and stops when there is nothing left to retire, rather than running
        // a timer for the lifetime of the view.
        .task(id: settledJobIDs) { await retireSettledRows() }
    }

    // MARK: Which rows are on screen

    /// A finished job earns a row only when it is an export holding its result
    /// card. Everything else that finishes just stops — a re-render that took
    /// 90 ms must not leave a "done" row sitting there for three seconds,
    /// which would undo the whole point of the quiet delay. A failure and a
    /// cancellation always get a row: one carries the only sentence saying
    /// what went wrong, the other is the proof the button worked.
    private func visible(at now: Date) -> [EditorJob] {
        store.jobs.filter { job in
            switch job.state {
            case .running:
                return now.timeIntervalSince(started(job)) >= JobStripTuning.quietDelay
            case .finished:
                return exports.outcome?.jobID == job.id
            case .failed, .cancelled:
                return true
            }
        }
    }

    private func started(_ job: EditorJob) -> Date {
        #if MELO_DEV
        if let seeded = JobStripTuning.snapshotStartDates[job.id] { return seeded }
        #endif
        return job.startedAt
    }

    // MARK: Leaving

    /// Changes exactly when a job settles or a settled one leaves, which is the
    /// only thing that should wake the retirement loop.
    private var settledJobIDs: [UUID] {
        store.jobs.filter { $0.state != .running }.map(\.id)
    }

    /// `EditorRootView` draws the strip whenever `store.jobs` is not empty
    /// and leaves it to this view to decide when a settled row goes. Runs outside
    /// the view update, so retiring a job cannot mutate state mid-render, and
    /// **returns as soon as there is nothing left to retire** — the earlier
    /// version was an unconditional half-second timer that lived as long as the
    /// view, writing to shared published state forever whether or not anything
    /// needed it.
    private func retireSettledRows() async {
        guard !JobStripTuning.freezeMotion else { return }
        while !Task.isCancelled {
            let holding = exports.outcome?.jobID
            let pending = store.jobs.filter { job in
                job.id != holding && (job.state == .finished || job.state == .cancelled)
            }
            guard !pending.isEmpty else { return }

            let now = Date()
            for job in pending {
                switch job.state {
                case .finished:
                    // Never drawn, so nothing is lost by taking it out now.
                    store.retire(job)
                case .cancelled where now.timeIntervalSince(started(job)) >= JobStripTuning.settledLinger:
                    store.retire(job)
                default:
                    continue
                }
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
    }
}

// MARK: - One job

@MainActor
private struct JobRow: View {

    @ObservedObject var job: EditorJob
    let now: Date
    let startedAt: Date
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: DesignTokens.Spacing.md) {
            if let symbol = stateSymbol {
                Image(systemName: symbol.name)
                    .font(DesignTokens.Typography.Scale.title3())
                    .foregroundStyle(symbol.tint)
                    .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.sm) {
                    Text(job.progress.stage)
                        .font(DesignTokens.Typography.Scale.headline(.medium))
                        .foregroundStyle(DesignTokens.Colors.textPrimary)
                        .lineLimit(1)

                    Spacer(minLength: DesignTokens.Spacing.sm)

                    if let timing {
                        Text(timing)
                            .font(DesignTokens.Typography.Scale.caption())
                            .monospacedDigit()
                            .foregroundStyle(DesignTokens.Colors.textSecondary)
                    }
                }

                if job.state == .running {
                    JobProgressBar(fraction: job.progress.fraction)
                }

                if let detail = job.progress.detail, !detail.isEmpty {
                    Text(detail)
                        .font(DesignTokens.Typography.Scale.caption())
                        .foregroundStyle(DesignTokens.Colors.textSecondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            trailingButton
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(job.progress.stage)
        .accessibilityValue(accessibilityValue)
    }

    // MARK: Pieces

    private var stateSymbol: (name: String, tint: Color)? {
        switch job.state {
        case .running: return nil
        case .finished: return ("checkmark.circle.fill", DesignTokens.Colors.accentPrimary)
        case .failed: return ("exclamationmark.triangle.fill", DesignTokens.Colors.mutedIndicator)
        case .cancelled: return ("xmark.circle", DesignTokens.Colors.textTertiary)
        }
    }

    @ViewBuilder
    private var trailingButton: some View {
        switch job.state {
        case .running where job.progress.isCancellable:
            IconActionButton(symbol: "xmark", label: "Stop", help: "Stop this") {
                job.cancel()
            }
        case .failed:
            IconActionButton(symbol: "xmark", label: "Dismiss", help: "Dismiss") {
                onDismiss()
            }
        default:
            EmptyView()
        }
    }

    /// Elapsed always, once there is a second of it. Remaining only once the
    /// bar has moved far enough for the estimate to mean something — a
    /// countdown invented at 2% is a guess wearing a number.
    private var timing: String? {
        guard job.state == .running else { return nil }
        let elapsed = now.timeIntervalSince(startedAt)
        guard elapsed >= 1 else { return nil }
        var text = EditorFormat.timecode(elapsed)
        if let fraction = job.progress.fraction, fraction >= 0.08, elapsed >= 2.5 {
            let remaining = elapsed / fraction - elapsed
            if remaining >= 2 {
                text += " · about \(ExportCopy.coarseDuration(remaining)) left"
            }
        }
        return text
    }

    private var accessibilityValue: String {
        var parts: [String] = []
        if let fraction = job.progress.fraction {
            parts.append("\(Int((fraction * 100).rounded())) percent")
        }
        if let detail = job.progress.detail { parts.append(detail) }
        return parts.joined(separator: ", ")
    }
}

// MARK: - The bar

@MainActor
private struct JobProgressBar: View {

    /// `nil` is indeterminate, and says so rather than parking a bar at 90%.
    let fraction: Double?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sweeping = false

    private static let height: CGFloat = 3
    /// How much of the track the indeterminate segment occupies.
    private static let segment: CGFloat = 0.28

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(DesignTokens.Colors.sliderTrack)

                if let fraction {
                    Capsule(style: .continuous)
                        .fill(DesignTokens.Colors.sliderFill)
                        .frame(width: max(2, geometry.size.width * min(max(fraction, 0), 1)))
                        .animation(DesignTokens.Animation.track, value: fraction)
                } else if reduceMotion {
                    // Reduce Motion replaces travel with a fade, per Apple's
                    // guidance. A static segment would read as stuck.
                    Capsule(style: .continuous)
                        .fill(DesignTokens.Colors.sliderFill)
                        .opacity(sweeping ? 0.75 : 0.25)
                } else {
                    // `offset` rather than a leading spacer on purpose: it is a
                    // render-time transform and takes no part in layout, so the
                    // sweep cannot feed back into the pass that sized the bar.
                    Capsule(style: .continuous)
                        .fill(DesignTokens.Colors.sliderFill)
                        .frame(width: geometry.size.width * Self.segment)
                        .offset(x: sweeping ? geometry.size.width * (1 - Self.segment) : 0)
                }
            }
        }
        .frame(height: Self.height)
        .onAppear { startSweepIfNeeded() }
        .onChange(of: fraction == nil) { _, _ in startSweepIfNeeded() }
    }

    /// There is no token for a continuous indeterminate sweep — every
    /// `DesignTokens.Animation` value is a settling curve for a state change,
    /// and this one never settles. Linear and repeating on purpose.
    ///
    /// Three things switch it off: a determinate fraction, Reduce Motion
    /// (which gets a fade instead of travel), and the snapshot harness, which
    /// cannot photograph motion and keeps every hosting view it has ever
    /// staged alive — so an animation that never ends never ends anywhere.
    private func startSweepIfNeeded() {
        guard fraction == nil, !JobStripTuning.freezeMotion else {
            sweeping = false
            return
        }
        sweeping = false
        let curve = reduceMotion
            ? SwiftUI.Animation.linear(duration: 0.9).repeatForever(autoreverses: true)
            : SwiftUI.Animation.linear(duration: 1.15).repeatForever(autoreverses: false)
        withAnimation(curve) { sweeping = true }
    }
}

// MARK: - The result

/// The finished export, and what it did to the sound. Three lines against the
/// destination's published targets, because "Melo made it better" that nobody
/// can check is not a claim, it is a mood.
@MainActor
private struct ExportResultRow: View {

    let outcome: ExportOutcome
    let onReveal: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.md) {
            Image(systemName: "checkmark.circle.fill")
                .font(DesignTokens.Typography.Scale.title3())
                .foregroundStyle(DesignTokens.Colors.accentPrimary)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                Text("Saved \(outcome.url.lastPathComponent)")
                    .font(DesignTokens.Typography.Scale.headline(.medium))
                    .foregroundStyle(DesignTokens.Colors.textPrimary)
                    .lineLimit(1)

                Text("\(outcome.format.displayName) · \(ExportCopy.fileSize(outcome.byteCount))")
                    .font(DesignTokens.Typography.Scale.caption())
                    .foregroundStyle(DesignTokens.Colors.textSecondary)

                comparison

                // The only place a Melo Edit export has somewhere to go
                // inside the app. `MeloThemeAdoptionRow` owns the row; this
                // decides when it shows.
                if outcome.isThemeExport {
                    MeloThemeAdoptionRow(renderedURL: outcome.url)
                        .padding(.top, DesignTokens.Spacing.xxs)
                }
            }

            Spacer(minLength: DesignTokens.Spacing.sm)

            Button("Show in Finder", action: onReveal)
                .buttonStyle(.link)
                .font(DesignTokens.Typography.Scale.footnote())

            IconActionButton(symbol: "xmark", label: "Dismiss", help: "Dismiss") {
                onDismiss()
            }
        }
    }

    /// A bare "target −16" claims a specification. Two of the six destinations
    /// are not one — the ringtone's figure is Melo's own, and YouTube has never
    /// printed the −14 everybody measures — so the chip names whoever actually
    /// stands behind the number: "Apple Podcasts −16.0", "YouTube −14.0",
    /// "Melo's own −12.0". Asked of `targetProvenance`, never of the id: a
    /// hardcoded id was already wrong for a second destination the same day it
    /// was written.
    private static func loudnessTarget(_ destination: Destination) -> String {
        "\(destination.targetAttribution) \(EditorFormat.number(destination.targetLUFS, places: 1))"
    }

    @ViewBuilder
    private var comparison: some View {
        if outcome.isMeasuring {
            Text("Checking the result")
                .font(DesignTokens.Typography.Scale.caption())
                .foregroundStyle(DesignTokens.Colors.textTertiary)
        } else if let after = outcome.after {
            VStack(alignment: .leading, spacing: 2) {
                ComparisonLine(
                    label: "Loudness",
                    before: outcome.before.map { "\(EditorFormat.number($0.integratedLUFS, places: 1))" },
                    after: "\(EditorFormat.number(after.integratedLUFS, places: 1)) LUFS",
                    target: outcome.destination.map(Self.loudnessTarget),
                    onTarget: outcome.destination.map { abs(after.integratedLUFS - $0.targetLUFS) <= 1.0 }
                )
                ComparisonLine(
                    label: "True peak",
                    before: outcome.before.map { "\(EditorFormat.number($0.truePeakDBTP, places: 1))" },
                    after: "\(EditorFormat.number(after.truePeakDBTP, places: 1)) dBTP",
                    target: outcome.destination.map { "ceiling \(EditorFormat.number($0.truePeakCeilingDBTP, places: 1))" },
                    onTarget: outcome.destination.map { after.truePeakDBTP <= $0.truePeakCeilingDBTP + 0.1 }
                )
                ComparisonLine(
                    label: "Length",
                    before: EditorFormat.timecode(outcome.sourceDuration),
                    after: EditorFormat.timecode(outcome.outputDuration ?? outcome.sourceDuration),
                    target: nil,
                    onTarget: nil
                )
            }
            .padding(.top, DesignTokens.Spacing.xxs)
        }
    }
}

@MainActor
private struct ComparisonLine: View {
    let label: String
    let before: String?
    let after: String
    let target: String?
    let onTarget: Bool?

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            Text(label)
                .font(DesignTokens.Typography.Scale.caption())
                .foregroundStyle(DesignTokens.Colors.textSecondary)
                .frame(width: 64, alignment: .leading)

            if let before {
                Text(before)
                    .font(DesignTokens.Typography.Scale.caption())
                    .monospacedDigit()
                    .foregroundStyle(DesignTokens.Colors.textTertiary)

                Image(systemName: "arrow.right")
                    .font(DesignTokens.Typography.Scale.caption2())
                    .foregroundStyle(DesignTokens.Colors.textQuaternary)
                    .accessibilityHidden(true)
            }

            Text(after)
                .font(DesignTokens.Typography.Scale.caption(.medium))
                .monospacedDigit()
                .foregroundStyle(DesignTokens.Colors.textPrimary)

            if let target {
                Text(target)
                    .font(DesignTokens.Typography.Scale.caption())
                    .monospacedDigit()
                    .foregroundStyle(DesignTokens.Colors.textTertiary)
            }

            if onTarget == true {
                Image(systemName: "checkmark")
                    .font(DesignTokens.Typography.Scale.caption2(.bold))
                    .foregroundStyle(DesignTokens.Colors.accentPrimary)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(before.map { "\(label), was \($0), now \(after)" } ?? "\(label), \(after)")
    }
}

// MARK: - A small round button

/// Used for stop and dismiss. Its glyph is 11pt; its hit area is the full
/// `minTouchTarget`, which is the part that matters.
@MainActor
private struct IconActionButton: View {
    let symbol: String
    let label: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(DesignTokens.Typography.Scale.footnote(.semibold))
                .foregroundStyle(DesignTokens.Colors.interactiveDefault)
                .frame(
                    width: DesignTokens.Dimensions.minTouchTarget,
                    height: DesignTokens.Dimensions.minTouchTarget
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.meloHover)
        .accessibilityLabel(label)
        .help(help)
    }
}

// MARK: - Snapshot seeding

#if MELO_DEV
extension JobStripTuning {

    /// Empties the job list and the result card, and puts the two timings
    /// where a scene that seeds rows needs them: no quiet delay, because the
    /// harness creates a job and renders in the same turn, and no automatic
    /// retirement, because a settled row has to survive long enough to be
    /// photographed. Both seeders start here, so scene order cannot leak one
    /// scene's rows into the next.
    static func clearSnapshotSeeding(in store: EditorStore) {
        quietDelay = 0
        settledLinger = .greatestFiniteMagnitude
        freezeMotion = true
        snapshotStartDates.removeAll()
        for job in store.jobs { store.retire(job) }
        ExportCoordinator.shared.setForSnapshot(nil)
    }

    /// Puts the four job states worth a frame into `store`, backdated so the
    /// elapsed and remaining readouts have something to say, and switches the
    /// quiet delay off so they render in the turn they are created.
    ///
    /// Returns the jobs so a scene can reach one if it wants to.
    @discardableResult
    static func seedSnapshotJobs(in store: EditorStore) -> [EditorJob] {
        clearSnapshotSeeding(in: store)

        let rendering = store.makeJob(
            stage: "Applying 4 moves",
            detail: EditorFormat.elapsedOfTotal(102, 250),
            fraction: 0.41,
            isCancellable: true
        )
        let writing = store.makeJob(
            stage: "Writing AAC",
            detail: "morning-show-ep41.m4a",
            fraction: 0.94,
            isCancellable: true
        )
        let measuring = store.makeJob(
            stage: "Measuring loudness",
            detail: nil,
            fraction: nil,
            isCancellable: true
        )
        let failed = store.makeJob(stage: "Export failed", detail: nil, fraction: nil)
        failed.setStage("Export failed", detail: "Melo couldn't finish writing the file. The disk is full.")
        failed.fail("Melo couldn't finish writing the file.")

        let cancelled = store.makeJob(stage: "Rendering the sound", detail: nil, fraction: 0.3, isCancellable: true)
        cancelled.setStage("Cancelled", detail: "Nothing was written.")
        cancelled.cancel()

        let jobs = [rendering, writing, measuring, failed, cancelled]
        let now = Date()
        snapshotStartDates[rendering.id] = now.addingTimeInterval(-38)
        snapshotStartDates[writing.id] = now.addingTimeInterval(-71)
        snapshotStartDates[measuring.id] = now.addingTimeInterval(-6)
        snapshotStartDates[failed.id] = now.addingTimeInterval(-12)
        snapshotStartDates[cancelled.id] = now.addingTimeInterval(-9)
        return jobs
    }

    /// The finished-export card, with its before-and-after already measured.
    static func seedSnapshotOutcome(in store: EditorStore) {
        clearSnapshotSeeding(in: store)
        let job = store.makeJob(stage: "Saved", detail: "morning-show-ep41.m4a")
        job.finish()
        snapshotStartDates[job.id] = Date().addingTimeInterval(-4)
        ExportCoordinator.shared.setForSnapshot(.snapshotSample(jobID: job.id))
    }
}
#endif
