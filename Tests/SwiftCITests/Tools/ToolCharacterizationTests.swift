@testable import SwiftCI
@testable import SwiftCITestSupport
import SwiftCITesting
import Testing

extension GlobalStateTests {
    /// Characterization tests of `Tool`, using only harmless real programs. They pin the behavior that the
    /// public `Tool` contract requires, so a change to it shows up here.
    ///
    /// These tests run `Tool` outside a command, so the full log is not open and its writes do nothing.
    /// They assert the console lines (through `LogMock`) and the returned values.
    @Suite(.serialized) struct ToolCharacterizationTests {
        init() {
            registerDependencies()
            log = LogMock()
            register(Log.self, log)
        }

        var log: LogMock!

        /// Writes two lines to stdout and one to stderr, with a line to stdout in between.
        static let mixedScript = "echo out; echo err >&2; echo out2"

        @Test func streamsStdoutLinesToTheConsoleInOrder() async throws {
            try await Tool(shellCommand: "echo one; echo two; echo three").run()

            #expect(log.loggedLines == ["one", "two", "three"])
        }

        @Test func runsAProgramWithArgumentsDirectly() async throws {
            try await Tool(command: "/bin/echo", arguments: ["hello world"]).run()

            #expect(log.loggedLines == ["hello world"])
        }

        /// The filter hides `hide-me` and replaces the whole line that contains `rewrite`.
        @Test func filtersHideAndRewriteConsoleLines() async throws {
            try await Tool(
                shellCommand: "echo keep; echo hide-me; echo rewrite-me",
                filters: [filter("hide-me"), filter("rewrite", "REWRITTEN")]
            ).run()

            #expect(log.loggedLines == ["keep", "REWRITTEN"])
        }

        /// Captured output is taken before the filters run, so `output()` keeps lines that the console hides or
        /// rewrites.
        @Test func filtersDoNotChangeCapturedOutput() async throws {
            let output = try await Tool(
                shellCommand: "echo keep; echo hide-me; echo rewrite-me",
                filters: [filter("hide-me"), filter("rewrite", "REWRITTEN")]
            ).output()

            #expect(output == "keep\nhide-me\nrewrite-me")
            #expect(log.loggedLines == ["keep", "REWRITTEN"])
        }

        /// stderr is shown on the console. stdout and stderr come from separate pipes, so only the order within each
        /// stream is kept. The order between the two streams is not defined.
        @Test func stderrIsShownOnTheConsole() async throws {
            try await Tool(shellCommand: Self.mixedScript).run()

            #expect(log.loggedLines.sorted() == ["err", "out", "out2"])
            #expect(log.loggedLines.filter { $0 != "err" } == ["out", "out2"])
        }

        @Test func outputJoinsLinesWithLFAndHasNoTrailingNewline() async throws {
            let output = try await Tool(shellCommand: "echo a; echo b").output()

            #expect(output == "a\nb")
            #expect(log.loggedLines == ["a", "b"])
        }

        /// `output()` returns stdout only. stderr is shown on the console, but it is not part of the value.
        @Test func outputExcludesStandardError() async throws {
            let output = try await Tool(shellCommand: Self.mixedScript).output()

            #expect(output == "out\nout2")
        }

        /// `result()` returns stdout and stderr separately, and the exit code.
        @Test func resultReturnsStdoutStderrAndExitCode() async throws {
            let result = try await Tool(shellCommand: "echo out; echo err >&2; exit 0").result()

            #expect(result == ToolResult(stdout: "out", stderr: "err", exitCode: 0))
        }

        /// `Tool(shellCommand:)` runs `/bin/sh -c`, so shell arithmetic is expanded.
        @Test func shellCommandRunsThroughBinSh() async throws {
            let output = try await Tool(shellCommand: "echo $((6 * 7))").output()

            #expect(output == "42")
        }

        /// The message names the tool. Stderr is empty here, so no stderr lines follow.
        @Test func nonZeroExitThrowsNamingTheTool() async {
            let error = await thrownError {
                try await Tool(command: "/bin/sh", arguments: ["-c", "echo before; exit 3"]).run()
            }

            #expect(error?.message == "sh exited with code 3.")
            #expect(error?.code == .failure)
            #expect(log.loggedLines == ["before"])
        }

        /// `output()` throws on a non-zero exit, like `run()`. A shell tool is named "Shell command".
        @Test func outputThrowsOnNonZeroExit() async {
            let error = await thrownError {
                _ = try await Tool(shellCommand: "echo partial; exit 4").output()
            }

            #expect(error?.message == "Shell command exited with code 4.")
        }

        /// `result()` does not throw because of the exit code. It returns the code and the output.
        @Test func resultDoesNotThrowOnNonZeroExit() async throws {
            let result = try await Tool(shellCommand: "echo kept; exit 3").result()

            #expect(result.exitCode == 3)
            #expect(result.stdout == "kept")
            #expect(log.loggedLines == ["kept"])
        }

        /// The message starts with "Failed to execute tool '<command>'", and gives the reason.
        @Test func missingExecutableThrowsFailedToExecute() async {
            let error = await thrownError {
                try await Tool(command: "/nonexistent/swift-ci-missing-tool").run()
            }

            #expect(error?.message.hasPrefix("Failed to execute tool '/nonexistent/swift-ci-missing-tool'") == true)
            #expect(error?.code == .failure)
        }

        /// A program name without `/` is looked up in the `PATH` of the effective environment. `PATH` is set through
        /// `environment`, so the test does not depend on the host's `PATH`.
        @Test func commandNameIsLookedUpInEnvironmentPath() async throws {
            try await Tool(command: "echo", arguments: ["hi"], environment: ["PATH": "/bin:/usr/bin"]).run()

            #expect(log.loggedLines == ["hi"])
        }
    }
}
