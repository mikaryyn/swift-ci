@testable import SwiftCI
@testable import SwiftCITestSupport
import Foundation
import SwiftCITesting
import Testing

extension GlobalStateTests {
    /// `--verbose` shows every line of tool output on the console, without the tools' filters. Secrets stay masked, and
    /// the full log does not change.
    @Suite(.serialized) struct VerboseTests {
        /// The console lines of the tool output: the lines of the run without the full log's "Saving" and "Saved" lines.
        private func toolLines(_ result: SwiftCITestResult) -> [String] {
            result.log.map(stripANSI).filter { !$0.hasPrefix("Saving full log") && !$0.hasPrefix("Saved full log") }
        }

        /// A script that runs one tool whose output has a line the filter hides.
        private func runFilteredTool(_ arguments: [String], runner: ProcessRunnerMock) async -> SwiftCITestResult {
            await SwiftCITest.run(arguments, runner: runner) {
                command(Command("log") {
                    try await Tool(command: "/usr/bin/fake-tool", filters: [filter("hide-me")]).run()
                })
            }
        }

        @Test func verboseShowsLinesThatTheFilterHides() async {
            let runner = ProcessRunnerMock()
            runner.responses = [.init(lines: [stdoutLine("keep"), stdoutLine("hide-me"), stderrLine("warn")])]

            let result = await runFilteredTool(["log", "--verbose"], runner: runner)

            #expect(result.exitCode == 0)
            #expect(toolLines(result) == ["keep", "hide-me", "warn"])
        }

        @Test func withoutVerboseTheFilterHidesLines() async {
            let runner = ProcessRunnerMock()
            runner.responses = [.init(lines: [stdoutLine("keep"), stdoutLine("hide-me"), stderrLine("warn")])]

            let result = await runFilteredTool(["log"], runner: runner)

            #expect(result.exitCode == 0)
            #expect(toolLines(result) == ["keep", "warn"])
        }

        @Test func verboseAppliesToEveryToolRunOfTheCommand() async {
            let runner = ProcessRunnerMock()
            runner.responses = [
                .init(lines: [stdoutLine("first hide-me")]),
                .init(lines: [stdoutLine("second hide-me")]),
            ]

            let result = await SwiftCITest.run(["log", "--verbose"], runner: runner) {
                command(Command("log") {
                    try await Tool(command: "/usr/bin/fake-tool", filters: [filter("hide-me")]).run()
                    try await Tool(command: "/usr/bin/other-tool", filters: [filter("hide-me")]).run()
                })
            }

            #expect(toolLines(result) == ["first hide-me", "second hide-me"])
        }

        @Test func verboseStillMasksSecretsOnTheConsole() async {
            let runner = ProcessRunnerMock()
            var fullLog = ""
            runner.responses = [.init(lines: [
                stdoutLine("token token-value-123 end"),
                stderrLine("error token-value-123"),
            ])]

            let result = await SwiftCITest.run(["log", "--verbose"], environment: ["SWIFTCI_TEST_TOKEN": "token-value-123"], runner: runner) {
                _ = Secret("SWIFTCI_TEST_TOKEN")
                command(Command("log") {
                    try await Tool(command: "/usr/bin/fake-tool", filters: [filter("hide-me")]).run()
                    fullLog = try readFullLog()
                })
            }

            #expect(toolLines(result) == ["token \(SecretRegistry.mask) end", "error \(SecretRegistry.mask)"])
            #expect(!result.log.joined().contains("token-value-123"))
            #expect(!fullLog.contains("token-value-123"))
        }

        @Test func fullLogIsTheSameWithAndWithoutVerbose() async throws {
            let lines: [ToolOutputLine] = [stdoutLine("keep"), stdoutLine("hide-me"), stderrLine("warn")]
            var fullLogs: [String] = []

            for arguments in [["log"], ["log", "--verbose"]] {
                let runner = ProcessRunnerMock()
                runner.responses = [.init(lines: lines)]
                var fullLog = ""
                _ = await SwiftCITest.run(arguments, runner: runner) {
                    command(Command("log") {
                        try await Tool(command: "/usr/bin/fake-tool", filters: [filter("hide-me")]).run()
                        fullLog = try readFullLog()
                    })
                }
                fullLogs.append(fullLog)
            }

            #expect(fullLogs[0] == fullLogs[1])
            #expect(fullLogs[0].contains("hide-me"))
            #expect(fullLogs[0].contains("[stderr] warn"))
        }

        @Test func outsideARunFiltersStillApply() async throws {
            let (log, runner) = registerToolMocks()
            runner.responses = [.init(lines: [stdoutLine("keep"), stdoutLine("hide-me")])]
            #expect(RunOptions.current == nil)

            try await Tool(command: "/usr/bin/fake-tool", filters: [filter("hide-me")]).run()

            #expect(log.loggedLines == ["keep"])
        }
    }
}
