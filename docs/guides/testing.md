# Testing CI scripts and extensions

A CI script or an extension can be tested without running real tools. Add the
`SwiftCITesting` product to the test target of the CI package, or of the
extension, and use only its public API:

```swift
import SwiftCI
import SwiftCITesting
import Testing

@Suite(.serialized) struct BuildTests {
    @Test func buildCompilesTheScheme() async {
        let runner = ProcessRunnerMock()
        let result = await SwiftCITest.run(
            ["build"],
            environment: ["MYAPP_SCHEME": "MyApp"],
            runner: runner
        ) {
            command(Command("build") {
                let scheme = try Environment.required("MYAPP_SCHEME")
                try await step("Compile") {
                    try await Tool(command: "mytool", arguments: ["build", scheme]).run()
                }
            })
        }

        #expect(result.exitCode == 0)
        #expect(result.plainLog.contains("Entering step [Compile]"))
        #expect(runner.tools.map(\.arguments) == [["build", "MyApp"]])
    }
}
```

- `SwiftCITest.run` runs the commands of a script as `./ci <command>` does, with
  the mocks in place, and returns the exit code and the log. It does not exit the
  process.
- `ProcessRunnerMock` records every `Tool` that runs: its command, arguments,
  environment (secret values stay secrets), input and working directory. Set the
  result of a program with `respond(to:with:)`, a queue of responses, or a
  `handler`. `Response(stdout:stderr:exitCode:)` makes the lines of the log and
  the result from the same text. A response can also stream chosen lines, or throw.
- `LogMock` records each console line and the arguments of each log method.
- `SwiftCITest.withMocks` does the same setup for code that is not a command, such
  as a call of a module's function. The environment is set only inside it.
- Each `run` and `withMocks` call has its own artifacts directory. Without an
  `artifactsDirectory:`, it is a temporary directory that is removed afterwards,
  so the files of a test are gone when it returns. A test that checks files passes
  its own directory. The result of `run` reports the directory it used. Nothing is
  written to the working directory.
- Only `Environment` and `Secret` read the variables that the test sets. The
  real environment of the shell that runs the tests is not read.

**Tests that use `SwiftCITesting` must not run at the same time.** SwiftCI keeps
its state in globals, such as the registrations, the secrets and the environment.
Put the tests in a suite marked `.serialized` (Swift Testing), or leave XCTest at its
default of one test at a time. Do not run them with `--parallel`.
