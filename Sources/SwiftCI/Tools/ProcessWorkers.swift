import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif


/// The threads of a run: the readers, the writer and the supervisor, and what they exchange with the calling task.
extension ProcessRunnerImpl {
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

    /// Starts the supervisor of a run. It is the only code that reaps the child and sends it signals. Every tick (``supervisorTick``)
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

                Thread.sleep(forTimeInterval: supervisorTick)
            }
        }
        thread.start()
    }
}
