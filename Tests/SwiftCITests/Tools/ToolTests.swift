@testable import SwiftCI
@testable import SwiftCITestSupport
import Foundation
import SwiftCITesting
import Testing

extension GlobalStateTests {
    /// `Tool` with a mock runner, so no process is started. These tests cover the rules `Tool` owns: the full
    /// log, the console filters, the error messages and the result methods.
    @Suite(.serialized) struct ToolTests {
        @Test func runPassesTheToolToTheRunner() async throws {
            let (_, runner) = registerToolMocks()

            try await Tool(
                command: "/usr/bin/fake-tool",
                arguments: ["-a"],
                environment: ["NAME": "value"],
                timeout: .seconds(9)
            ).run()

            #expect(runner.tools.count == 1)
            #expect(runner.tools[0].command == "/usr/bin/fake-tool")
            #expect(runner.tools[0].arguments == ["-a"])
            #expect(runner.tools[0].environment["NAME"] == .text("value"))
            #expect(runner.tools[0].timeout == .seconds(9))
        }

        @Test func consoleGetsFilteredLinesFromBothStreams() async throws {
            let (log, runner) = registerToolMocks()
            runner.responses = [.init(lines: [stdoutLine("keep"), stdoutLine("hide-me"), stderrLine("warn")])]

            try await Tool(command: "/usr/bin/fake-tool", filters: [filter("hide-me")]).run()

            #expect(log.loggedLines == ["keep", "warn"])
        }

        /// The block filter decides the lines first, and `filters` apply to the lines it shows.
        @Test func blockFilterRunsBeforeTheFilters() async throws {
            let (log, runner) = registerToolMocks()
            runner.responses = [.init(lines: [stdoutLine("+--+"), stdoutLine("| Keep |"), stdoutLine("+--+"), stdoutLine("hide-me")])]

            try await Tool(
                command: "/usr/bin/fake-tool",
                filters: [filter("hide-me")],
                blockFilter: tableFilter(keeping: { $0 == "Keep" }, otherLines: { $0 })
            ).run()

            #expect(log.loggedLines == ["+--+", "| Keep |", "+--+"])
        }

        @Test func runThrowsNamingTheToolAndShowsTheLastTenStderrLines() async {
            let (_, runner) = registerToolMocks()
            let stderr = (1...12).map { "e\($0)" }.joined(separator: "\n")
            runner.responses = [.init(result: ToolResult(stdout: "", stderr: stderr, exitCode: 2))]

            let error = await thrownError {
                try await Tool(command: "/usr/bin/fake-tool").run()
            }

            #expect(error?.message == "fake-tool exited with code 2.\n" + (3...12).map { "e\($0)" }.joined(separator: "\n"))
            #expect(error?.code == .failure)
        }

        @Test func runThrowsWithoutStderrLinesWhenThereAreNone() async {
            let (_, runner) = registerToolMocks()
            runner.responses = [.init(result: ToolResult(stdout: "out", stderr: "", exitCode: 5))]

            let error = await thrownError {
                try await Tool(command: "/usr/bin/fake-tool").run()
            }

            #expect(error?.message == "fake-tool exited with code 5.")
        }

        @Test func outputReturnsStdoutOnly() async throws {
            let (_, runner) = registerToolMocks()
            runner.responses = [.init(result: ToolResult(stdout: "a\nb", stderr: "x", exitCode: 0))]

            let output = try await Tool(command: "/usr/bin/fake-tool").output()

            #expect(output == "a\nb")
        }

        @Test func outputThrowsOnNonZeroExit() async {
            let (_, runner) = registerToolMocks()
            runner.responses = [.init(result: ToolResult(stdout: "a", stderr: "", exitCode: 6))]

            let error = await thrownError {
                _ = try await Tool(command: "/usr/bin/fake-tool").output()
            }

            #expect(error?.message == "fake-tool exited with code 6.")
        }

        @Test func resultReturnsTheExitCodeWithoutThrowing() async throws {
            let (_, runner) = registerToolMocks()
            let expected = ToolResult(stdout: "o", stderr: "e", exitCode: 7)
            runner.responses = [.init(result: expected)]

            let result = try await Tool(command: "/usr/bin/fake-tool").result()

            #expect(result == expected)
        }

        @Test func outputDoesNotIncludeStderrButTheConsoleShowsIt() async throws {
            let (log, runner) = registerToolMocks()
            runner.responses = [.init(
                lines: [stdoutLine("a"), stderrLine("b"), stdoutLine("c")],
                result: ToolResult(stdout: "a\nc", stderr: "b", exitCode: 0)
            )]

            let output = try await Tool(command: "/usr/bin/fake-tool").output()

            #expect(output == "a\nc")
            #expect(log.loggedLines == ["a", "b", "c"])
        }

        /// The full log holds every line, stderr lines with a `[stderr] ` prefix. The console gets only the filtered
        /// lines. The header lists the command, arguments and working directory, and the names of the environment
        /// variables, but no values and no input.
        @Test func fullLogHasEveryLineHeaderAndNoSecretValues() async {
            let (_, runner) = registerToolMocks()
            runner.responses = [.init(lines: [stdoutLine("keep"), stdoutLine("hide-me"), stderrLine("warn")])]
            var fullLog = ""
            let result = await SwiftCITest.run(["log"]) {
                register(ProcessRunner.self, runner)
                command(Command("log") {
                    try await Tool(
                        command: "/usr/bin/fake-tool",
                        arguments: ["--flag", "value"],
                        environment: ["SECRET_NAME": "secret-value"],
                        workingDirectory: URL(fileURLWithPath: "/tmp/work"),
                        input: .text("input-text"),
                        filters: [filter("hide-me")]
                    ).run()
                    fullLog = try readFullLog()
                })
            }
            let consoleLines = result.log.map(stripANSI)

            let lines = fullLog.components(separatedBy: "\n")
            #expect(result.exitCode == 0)
            #expect(lines.contains("➤ Command /usr/bin/fake-tool"))
            #expect(lines.contains("  ➤ --flag"))
            #expect(lines.contains("  ➤ value"))
            #expect(lines.contains("➤ Working directory /tmp/work"))
            #expect(lines.contains("➤ Environment variables SECRET_NAME"))
            #expect(lines.contains("keep"))
            #expect(lines.contains("hide-me"))
            #expect(lines.contains("[stderr] warn"))
            #expect(!fullLog.contains("secret-value"))
            #expect(!fullLog.contains("input-text"))
            #expect(consoleLines.contains("keep"))
            #expect(consoleLines.contains("warn"))
            #expect(!consoleLines.contains("hide-me"))
        }

        /// A full log that cannot be written fails the command with exit code 3, and its `onFailure` handler still runs.
        /// The header is the first write, so the runner is never called. The handler runs as a step, and its own
        /// status lines hit the same broken log, so the write error can be logged more than once.
        @Test func fullLogWriteFailureExitsWithThreeAndRunsHandlers() async {
            let (_, runner) = registerToolMocks()
            var events: [String] = []
            let result = await SwiftCITest.run(["write"]) {
                register(ProcessRunner.self, runner)
                command(Command("write") {
                    onFailure { events.append("onFailure") }
                    try FullLog.file?.close()
                    if let path = FullLog.path {
                        FullLog.file = FileHandle(forReadingAtPath: path.filePath)
                    }
                    try await Tool(command: "/usr/bin/fake-tool").run()
                })
            }

            let lines = result.log.map(stripANSI)
            #expect(result.exitCode == 3)
            #expect(lines.contains { $0.hasPrefix("<Error> Failed to write into the build log") })
            #expect(events == ["onFailure"])
            #expect(runner.tools.isEmpty)
        }

        /// The first line of output cannot be written to the full log, so `onLine` throws while the run is in progress.
        /// The error keeps exit code 3, and the handlers still run.
        @Test func fullLogWriteFailureDuringTheRunExitsWithThree() async {
            let runner = FullLogBreakingRunner()
            var events: [String] = []
            let result = await SwiftCITest.run(["during"]) {
                register(ProcessRunner.self, runner)
                command(Command("during") {
                    onFailure { events.append("onFailure") }
                    try await Tool(command: "/usr/bin/fake-tool").run()
                })
            }

            let lines = result.log.map(stripANSI)
            #expect(result.exitCode == 3)
            #expect(lines.contains { $0.hasPrefix("<Error> Failed to write into the build log") })
            #expect(events == ["onFailure"])
            #expect(runner.linesDelivered == 1)
        }
    }
}

/// The text of the full log of the running command. Writes are not buffered, so the file is current.
@MainActor
func readFullLog() throws -> String {
    guard let path = FullLog.path else { return "" }
    return try String(contentsOfFile: path.filePath, encoding: .utf8)
}

/// Emits one line, after closing the full log and reopening it read-only, so the write of that line fails.
final class FullLogBreakingRunner: ProcessRunner {
    var linesDelivered = 0

    func run(_ tool: Tool, onLine: (ToolOutputLine) throws -> Void) async throws -> ToolResult {
        try FullLog.file?.close()
        if let path = FullLog.path {
            FullLog.file = FileHandle(forReadingAtPath: path.filePath)
        }
        linesDelivered += 1
        try onLine(stdoutLine("first"))
        return ToolResult(stdout: "first", stderr: "", exitCode: 0)
    }
}
