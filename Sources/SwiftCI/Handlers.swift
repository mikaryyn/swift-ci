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
/// registration, like Swift's `defer`. Then, if the command has failed, the `onFailure`
/// handlers run in reverse order of registration. A failed cleanup therefore also triggers
/// the `onFailure` handlers. Every handler runs, even if an earlier one failed.
///
/// A handler is logged as a step named "Cleanup". A handler that fails, and is not allowed
/// to, fails the command, unless the body already failed. The body's error decides the exit code.
/// Handlers registered inside a step still run at the end of the command, not at the end of the step.
///
/// With `failure: .allowed`, a failure is logged as a warning and as "failed (allowed)", and it
/// does not fail the command or trigger `onFailure` handlers.
///
/// Only call it inside a command body, directly or through a function called from it. Calling
/// it outside a running command, or inside another handler, stops the process with a
/// `preconditionFailure`. This check is not unit tested.
///
/// - Parameters:
///   - failure: `nil`, the default, if a failure fails the command. `.allowed` if it may fail.
///   - body: The work of the handler. It is stored and runs at the end of the command.
public func cleanup(failure: FailureMode? = nil, _ body: @escaping () async throws -> Void) {
    addHandler(.cleanup, failure: failure, body, name: "cleanup")
}

/// Registers a handler that runs when the command ends, only if the command has failed.
///
/// It runs after the `cleanup` handlers, so it also runs when a cleanup handler failed. Use it
/// for work that reports a failure, such as a notification:
///
/// ```swift
/// onFailure { try await notifier.send(text: "Build failed") }
/// ```
///
/// Ordering, failure modes and the precondition are the same as for ``cleanup(failure:_:)``.
/// Register `onFailure` near the top of the command, so that it covers every step.
///
/// - Parameters:
///   - failure: `nil`, the default, if a failure fails the command. `.allowed` if it may fail.
///   - body: The work of the handler. It is stored and runs at the end of the command.
public func onFailure(failure: FailureMode? = nil, _ body: @escaping () async throws -> Void) {
    addHandler(.onFailure, failure: failure, body, name: "onFailure")
}

/// Stores a handler in the running command's context. Stops the process if no command runs or
/// if called inside another handler.
@MainActor
private func addHandler(
    _ kind: RunContext.Handler.Kind,
    failure: FailureMode?,
    _ body: @escaping () async throws -> Void,
    name: String
) {
    guard let context = RunContext.current else {
        preconditionFailure("\(name) may only be called while a command runs, inside a Command body.")
    }
    guard !context.isRunningHandler else {
        preconditionFailure("\(name) may not be called inside a cleanup or onFailure handler. Register it inside the Command body.")
    }
    context.addHandler(RunContext.Handler(kind: kind, failure: failure, body: body))
}

/// Runs the handlers of one kind in reverse order of registration. Every handler runs.
///
/// `exitCode` is the code of the first failure so far. A handler failure only sets it if nothing
/// failed before. An internal error recorded by a handler's status line is handled after the handler.
@MainActor
internal func runHandlers(
    _ kind: RunContext.Handler.Kind,
    in context: RunContext,
    exitCode: inout ErrorCode?
) async {
    for handler in context.handlers.filter({ $0.kind == kind }).reversed() {
        let handlerCode = await runHandler(handler, in: context)
        exitCode = exitCode ?? handlerCode
        absorbInternalError(context, into: &exitCode)
    }
}

/// Runs one handler as a step at depth 0. Returns the exit code of a failure that counts for
/// the command, or `nil` if the handler succeeded or its failure is allowed.
///
/// The handler body always runs, even if the full log cannot be written. Its status lines are
/// therefore written without `try`, as in the allowed step, and their errors are recorded.
@MainActor
private func runHandler(_ handler: RunContext.Handler, in context: RunContext) async -> ErrorCode? {
    @Use var log: Log

    context.isRunningHandler = true
    defer { context.isRunningHandler = false }

    let name = handler.kind.stepName
    if handler.failure == .allowed {
        await step(name, failure: .allowed) { try await handler.body() }
        return nil
    }

    let startDate = Date.now
    context.writeStatus { try log.enteringStep(name: name, depth: 0) }
    context.enterStep()
    defer { context.leaveStep() }

    do {
        try await handler.body()
    } catch {
        context.writeStatus { try log.failedStep(name: name, depth: 0) }
        return logFailure(error)
    }
    context.writeStatus {
        try log.finishedStep(name: name, duration: startDate.distance(to: Date.now), depth: 0)
    }
    return nil
}
