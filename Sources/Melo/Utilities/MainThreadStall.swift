import Foundation
import OSLog

/// Finds out what is beachballing, instead of guessing.
///
/// Melo is an accessory app whose windows open by themselves. A stall while one
/// of them is being built is worse than slow: the pointer beachballs over
/// whatever the user was actually doing, and the app responsible is not even
/// frontmost, so there is nothing on screen connecting the freeze to Melo.
///
/// This exists because that has been reported three times and diagnosed none.
/// Every previous attempt started from a guess about which call was expensive —
/// the activation policy, the panel, SwiftUI's first layout — and once the
/// symptom happens not to reproduce, a guess is indistinguishable from a fix.
///
/// Two halves, and the second is the one that matters:
///
/// * `measure` times a named span. Useful, but it can only ever report on code
///   somebody already suspected.
/// * `startWatchdog` watches the main thread from outside and reports **any**
///   stall, including one in a frame nobody instrumented — AppKit, CoreAudio,
///   a SwiftUI layout, the window server. It names the innermost `measure` span
///   in flight, so an instrumented stall is attributed and an uninstrumented one
///   still gets a duration and a breadcrumb.
///
/// Always compiled, deliberately. The watchdog is one sleeping thread and one
/// `DispatchQueue.main.async` every 150ms; a diagnosis that only exists in a dev
/// build cannot answer "it beachballed on my Mac just now".
enum MainThreadStall {
    private static let logger = Logger(
        subsystem: "io.github.megavessal.Melo",
        category: "Stall"
    )

    /// Roughly where macOS starts showing the wait cursor for an unresponsive
    /// main thread. Below it a span is slow; above it a span is a beachball.
    static let threshold: TimeInterval = 0.12

    /// Guards the two pieces of state the watchdog thread shares with the main
    /// thread. A lock rather than a queue because the watchdog must be able to
    /// read this *while* the main thread is wedged, which is exactly when a
    /// main-queue hop would never come back.
    private static let lock = NSLock()
    // `nonisolated(unsafe)` and then guarded by the lock above, rather than by
    // an actor or the main actor. Every read the watchdog makes happens while
    // the main thread is wedged, which is precisely when a hop onto it never
    // returns — an actor here would make the instrument unable to report the
    // thing it exists to report.
    private nonisolated(unsafe) static var spanStack: [String] = []
    private nonisolated(unsafe) static var report: [String] = []

    // MARK: - Timing a span

    @discardableResult
    static func measure<T>(_ label: String, _ work: () throws -> T) rethrows -> T {
        push(label)
        let started = ContinuousClock.now
        defer {
            pop()
            record(label, seconds(since: started))
        }
        return try work()
    }

    private static func seconds(since start: ContinuousClock.Instant) -> TimeInterval {
        let elapsed = ContinuousClock.now - start
        return Double(elapsed.components.seconds)
            + Double(elapsed.components.attoseconds) / 1e18
    }

    private static func push(_ label: String) {
        lock.lock()
        spanStack.append(label)
        lock.unlock()
    }

    private static func pop() {
        lock.lock()
        if !spanStack.isEmpty { spanStack.removeLast() }
        lock.unlock()
    }

    private static func record(_ label: String, _ seconds: TimeInterval) {
        lock.lock()
        report.append(String(format: "%@ %.0fms", label, seconds * 1000))
        lock.unlock()
        if seconds >= threshold {
            logger.error(
                "\(label, privacy: .public) blocked the main thread for \(Int(seconds * 1000))ms"
            )
        }
    }

    // MARK: - Reporting one presentation

    /// Starts a fresh report. Called at the top of each presentation so the
    /// numbers describe one window opening rather than every window this launch.
    static func beginReport() {
        lock.lock()
        report.removeAll()
        lock.unlock()
    }

    /// Everything measured since `beginReport`, as one line.
    static var summary: String {
        lock.lock()
        defer { lock.unlock() }
        return report.joined(separator: " · ")
    }

    /// One line per window opening, at `notice` when it was quick and `error`
    /// when something in it beachballed.
    ///
    /// Logged either way, and that is deliberate. A line that only appears on a
    /// bad day has no good day to be compared against, and "was this always this
    /// slow" is the first question anyone asks of a stall report.
    static func report(_ what: String) {
        lock.lock()
        let lines = report
        lock.unlock()
        let worst = lines.compactMap(milliseconds(in:)).max() ?? 0
        let text = lines.joined(separator: " · ")
        if worst / 1000 >= threshold {
            logger.error("\(what, privacy: .public) beachballed — \(text, privacy: .public)")
        } else {
            logger.notice("\(what, privacy: .public) opened — \(text, privacy: .public)")
        }
    }

    private static func milliseconds(in line: String) -> Double? {
        guard let field = line.split(separator: " ").last, field.hasSuffix("ms") else { return nil }
        return Double(field.dropLast(2))
    }

    // MARK: - Watching the main thread from outside

    private nonisolated(unsafe) static var watchdog: Thread?

    /// The longest stall the watchdog has seen, in milliseconds, or zero if it
    /// has never seen one.
    ///
    /// Exists so the watchdog can be checked by running it rather than by
    /// reading it: `scripts/verify-stall-watchdog.py` compiles this file, blocks
    /// the main thread on purpose, and asserts this number moves — and then does
    /// not block it and asserts the number stays at zero. A detector nobody has
    /// watched detect anything is a detector that reports silence either way.
    private(set) nonisolated(unsafe) static var longestStallMilliseconds = 0

    /// One bool the watchdog thread writes to and the main thread sets.
    ///
    /// A box rather than a captured `var` because Swift 6 will not let a closure
    /// heading for another thread write to a local, and rightly: the whole point
    /// is that two threads read and write it. The lock makes it actually safe
    /// rather than merely permitted.
    private final class Ping: @unchecked Sendable {
        private let lock = NSLock()
        private var answered = false

        func answer() {
            lock.lock()
            answered = true
            lock.unlock()
        }

        var wasAnswered: Bool {
            lock.lock()
            defer { lock.unlock() }
            return answered
        }
    }

    /// Starts the one background thread that can see a stall nobody predicted.
    ///
    /// The shape is the standard one: set a flag, ask the main queue to clear
    /// it, and see how long that takes. A main thread that is busy cannot run
    /// the clearing block, so the delay in clearing *is* the stall — measured
    /// from outside, with no cooperation from the code doing the blocking.
    ///
    /// Poll every 150ms rather than continuously. A tighter loop measures the
    /// same stalls to no better effect and puts a wakeup on a laptop battery
    /// twenty times a second for the life of the process.
    ///
    /// **The number it reports is a floor, short by up to one poll interval.**
    /// A stall that begins just after a ping has been answered is not noticed
    /// until the next ping goes out, so the clock starts late. Measured against
    /// a deliberate 600ms freeze it reports 447–546ms. Read every figure in the
    /// log as "at least this long"; it never overstates.
    static func startWatchdog() {
        guard watchdog == nil else { return }
        let thread = Thread {
            var reported = false
            while !Thread.current.isCancelled {
                let asked = ContinuousClock.now
                let ping = Ping()
                DispatchQueue.main.async { ping.answer() }
                // Wait out the poll interval, then see whether the main thread
                // ever got to the block. Anything past the threshold is a stall
                // the user could have seen.
                Thread.sleep(forTimeInterval: 0.15)
                if ping.wasAnswered {
                    reported = false
                    continue
                }
                // Still wedged. Keep waiting so the number is the real length of
                // the stall rather than the length of one poll, but say something
                // only once per stall — a beachball that lasts four seconds is
                // one event, not twenty-six.
                while !Thread.current.isCancelled, !ping.wasAnswered {
                    Thread.sleep(forTimeInterval: 0.05)
                }
                guard !reported else { continue }
                reported = true
                let stalled = seconds(since: asked)
                guard stalled >= threshold else { continue }
                longestStallMilliseconds = max(longestStallMilliseconds, Int(stalled * 1000))
                lock.lock()
                let inside = spanStack.last
                lock.unlock()
                let place = inside ?? "no instrumented span — the stall is somewhere nobody has named yet"
                logger.error(
                    """
                    main thread unresponsive for \(Int(stalled * 1000))ms, inside \
                    \(place, privacy: .public)
                    """
                )
            }
        }
        thread.name = "melo.stall-watchdog"
        // Below the default. This thread must never be the reason something else
        // is late, and it is measuring latency rather than competing for it.
        thread.qualityOfService = .utility
        watchdog = thread
        thread.start()
    }
}
