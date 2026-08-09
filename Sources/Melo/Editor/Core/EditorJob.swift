// Melo/Editor/Core/EditorJob.swift
//
// One long operation, observable from the main actor and reportable-to from
// anywhere. Import, analysis, render, export, extraction and recording all use
// this, so one progress view serves all six.

import Foundation
import Synchronization
import os

@MainActor
final class EditorJob: ObservableObject, Identifiable {
    let id = UUID()

    /// When the work began. A `let` of a `Sendable` type, so it is readable
    /// from any executor without a hop.
    ///
    /// It lives here so no view has to keep a first-seen map beside the job
    /// list to render elapsed and remaining. Those two numbers are the
    /// difference between a wait that reads as work and one that reads as a
    /// hang, and shadow state that has to be pruned when a job disappears is
    /// the wrong place for them.
    let startedAt = Date()

    @Published private(set) var progress: JobProgress
    @Published private(set) var state: State = .running

    enum State: Equatable {
        case running, finished, failed(String), cancelled
    }

    /// Read from the worker, written by `cancel()` on the main actor. Atomic
    /// rather than actor-isolated because a decode loop checks it thousands of
    /// times and cannot await anything to do it.
    private let cancelledFlag = Atomic<Bool>(false)

    /// Monotonic nanoseconds of the last fraction posted to the main actor.
    private let lastPost = Atomic<UInt64>(0)

    /// Progress posts are coalesced to ~24 a second. A decode reports every
    /// 64k frames, which on a short file is faster than the display can show
    /// and would otherwise queue thousands of main-actor hops behind the work.
    ///
    /// `nonisolated` because the sinks below read it from wherever the work is
    /// running — the render actor, a decode loop, an external tool's output
    /// parser — and never from the main actor. That is the whole point of the
    /// coalescing: the decision not to post has to be made on the worker's
    /// thread, before anything hops. Safe to expose because it is an immutable
    /// `UInt64`, which is the same reason `cancelledFlag` and `lastPost` above
    /// are reachable from `isCancelled` without a hop.
    nonisolated private static let postInterval: UInt64 = 40_000_000

    /// The work this job represents, so `cancel()` reaches it. Optional because
    /// some callers cancel by polling `isCancelled` instead.
    private var work: Task<Void, Never>?

    init(stage: String,
         detail: String? = nil,
         fraction: Double? = nil,
         isCancellable: Bool = false) {
        progress = JobProgress(
            stage: stage,
            detail: detail,
            fraction: fraction,
            isCancellable: isCancellable
        )
    }

    // MARK: - Reporting, from the main actor

    func setStage(_ stage: String, detail: String? = nil) {
        guard state == .running else { return }
        progress.stage = stage
        progress.detail = detail
    }

    func setDetail(_ detail: String?) {
        guard state == .running else { return }
        progress.detail = detail
    }

    /// `nil` makes the job indeterminate again.
    func setFraction(_ fraction: Double?) {
        guard state == .running else { return }
        progress.fraction = fraction.map { min(max($0, 0), 1) }
    }

    func finish() {
        guard state == .running else { return }
        progress.fraction = 1
        state = .finished
    }

    func fail(_ message: String) {
        guard state == .running else { return }
        state = .failed(message)
    }

    func cancel() {
        guard state == .running else { return }
        cancelledFlag.store(true, ordering: .relaxed)
        work?.cancel()
        state = .cancelled
    }

    /// Hands the job the task it should cancel.
    func attach(_ task: Task<Void, Never>) {
        guard state == .running else {
            task.cancel()
            return
        }
        work = task
    }

    // MARK: - Reporting, from anywhere

    /// True once `cancel()` has been called. Safe to poll from a render loop.
    nonisolated var isCancelled: Bool {
        cancelledFlag.load(ordering: .relaxed)
    }

    /// A `@Sendable` sink to hand to `AudioFileIO.decode`, `RenderEngine.render`
    /// or an external tool's progress parser. Callable from any executor;
    /// coalesced so a tight loop cannot flood the main actor.
    nonisolated func fractionSink() -> @Sendable (Double) -> Void {
        { [weak self] fraction in
            guard let self else { return }
            let now = DispatchTime.now().uptimeNanoseconds
            if fraction < 1 {
                let previous = lastPost.load(ordering: .relaxed)
                guard now &- previous >= Self.postInterval else { return }
            }
            lastPost.store(now, ordering: .relaxed)
            Task { @MainActor in self.setFraction(fraction) }
        }
    }

}
