import Foundation

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