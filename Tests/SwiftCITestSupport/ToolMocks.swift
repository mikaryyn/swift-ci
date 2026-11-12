@_spi(Testing) import SwiftCI
import SwiftCITesting

/// Registers a log mock and a runner mock for one test, and returns them. Scripts with `SwiftCITest.run` do not need
/// it. Call it only inside a test that restores the global state, for example after `isolatedGlobalState()`.
func registerToolMocks() -> (log: LogMock, runner: ProcessRunnerMock) {
    let log = LogMock()
    let runner = ProcessRunnerMock()
    installTestDependencies(log: log, runner: runner, httpClient: HTTPClientMock())
    return (log, runner)
}

func stdoutLine(_ text: String) -> ToolOutputLine {
    ToolOutputLine(stream: .stdout, text: text)
}

func stderrLine(_ text: String) -> ToolOutputLine {
    ToolOutputLine(stream: .stderr, text: text)
}
