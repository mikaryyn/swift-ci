import Foundation

/// Registers a handler that runs when the command ends, whether it succeeded or failed.
///
/// Use it right after the resource it cleans up is created, such as a temporary directory:
///
/// ```swift
/// let directory = try makeTemporaryDirectory()
/// cleanup { try FileManager.default.removeItem(at: directory) }
/// ```
///
/// Ordering: when the command body ends, all `cleanup` handlers run in reverse order of
/// registration, like Swift's `defer`. If the body and the cleanup handlers succeeded but the run
/// report has failures (see ``Report``), the command fails then, before the `onFailure` handlers run.
/// Then, if the command has failed, the `onFailure` handlers run in reverse order of registration.
/// A failed cleanup therefore also triggers the `onFailure` handlers. Every handler runs, even if an
/// earlier one failed. The `onReport` handlers run last (see ``onReport(failure:_:)``).
///
/// A handler is logged as a step named "Cleanup". A handler that fails, and is not allowed
/// to, fails the command, unless the body already failed. The body's error decides the exit code.
/// Handlers registered inside a step still run at the end of the command, not at the end of the step.
///
/// With `failure: .allowed`, a failure is logged as a warning and as "failed (allowed)", and it
/// does not fail the command or trigger `onFailure` handlers.
///
/// A cleanup handler may add findings and sections to the run report. Its failure counts in the
/// report as a failure of the command.
///
/// Only call it inside a command body, directly or through a function called from it. Calling
/// it outside a running command, or inside another handler, stops the process with a
/// `preconditionFailure`. This check is not unit tested.
///
/// - Parameters:
///   - failure: `nil`, the default, if a failure fails the command. `.allowed` if it may fail.
///   - body: The work of the handler. It is stored and runs at the end of the command.
public func cleanup(failure: FailureMode? = nil, _ body: @escaping () async throws -> Void) {
    addHandler(.cleanup, failure: failure, { _ in try await body() }, name: "cleanup")
}

/// Registers a handler that runs when the command ends, only if the command has failed.
///
/// It runs after the `cleanup` handlers, so it also runs when a cleanup handler failed, or when the
/// run report has failures. Use it for work that reports a failure, such as a notification:
///
/// ```swift
/// onFailure { try await notifier.send(text: "Build failed") }
/// ```
///
/// Ordering, failure modes and the precondition are the same as for ``cleanup(failure:_:)``.
/// Register `onFailure` near the top of the command, so that it covers every step.
///
/// These handlers run before the run report is final. ``Report/current`` has no outcome yet
/// in them, but they may still add findings and sections.
///
/// - Parameters:
///   - failure: `nil`, the default, if a failure fails the command. `.allowed` if it may fail.
///   - body: The work of the handler. It is stored and runs at the end of the command.
public func onFailure(failure: FailureMode? = nil, _ body: @escaping () async throws -> Void) {
    addHandler(.onFailure, failure: failure, { _ in try await body() }, name: "onFailure")
}

/// Registers a handler that runs when the command ends, after the run report is final, and receives the report.
///
/// Use it to publish the report, for example as a merge request comment:
///
/// ```swift
/// onReport { report in
///     try await notifier.send(text: "\(report.failures.count) failure(s)")
/// }
/// ```
///
/// The handler runs after the body, the `cleanup` and `onFailure` handlers, and the outcome is set. The summary of
/// the report is printed and the report file is written before it runs (see ``Report``). The report it receives has
/// its ``RunReport/outcome`` set, and it is the same report as the one in the file. Report handlers run in registration
/// order, not in reverse. Each one is logged as a step named "Report".
///
/// A report handler cannot add to the report. `Report.failure`, `Report.warning`, `Report.message` and
/// `Report.markdown` stop the process with a `preconditionFailure` inside it. `Report.current` still works.
///
/// A handler that fails, and is not allowed to, fails the command with the exit code of its error,
/// unless an earlier failure already decided the exit code. The failure does not change the outcome
/// that later report handlers see, and it does not run the `onFailure` handlers. With
/// `failure: .allowed`, the failure is logged as a warning and as "failed (allowed)", and the command
/// keeps its exit code.
///
/// The full log is closed after the report handlers. If closing it fails after a successful run, the
/// report handlers have already seen ``CommandOutcome/succeeded``, and the command exits with code 3.
///
/// Only call it inside a command body, directly or through a function called from it. Calling
/// it outside a running command, or inside another handler, stops the process with a
/// `preconditionFailure`. This check is not unit tested.
///
/// - Parameters:
///   - failure: `nil`, the default, if a failure fails the command. `.allowed` if it may fail.
///   - body: The work of the handler. It receives the finished report and runs at the end of the command.
public func onReport(failure: FailureMode? = nil, _ body: @escaping (RunReport) async throws -> Void) {
    addHandler(.report, failure: failure, body, name: "onReport")
}

/// Stores a handler in the running command's context. Stops the process if no command runs or
/// if called inside another handler.
@MainActor
private func addHandler(
    _ kind: RunContext.Handler.Kind,
    failure: FailureMode?,
    _ body: @escaping (RunReport) async throws -> Void,
    name: String
) {
    guard let context = RunContext.current else {
        preconditionFailure("\(name) may only be called while a command runs, inside a Command body.")
    }
    guard !context.isRunningHandler else {
        preconditionFailure("\(name) may not be called inside a cleanup, onFailure or onReport handler. Register it inside the Command body.")
    }
    context.addHandler(RunContext.Handler(kind: kind, failure: failure, body: body))
}

/// Runs the handlers of one kind. `cleanup` and `onFailure` handlers run in reverse order of registration, and
/// `onReport` handlers in registration order. Every handler runs.
///
/// `failure` is the first failure so far. A handler failure only sets it if nothing failed before. An internal error
/// recorded by a handler's status line is handled after the handler.
@MainActor
internal func runHandlers(
    _ kind: RunContext.Handler.Kind,
    in context: RunContext,
    failure: inout CommandFailure?
) async {
    let registered = context.handlers.filter { $0.kind == kind }
    let ordered = kind == .report ? registered : Array(registered.reversed())
    for handler in ordered {
        let handlerFailure = await runHandler(handler, in: context)
        failure = failure ?? handlerFailure
        absorbInternalError(context, into: &failure)
    }
}

/// Runs one handler as a step at depth 0. Returns the failure that counts for the command, or `nil` if the handler
/// succeeded or its failure is allowed.
///
/// The handler body always runs, even if the full log cannot be written. Its status lines are
/// therefore written without `try`, as in the allowed step, and their errors are recorded.
@MainActor
private func runHandler(_ handler: RunContext.Handler, in context: RunContext) async -> CommandFailure? {
    @Use var log: Log

    context.isRunningHandler = true
    context.isRunningReportHandler = handler.kind == .report
    defer {
        context.isRunningHandler = false
        context.isRunningReportHandler = false
    }

    let name = handler.kind.stepName
    // The report is final for an onReport handler. Cleanup and onFailure handlers get the report as it is now.
    let report = context.report
    if handler.failure == .allowed {
        await step(name, failure: .allowed) { try await handler.body(report) }
        return nil
    }

    let startDate = Date.now
    context.writeStatus { try log.enteringStep(name: name, depth: 0) }
    context.enterStep()
    defer { context.leaveStep() }

    do {
        try await handler.body(report)
    } catch {
        context.writeStatus { try log.failedStep(name: name, depth: 0) }
        return logFailure(error)
    }
    context.writeStatus {
        try log.finishedStep(name: name, duration: startDate.distance(to: Date.now), depth: 0)
    }
    return nil
}
