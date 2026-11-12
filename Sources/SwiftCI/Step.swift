import Foundation

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

/// Marks a step that may fail without failing the command. Used as `step(_:failure:_:)`.
///
/// There is deliberately no "not allowed" value. A step that may not fail is the throwing `step(_:_:)`.
public enum FailureMode: Hashable, Sendable {
    /// The step may fail. Its error is logged as a warning, and the command continues.
    case allowed
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
        log.warning("\(error)")
        context.writeStatus { try log.allowedFailedStep(name: name, depth: depth) }
        return nil
    }
}

/// Runs `body` as a named, timed step whose failure is allowed or not, decided at run time. It returns `nil` only when
/// `allowsFailure` is true and `body` threw.
///
/// With `allowsFailure` set to `false` it behaves as ``step(_:_:)``, and the error fails the command. With `true` it
/// behaves as ``step(_:failure:_:)``: the error is logged as a warning, and the command continues. Use it when a flag of
/// the run decides whether a failure may be ignored:
///
/// ```swift
/// let allowsMatchFailure = try input("allow-match-failure", default: false)
/// try await step("Install signing assets", allowsFailure: allowsMatchFailure) {
///     try await Signing.installMatchAssets(type: .adhoc, bundleIdentifiers: ["com.example.myapp"], teamId: teamId, …)
/// }
/// ```
///
/// Only call it inside a command body, as with `step(_:_:)`. Calling it elsewhere stops the process with a
/// `preconditionFailure`. This check is not unit tested.
///
/// - Parameters:
///   - name: The name shown in the log.
///   - allowsFailure: Whether a failure of `body` is only a warning.
///   - body: The work of the step. It is not stored, so it does not escape.
/// - Returns: The value returned by `body`, or `nil` if `allowsFailure` is true and `body` threw.
@discardableResult
public func step<T>(_ name: String, allowsFailure: Bool, _ body: () async throws -> T) async throws -> T? {
    guard allowsFailure else {
        return try await step(name, body)
    }
    return await step(name, failure: .allowed, body)
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

/// Whether a step runs, and the reason that is logged when it does not. ``onCI`` is the common case.
///
/// ```swift
/// try await step("Unlock keychains", when: .onCI) {
///     try await Keychain.unlock(name: "login", password: password)
/// }
/// ```
public struct StepCondition: Sendable {
    /// Whether the step runs.
    public var isMet: Bool
    /// Why the step did not run, logged when ``isMet`` is false.
    public var skipReason: String

    /// A condition that is met when `isMet` is true. Otherwise the step is skipped with `skipReason`.
    public init(_ isMet: Bool, skipReason: String) {
        self.isMet = isMet
        self.skipReason = skipReason
    }

    /// Met when a CI system runs the build (``CIEnvironment/isCI``). Otherwise the step is skipped as "not running on
    /// CI". Read it while a command runs, as ``CI/environment``.
    public static var onCI: StepCondition {
        StepCondition(CI.environment.isCI, skipReason: "not running on CI")
    }
}

/// Runs `body` as the step `name` if `condition` is met, as ``step(_:when:skipReason:_:)`` does with its values.
///
/// - Parameters:
///   - name: The name shown in the log.
///   - condition: Whether the step runs, and why it did not.
///   - body: The work of the step. It is not stored, so it does not escape.
/// - Returns: The value returned by `body`, or `nil` if the step was skipped.
@discardableResult
public func step<T>(_ name: String, when condition: StepCondition, _ body: () async throws -> T) async throws -> T? {
    try await step(name, when: condition.isMet, skipReason: condition.skipReason, body)
}

/// Runs `body` as the step `name` that may fail if `condition` is met, as ``step(_:when:skipReason:failure:_:)`` does
/// with its values.
///
/// - Parameters:
///   - name: The name shown in the log.
///   - condition: Whether the step runs, and why it did not.
///   - failure: Must be `.allowed`. See ``FailureMode``.
///   - body: The work of the step. It is not stored, so it does not escape.
/// - Returns: The value returned by `body`, or `nil` if the step was skipped or failed.
@discardableResult
public func step<T>(
    _ name: String,
    when condition: StepCondition,
    failure: FailureMode,
    _ body: () async throws -> T
) async -> T? {
    await step(name, when: condition.isMet, skipReason: condition.skipReason, failure: failure, body)
}

/// Runs `body` as the step `name` whose failure is allowed or not, if `condition` is met, as ``step(_:allowsFailure:_:)``
/// does. Otherwise it logs the step as skipped, with the reason of `condition`, and returns `nil` without running `body`.
///
/// - Parameters:
///   - name: The name shown in the log.
///   - condition: Whether the step runs, and why it did not.
///   - allowsFailure: Whether a failure of `body` is only a warning.
///   - body: The work of the step. It is not stored, so it does not escape.
/// - Returns: The value returned by `body`, or `nil` if the step was skipped, or if `allowsFailure` is true and `body`
///   threw.
@discardableResult
public func step<T>(
    _ name: String,
    when condition: StepCondition,
    allowsFailure: Bool,
    _ body: () async throws -> T
) async throws -> T? {
    guard condition.isMet else {
        skipStep(name, reason: condition.skipReason)
        return nil
    }
    return try await step(name, allowsFailure: allowsFailure, body)
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
/// public func upload(file: URL, step name: String? = nil) async throws {
///     try await step(default: "Upload \(file.lastPathComponent)", name: name) {
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

/// Runs `body` and defers its failure to the end of the command, so that the rest of the command still runs. Returns
/// `true` if `body` succeeded.
///
/// If `body` throws, the error is stored in the running command, `deferringFailure` returns `false`, and the command
/// continues. When the command body ends, normally or by throwing, the command fails with the first deferred error, as if
/// that error had escaped the body: it is logged the same way, its code is the exit code, and the `onFailure`, `cleanup`
/// and report handlers run as usual. Each deferred error is logged once, when the command ends, not when it is thrown.
///
/// A later deferred error is logged too, but it does not change the exit code. If the body also throws after a deferred
/// error, the first deferred error decides the exit code, and the thrown error is logged as well. A step inside `body`
/// that fails is logged as a failed step, as usual.
///
/// Use it for work whose reports must still run when it fails:
///
/// ```swift
/// let testsPassed = await deferringFailure {
///     try await xcode.test(destination: destination, resultBundleURL: bundle)
/// }
/// // Reports that should run also when the tests failed.
/// try await Xcode.reportTestFailures(resultBundleURL: bundle)
/// ```
///
/// Only call it inside a command body, directly or through a function called from it. Calling it outside a running
/// command, or inside a cleanup, onFailure or onReport handler, stops the process with a `preconditionFailure`. This
/// check is not unit tested.
///
/// - Parameter body: The work that may fail. It is not stored, so it does not escape.
/// - Returns: `true` if `body` succeeded, `false` if it threw. The error is not returned; it is deferred.
@discardableResult
public func deferringFailure(_ body: () async throws -> Void) async -> Bool {
    guard let context = RunContext.current else {
        preconditionFailure("deferringFailure may only be called while a command runs, inside a Command body.")
    }
    guard !context.isRunningHandler else {
        preconditionFailure("deferringFailure may not be called inside a cleanup, onFailure or onReport handler.")
    }
    do {
        try await body()
        return true
    } catch {
        context.deferError(error)
        return false
    }
}

/// The running command's context, the nesting depth of the step that starts now, and its start time.
/// Stops the process if no command runs.
private func stepStart(_ name: String) -> (context: RunContext, depth: Int, startDate: Date) {
    guard let context = RunContext.current else {
        preconditionFailure("step may only be called while a command runs, inside a Command body.")
    }
    return (context, context.stepDepth, Date.now)
}
