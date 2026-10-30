import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Starts a ``Tool``'s program and reports its output line by line.
///
/// The runner does not log, filter or check the exit code. ``Tool`` does that. Tests replace the runner with
/// `register(ProcessRunner.self, …)`.
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
/// **Completion.** Normal completion waits for both output streams to reach end of file, as it always has, unless a
/// timeout is set. Once the child has been reaped and both streams have ended, the supervisor closes the stop pipe.
/// That releases a writer still blocked on input that a descendant holds unread. Such a release is not an error. The
/// rest of the input is dropped, because the program has gone.
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
            throw BuildError(message: "\(name) timed out after \(tool.timeout ?? .zero).", isTimeout: true)
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

    /// Finds the program. A `command` with a `/` is a path, relative to `workingDirectory`. Any other `command` is
    /// looked up in the `PATH` of `environment`. Empty and relative `PATH` entries are skipped. If `PATH` is missing,
    /// `/usr/bin:/bin` is used. The first directory whose `command` entry is an executable regular file wins.
    nonisolated static func programPath(for tool: Tool, environment: [String: String]) throws -> String {
        if tool.command.contains("/") {
            let path = URL(fileURLWithPath: tool.command, relativeTo: tool.workingDirectory).standardizedFileURL.path
            guard isExecutableFile(path) else {
                throw BuildError(
                    message: "Failed to execute tool '\(tool.command)': there is no executable file at this path. Check the path and that the file is executable."
                )
            }
            return path
        }

        let searchPath = environment["PATH"] ?? "/usr/bin:/bin"
        for directory in searchPath.split(separator: ":") where directory.hasPrefix("/") {
            let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent(tool.command).path
            if isExecutableFile(candidate) {
                return candidate
            }
        }
        throw BuildError(
            message: "Failed to execute tool '\(tool.command)': no executable with this name in PATH '\(searchPath)'. Check the name, or pass the full path."
        )
    }

    /// Whether `path` is an executable regular file. Symbolic links are followed, so a link to one counts. Directories,
    /// FIFOs, sockets and devices do not.
    nonisolated static func isExecutableFile(_ path: String) -> Bool {
        var info = stat()
        guard stat(path, &info) == 0 else { return false }
        return (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) && access(path, X_OK) == 0
    }

    /// Throws unless SwiftCI can reap its own children. An ignored SIGCHLD, or `SA_NOCLDWAIT`, makes the kernel reap
    /// children on exit. The PID could then be reused before SwiftCI signals it.
    nonisolated static func checkChildReaping(for tool: Tool) throws {
        var action = sigaction()
        guard sigaction(SIGCHLD, nil, &action) == 0 else {
            throw BuildError(
                message: "Failed to execute tool '\(tool.command)': could not read the SIGCHLD disposition. Details: \(String(cString: strerror(errno)))."
            )
        }
        let ignored = handlerValue(action) == 1
        let autoReaped = (action.sa_flags & SA_NOCLDWAIT) != 0
        guard !ignored && !autoReaped else {
            throw BuildError(
                message: "SwiftCI must own child reaping, so the host process must not ignore SIGCHLD or set SA_NOCLDWAIT. Restore the default SIGCHLD disposition. Tool '\(tool.command)' was not started.",
                code: .internal
            )
        }
    }

    /// The raw value of a signal action's handler: 0 for the default, 1 for ignore.
    nonisolated static func handlerValue(_ action: sigaction) -> UInt {
        #if canImport(Darwin)
        unsafeBitCast(action.__sigaction_u.__sa_handler, to: UInt.self)
        #else
        unsafeBitCast(action.__sigaction_handler.sa_handler, to: UInt.self)
        #endif
    }

    /// Converts a `waitpid` status to an exit code. A normal exit gives its exit status. A child killed by a signal
    /// gives 128 plus the signal number, as shells do. Foundation's `Process` reports the bare signal number instead.
    nonisolated static func decodeExitStatus(_ status: Int32) -> Int32 {
        let signal = status & 0x7f
        if signal == 0 {
            return (status >> 8) & 0xff
        }
        return 128 + signal
    }

    /// Creates the event stream. `makeStream` needs macOS 14, so the closure-based initializer is used.
    nonisolated static func makeEventStream() -> (AsyncStream<ProcessEvent>, AsyncStream<ProcessEvent>.Continuation) {
        var continuation: AsyncStream<ProcessEvent>.Continuation!
        let events = AsyncStream<ProcessEvent> { continuation = $0 }
        return (events, continuation)
    }

    /// The descriptors the run keeps after the child has started. `stopReads` has one descriptor per worker: the
    /// stdout reader, the stderr reader, and the writer if there is input.
    nonisolated struct SpawnedPipes {
        let pid: pid_t
        let stdout: Int32
        let stderr: Int32
        let stdinWrite: Int32?
        let stopReads: [Int32]
        let stopWrite: Int32
    }

    /// Starts the program with `posix_spawn`, connected to new pipes. Every descriptor is configured before the spawn:
    /// parent ends are non-blocking and close-on-exec, and the child ends are close-on-exec, so the child gets only
    /// the copies made by the file actions. Every result is checked. On any failure, every descriptor created here
    /// is closed, and the start-failure error is thrown. After a successful spawn nothing else can fail.
    nonisolated static func spawn(_ tool: Tool, program: String, environment: [String: String]) throws -> SpawnedPipes {
        var owned: [Int32] = []
        func fail(_ reason: String) -> BuildError {
            for fd in owned {
                close(fd)
            }
            owned = []
            return BuildError(message: "Failed to execute tool '\(tool.command)': \(reason)")
        }
        // Checks a call that returns -1 and sets errno.
        func check(_ result: Int32) throws {
            guard result != -1 else { throw fail(errorText(errno)) }
        }
        // Checks a call that returns an error number, as the posix_spawn file action functions do.
        func require(_ code: Int32) throws {
            guard code == 0 else { throw fail(errorText(code)) }
        }
        func makePipe() throws -> (read: Int32, write: Int32) {
            var fds: [Int32] = [-1, -1]
            try check(pipe(&fds))
            owned += fds
            for fd in fds {
                try check(fcntl(fd, F_SETFD, FD_CLOEXEC))
            }
            return (fds[0], fds[1])
        }
        func nonBlocking(_ fd: Int32) throws {
            let flags = fcntl(fd, F_GETFL)
            try check(flags)
            try check(fcntl(fd, F_SETFL, flags | O_NONBLOCK))
        }

        let stdoutPipe = try makePipe()
        let stderrPipe = try makePipe()
        let stop = try makePipe()
        var stdinPipe: (read: Int32, write: Int32)?
        if tool.input != nil {
            stdinPipe = try makePipe()
        }
        let stdinChild: Int32
        if let stdinPipe {
            stdinChild = stdinPipe.read
            try nonBlocking(stdinPipe.write)
            #if os(macOS)
            // A write to a closed pipe must fail with EPIPE, not send SIGPIPE. macOS can say so per descriptor.
            try check(fcntl(stdinPipe.write, F_SETNOSIGPIPE, 1))
            #endif
        } else {
            stdinChild = open("/dev/null", O_RDONLY | O_CLOEXEC)
            try check(stdinChild)
            owned.append(stdinChild)
        }

        // Each worker gets its own duplicate of the stop pipe's read end, so it can close its copy.
        var stopReads: [Int32] = []
        for _ in 0..<(stdinPipe == nil ? 2 : 3) {
            let fd = fcntl(stop.read, F_DUPFD_CLOEXEC, 0)
            try check(fd)
            owned.append(fd)
            stopReads.append(fd)
        }
        try nonBlocking(stdoutPipe.read)
        try nonBlocking(stderrPipe.read)

        // Darwin declares the object as an opaque pointer, Linux as a struct.
        #if os(macOS)
        var actions: posix_spawn_file_actions_t? = nil
        #else
        var actions = posix_spawn_file_actions_t()
        #endif
        try require(posix_spawn_file_actions_init(&actions))
        defer { posix_spawn_file_actions_destroy(&actions) }
        try require(posix_spawn_file_actions_adddup2(&actions, stdinChild, 0))
        try require(posix_spawn_file_actions_adddup2(&actions, stdoutPipe.write, 1))
        try require(posix_spawn_file_actions_adddup2(&actions, stderrPipe.write, 2))
        if let directory = tool.workingDirectory {
            // macOS 10.15 and later, glibc 2.29 and later.
            try require(posix_spawn_file_actions_addchdir_np(&actions, directory.path))
        }

        // argv[0] is the command as given. The program is the resolved path, so no lookup happens in the child.
        guard let arguments = cStrings([tool.command] + tool.arguments) else {
            throw fail("Details: could not allocate the arguments.")
        }
        defer { freeCStrings(arguments) }
        guard let variables = cStrings(environment.map { "\($0.key)=\($0.value)" }) else {
            throw fail("Details: could not allocate the environment.")
        }
        defer { freeCStrings(variables) }

        var pid: pid_t = 0
        let result = posix_spawn(&pid, program, &actions, nil, arguments, variables)
        guard result == 0 else { throw fail(errorText(result)) }

        // The child has its own copies now. Closing the parent's copies makes end of file reach the parent.
        for fd in [stdoutPipe.write, stderrPipe.write, stdinChild, stop.read] {
            close(fd)
        }
        owned = []

        return SpawnedPipes(
            pid: pid,
            stdout: stdoutPipe.read,
            stderr: stderrPipe.read,
            stdinWrite: stdinPipe?.write,
            stopReads: stopReads,
            stopWrite: stop.write
        )
    }

    /// Copies strings into C strings, with a trailing nil. Returns `nil` if an allocation fails. Nothing is left
    /// allocated then.
    nonisolated static func cStrings(_ strings: [String]) -> [UnsafeMutablePointer<CChar>?]? {
        var pointers: [UnsafeMutablePointer<CChar>?] = []
        for string in strings {
            guard let pointer = strdup(string) else {
                freeCStrings(pointers)
                return nil
            }
            pointers.append(pointer)
        }
        pointers.append(nil)
        return pointers
    }

    nonisolated static func freeCStrings(_ pointers: [UnsafeMutablePointer<CChar>?]) {
        for case let pointer? in pointers {
            free(pointer)
        }
    }

    nonisolated static func errorText(_ code: Int32) -> String {
        "Details: \(String(cString: strerror(code)))."
    }

    /// Reads `fd` until end of file, and sends its lines as events. The worker waits with `poll` on `fd` and on `stop`,
    /// so the run can stop it. Each `read(2)` returns what is available. An unexpected error is recorded as the run's
    /// outcome. The worker closes its descriptors, reports `readerFinished` and leaves the groups, in that order.
    nonisolated static func startReader(
        _ fd: Int32,
        stop stopFD: Int32,
        stream: ToolOutputLine.Stream,
        tool: String,
        state: RunState,
        readers: DispatchGroup,
        workers: DispatchGroup,
        to continuation: AsyncStream<ProcessEvent>.Continuation
    ) {
        readers.enter()
        workers.enter()
        let thread = Thread {
            var splitter = LineSplitter()
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            var failure: String?
            var reachedEnd = false
            reading: while true {
                var descriptors = [
                    pollfd(fd: fd, events: Int16(POLLIN), revents: 0),
                    pollfd(fd: stopFD, events: Int16(POLLIN), revents: 0),
                ]
                if poll(&descriptors, 2, -1) < 0 {
                    if errno == EINTR { continue }
                    failure = "Failed to read the output of tool '\(tool)'. \(errorText(errno))"
                    break reading
                }
                if descriptors[1].revents != 0 {
                    break reading
                }
                guard descriptors[0].revents != 0 else { continue }

                let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
                if count > 0 {
                    for text in splitter.append(Data(buffer[..<count])) {
                        continuation.yield(.line(ToolOutputLine(stream: stream, text: text)))
                    }
                } else if count == 0 {
                    reachedEnd = true
                    break reading
                } else if errno != EAGAIN && errno != EINTR {
                    failure = "Failed to read the output of tool '\(tool)'. \(errorText(errno))"
                    break reading
                }
            }
            if reachedEnd, let text = splitter.finish() {
                continuation.yield(.line(ToolOutputLine(stream: stream, text: text)))
            }
            if let failure {
                state.end(.failed(BuildError(message: failure)))
            }
            close(fd)
            close(stopFD)
            continuation.yield(.readerFinished)
            readers.leave()
            workers.leave()
        }
        thread.start()
    }

    /// Writes `bytes` to `fd`, then closes it, so the program sees end of file. The worker waits with `poll` on `fd`
    /// and on `stop`. EPIPE means the program closed its standard input early. That is not an error of the run.
    /// A stop, including the release at normal completion, drops the rest of the input without an error.
    ///
    /// SIGPIPE does not change the process's disposition. On macOS the descriptor is marked with `F_SETNOSIGPIPE`.
    /// On Linux the worker blocks SIGPIPE in its own thread. After an EPIPE it consumes the pending signal with a
    /// zero-timeout `sigtimedwait`, then restores its mask. The signal is thread-directed, so no other thread is
    /// affected.
    nonisolated static func startWriter(
        _ bytes: Data,
        to fd: Int32,
        stop stopFD: Int32,
        tool: String,
        state: RunState,
        workers: DispatchGroup
    ) {
        workers.enter()
        let thread = Thread {
            var failure: String?
            #if !os(macOS)
            var sigpipe = sigset_t()
            var previousMask = sigset_t()
            sigemptyset(&sigpipe)
            sigaddset(&sigpipe, SIGPIPE)
            let masked = pthread_sigmask(SIG_BLOCK, &sigpipe, &previousMask)
            if masked != 0 {
                failure = "Failed to write the input of tool '\(tool)'. \(errorText(masked))"
            }
            var brokenPipe = false
            #endif

            if failure == nil {
                bytes.withUnsafeBytes { raw in
                    var offset = 0
                    writing: while offset < raw.count {
                        var descriptors = [
                            pollfd(fd: fd, events: Int16(POLLOUT), revents: 0),
                            pollfd(fd: stopFD, events: Int16(POLLIN), revents: 0),
                        ]
                        if poll(&descriptors, 2, -1) < 0 {
                            if errno == EINTR { continue }
                            failure = "Failed to write the input of tool '\(tool)'. \(errorText(errno))"
                            break writing
                        }
                        if descriptors[1].revents != 0 {
                            break writing
                        }
                        guard descriptors[0].revents != 0 else { continue }

                        let count = write(fd, raw.baseAddress! + offset, raw.count - offset)
                        if count > 0 {
                            offset += count
                        } else if count < 0 && (errno == EAGAIN || errno == EINTR) {
                            continue
                        } else if count < 0 && errno == EPIPE {
                            #if !os(macOS)
                            brokenPipe = true
                            #endif
                            break writing
                        } else {
                            failure = "Failed to write the input of tool '\(tool)'. \(errorText(errno))"
                            break writing
                        }
                    }
                }
            }

            #if !os(macOS)
            if masked == 0 {
                if brokenPipe {
                    var zero = timespec()
                    _ = sigtimedwait(&sigpipe, nil, &zero)
                }
                _ = pthread_sigmask(SIG_SETMASK, &previousMask, nil)
            }
            #endif
            if let failure {
                state.end(.failed(BuildError(message: failure)))
            }
            close(fd)
            close(stopFD)
            workers.leave()
        }
        thread.start()
    }

    /// Starts the supervisor of a run. It is the only code that reaps the child and sends it signals. Every tick (10 ms)
    /// it:
    /// 1. reaps the child with `waitpid(WNOHANG)`, if it has not been reaped;
    /// 2. when the deadline has passed, or a stop was requested, records the outcome, sends SIGTERM if the child is not
    ///    reaped, and closes the stop pipe, which stops the workers;
    /// 3. sends SIGKILL if the child is still running when the grace period has passed;
    /// 4. once the child is reaped and both output streams have ended, closes the stop pipe, which releases a writer
    ///    that is still blocked on input;
    /// 5. finishes when every worker has finished, and ends the event stream.
    /// Nothing here waits for the main actor, so a slow `onLine` cannot delay the deadline or the reap.
    nonisolated static func startSupervisor(
        pid: pid_t,
        stopWrite: Int32,
        deadline: ContinuousClock.Instant?,
        grace: Duration,
        tool: String,
        state: RunState,
        readers: DispatchGroup,
        workers: DispatchGroup,
        to continuation: AsyncStream<ProcessEvent>.Continuation
    ) {
        let thread = Thread {
            var stopWrite = stopWrite
            var reaped = false
            var stopping = false
            var killAt: ContinuousClock.Instant?
            var killSent = false

            func closeStopPipe() {
                if stopWrite >= 0 {
                    close(stopWrite)
                    stopWrite = -1
                }
            }

            while true {
                let now = ContinuousClock.now
                if !reaped {
                    var status: Int32 = 0
                    let result = waitpid(pid, &status, WNOHANG)
                    if result == pid {
                        reaped = true
                        continuation.yield(.exited(decodeExitStatus(status)))
                    } else if result < 0 && errno != EINTR {
                        // The child is no longer ours to signal. Nothing is sent to it from now on.
                        reaped = true
                        state.end(.failed(BuildError(
                            message: "Failed to wait for tool '\(tool)'. \(errorText(errno)) SwiftCI must own child reaping, so nothing else may reap the program."
                        )))
                    }
                }

                if !stopping && (state.isStopRequested || (deadline.map { now >= $0 } ?? false)) {
                    stopping = true
                    if let deadline, now >= deadline {
                        // Recorded before the event, so the run sees the outcome when it wakes.
                        state.end(.timedOut)
                        continuation.yield(.timedOut)
                    }
                    if !reaped {
                        kill(pid, SIGTERM)
                        killAt = now.advanced(by: grace)
                    }
                    closeStopPipe()
                }
                if !reaped, !killSent, let killAt, now >= killAt {
                    kill(pid, SIGKILL)
                    killSent = true
                }

                // The child has exited and both output streams have ended. A writer still blocked on input that a
                // descendant holds unread is released here. The rest of its input is dropped.
                if reaped && readers.wait(timeout: .now()) == .success {
                    closeStopPipe()
                }
                if reaped && workers.wait(timeout: .now()) == .success {
                    closeStopPipe()
                    state.markFinished()
                    continuation.finish()
                    return
                }

                Thread.sleep(forTimeInterval: 0.01)
            }
        }
        thread.start()
    }
}

/// The outcome and stop flag of a run, shared by the calling task, the supervisor and the workers. Guarded by a lock.
///
/// `@unchecked Sendable` is needed because the lock is the synchronization. `Mutex` from the Synchronization module
/// needs macOS 15, and the package supports macOS 13.
nonisolated final class RunState: @unchecked Sendable {
    /// How a run ended early. The first outcome recorded wins.
    nonisolated enum Outcome {
        case timedOut
        case failed(Error)
    }

    private let lock = NSLock()
    private var recorded: Outcome?
    private var stopRequested = false
    private var finished = false
    private var waiter: CheckedContinuation<Void, Never>?

    /// The recorded outcome, or `nil` if the run has not ended early.
    var outcome: Outcome? {
        locked { recorded }
    }

    var hasEnded: Bool {
        locked { recorded != nil }
    }

    var isStopRequested: Bool {
        locked { stopRequested }
    }

    /// Records how the run ended, unless an outcome was recorded before, and asks the supervisor to end the process.
    func end(_ outcome: Outcome) {
        locked {
            if recorded == nil {
                recorded = outcome
            }
            stopRequested = true
        }
    }

    /// Asks the supervisor to end the process, without recording an outcome. Used for cancellation.
    func requestStop() {
        locked { stopRequested = true }
    }

    /// Called by the supervisor as its last step. Resumes the waiter, if there is one.
    func markFinished() {
        let waiting: CheckedContinuation<Void, Never>? = locked {
            finished = true
            let waiting = waiter
            waiter = nil
            return waiting
        }
        waiting?.resume()
    }

    /// Waits until the supervisor has finished. Cancellation does not end the wait.
    func awaitFinished() async {
        await withCheckedContinuation { continuation in
            let alreadyFinished: Bool = locked {
                if !finished {
                    waiter = continuation
                }
                return finished
            }
            if alreadyFinished {
                continuation.resume()
            }
        }
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

/// What the readers and the supervisor tell a run. Created off the main actor.
nonisolated enum ProcessEvent: Sendable {
    case line(ToolOutputLine)
    /// An output stream has ended, or was stopped. Its last line was sent before this event.
    case readerFinished
    case exited(Int32)
    /// The deadline has passed. Sent to wake the run. The outcome was recorded before.
    case timedOut
}

/// Splits bytes into lines: at LF, with a CR before the LF removed. A final line without LF is kept.
///
/// It works on bytes and decodes each whole line as UTF-8, with invalid bytes replaced. A multi-byte character split
/// across two reads is therefore decoded correctly.
nonisolated struct LineSplitter {
    private var pending: [UInt8] = []

    /// Returns the lines completed by `bytes`. The rest is kept until the next call or ``finish()``.
    mutating func append(_ bytes: Data) -> [String] {
        var lines: [String] = []
        for byte in bytes {
            if byte == 0x0A {
                lines.append(completedLine())
            } else {
                pending.append(byte)
            }
        }
        return lines
    }

    /// Returns the final line without LF, or `nil` if there is none.
    mutating func finish() -> String? {
        guard !pending.isEmpty else { return nil }
        defer { pending = [] }
        return String(decoding: pending, as: UTF8.self)
    }

    private mutating func completedLine() -> String {
        if pending.last == 0x0D {
            pending.removeLast()
        }
        defer { pending = [] }
        return String(decoding: pending, as: UTF8.self)
    }
}
