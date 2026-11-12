import Foundation

/// Runs one command and logs its failure. Returns 0 if the command succeeded, otherwise the exit code of the failure.
///
/// A failure of the body decides the exit code. The first error that ``deferringFailure(_:)`` deferred takes its place,
/// and the body's error is logged as well. The `cleanup`, `onFailure` and `onReport` handlers run after the body, and
/// the run report is printed and written to the artifacts directory. A failure of any of these steps decides the exit
/// code only if nothing failed before, and an allowed handler failure never does. This includes the failures of the run
/// report, which fail the command with exit code 1, a status-line write that recorded an internal error, and the
/// close of the full log. The `onFailure` handlers run only if the command has failed.
///
/// The outcome of the run report is set before the summary and the `onReport` handlers run, so they all see the same
/// outcome. If the full log cannot be closed after a successful run, the outcome stays ``CommandOutcome/succeeded``. The
/// `onFailure` handlers then run after the close, and their failures are logged but do not change the exit code (3).
///
/// `isLast` tells whether the command is the last one that the run would run if it does not fail. The options that no
/// `input` call read are logged once, by the last command that runs, or by the command that failed.
///
/// The run context is created for the command and stays set while the handlers run, so steps work inside them. It is
/// cleared when the command ends, also after a thrown error.
internal func runCommand(_ command: Command, isLast: Bool) async -> Int32 {
    let context = RunContext(commandName: command.name)
    RunContext.current = context
    defer { RunContext.current = nil }

    var failure: CommandFailure?
    do {
        try ArtifactsLocation.current?.prepareDirectory()
        try FullLog.open(name: command.name)
        try FullLog.write(CIDetection.summary(CI.environment))
        if let arguments = RunOptions.current?.commandLine {
            try FullLog.write("➤ Arguments \(arguments.joined(separator: " "))")
        }
        try await command.run()
    } catch {
        failure = logFailure(error)
    }
    absorbDeferredFailures(context, into: &failure)
    absorbInternalError(context, into: &failure)

    await runHandlers(.cleanup, in: context, failure: &failure)
    absorbReportFailures(context, into: &failure)
    if failure != nil {
        await runHandlers(.onFailure, in: context, failure: &failure)
    }

    finishReport(context, failure: failure)
    publishRunReport(context, failure: &failure)
    await runHandlers(.report, in: context, failure: &failure)

    // Written before the close, so they are in the full log. The options are logged once, by the last command that runs.
    if isLast || failure != nil {
        logUnreadOptions()
    }
    if let failure {
        logCommandFailed(command.name, failure)
    }

    do {
        try FullLog.close()
    } catch {
        // Log first: `??` would skip logging when the command already failed.
        let closeFailure = logFailure(error)
        if failure == nil {
            failure = closeFailure
            // The full log is closed now, so the lines below go to the console only.
            if !isLast {
                logUnreadOptions()
            }
            await runHandlers(.onFailure, in: context, failure: &failure)
            logCommandFailed(command.name, closeFailure)
        }
    }

    return failure?.code.rawValue ?? 0
}

/// The failure that decides how a command ends: its exit code, and the message that the run report records as the
/// outcome. The first failure of a command is kept, and later failures do not replace it.
struct CommandFailure: Equatable {
    let code: ErrorCode
    let message: String
}

/// Logs the message of an error that failed a command, and returns the failure it makes.
internal func logFailure(_ error: Error) -> CommandFailure {
    @Use var log: Log

    let message = "\(error)"
    log.error(message)
    return CommandFailure(code: (error as? BuildError)?.code ?? .failure, message: message)
}

/// Logs each error that `deferringFailure` deferred, in order. The first one becomes the failure of the command, in place
/// of a failure of the body, which was logged already. Later ones are logged only.
internal func absorbDeferredFailures(_ context: RunContext, into failure: inout CommandFailure?) {
    for (index, error) in context.takeDeferredErrors().enumerated() {
        let deferred = logFailure(error)
        if index == 0 {
            failure = deferred
        }
    }
}

/// Logs the first internal error recorded since the last check, and sets the failure to it
/// if nothing failed before.
internal func absorbInternalError(_ context: RunContext, into failure: inout CommandFailure?) {
    guard let error = context.takeInternalError() else { return }
    let internalFailure = logFailure(error)
    failure = failure ?? internalFailure
}

/// Fails the command if the run report has failures and nothing failed before. The error is logged once, as a
/// failure of the command.
internal func absorbReportFailures(_ context: RunContext, into failure: inout CommandFailure?) {
    let count = context.report.failures.count
    guard failure == nil, count > 0 else { return }
    failure = logFailure(BuildError(message: "The run report has \(count) failure(s)."))
}

/// Sets the outcome of the run report from the failure that decided the exit code, or to success if nothing failed.
///
/// If the command failed and the report has no failure, adds the failure "The command failed: <message>" to the report.
/// It is not logged, because the error that failed the command was already logged once.
internal func finishReport(_ context: RunContext, failure: CommandFailure?) {
    guard let failure else {
        context.report.outcome = .succeeded
        return
    }
    if context.report.failures.isEmpty {
        context.report.findings.append(ReportFinding(severity: .failure, text: "The command failed: \(failure.message)"))
    }
    context.report.outcome = .failed(message: failure.message)
}

/// Logs a warning that lists the options no `input` call read in this run. Logs nothing if every option was read.
private func logUnreadOptions() {
    @Use var log: Log

    guard let unread = RunOptions.current?.unreadNames, !unread.isEmpty else { return }
    let flags = unread.map { "--\($0)" }.joined(separator: ", ")
    log.warning("No input read these options: \(flags). Check their spelling, or remove them.")
}

/// Logs that the command failed, and its exit code. The lines go to the full log while it is open, and to the console.
private func logCommandFailed(_ name: String, _ failure: CommandFailure) {
    @Use var log: Log

    log("Command [\(name.red().bold())] failed")
    log("Exit code \(failure.code.rawValue)")
}
