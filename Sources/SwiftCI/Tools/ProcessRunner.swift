import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Starts a ``Tool``'s program and reports its output line by line.
///
/// The runner does not log output, filter it or check the exit code. ``Tool`` does that. The one line the runner writes is
/// the resolved path of a program name, when it is found in `PATH`. Tests replace the runner with `SwiftCITesting`
/// (`ProcessRunnerMock`).
public protocol ProcessRunner {
    /// Starts the program, writes the input, reads both streams and calls `onLine` for each line, in the order it was
    /// read. Returns the captured stdout and stderr and the exit code.
    ///
    /// Throws if the program cannot be started, or if the timeout expires. If `onLine` throws, the error is thrown
    /// after the process has been ended. If the calling task is cancelled, the process is ended and
    /// `CancellationError` is thrown. In these cases the process is ended with SIGTERM, then SIGKILL after a grace
    /// period. The timeout covers the whole run, including output held open by a child of the program.
    ///
    /// When this method returns or throws, the process has been reaped, the descriptors of the run are closed, and
    /// its workers have finished. Input that a descendant of the program still holds unread is dropped once the
    /// program has exited and both output streams have ended. Such a descendant does not delay the return.
    ///
    /// Only the program itself is ended, not the processes it started. A descendant that outlives an ended program
    /// keeps running.
    func run(_ tool: Tool, onLine: (ToolOutputLine) throws -> Void) async throws -> ToolResult
}

/// The real runner, built on `posix_spawn`. Registered in `registerDependencies()`.
///
/// **Ownership.** Each run has one supervisor thread. It is the only code that calls `waitpid` on the child, and the
/// only code that sends signals to it. It signals only while the child has not been reaped, so the PID cannot be
/// reused under a signal. The supervisor also owns the deadlines: the timeout, then SIGTERM, then SIGKILL after the
/// grace period. Each stdout and stderr stream has a reader thread, and the input has a writer thread. A worker waits
/// with `poll` on its descriptor and on a stop pipe. Only the supervisor closes the write end of the stop pipe, which
/// stops the workers. A worker closes its own descriptors before it finishes.
///
/// **Outcome.** A timeout, a failed `onLine`, a failed worker or cancellation is recorded once, the first one wins.
/// The supervisor then ends the process and stops the workers. The calling task reads the outcome only after the
/// supervisor has finished, so every worker error is seen, including one that happens during shutdown.
///
/// **Completion.** Normal completion waits for both output streams to reach end of file, unless a timeout is set. Once the child has been reaped and both streams have ended, the supervisor closes the stop pipe.
/// That releases a writer still blocked on input that a descendant holds unread. Such a release is not an error. The
/// rest of the input is dropped, because the program has gone.
///
/// **Descendants.** Signals go to the program's PID only, so the processes that the program started are not ended with
/// it. The program does not lead a process group of its own: that would stop Ctrl-C at the terminal from reaching it,
/// and would put it in the background group of the terminal, where a tool that reads from `/dev/tty` is stopped. A
/// process group needs signal handling in SwiftCI and a decision about the terminal first.
///
/// **Polling.** The supervisor wakes every ``supervisorTick`` and checks everything it owns: the child, the deadline, the
/// stop request and the workers. Nothing else can wait for all of these at once, and event sources for a child's exit
/// differ by platform. A run returns up to one tick after the program has exited, so the tick is short. A tick costs
/// one `waitpid` and two non-blocking group checks.
///
/// **Main actor.** The calling task consumes the events and calls `onLine`, one line at a time. A synchronous
/// `onLine` call cannot be preempted. The supervisor keeps enforcing the deadline and reaping while it runs.
///
/// **Buffering limitation.** The readers keep reading while `onLine` is busy, and the lines wait in memory with no
/// limit. A program that writes faster than `onLine` consumes uses memory in proportion to the backlog. Backpressure
/// is not implemented.
///
/// **Requirement.** SwiftCI must reap its children itself. Before spawning, the runner checks that the host process
/// does not ignore SIGCHLD and does not set `SA_NOCLDWAIT`, because the kernel would then reap the child on its own,
/// and the PID could be reused before SwiftCI signals it. Host code must not wait for arbitrary children either
/// (`waitpid(-1, …)`), because it would take the status of the program.
struct ProcessRunnerImpl: ProcessRunner {
    /// The time between the checks of the supervisor, in seconds.
    nonisolated static let supervisorTick: TimeInterval = 0.01

    /// The time between SIGTERM and SIGKILL when a run is ended early. Tests shorten it.
    static var killGrace: Duration = .seconds(5)

    /// Test hook. Called on the calling task right after the child has started, inside the cancellation scope.
    static var afterSpawnHook: (() -> Void)?

    /// Workers of runs that have not finished yet. Changed only on the main actor.
    static var openWorkerCount = 0

    func run(_ tool: Tool, onLine: (ToolOutputLine) throws -> Void) async throws -> ToolResult {
        // Secrets are revealed here, only now that the process is about to start.
        let environment = try tool.effectiveEnvironment()
        let inputBytes = try tool.input?.revealedBytes()
        let program = try Self.programPath(for: tool, environment: environment)
        if !tool.command.contains("/") {
            try FullLog.write("➤ Executable \(program)")
        }
        try Self.checkChildReaping(for: tool)
        let pipes = try Self.spawn(tool, program: program, environment: environment)
        let workerCount = pipes.stopReads.count
        ProcessRunnerImpl.openWorkerCount += workerCount

        let state = RunState()
        let (events, continuation) = Self.makeEventStream()
        let readers = DispatchGroup()
        let workers = DispatchGroup()
        let start = ContinuousClock.now
        let deadline = tool.timeout.map { start.advanced(by: $0) }
        let name = tool.displayName

        Self.startReader(pipes.stdout, stop: pipes.stopReads[0], stream: .stdout, tool: name,
                         state: state, readers: readers, workers: workers, to: continuation)
        Self.startReader(pipes.stderr, stop: pipes.stopReads[1], stream: .stderr, tool: name,
                         state: state, readers: readers, workers: workers, to: continuation)
        if let inputBytes, let stdinWrite = pipes.stdinWrite {
            Self.startWriter(inputBytes, to: stdinWrite, stop: pipes.stopReads[2], tool: name,
                             state: state, workers: workers)
        }
        // Started last, so that every group has its members counted before the supervisor waits on them.
        Self.startSupervisor(
            pid: pipes.pid,
            stopWrite: pipes.stopWrite,
            deadline: deadline,
            grace: Self.killGrace,
            tool: name,
            state: state,
            readers: readers,
            workers: workers,
            to: continuation
        )

        var exitStatus: Int32?
        var readersLeft = 2
        var stdoutLines: [String] = []
        var stderrLines: [String] = []

        await withTaskCancellationHandler {
            ProcessRunnerImpl.afterSpawnHook?()
            loop: for await event in events {
                switch event {
                case .line(let line):
                    // Once the run has ended, queued lines are dropped without calling `onLine`.
                    guard !state.hasEnded else { break }
                    switch line.stream {
                    case .stdout: stdoutLines.append(line.text)
                    case .stderr: stderrLines.append(line.text)
                    }
                    do {
                        try onLine(line)
                    } catch {
                        state.end(.failed(error))
                    }
                case .readerFinished:
                    readersLeft -= 1
                case .exited(let status):
                    exitStatus = status
                case .timedOut:
                    // Only wakes the loop. The outcome was recorded before the event was sent.
                    break
                }
                // Stops consuming once the run has ended, or once the program has exited and its output has ended.
                // The supervisor still finishes the workers, and `awaitFinished` below waits for that.
                if state.hasEnded || (exitStatus != nil && readersLeft == 0) {
                    break loop
                }
            }
        } onCancel: {
            state.requestStop()
        }

        // Cancellation can end the loop early. This wait is not cancellable: it returns only after the child is reaped,
        // the descriptors are closed and the workers have finished.
        await state.awaitFinished()
        ProcessRunnerImpl.openWorkerCount -= workerCount

        switch state.outcome {
        case .timedOut?:
            throw BuildError(message: "\(name) timed out after \(tool.timeout ?? .zero).", code: .timeout)
        case .failed(let error)?:
            throw error
        case nil:
            if Task.isCancelled {
                throw CancellationError()
            }
            return ToolResult(
                stdout: stdoutLines.joined(separator: "\n"),
                stderr: stderrLines.joined(separator: "\n"),
                exitCode: exitStatus ?? -1
            )
        }
    }
}
