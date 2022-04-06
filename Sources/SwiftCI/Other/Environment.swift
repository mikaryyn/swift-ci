import Foundation

public typealias EnvAccessor = () throws -> String

@propertyWrapper public struct Env<T> {
    public init(wrappedValue: T, _ key: String) where T == Optional<String> {
        self.wrappedValue = Environment.optional(key)
    }

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

public struct Environment {
    public static func required(_ key: String) throws -> String {
        let value = ProcessInfo.processInfo.environment[key] ?? ""
        if value.isEmpty {
            throw BuildError(message: "Required environment variable \(key) was not set.")
        }
        return value
    }

    public static func optional(_ key: String) -> String? {
        ProcessInfo.processInfo.environment[key]
    }

    public static func optional(_ key: String, fallback: String) -> String {
        optional(key) ?? fallback
    }

    public static func all() -> [(String, String)] {
        ProcessInfo.processInfo.environment.map({ ($0, $1) })
    }

    public static func writeToLog() {
        let envs = ProcessInfo.processInfo.environment.sorted { $0.key < $1.key }
        for (key, value) in envs {
            log("\(key): \(value)")
        }
    }
}
