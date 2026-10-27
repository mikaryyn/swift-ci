import SwiftCI
import SwiftCITesting
import Testing

/// These tests use only the public API, as a script or an extension author does. They prove that `SwiftCITesting` is
/// enough to test a command without `@testable` or SPI.
@Suite(.serialized) struct ExtensionAuthorTests {
    @Test func stepRunsMockedToolAndRecordsItsInvocation() async {
        let runner = ProcessRunnerMock()
        let result = await SwiftCITest.run(["build"], runner: runner) {
            command(Command("build") {
                try await step("Compile") {
                    try await Tool(command: "mytool", arguments: ["compile", "MyApp"]).run()
                }
            })
        }

        #expect(result.exitCode == 0)
        #expect(result.plainLog.contains("Entering step [Compile]"))
        #expect(result.plainLog.contains { $0.hasPrefix("Finished step [Compile] in ") })
        #expect(runner.tools.count == 1)
        #expect(runner.tools[0].command == "mytool")
        #expect(runner.tools[0].arguments == ["compile", "MyApp"])
    }

    @Test func failingToolFailsTheCommandWithExitCode1() async {
        let runner = ProcessRunnerMock()
        runner.respond(to: "mytool", with: .init(result: ToolResult(stdout: "", stderr: "no scheme", exitCode: 65)))

        let result = await SwiftCITest.run(["build"], runner: runner) {
            command(Command("build") {
                try await step("Compile") {
                    try await Tool(command: "mytool").run()
                }
            })
        }

        #expect(result.exitCode == 1)
        #expect(result.plainLog.contains("Step [Compile] failed"))
        #expect(result.plainLog.contains { $0.hasPrefix("<Error> mytool exited with code 65.") })
    }

    /// The variable set by the testing API is read by `Environment` and `Secret`, the secret goes to the tool's
    /// environment as a secret, and its value never reaches the log.
    @Test func environmentIsReadAndSecretIsMasked() async {
        let runner = ProcessRunnerMock()
        runner.respond(to: "deploy", with: .init(lines: [
            ToolOutputLine(stream: .stdout, text: "uploaded with s3cret-VALUE"),
        ]))

        let result = await SwiftCITest.run(
            ["deploy"],
            environment: ["MYAPP_TOKEN": "s3cret-VALUE", "MYAPP_TARGET": "staging"],
            runner: runner
        ) {
            command(Command("deploy") {
                let token = Secret("MYAPP_TOKEN")
                let target = try Environment.required("MYAPP_TARGET")
                try await step("Upload") {
                    try await Tool(
                        command: "deploy",
                        arguments: ["--target", target],
                        environment: ["TOKEN": .secret(token)]
                    ).run()
                }
            })
        }

        #expect(result.exitCode == 0)
        #expect(result.log.contains { $0.contains("uploaded with ••••••") })
        #expect(!result.log.contains { $0.contains("s3cret-VALUE") })
        #expect(runner.tools[0].arguments == ["--target", "staging"])
        #expect(isSecret(runner.tools[0].environment["TOKEN"]))
    }

    @Test func withMocksSetsTheEnvironmentAndRestoresIt() async throws {
        let runner = ProcessRunnerMock()
        runner.respond(to: "mytool", with: .init(result: ToolResult(stdout: "1.2.3", stderr: "", exitCode: 0)))

        let version = try await SwiftCITest.withMocks(["SWIFTCI_EXAMPLE_NAME": "Demo", "SWIFTCI_EXAMPLE_TOKEN": "tok-VALUE-1"], runner: runner) {
            @Env("SWIFTCI_EXAMPLE_NAME") var name: EnvAccessor
            #expect(try name() == "Demo")
            #expect(try Secret("SWIFTCI_EXAMPLE_TOKEN").revealedValue() == "tok-VALUE-1")
            return try await Tool(command: "mytool", arguments: ["--version"]).output()
        }

        #expect(version == "1.2.3")
        #expect(runner.tools.map(\.arguments) == [["--version"]])
        #expect(Environment.optional("SWIFTCI_EXAMPLE_NAME") == nil)
    }

    private func isSecret(_ value: ToolEnvironmentValue?) -> Bool {
        if case .secret? = value {
            return true
        }
        return false
    }
}
