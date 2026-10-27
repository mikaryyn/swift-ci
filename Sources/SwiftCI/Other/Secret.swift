import Foundation

/// A secret value, such as a password or a token. SwiftCI never writes it. Every registered value is masked in the
/// console, the full log and error messages (see ``SecretRegistry``).
///
/// Declare a secret read from an environment variable with ``init(_:)``. The declaration does not throw, so it can be
/// written at the top level of a script. The value is checked at first use. A missing or empty variable, or a value
/// shorter than 4 characters, is a usage error (exit code 2) when a ``Tool`` that uses it runs.
///
/// ```swift
/// let matchPassword = Secret("MATCH_PASSWORD")
/// ```
///
/// Use ``init(value:)`` for a value derived at runtime, such as a token. Give a secret to a ``Tool`` only through its
/// environment or its input, never as an argument, because arguments are written to the full log.
public struct Secret: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// Declares a secret read from the environment variable `environmentVariable`. The variable is read now, and
    /// its value is masked from now on, even if it is too short to be used. The variable is checked at first use.
    ///
    /// - Parameter environmentVariable: The name of the variable, for example `"MATCH_PASSWORD"`.
    public init(_ environmentVariable: String) {
        let value = EnvironmentSource.value(environmentVariable)
        source = .environment(name: environmentVariable, value: value)
        if let value, !value.isEmpty {
            SecretRegistry.register(value)
        }
    }

    /// Declares a secret with a value derived at runtime, such as a token or an `Authorization` header. The value is
    /// masked from now on. It is always valid.
    ///
    /// The value must not be empty. An empty value is a programming error, so the process stops.
    ///
    /// - Parameter value: The secret value.
    public init(value: String) {
        precondition(!value.isEmpty, "Secret(value:) needs a non-empty value. An empty value is a programming error.")
        source = .derived(value)
        SecretRegistry.register(value)
    }

    /// Declares a secret read from the environment variable `environmentVariable`, or returns `nil` if the variable is
    /// unset or empty. Otherwise it behaves exactly like ``init(_:)``, including the check for values that are too
    /// short at first use.
    ///
    /// An empty variable counts as unset, as in ``Environment/required(_:)``, because CI systems often export empty
    /// variables for settings that are not used.
    ///
    /// - Parameter environmentVariable: The name of the variable, for example `"MATCH_KEYCHAIN_PASSWORD"`.
    /// - Returns: The secret, or `nil` if the variable is unset or empty.
    public static func optional(_ environmentVariable: String) -> Secret? {
        guard let value = EnvironmentSource.value(environmentVariable), !value.isEmpty else { return nil }
        return Secret(environmentVariable)
    }

    /// Masks every registered secret in `text`, as the console and the full log do. Use it before writing text that
    /// might contain a secret, such as a request body. The text itself is not changed.
    ///
    /// - Parameter text: The text to mask.
    /// - Returns: The text with each registered secret replaced by `••••••`.
    public static func redact(_ text: String) -> String {
        SecretRegistry.redact(text)
    }

    /// Returns the raw value. Use it only where a value must be handed to an API, such as an HTTP request.
    ///
    /// Throws a usage error (exit code 2) for a secret read from an environment variable that is missing, empty or
    /// shorter than 4 characters. The error names the variable and never shows the value.
    public func revealedValue() throws -> String {
        switch source {
        case .derived(let value):
            return value
        case .environment(let name, let value):
            guard let value, !value.isEmpty else {
                throw BuildError(
                    message: "Secret environment variable \(name) is not set or is empty. Set it in the environment before running the command.",
                    code: .usage
                )
            }
            guard value.count >= 4 else {
                throw BuildError(
                    message: "Secret environment variable \(name) is shorter than 4 characters. Use a longer value.",
                    code: .usage
                )
            }
            return value
        }
    }

    /// Shows `••••••` in place of the value, so that string interpolation is safe.
    public var description: String {
        SecretRegistry.mask
    }

    /// Shows `••••••` in place of the value, so that `String(reflecting:)` is safe.
    public var debugDescription: String {
        SecretRegistry.mask
    }

    /// The reflection mirror, which `dump` prints. It shows `••••••` in place of the value.
    public var customMirror: Mirror {
        Mirror(self, children: [(label: "value", value: SecretRegistry.mask)], displayStyle: .struct)
    }

    private enum Source: Equatable, Sendable {
        case environment(name: String, value: String?)
        case derived(String)
    }

    private let source: Source
}
