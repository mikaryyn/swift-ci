@testable import SwiftCI
@testable import SwiftCITestSupport
import SwiftCITesting
import Testing

extension GlobalStateTests {
    @Suite(.serialized) struct GitTests {
        /// The hash comes from stdout. The console filter hides the output, so the hash is not shown.
        @Test func getCommitHashRunsGitAndReturnsTheHashQuietly() async throws {
            let (log, runner) = registerToolMocks()
            runner.responses = [response(stdout: "a1b2c3d")]

            let hash = try await Git.getCommitHash()

            #expect(hash == "a1b2c3d")
            #expect(runner.tools.count == 1)
            #expect(runner.tools[0].command == "git")
            #expect(runner.tools[0].arguments == ["rev-parse", "--short", "HEAD"])
            #expect(log.loggedLines.isEmpty)
        }

        /// The tag is the stdout of a zero exit, without a trailing line break.
        @Test func getCommitTagReturnsTheTagWithoutALineBreak() async throws {
            let (log, runner) = registerToolMocks()
            runner.responses = [response(stdout: "v1.2.3")]

            let tag = try await Git.getCommitTag()

            #expect(tag == "v1.2.3")
            #expect(runner.tools[0].command == "git")
            #expect(runner.tools[0].arguments == ["describe", "--tags", "--exact-match"])
            // The tag is shown on the console, as before. Only the "fatal:" line of a missing tag is hidden.
            #expect(log.loggedLines == ["v1.2.3"])
        }

        /// Exit code 128 means that there is no tag. That is expected, so it is not a warning and not an error.
        @Test func getCommitTagReturnsNilForExitCode128WithoutWarning() async throws {
            let (log, runner) = registerToolMocks()
            let message = "fatal: no tag exactly matches 'a1b2c3d'"
            runner.responses = [ProcessRunnerMock.Response(
                lines: [stderrLine(message)],
                result: ToolResult(stdout: "", stderr: message, exitCode: 128)
            )]

            let tag = try await Git.getCommitTag()

            #expect(tag == nil)
            #expect(log.loggedLines.isEmpty)
        }
    }
}
