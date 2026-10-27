import Foundation

public typealias EnvAccessor = () throws -> String

@propertyWrapper public struct Env<T> {
    //public init(wrappedValue: T, _ key: String) where T == Optional<String> {
    //    self.wrappedValue = Environment.optional(key)
    //}

    public init(wrappedValue: T, _ key: String) where T == String {
        self.wrappedValue = Environment.optional(key, fallback: wrappedValue)
    }

    public init(_ key: String) where T == EnvAccessor {
        wrappedValue = {
            try Environment.required(key)
        }
    }

    public let wrappedValue: T
}

@propertyWrapper public struct EnvOpt<T> {
    public init(_ key: String) where T == String? {
        self.wrappedValue = Environment.optional(key)
    }

    public let wrappedValue: T
}


public struct Environment {
    public static func required(_ key: String) throws -> String {
        let value = EnvironmentSource.value(key) ?? ""
        if value.isEmpty {
            throw BuildError(message: "Required environment variable \(key) was not set.")
        }
        return value
    }

    public static func optional(_ key: String) -> String? {
        EnvironmentSource.value(key)
    }

    public static func optional(_ key: String, fallback: String) -> String {
        optional(key) ?? fallback
    }

    public static func all() -> [(String, String)] {
        EnvironmentSource.variables().map({ ($0, $1) })
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
