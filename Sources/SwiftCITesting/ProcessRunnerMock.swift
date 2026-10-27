@_spi(Testing) import SwiftCI

/// A process runner for tests. It records every ``Tool`` it runs and returns prepared results, so no program is started.
///
/// Every ``Tool`` run goes through the runner, whether it is `run()`, `output()` or `result()`. Lines of a response are
/// streamed to the log, as a real program's output would be, before the result is returned.
///
/// The response for a run is chosen in this order:
/// 1. the next of the queued ``responses``, each used once,
/// 2. the result of ``handler``, called with the tool,
/// 3. the response set with ``respond(to:with:)`` for the program name (``Tool/command``),
/// 4. an empty success: no output and exit code 0.
///
/// ```swift
/// let runner = ProcessRunnerMock()
/// runner.respond(to: "mytool", with: .init(
///     lines: [ToolOutputLine(stream: .stdout, text: "compiled MyApp")]
/// ))
/// ```
public final class ProcessRunnerMock: ProcessRunner {
    /// What a mocked run produces: the lines streamed to the log, the result, or an error to throw.
    public struct Response {
        /// The lines that the program prints, in order. Each goes to the log, as the real runner does.
        public var lines: [ToolOutputLine]
        /// The stdout, stderr and exit code that the run returns.
        public var result: ToolResult
        /// Thrown after the lines, instead of the result. Use it to simulate a program that cannot be started, or a timeout.
        public var error: Error?

        /// Creates a response. By default it prints nothing, succeeds and returns an empty stdout and stderr.
        public init(
            lines: [ToolOutputLine] = [],
            result: ToolResult = ToolResult(stdout: "", stderr: "", exitCode: 0),
            error: Error? = nil
        ) {
            self.lines = lines
            self.result = result
            self.error = error
        }
    }

    /// Chooses the response for a tool. See ``handler``.
    public typealias Handler = (Tool) throws -> Response

    /// Creates a runner with no responses and no handler.
    public init() {}

    /// The tools that were run, in order. Each keeps its command, arguments, environment (including which values are
    /// secrets), input, working directory and filters.
    public private(set) var tools: [Tool] = []

    /// Responses used in order, one per run, before any other choice. A run takes the first one and removes it.
    public var responses: [Response] = []

    /// Chooses a response for each run that no queued response covers. It receives the tool, so it can answer by
    /// argument or environment. Return a `Response` or throw.
    public var handler: Handler?

    /// Sets the response for every run of a program, identified by ``Tool/command``, when no queued response or handler
    /// applies. A later call for the same program replaces the earlier one.
    ///
    /// - Parameters:
    ///   - command: The program as given to `Tool(command:)`, for example `"mytool"`, or a path such as `"/usr/bin/git"`.
    ///   - response: The response for each run of that program.
    public func respond(to command: String, with response: Response) {
        responsesByCommand[command] = response
    }

    /// Records the tool, then streams the lines of its response to `onLine`, and returns or throws as the response says.
    /// Called by the SwiftCI runner. Scripts do not call it.
    public func run(_ tool: Tool, onLine: (ToolOutputLine) throws -> Void) async throws -> ToolResult {
        tools.append(tool)
        let response = try nextResponse(for: tool)
        for line in response.lines {
            try onLine(line)
        }
        if let error = response.error {
            throw error
        }
        return response.result
    }

    private var responsesByCommand: [String: Response] = [:]

    private func nextResponse(for tool: Tool) throws -> Response {
        if !responses.isEmpty {
            return responses.removeFirst()
        }
        if let handler {
            return try handler(tool)
        }
        return responsesByCommand[tool.command] ?? Response()
    }
}
