import Foundation

/// A named entry point of a CI script, run from the command line as `./ci <name>`.
///
/// Create it with `Command(name) { … }` and register it with `command(_:)` inside `SwiftCI { }`.
public class Command {
    /// Creates a command. Register it with `command(_:)` inside `SwiftCI { }`.
    ///
    /// - Parameters:
    ///   - name: The name given on the command line, for example `test` for `./ci test`.
    ///   - description: A short description, shown by `--list` and after a missing or unknown command name.
    ///   - perform: The command body. If it throws, the command fails and later commands do not run.
    public init(_ name: String, description: String? = nil, perform: @MainActor @escaping () async throws -> Void) {
        self.name = name
        self.description = description
        self.perform = perform
    }

    func run() async throws {
        try await perform()
    }

    let name: String
    let description: String?

    private let perform: @MainActor () async throws -> Void
}

/// Marks a step that may fail without failing the command. Used as `step(_:failure:_:)`.
///
/// There is deliberately no "not allowed" value. A step that may not fail is the throwing `step(_:_:)`.
public enum FailureMode: Hashable, Sendable {
    /// The step may fail. Its error is logged as a warning, and the command continues.
    case allowed
}

/// Runs `body` as a named, timed step and returns its value.
///
/// If `body` throws, the step is logged as failed and the original error is rethrown
/// unchanged, so the rest of the command does not run. The error message is not logged
/// here; the runner logs it once when the command fails. A script may catch the error with
/// `do`/`catch`. The step is still logged as failed, and the command continues.
///
/// A step started inside another step is shown as part of the outer step's group.
///
/// Only call `step` inside a command body, directly or through a reusable function. Calling
/// it anywhere else (outside a command, or in a test without a running command) stops the
/// process with a `preconditionFailure`. This check is not unit tested.
///
/// - Parameters:
///   - name: The name shown in the log.
///   - body: The work of the step. It is not stored, so it does not escape.
/// - Returns: The value returned by `body`.
public func step<T>(_ name: String, _ body: () async throws -> T) async throws -> T {
    @Use var log: Log

    let (context, depth, startDate) = stepStart(name)
    try log.enteringStep(name: name, depth: depth)

    context.enterStep()
    defer { context.leaveStep() }

    let result: T
    do {
        result = try await body()
    } catch {
        context.writeStatus { try log.failedStep(name: name, depth: depth) }
        throw error
    }
    try log.finishedStep(name: name, duration: startDate.distance(to: Date.now), depth: depth)
    return result
}

/// Runs `body` as a named, timed step that may fail, and returns its value, or `nil` if it failed.
///
/// If `body` throws, the error is logged once as a warning, the step is logged as
/// "failed (allowed)", and the command continues. The error does not reach the runner, so
/// the command does not fail because of it. This includes an error from a step nested inside
/// `body`, and an error with any exit code.
///
/// Log writes made by this step do not throw. If writing the full log fails, the error is recorded
/// and fails the command with exit code 3, after the body or the handler that is running. The
/// step itself still runs and returns normally.
///
/// Use it for work whose failure should not fail the build, such as a notification:
///
/// ```swift
/// let sent = await step("Notify", failure: .allowed) {
///     try await notifier.send(text: "Build started")
/// }
/// if sent == nil {
///     // Continue without the notification.
/// }
/// ```
///
/// Only call it inside a command body, as with `step(_:_:)`. Calling it elsewhere stops the
/// process with a `preconditionFailure`. This check is not unit tested.
///
/// - Parameters:
///   - name: The name shown in the log.
///   - failure: Must be `.allowed`. See ``FailureMode``.
///   - body: The work of the step. It is not stored, so it does not escape.
/// - Returns: The value returned by `body`, or `nil` if `body` threw.
@discardableResult
public func step<T>(_ name: String, failure: FailureMode, _ body: () async throws -> T) async -> T? {
    @Use var log: Log

    let (context, depth, startDate) = stepStart(name)
    context.writeStatus { try log.enteringStep(name: name, depth: depth) }

    context.enterStep()
    defer { context.leaveStep() }

    do {
        let result = try await body()
        context.writeStatus {
            try log.finishedStep(name: name, duration: startDate.distance(to: Date.now), depth: depth)
        }
        return result
    } catch {
        log.warning(errorMessage(error))
        context.writeStatus { try log.allowedFailedStep(name: name, depth: depth) }
        return nil
    }
}

/// Logs that the step `name` was skipped, with `reason`, for example `not running on CI`. Nothing runs.
///
/// Use it where a step only runs under a condition, so the log shows that the step exists and why it did not run.
/// ``step(_:when:skipReason:_:)`` combines the condition and the step. Call `skipStep` directly when the work is not a
/// plain step, for example a call of an integration that opens its own step:
///
/// ```swift
/// if CI.environment.isCI {
///     try await Keychain.unlock(name: "login", password: password)
/// } else {
///     skipStep("Unlock keychain login", reason: "not running on CI")
/// }
/// ```
///
/// The line is written at the current nesting depth, as a step would be. Log writes do not throw. If writing the full
/// log fails, the error fails the command with exit code 3, as with ``step(_:failure:_:)``.
///
/// Only call it inside a command body, as with `step(_:_:)`. Calling it elsewhere stops the process with a
/// `preconditionFailure`. This check is not unit tested.
///
/// - Parameters:
///   - name: The name of the step, shown in the log.
///   - reason: Why the step did not run, shown after the name.
public func skipStep(_ name: String, reason: String) {
    @Use var log: Log

    let (context, depth, _) = stepStart(name)
    context.writeStatus { try log.skippedStep(name: name, reason: reason, depth: depth) }
}

/// Runs `body` as the step `name` if `condition` is true, as ``step(_:_:)`` does. Otherwise it logs the step as skipped,
/// with `skipReason`, and returns `nil` without running `body`.
///
/// ```swift
/// try await step("Unlock keychains", when: CI.environment.isCI, skipReason: "not running on CI") {
///     try await Keychain.unlock(name: "login", password: password)
/// }
/// ```
///
/// - Parameters:
///   - name: The name shown in the log.
///   - condition: Whether the step runs.
///   - skipReason: Why the step did not run, logged when `condition` is false.
///   - body: The work of the step. It is not stored, so it does not escape.
/// - Returns: The value returned by `body`, or `nil` if the step was skipped.
@discardableResult
public func step<T>(
    _ name: String,
    when condition: Bool,
    skipReason: String,
    _ body: () async throws -> T
) async throws -> T? {
    guard condition else {
        skipStep(name, reason: skipReason)
        return nil
    }
    return try await step(name, body)
}

/// Runs `body` as the step `name` that may fail if `condition` is true, as ``step(_:failure:_:)`` does. Otherwise it
/// logs the step as skipped, with `skipReason`, and returns `nil` without running `body`.
///
/// - Parameters:
///   - name: The name shown in the log.
///   - condition: Whether the step runs.
///   - skipReason: Why the step did not run, logged when `condition` is false.
///   - failure: Must be `.allowed`. See ``FailureMode``.
///   - body: The work of the step. It is not stored, so it does not escape.
/// - Returns: The value returned by `body`, or `nil` if the step was skipped or failed.
@discardableResult
public func step<T>(
    _ name: String,
    when condition: Bool,
    skipReason: String,
    failure: FailureMode,
    _ body: () async throws -> T
) async -> T? {
    guard condition else {
        skipStep(name, reason: skipReason)
        return nil
    }
    return await step(name, failure: failure, body)
}

/// Runs the work of an integration call as a step, named `name` or else `defaultName`, and returns its value.
///
/// This is for integration and extension authors. Scripts use `step(_:_:)` instead.
///
/// What happens depends on where the call is made:
/// - At the top level of a command, outside any step, it runs `body` as a step with the
///   name `name ?? defaultName`, exactly like `step(_:_:)`.
/// - Inside a step or a handler, it runs `body` as part of that step. It opens no step of its own.
/// - Outside a running command, for example in a test, it runs `body` directly, without logging.
///
/// Errors are rethrown unchanged in every case. Integration methods pass their optional `step:` parameter
/// as `name`, so that a script can rename the step:
///
/// ```swift
/// public func archiveAndExport(method: ExportMethod, step name: String? = nil) async throws -> URL {
///     try await step(default: "Archive and export \(scheme)", name: name) {
///         // The work of the integration.
///     }
/// }
/// ```
///
/// - Parameters:
///   - defaultName: The step name used when `name` is `nil`.
///   - name: The step name chosen by the caller, or `nil` to use `defaultName`.
///   - body: The work of the integration. It is not stored, so it does not escape.
/// - Returns: The value returned by `body`.
public func step<T>(default defaultName: String, name: String?, _ body: () async throws -> T) async throws -> T {
    guard let context = RunContext.current, context.stepDepth == 0 else {
        return try await body()
    }
    return try await step(name ?? defaultName, body)
}

/// The running command's context, the nesting depth of the step that starts now, and its start time.
/// Stops the process if no command runs.
@MainActor
private func stepStart(_ name: String) -> (context: RunContext, depth: Int, startDate: Date) {
    guard let context = RunContext.current else {
        preconditionFailure("step may only be called while a command runs, inside a Command body.")
    }
    return (context, context.stepDepth, Date.now)
}
