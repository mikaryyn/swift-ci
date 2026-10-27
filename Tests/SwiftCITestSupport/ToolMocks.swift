@_spi(Testing) import SwiftCI
import SwiftCITesting

/// Registers a log mock and a runner mock for one test, and returns them. Scripts with `SwiftCITest.run` do not need
/// it. Call it only inside a test that restores the global state, for example after `secretsSetUp()`.
@MainActor
func registerToolMocks() -> (log: LogMock, runner: ProcessRunnerMock) {
    let log = LogMock()
    let runner = ProcessRunnerMock()
    installTestDependencies(log: log, runner: runner)
    return (log, runner)
}

func stdoutLine(_ text: String) -> ToolOutputLine {
    ToolOutputLine(stream: .stdout, text: text)
}

func stderrLine(_ text: String) -> ToolOutputLine {
    ToolOutputLine(stream: .stderr, text: text)
}

/// A prepared response for a run with only a result, for example a query that prints `stdout`.
func response(stdout: String = "", stderr: String = "", exitCode: Int32 = 0) -> ProcessRunnerMock.Response {
    ProcessRunnerMock.Response(
        lines: stdout.isEmpty ? [] : stdout.components(separatedBy: "\n").map(stdoutLine),
        result: ToolResult(stdout: stdout, stderr: stderr, exitCode: exitCode)
    )
}
