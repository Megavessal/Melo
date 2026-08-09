// Melo/Editor/Sources/ToolProcessRunner.swift
import Foundation

// MARK: - Output

/// One line of output from an external tool, tagged with the stream it arrived on.
/// yt-dlp writes progress to stdout and diagnostics to stderr, and the two have to
/// stay distinguishable: a progress line is a UI update, an error line is a message.
enum ToolOutputLine: Sendable, Equatable {
    case standardOutput(String)
    case standardError(String)

    var text: String {
        switch self {
        case .standardOutput(let line), .standardError(let line): return line
        }
    }
}

/// Everything the caller needs to decide what happened, with no `Process` in it —
/// so a stand-in runner can produce one without spawning anything.
struct ToolProcessResult: Sendable, Equatable {
    var exitCode: Int32
    /// True when `NSTaskTerminationReason` was `.uncaughtSignal`. A tool killed by
    /// a signal has an exit code of 0 in some code paths, so this is the only
    /// honest way to tell "finished" from "was killed".
    var wasKilledBySignal: Bool
    var standardOutput: String
    var standardError: String

    var didSucceed: Bool { exitCode == 0 && !wasKilledBySignal }
}

enum ToolProcessFailure: LocalizedError, Equatable {
    case notExecutable(URL)
    case launchFailed(String)

    var errorDescription: String? {
        switch self {
        case .notExecutable(let url):
            return "\(url.lastPathComponent) is there but macOS won't run it."
        case .launchFailed(let reason):
            return reason
        }
    }
}

// MARK: - The abstraction

/// The one place this piece starts a child process.
///
/// Everything in the editor that shells out goes through this, for two reasons. `yt-dlp`
/// and `ffmpeg` are not installed on the build machine, so the only way to exercise
/// argument construction, progress parsing, cancellation and each error path is to
/// substitute a runner that speaks the same command line. And keeping `Process` in
/// exactly one file means the "never build a shell string, never interpolate a URL"
/// rule has one place to hold rather than four.
protocol ToolProcessRunning: Sendable {
    /// Runs `executable` with `arguments` passed as an array — never a shell string.
    ///
    /// `onLine` is called for every complete line on either stream, on an arbitrary
    /// queue, while the tool runs. Cancelling the surrounding task terminates the
    /// child: `SIGTERM` first, `SIGKILL` if it is still alive two seconds later.
    func run(
        executable: URL,
        arguments: [String],
        workingDirectory: URL?,
        onLine: (@Sendable (ToolOutputLine) -> Void)?
    ) async throws -> ToolProcessResult
}

// MARK: - The real one

struct SystemToolProcessRunner: ToolProcessRunning {
    init() {}

    func run(
        executable: URL,
        arguments: [String],
        workingDirectory: URL?,
        onLine: (@Sendable (ToolOutputLine) -> Void)?
    ) async throws -> ToolProcessResult {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw ToolProcessFailure.notExecutable(executable)
        }

        let handle = RunningProcessHandle()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let process = Process()
                process.executableURL = executable
                process.arguments = arguments
                if let workingDirectory {
                    process.currentDirectoryURL = workingDirectory
                }
                // Melo is unsandboxed, so the child inherits a usable environment.
                // The one thing forced is a C locale, because every string this
                // piece parses out of yt-dlp — percentages, "Video unavailable" —
                // is matched in English.
                var environment = ProcessInfo.processInfo.environment
                environment["LC_ALL"] = "C"
                environment["LANG"] = "C"
                process.environment = environment

                let outPipe = Pipe()
                let errPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = errPipe
                process.standardInput = FileHandle.nullDevice

                let collector = OutputCollector(onLine: onLine)
                let completion = CompletionLatch { result in
                    continuation.resume(returning: result)
                }

                outPipe.fileHandleForReading.readabilityHandler = { fileHandle in
                    let data = fileHandle.availableData
                    if data.isEmpty {
                        fileHandle.readabilityHandler = nil
                        collector.finishStandardOutput()
                        completion.markStandardOutputClosed(collector)
                    } else {
                        collector.ingest(data, isError: false)
                    }
                }
                errPipe.fileHandleForReading.readabilityHandler = { fileHandle in
                    let data = fileHandle.availableData
                    if data.isEmpty {
                        fileHandle.readabilityHandler = nil
                        collector.finishStandardError()
                        completion.markStandardErrorClosed(collector)
                    } else {
                        collector.ingest(data, isError: true)
                    }
                }

                process.terminationHandler = { finished in
                    completion.markExited(
                        code: finished.terminationStatus,
                        killedBySignal: finished.terminationReason == .uncaughtSignal,
                        collector: collector
                    )
                }

                guard handle.adopt(process) else {
                    // Cancelled between entering the handler and launching.
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    process.terminationHandler = nil
                    continuation.resume(throwing: CancellationError())
                    return
                }

                do {
                    try process.run()
                } catch {
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    process.terminationHandler = nil
                    handle.clear()
                    continuation.resume(
                        throwing: ToolProcessFailure.launchFailed(error.localizedDescription)
                    )
                }
            }
        } onCancel: {
            handle.terminate()
        }
    }
}

// MARK: - Cancellation

/// Holds the live `Process` so the cancellation handler can reach it. A cancel that
/// lands before `run()` is recorded, so the process is never started and then orphaned.
private final class RunningProcessHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var isCancelled = false

    func adopt(_ process: Process) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isCancelled else { return false }
        self.process = process
        return true
    }

    func clear() {
        lock.lock()
        process = nil
        lock.unlock()
    }

    /// `SIGTERM`, then `SIGKILL` if the child is still alive. yt-dlp cleans up its
    /// `.part` files on `SIGTERM`, so the polite signal is worth the two seconds.
    func terminate() {
        lock.lock()
        isCancelled = true
        let running = process
        lock.unlock()

        guard let running, running.isRunning else { return }
        running.terminate()

        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
            guard running.isRunning else { return }
            kill(running.processIdentifier, SIGKILL)
        }
    }
}

// MARK: - Output collection

/// Splits both streams into lines and keeps the full text. `readabilityHandler`
/// callbacks for the two pipes run on different queues, so every mutation is locked.
/// None of this is on an audio thread — the lock is the simple correct answer here.
private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private let onLine: (@Sendable (ToolOutputLine) -> Void)?

    private var outBuffer = Data()
    private var errBuffer = Data()
    private var outText = ""
    private var errText = ""

    init(onLine: (@Sendable (ToolOutputLine) -> Void)?) {
        self.onLine = onLine
    }

    func ingest(_ data: Data, isError: Bool) {
        var completedLines: [String] = []

        lock.lock()
        if isError {
            errBuffer.append(data)
            completedLines = Self.drainLines(from: &errBuffer)
            errText += completedLines.joined(separator: "\n") + (completedLines.isEmpty ? "" : "\n")
        } else {
            outBuffer.append(data)
            completedLines = Self.drainLines(from: &outBuffer)
            outText += completedLines.joined(separator: "\n") + (completedLines.isEmpty ? "" : "\n")
        }
        lock.unlock()

        guard let onLine else { return }
        for line in completedLines where !line.isEmpty {
            onLine(isError ? .standardError(line) : .standardOutput(line))
        }
    }

    func finishStandardOutput() { flushRemainder(isError: false) }
    func finishStandardError() { flushRemainder(isError: true) }

    private func flushRemainder(isError: Bool) {
        lock.lock()
        let remainder: String
        if isError {
            remainder = String(decoding: errBuffer, as: UTF8.self)
            errBuffer.removeAll()
            errText += remainder
        } else {
            remainder = String(decoding: outBuffer, as: UTF8.self)
            outBuffer.removeAll()
            outText += remainder
        }
        lock.unlock()

        let trimmed = remainder.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let onLine else { return }
        onLine(isError ? .standardError(trimmed) : .standardOutput(trimmed))
    }

    var texts: (standardOutput: String, standardError: String) {
        lock.lock()
        defer { lock.unlock() }
        return (outText, errText)
    }

    /// Splits on both `\n` and `\r`. `--newline` makes yt-dlp use `\n` for progress,
    /// but a carriage-return progress bar from an older build or a different tool
    /// would otherwise arrive as one enormous line at exit.
    private static func drainLines(from buffer: inout Data) -> [String] {
        var lines: [String] = []
        while let index = buffer.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
            let lineData = buffer[buffer.startIndex..<index]
            buffer.removeSubrange(buffer.startIndex...index)
            let line = String(decoding: lineData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !line.isEmpty { lines.append(line) }
        }
        return lines
    }
}

// MARK: - Completion

/// Resumes the continuation exactly once, and only after the process has exited
/// *and* both pipes have reached EOF. Resuming on `terminationHandler` alone loses
/// the last chunk of output, which is usually the error message.
private final class CompletionLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var outClosed = false
    private var errClosed = false
    private var exited = false
    private var exitCode: Int32 = 0
    private var killedBySignal = false
    private var resumed = false
    private let resume: @Sendable (ToolProcessResult) -> Void

    init(resume: @escaping @Sendable (ToolProcessResult) -> Void) {
        self.resume = resume
    }

    func markStandardOutputClosed(_ collector: OutputCollector) {
        lock.lock(); outClosed = true; lock.unlock()
        finishIfReady(collector)
    }

    func markStandardErrorClosed(_ collector: OutputCollector) {
        lock.lock(); errClosed = true; lock.unlock()
        finishIfReady(collector)
    }

    func markExited(code: Int32, killedBySignal: Bool, collector: OutputCollector) {
        lock.lock()
        exited = true
        exitCode = code
        self.killedBySignal = killedBySignal
        lock.unlock()
        finishIfReady(collector)
    }

    private func finishIfReady(_ collector: OutputCollector) {
        lock.lock()
        guard outClosed, errClosed, exited, !resumed else { lock.unlock(); return }
        resumed = true
        let code = exitCode
        let killed = killedBySignal
        lock.unlock()

        let texts = collector.texts
        resume(
            ToolProcessResult(
                exitCode: code,
                wasKilledBySignal: killed,
                standardOutput: texts.standardOutput,
                standardError: texts.standardError
            )
        )
    }
}
