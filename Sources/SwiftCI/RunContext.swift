/// Lifecycle state of the command that is running: its name, the number of steps currently open,
/// the `cleanup`, `onFailure` and `onReport` handlers registered so far, the run report, the errors deferred by
/// `deferringFailure`, and the first internal error of a status-line write that could not be thrown. Created by the
/// runner for each command and cleared when the command ends.
///
/// This state never skips ordinary command or step code. A failure only changes how the
/// command ends, not what runs before that.
final class RunContext {
    /// The context of the command that is running, or `nil` outside a command.
    static var current: RunContext?

    let commandName: String

    /// The number of steps that are currently running. Zero at command level.
    private(set) var stepDepth = 0

    /// The handlers registered so far, in registration order.
    private(set) var handlers: [Handler] = []

    /// The findings and sections that the command has added to its run report so far.
    var report: RunReport

    /// The kind of the handler that runs now, or `nil` if none does. Handlers cannot be registered while one runs, and
    /// the report is final while an `onReport` handler runs, so it cannot be added to then.
    var runningHandler: Handler.Kind?

    /// `true` while a handler runs. Handlers cannot be registered then.
    var isRunningHandler: Bool { runningHandler != nil }

    /// `true` while an `onReport` handler runs. The report is final then, so it cannot be added to.
    var isRunningReportHandler: Bool { runningHandler == .report }

    /// The first internal error since the runner last took it. See ``writeStatus(_:)``.
    private var internalError: BuildError?

    /// The errors of `deferringFailure` calls, in the order they happened, until the runner takes them.
    private var deferredErrors: [Error] = []

    init(commandName: String) {
        self.commandName = commandName
        report = RunReport(commandName: commandName)
    }

    func enterStep() {
        stepDepth += 1
    }

    func leaveStep() {
        stepDepth -= 1
    }

    func addHandler(_ handler: Handler) {
        handlers.append(handler)
    }

    /// Runs a status-line write whose error cannot be thrown to the caller, such as the
    /// non-throwing allowed step or the status line of a step that already failed.
    ///
    /// The first error is kept and fails the command with ``ErrorCode/internal`` at the
    /// runner's next checkpoint. Later errors are dropped until the runner takes the error.
    func writeStatus(_ write: () throws -> Void) {
        do {
            try write()
        } catch {
            if internalError == nil {
                internalError = BuildError(message: "\(error)", code: .internal)
            }
        }
    }

    /// Returns the first internal error recorded since the last call, and clears it.
    func takeInternalError() -> BuildError? {
        defer { internalError = nil }
        return internalError
    }

    /// Stores an error that `deferringFailure` caught. The runner fails the command with it when the body ends.
    func deferError(_ error: Error) {
        deferredErrors.append(error)
    }

    /// Returns the errors deferred since the last call, in order, and clears them.
    func takeDeferredErrors() -> [Error] {
        defer { deferredErrors = [] }
        return deferredErrors
    }

    /// A `cleanup`, `onFailure` or `onReport` handler, kept in registration order. The body receives the run report
    /// as it is when the handler runs. Only an `onReport` handler sees the final report.
    struct Handler {
        enum Kind {
            case cleanup
            case onFailure
            case report

            /// The name the handler is logged with, like a step.
            var stepName: String {
                switch self {
                case .cleanup: "Cleanup"
                case .onFailure: "On failure"
                case .report: "Report"
                }
            }
        }

        let kind: Kind
        /// `.allowed` if the handler may fail without failing the command. `nil` otherwise.
        let failure: FailureMode?
        let body: (RunReport) async throws -> Void
    }
}
