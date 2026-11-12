import Foundation

/// Reads environment variables. A variable that is set but empty counts as unset, because CI systems often export
/// empty variables for values they do not have.
///
/// Inside a test run of `SwiftCITesting`, these functions read the variables that the test gives, not the real
/// environment. For secrets, use ``Secret``.
public enum Environment {
    /// The value of the variable `key`. A query; it does not open a step.
    ///
    /// - Throws: A ``BuildError`` that names the variable when it is not set or is empty.
    public static func required(_ key: String) throws -> String {
        guard let value = optional(key) else {
            throw BuildError(message: "Required environment variable \(key) is not set or is empty.")
        }
        return value
    }

    /// The value of the variable `key`, or `nil` when it is not set or is empty. A query; it does not open a step.
    public static func optional(_ key: String) -> String? {
        guard let value = EnvironmentSource.value(key), !value.isEmpty else { return nil }
        return value
    }

    /// The value of the variable `key`, or `fallback` when it is not set or is empty. A query; it does not open a step.
    public static func optional(_ key: String, fallback: String) -> String {
        optional(key) ?? fallback
    }

    /// Logs every environment variable as `NAME: value`, sorted by name. A query; it does not open a step.
    ///
    /// Values that look secret are masked as `••••••`: variables whose name contains a part such as `PASSWORD`, `TOKEN`,
    /// `SECRET` or `KEY` (but not `KEY_ID` or `KEY_PATH`), and values in a well-known secret format, such as GitHub,
    /// GitLab and Slack tokens, private keys and JWTs. A URL with a password keeps the URL and masks the password.
    /// Values declared with `Secret` are always masked.
    ///
    /// - Parameter reveal: Names of variables to print unmasked, for names that look secret but are not. A value
    ///   declared with `Secret` stays masked.
    public static func writeToLog(reveal: Set<String> = []) {
        @Use var log: Log
        let envs = EnvironmentSource.variables().sorted { $0.key < $1.key }
        for (key, value) in envs {
            let shown = reveal.contains(key) ? value : EnvironmentMasking.masked(name: key, value: value)
            log("\(key): \(shown)")
        }
    }
}

/// Where ``Environment`` and ``Secret`` read variables from: the real process environment by default. Tests replace it
/// through ``isolateGlobalState(environment:artifactsDirectory:)``, so they never touch the real environment. It is not reset by
/// `registerDependencies()`, and it does not use `@Use`, because secrets are declared at the top level of a script,
/// before dependencies are registered.
enum EnvironmentSource {
    static var variables: () -> [String: String] = { ProcessInfo.processInfo.environment }

    static func value(_ name: String) -> String? {
        variables()[name]
    }
}
