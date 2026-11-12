import SwiftCI
import SwiftCITesting
import Testing

/// The process runner mock as an extension author uses it: through `Tool` and `SwiftCITest.withMocks`, with only the
/// public API.
@Suite(.serialized) struct ProcessRunnerMockTests {
    private struct Failure: Error, Equatable {}

    @Test func queuedResponseComesBeforeTheHandlerAndTheProgramResponse() async throws {
        let runner = ProcessRunnerMock()
        runner.responses = [.init(stdout: "queued")]
        runner.handler = { _ in .init(stdout: "handler") }
        runner.respond(to: "mytool", with: .init(stdout: "program"))

        let outputs = try await SwiftCITest.withMocks(runner: runner) {
            [
                try await Tool(command: "mytool").output(),
                try await Tool(command: "mytool").output(),
            ]
        }

        // The queued response is used once, then the handler answers.
        #expect(outputs == ["queued", "handler"])
    }

    @Test func handlerComesBeforeTheProgramResponseAndTheProgramResponseBeforeTheDefault() async throws {
        let runner = ProcessRunnerMock()
        runner.respond(to: "known", with: .init(stdout: "program"))

        let withoutHandler = try await SwiftCITest.withMocks(runner: runner) {
            [
                try await Tool(command: "known").output(),
                try await Tool(command: "other").output(),
            ]
        }
        runner.handler = { tool in .init(stdout: "handler for \(tool.command)") }
        let withHandler = try await SwiftCITest.withMocks(runner: runner) {
            try await Tool(command: "known").output()
        }

        #expect(withoutHandler == ["program", ""])
        #expect(withHandler == "handler for known")
    }

    @Test func laterRespondForTheSameProgramReplacesTheEarlierOne() async throws {
        let runner = ProcessRunnerMock()
        runner.respond(to: "mytool", with: .init(stdout: "first"))
        runner.respond(to: "mytool", with: .init(stdout: "second"))

        let output = try await SwiftCITest.withMocks(runner: runner) {
            try await Tool(command: "mytool").output()
        }

        #expect(output == "second")
    }

    @Test func stdoutStderrAndExitCodeBecomeLinesAndResult() async throws {
        let runner = ProcessRunnerMock()
        runner.responses = [.init(stdout: "a\nb\n", stderr: "warning", exitCode: 3)]

        let (result, log) = try await withLog(runner: runner) {
            try await Tool(command: "mytool").result()
        }

        #expect(result == ToolResult(stdout: "a\nb", stderr: "warning", exitCode: 3))
        #expect(log.loggedLines.contains("a") && log.loggedLines.contains("b"))
        #expect(runner.responses.isEmpty)
    }

    @Test func linesAreStreamedToTheLogBeforeAnErrorIsThrown() async {
        let runner = ProcessRunnerMock()
        runner.responses = [.init(
            lines: [ToolOutputLine(stream: .stdout, text: "partial")],
            error: Failure()
        )]
        let log = LogMock()

        let error = await SwiftCITest.withMocks(runner: runner, log: log) {
            do {
                try await Tool(command: "mytool").run()
                return nil as Failure?
            } catch let failure as Failure {
                return failure
            } catch {
                return nil
            }
        }

        #expect(error == Failure())
        #expect(log.loggedLines.contains("partial"))
    }

    @Test func throwingHandlerThrowsFromTheToolAndTheToolIsStillRecorded() async {
        let runner = ProcessRunnerMock()
        runner.handler = { _ in throw Failure() }

        let thrown = await SwiftCITest.withMocks(runner: runner) {
            do {
                try await Tool(command: "mytool", arguments: ["go"]).run()
                return false
            } catch is Failure {
                return true
            } catch {
                return false
            }
        }

        #expect(thrown)
        #expect(runner.tools.map(\.arguments) == [["go"]])
    }

    @Test func runnerWithoutResponsesSucceedsWithNoOutput() async throws {
        let runner = ProcessRunnerMock()

        let result = try await SwiftCITest.withMocks(runner: runner) {
            try await Tool(command: "mytool").result()
        }

        #expect(result == ToolResult(stdout: "", stderr: "", exitCode: 0))
    }

    /// Runs `body` with a runner and a log mock, and returns its value and the log.
    private func withLog<T>(runner: ProcessRunnerMock, _ body: () async throws -> T) async throws -> (T, LogMock) {
        let log = LogMock()
        let value = try await SwiftCITest.withMocks(runner: runner, log: log, body)
        return (value, log)
    }
}
