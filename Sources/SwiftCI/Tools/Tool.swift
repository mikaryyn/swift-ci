import Foundation

/// A child process to run: the program, its arguments, environment, working directory, input, timeout and filters.
///
/// A `Tool` is a value. It starts nothing until ``run()``, ``output()`` or ``result()`` is called. The program is
/// started directly with its argument array, so no shell is involved. Use ``init(shellCommand:environment:workingDirectory:input:timeout:filters:)``
/// only for shell scripts written by the user.
///
/// A `command` that contains `/` is a path. A relative path is resolved against `workingDirectory`. Any other
/// `command` is a program name, looked up in the `PATH` of the effective environment (the inherited environment
/// with `environment` added). The first directory that holds an executable file wins.
///
/// Each line of stdout and stderr goes unfiltered to the full log, stderr lines with a `[stderr] ` prefix. Lines from
/// both streams pass through `blockFilter`, if any, and then `filters` to the console, unless the run was started with
/// `--verbose`. Then the console shows every line unfiltered. Secrets are masked in both cases.
public struct Tool {
    /// Creates a tool that runs `command` with `arguments`.
    ///
    /// - Parameters:
    ///   - command: A program path (contains `/`) or a program name. See the type's documentation.
    ///   - arguments: The arguments, without the program name.
    ///   - environment: Variables added to the inherited environment. A value overrides a variable of the same name.
    ///   - workingDirectory: The working directory. The current directory if `nil`.
    ///   - input: Written to standard input, which is then closed. Without input, standard input is empty.
    ///   - timeout: Ends the process after this duration (SIGTERM, then SIGKILL after a short grace period) and throws.
    ///     There is no default timeout.
    ///   - filters: Applied to each line before it reaches the console. A filter returns `nil` to hide a line. A run with
    ///     `--verbose` skips them, so the console shows every line.
    ///   - blockFilter: Decides the console lines together with the lines around them, before `filters`. It may show
    ///     several lines for one, or none. See ``BlockFilter``. A run with `--verbose` skips it too.
    public init(
        command: String,
        arguments: [String] = [],
        environment: [String: ToolEnvironmentValue] = [:],
        workingDirectory: URL? = nil,
        input: ToolInput? = nil,
        timeout: Duration? = nil,
        filters: [Filter] = [],
        blockFilter: BlockFilter? = nil
    ) {
        self.init(
            command: command,
            arguments: arguments,
            environment: environment,
            workingDirectory: workingDirectory,
            input: input,
            timeout: timeout,
            filters: filters,
            blockFilter: blockFilter,
            displayName: URL(fileURLWithPath: command).lastPathComponent
        )
    }

    /// Creates a tool that runs `shellCommand` with `/bin/sh -c`. Use it only for scripts written by the user.
    ///
    /// Errors name the tool "Shell command".
    ///
    /// - Parameters: See ``init(command:arguments:environment:workingDirectory:input:timeout:filters:)``.
    public init(
        shellCommand: String,
        environment: [String: ToolEnvironmentValue] = [:],
        workingDirectory: URL? = nil,
        input: ToolInput? = nil,
        timeout: Duration? = nil,
        filters: [Filter] = []
    ) {
        self.init(
            command: "/bin/sh",
            arguments: ["-c", shellCommand],
            environment: environment,
            workingDirectory: workingDirectory,
            input: input,
            timeout: timeout,
            filters: filters,
            blockFilter: nil,
            displayName: "Shell command"
        )
    }

    private init(
        command: String,
        arguments: [String],
        environment: [String: ToolEnvironmentValue],
        workingDirectory: URL?,
        input: ToolInput?,
        timeout: Duration?,
        filters: [Filter],
        blockFilter: BlockFilter?,
        displayName: String
    ) {
        self.command = command
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.input = input
        self.timeout = timeout
        self.filters = filters
        self.blockFilter = blockFilter
        self.displayName = displayName
    }

    /// The program: a path or a program name, as given.
    public let command: String
    /// The arguments, without the program name.
    public let arguments: [String]
    /// Variables added to the inherited environment, or overriding inherited variables of the same name.
    public let environment: [String: ToolEnvironmentValue]
    /// The working directory, or `nil` for the current directory.
    public let workingDirectory: URL?
    /// The data written to standard input, or `nil` for empty standard input.
    public let input: ToolInput?
    /// The timeout, or `nil` for none.
    public let timeout: Duration?
    /// The filters applied to each console line, in order.
    public let filters: [Filter]
    /// The block filter, which decides the console lines before `filters`, or `nil` for none.
    public let blockFilter: BlockFilter?

    /// The name used in error messages and warnings: the last path component of `command`, or "Shell command" for a
    /// shell tool. Read-only.
    public let displayName: String

    /// Runs the tool. Streams its output to the console and the full log, and throws if the exit code is not 0.
    ///
    /// The error names the tool and the exit code, and shows the last 10 lines of stderr. A failure to start the
    /// program, or a timeout, also throws.
    public func run() async throws {
        try checkExitCode(try await execute())
    }

    /// Runs the tool like ``run()``, and returns its stdout: the lines joined with LF, without a final LF. Stderr is
    /// shown and logged, but not returned. Throws if the exit code is not 0.
    public func output() async throws -> String {
        let result = try await execute()
        try checkExitCode(result)
        return result.stdout
    }

    /// Runs the tool like ``run()``, and returns stdout, stderr and the exit code.
    ///
    /// Does not throw because of the exit code. It still throws if the program cannot be started, the timeout expires,
    /// or the full log cannot be written.
    public func result() async throws -> ToolResult {
        try await execute()
    }

    /// Checks the secrets, writes the header, runs the process through the runner, and sends each line to the full log
    /// and the console. A secret is checked before anything else, so a missing value stops the call before the runner.
    private func execute() async throws -> ToolResult {
        @Use var runner: ProcessRunner
        @Use var log: Log

        try validateSecrets()
        try writeHeader()
        return try await runner.run(self) { line in
            try FullLog.write(line.stream == .stderr ? "[stderr] \(line.text)" : line.text)
            consoleTexts(for: line.text).forEach(log.callAsFunction)
        }
    }

    /// The full log header: the command, its arguments, the working directory and the names (never the values) of the
    /// environment variables that were added. The input is never written.
    private func writeHeader() throws {
        try FullLog.write("➤ Command \(command)")
        if !arguments.isEmpty {
            try FullLog.write(arguments.map { "  ➤ \($0)" }.joined(separator: "\n"))
        }
        try FullLog.write("➤ Working directory \(workingDirectory?.path ?? "(current directory)")")
        let names = environment.keys.sorted()
        if !names.isEmpty {
            try FullLog.write("➤ Environment variables \(names.joined(separator: ", "))")
        }
        try FullLog.write("")
    }

    /// Throws if the exit code is not 0 and the tool does not allow failure. The message names the tool and shows
    /// the last 10 lines of stderr, because the console filters may have hidden them.
    private func checkExitCode(_ result: ToolResult) throws {
        guard result.exitCode != 0 else { return }
        var message = "\(displayName) exited with code \(result.exitCode)."
        if !result.stderr.isEmpty {
            message += "\n" + result.stderr.components(separatedBy: "\n").suffix(10).joined(separator: "\n")
        }
        throw BuildError(message: message)
    }

    /// The lines on the console for a line of output: the line itself with `--verbose`, otherwise what the block filter
    /// and the filters keep. Secrets are not checked here, because the registered log masks every line it writes.
    private func consoleTexts(for line: String) -> [String] {
        if RunOptions.current?.verbose == true {
            return [line]
        }
        let lines = blockFilter?(line) ?? [line]
        return lines.compactMap { applyFilters(line: $0) }
    }

    private func applyFilters(line: String) -> String? {
        var filteredLine: String? = line
        for filter in filters {
            guard let line = filteredLine else { break }
            filteredLine = filter(line)
        }
        return filteredLine
    }

    /// Throws a usage error if a secret of the tool is missing, empty or too short. See ``Secret/revealedValue()``.
    private func validateSecrets() throws {
        for case .secret(let secret) in environment.values {
            _ = try secret.revealedValue()
        }
        if case .secret(let secret)? = input {
            _ = try secret.revealedValue()
        }
    }

    /// The environment of the process: the inherited environment with `environment` added and overriding. It reveals
    /// the secrets, so the runner calls it only when it starts the process.
    func effectiveEnvironment() throws -> [String: String] {
        var result = ProcessInfo.processInfo.environment
        for (name, value) in environment {
            switch value {
            case .text(let text):
                result[name] = text
            case .secret(let secret):
                result[name] = try secret.revealedValue()
            }
        }
        return result
    }
}

/// The captured result of a run: stdout and stderr as lines joined with LF (without a final LF), and the exit code.
public struct ToolResult: Equatable, Sendable {
    /// Creates a result. Tools return results from the runner. Tests create them for mocks.
    public init(stdout: String, stderr: String, exitCode: Int32) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
    }

    /// The lines of stdout, joined with LF.
    public let stdout: String
    /// The lines of stderr, joined with LF.
    public let stderr: String
    /// The exit code of the program.
    public let exitCode: Int32
}

/// One line of output of a program, with the stream it came from.
nonisolated public struct ToolOutputLine: Equatable, Sendable {
    /// The stream a line was read from.
    nonisolated public enum Stream: Equatable, Sendable {
        case stdout
        case stderr
    }

    /// Creates a line. The runner creates lines. Tests create them for mocks.
    public init(stream: Stream, text: String) {
        self.stream = stream
        self.text = text
    }

    /// The stream the line was read from.
    public let stream: Stream
    /// The text of the line, without its line feed. A carriage return before the line feed is removed.
    public let text: String
}

/// The value of an environment variable of a ``Tool``. A plain string literal is a `.text` value. A ``Secret`` is
/// revealed only when the process starts, and its value is masked in every log.
public enum ToolEnvironmentValue: ExpressibleByStringLiteral, Equatable, Sendable {
    /// A plain value.
    case text(String)
    /// A secret value.
    case secret(Secret)

    /// Creates a plain value from a string literal.
    public init(stringLiteral value: String) {
        self = .text(value)
    }
}

/// The standard input of a ``Tool``. It is written, and then standard input is closed.
public enum ToolInput: Equatable, Sendable {
    /// Text, written as UTF-8.
    case text(String)
    /// Raw bytes.
    case data(Data)
    /// A secret, written as UTF-8. It is revealed only when the process starts.
    case secret(Secret)

    /// The bytes to write. Reveals a secret, so the runner calls it only when it starts the process.
    func revealedBytes() throws -> Data {
        switch self {
        case .text(let text):
            return Data(text.utf8)
        case .data(let data):
            return data
        case .secret(let secret):
            return Data(try secret.revealedValue().utf8)
        }
    }
}
