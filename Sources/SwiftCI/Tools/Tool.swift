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
/// both streams pass through `filters` to the console, unless the run was started with `--verbose`. Then the console shows every line unfiltered. Secrets are masked in both cases.
///
/// If `outputFile` is set, every line also goes unfiltered to that file, without the `[stderr] ` prefix. See the initializers.
public struct Tool {
    /// Creates a tool that runs `command` with `arguments`.
    ///
    /// - Parameters:
    ///   - command: A program path (contains `/`) or a program name. See the type's documentation.
    ///   - arguments: The arguments, without the program name.
    ///   - environment: Variables added to the inherited environment. A value overrides a variable of the same name.
    ///   - workingDirectory: The working directory. The current directory if `nil`.
    ///   - input: Written to standard input, which is then closed. Without input, standard input is empty.
    ///   - timeout: Ends the process after this duration (SIGTERM, then SIGKILL after a short grace period) and throws a
    ///     ``BuildError`` with ``ErrorCode/timeout``. Only the program is ended, not the processes it started. There is
    ///     no default timeout.
    ///   - filters: Applied to each line before it reaches the console. A filter returns `nil` to hide a line. A run with
    ///     `--verbose` skips them, so the console shows every line.
    ///   - outputFile: A file that receives a copy of every line of stdout and stderr: unfiltered, without the `[stderr] `
    ///     prefix of the full log, and with secrets masked as in the full log. Lines are written as they arrive. The file
    ///     is created or truncated when the tool starts, and its directory is created if missing. `--verbose` does not
    ///     change it. `nil` for no copy.
    public init(
        command: String,
        arguments: [String] = [],
        environment: [String: ToolEnvironmentValue] = [:],
        workingDirectory: URL? = nil,
        input: ToolInput? = nil,
        timeout: Duration? = nil,
        filters: [Filter] = [],
        outputFile: URL? = nil
    ) {
        self.init(
            command: command,
            arguments: arguments,
            environment: environment,
            workingDirectory: workingDirectory,
            input: input,
            timeout: timeout,
            filters: filters,
            outputFile: outputFile,
            displayName: URL(fileURLWithPath: command).lastPathComponent
        )
    }

    /// Creates a tool that runs `shellCommand` with `/bin/sh -c`. Use it only for scripts written by the user.
    ///
    /// Errors name the tool "Shell command".
    ///
    /// - Parameters: See ``init(command:arguments:environment:workingDirectory:input:timeout:filters:outputFile:)``.
    public init(
        shellCommand: String,
        environment: [String: ToolEnvironmentValue] = [:],
        workingDirectory: URL? = nil,
        input: ToolInput? = nil,
        timeout: Duration? = nil,
        filters: [Filter] = [],
        outputFile: URL? = nil
    ) {
        self.init(
            command: "/bin/sh",
            arguments: ["-c", shellCommand],
            environment: environment,
            workingDirectory: workingDirectory,
            input: input,
            timeout: timeout,
            filters: filters,
            outputFile: outputFile,
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
        outputFile: URL?,
        displayName: String
    ) {
        self.command = command
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.input = input
        self.timeout = timeout
        self.filters = filters
        self.outputFile = outputFile
        self.displayName = displayName
    }

    /// How many of the last lines of stderr the error of a failed tool shows.
    private static let stderrLinesInError = 10

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
    /// The file that receives a copy of every output line, unfiltered, or `nil` for no copy.
    public let outputFile: URL?

    /// The name used in error messages and warnings: the last path component of `command`, or "Shell command" for a
    /// shell tool.
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
    /// The exit code goes to the full log after the process ends. A failure of the runner goes there too, before it is thrown.
    private func execute() async throws -> ToolResult {
        @Use var runner: ProcessRunner
        @Use var log: Log

        try validateSecrets()
        try writeHeader()
        let copy = try outputFile.map { try ToolOutputFile(url: $0) }
        let result: ToolResult
        do {
            result = try await runner.run(self) { line in
                // NUL separates the entries of `git -z` output, so each entry gets a line of its own in the full log.
                let text = line.text.replacingOccurrences(of: "\0", with: "\n")
                try FullLog.write(line.stream == .stderr ? "[stderr] \(text)" : text)
                try copy?.write(line.text)
                consoleTexts(for: line.text).forEach(log.consoleOnly)
            }
        } catch {
            try? copy?.close()
            try? FullLog.write("➤ Error: \(error)")
            throw error
        }
        try FullLog.write("➤ Exit code \(result.exitCode)")
        try copy?.close()
        return result
    }

    /// The full log header: the command, its arguments, the working directory and the names (never the values) of the
    /// environment variables that were added. The input is never written.
    private func writeHeader() throws {
        try FullLog.write("➤ Command \(command)")
        if !arguments.isEmpty {
            try FullLog.write(arguments.map { "  ➤ \($0)" }.joined(separator: "\n"))
        }
        try FullLog.write("➤ Working directory \(workingDirectory?.filePath ?? "(current directory)")")
        if let timeout {
            try FullLog.write("➤ Timeout \(String(format: "%g", timeout.seconds)) s")
        }
        let names = environment.keys.sorted()
        if !names.isEmpty {
            try FullLog.write("➤ Environment variables \(names.joined(separator: ", "))")
        }
        try FullLog.write("")
    }

    /// Throws if the exit code is not 0. The message names the tool and shows the last lines of stderr, because
    /// the console filters may have hidden them.
    private func checkExitCode(_ result: ToolResult) throws {
        guard result.exitCode != 0 else { return }
        var message = "\(displayName) exited with code \(result.exitCode)."
        if !result.stderr.isEmpty {
            message += "\n" + result.stderr.components(separatedBy: "\n").suffix(Self.stderrLinesInError).joined(separator: "\n")
        }
        throw BuildError(message: message)
    }

    /// The lines on the console for a line of output: the line itself with `--verbose`, otherwise what the filters keep.
    /// A filter may return several lines joined with line breaks. They are split, and each goes to the next filter on its
    /// own. Secrets are not checked here, because the registered log masks every line it writes.
    private func consoleTexts(for line: String) -> [String] {
        if RunOptions.current?.verbose == true {
            return [line]
        }
        return filters.reduce([line]) { lines, filter in
            lines.flatMap { filter($0)?.components(separatedBy: "\n") ?? [] }
        }
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

private extension Duration {
    /// The duration in seconds, with the fraction.
    var seconds: Double {
        let parts = components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}
