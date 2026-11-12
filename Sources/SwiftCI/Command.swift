import Foundation

/// A named entry point of a CI script, run from the command line as `./ci <name>`.
///
/// Create it with `Command(name) { … }` and register it with `command(_:)` inside `SwiftCI { }`. A name has no spaces
/// and does not start with `-`, because it is one argument of the command line and `--` starts an option.
public struct Command {
    let name: String
    let description: String?

    private let perform: @MainActor () async throws -> Void

    /// Creates a command. Register it with `command(_:)` inside `SwiftCI { }`.
    ///
    /// - Parameters:
    ///   - name: The name given on the command line, for example `test` for `./ci test`.
    ///   - description: A short description, shown by `--list` and after a missing or unknown command name.
    ///   - perform: The command body. If it throws, or if `deferringFailure` stored an error, the command fails and later
    ///     commands do not run.
    public init(_ name: String, description: String? = nil, perform: @MainActor @escaping () async throws -> Void) {
        self.name = name
        self.description = description
        self.perform = perform
    }

    func run() async throws {
        try await perform()
    }
}
