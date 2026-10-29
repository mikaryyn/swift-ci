import Foundation

/// The command line of a run, split into command names, options and reserved flags.
///
/// Every argument that starts with `--` is an option or a reserved flag. The reserved flags are `--list`, `--help`
/// and `--verbose`. They never take a value. Every other option is written `--name=value`, and every other argument is
/// a command name. A bare `--name`, an empty name, `--help=value` and an option given twice are usage errors.
internal struct RunArguments {
    /// The flags that SwiftCI reads itself. They are not inputs, so `input` refuses these names.
    static let reservedFlags: Set<String> = ["list", "help", "verbose"]

    /// The command names, in the order given.
    private(set) var commandNames: [String] = []
    /// The options written `--name=value`, by name without the dashes. The value may be empty or contain `=`.
    private(set) var options: [String: String] = [:]
    /// The reserved flags given, by name without the dashes.
    private(set) var flags: Set<String> = []

    /// Splits `arguments` (without the executable name).
    ///
    /// - Throws: a ``BuildError`` with the usage code if an option is malformed or given twice.
    init(parsing arguments: [String]) throws(BuildError) {
        for argument in arguments {
            guard argument.hasPrefix("--") else {
                commandNames.append(argument)
                continue
            }
            try parseOption(argument)
        }
    }

    private mutating func parseOption(_ argument: String) throws(BuildError) {
        let body = argument.dropFirst(2)
        let parts = body.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        let name = String(parts[0])

        guard !name.isEmpty else {
            throw usageError("Option '\(argument)' has no name. Use the form --name=value, for example --track=value.")
        }
        guard parts.count == 2 else {
            guard Self.reservedFlags.contains(name) else {
                throw usageError(
                    "Option '\(argument)' has no value. Options are written with a value, in the form --name=value, for example --\(name)=value."
                )
            }
            try addFlag(name, argument: argument)
            return
        }

        if Self.reservedFlags.contains(name) {
            throw usageError("'--\(name)' is a flag and takes no value. Write it as --\(name), without '='.")
        }
        guard options[name] == nil else {
            throw usageError("Option '--\(name)' is given more than once. Give each option once.")
        }
        options[name] = String(parts[1])
    }

    private mutating func addFlag(_ name: String, argument: String) throws(BuildError) {
        guard !flags.contains(name) else {
            throw usageError("Flag '--\(name)' is given more than once. Give each flag once.")
        }
        flags.insert(name)
    }

    private func usageError(_ message: String) -> BuildError {
        BuildError(message: message, code: .usage)
    }
}

/// The state of the running SwiftCI run that inputs read: the parsed options and the reserved flags, and which options
/// an `input` call has read. Set by the runner for the duration of a run, and restored when it returns.
internal struct RunOptions {
    /// The state of the running run, or `nil` outside a run.
    static var current: RunOptions?

    /// The options given on the command line, by name without the dashes.
    let values: [String: String]
    /// `true` if `--verbose` was given. Then every line of tool output goes to the console unfiltered, and the tools'
    /// filters are skipped. Secrets stay masked, and the full log is unchanged. See ``Tool``.
    let verbose: Bool
    /// The names of the options that an `input` call has read during the run.
    private(set) var readNames: Set<String> = []

    init(_ arguments: RunArguments) {
        values = arguments.options
        verbose = arguments.flags.contains("verbose")
    }

    mutating func markRead(_ name: String) {
        readNames.insert(name)
    }

    /// The options that no `input` call has read, sorted by name.
    var unreadNames: [String] {
        values.keys.filter { !readNames.contains($0) }.sorted()
    }
}
