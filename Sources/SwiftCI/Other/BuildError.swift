/// An error with a message for the user and an exit code.
///
/// Throw it from a step, a command body or a helper. An error that escapes a step or a
/// command body fails the command with `code`. A caught error does not fail the command.
public struct BuildError: Error {
    /// Creates an error that fails the command with `code`. The default code is ``ErrorCode/failure``.
    ///
    /// - Parameters:
    ///   - message: The message logged once, where the error is finally handled. Say what the user should do.
    ///   - code: The exit code of the run. Use ``ErrorCode/usage`` for usage or configuration errors.
    public init(message: String, code: ErrorCode = .failure) {
        self.message = message
        self.code = code
    }

    let message: String
    let code: ErrorCode
}

/// The exit code of a SwiftCI run. See the exit codes table in the script syntax plan.
public enum ErrorCode: Int32 {
    /// A step, command body or handler failed (exit code 1).
    case failure = 1
    /// A usage or configuration error, such as an unknown command name (exit code 2).
    case usage = 2
    /// An internal SwiftCI error outside the script, such as a full log that cannot be opened (exit code 3).
    case `internal` = 3
}
