@testable import SwiftCI
@testable import SwiftCITestSupport
import Foundation
import SwiftCITesting
import Testing

/// The kinds of invalid secret that the validation covers.
private enum InvalidKind: CaseIterable, CustomStringConvertible {
    case missing, empty, short

    var description: String {
        switch self {
        case .missing: "missing"
        case .empty: "empty"
        case .short: "short"
        }
    }
}

/// Where a secret is given to a `Tool`.
private enum SecretSlot: CaseIterable, CustomStringConvertible {
    case environment, input

    var description: String {
        switch self {
        case .environment: "environment"
        case .input: "input"
        }
    }
}

/// The execution methods of `Tool`.
private enum ExecutionMethod: CaseIterable, CustomStringConvertible {
    case run, output, result

    var description: String {
        switch self {
        case .run: "run"
        case .output: "output"
        case .result: "result"
        }
    }
}

/// Runs one invalid case inside a command with an open full log, and checks the outcome.
@MainActor
private func checkInvalidSecret(slot: SecretSlot, invalid: InvalidKind, method: ExecutionMethod) async {
    let label = "\(slot) \(invalid) \(method)"
    let variable = "SWIFTCI_TEST_\(slot)_\(invalid)_\(method)".uppercased()
    let value: String?
    switch invalid {
    case .missing: value = nil
    case .empty: value = ""
    case .short: value = "abc"
    }
    let restore = secretsSetUp(value.map { [variable: $0] } ?? [:])
    defer { restore() }
    let secret = Secret(variable)
    let runner = ProcessRunnerMock()
    var caught: BuildError?
    var headerBefore = ""
    var headerAfter = ""

    let result = await SwiftCITest.run(["invalid"]) {
        register(ProcessRunner.self, runner)
        command(Command("invalid") {
            let tool = slot == .environment
                ? Tool(command: "/usr/bin/fake-tool", environment: ["TOKEN": .secret(secret)])
                : Tool(command: "/usr/bin/fake-tool", input: .secret(secret))
            headerBefore = try readFullLog()
            do {
                switch method {
                case .run: try await tool.run()
                case .output: _ = try await tool.output()
                case .result: _ = try await tool.result()
                }
            } catch let error as BuildError {
                caught = error
                headerAfter = try readFullLog()
                throw error
            }
        })
    }

    #expect(result.exitCode == 2, "\(label)")
    #expect(caught?.code == .usage, "\(label)")
    #expect(caught?.message.contains(variable) == true, "\(label)")
    if let value, !value.isEmpty {
        #expect(caught?.message.contains(value) == false, "\(label)")
    }
    #expect(headerAfter == headerBefore, "\(label): the full log changed")
    #expect(!headerAfter.contains("➤ Command"), "\(label): a header was written")
    #expect(runner.tools.isEmpty, "\(label): the runner was called")
}

extension GlobalStateTests {
    /// `Tool` with secrets. The runner is a mock, except where a test says it uses the real runner to run a harmless
    /// program.
    @Suite(.serialized) struct ToolSecretTests {
        /// Every invalid secret (missing, empty or too short), in every place a secret can go (environment or input),
        /// with every execution method. Each call throws a usage error before the runner is called and before the full
        /// log header is written. Inside a command the error gives exit code 2.
        @Test func everyInvalidSecretFailsBeforeTheRunnerAndTheHeader() async {
            for slot in SecretSlot.allCases {
                for invalid in InvalidKind.allCases {
                    for method in ExecutionMethod.allCases {
                        await checkInvalidSecret(slot: slot, invalid: invalid, method: method)
                    }
                }
            }
        }

        /// Inside a command the usage error gives exit code 2, and the runner is not called.
        @Test func missingSecretGivesExitCodeTwoAtFirstUse() async {
            let restore = secretsSetUp()
            defer { restore() }
            let runner = ProcessRunnerMock()

            let result = await SwiftCITest.run(["use"]) {
                register(ProcessRunner.self, runner)
                command(Command("use") {
                    try await Tool(
                        command: "/usr/bin/fake-tool",
                        environment: ["TOKEN": .secret(Secret("SWIFTCI_TEST_MISSING_AT_USE"))]
                    ).run()
                })
            }

            #expect(result.exitCode == 2)
            #expect(runner.tools.isEmpty)
            #expect(result.log.map(stripANSI).contains { $0.contains("SWIFTCI_TEST_MISSING_AT_USE") })
        }

        /// The full log header lists the names of the secret variables and never their values, and it never lists the input.
        @Test func fullLogHeaderNamesSecretVariablesButNeverShowsValues() async {
            let runner = ProcessRunnerMock()
            var fullLog = ""

            _ = await SwiftCITest.run(["header"], environment: [
                "SWIFTCI_TEST_HEADER_TOKEN": "header-value-1",
                "SWIFTCI_TEST_HEADER_INPUT": "input-value-2",
            ], runner: runner) {
                command(Command("header") {
                    try await Tool(
                        command: "/usr/bin/fake-tool",
                        arguments: ["--flag"],
                        environment: ["TOKEN": .secret(Secret("SWIFTCI_TEST_HEADER_TOKEN"))],
                        input: .secret(Secret("SWIFTCI_TEST_HEADER_INPUT"))
                    ).run()
                    fullLog = try readFullLog()
                })
            }

            #expect(fullLog.contains("➤ Environment variables TOKEN"))
            #expect(!fullLog.contains("header-value-1"))
            #expect(!fullLog.contains("input-value-2"))
            #expect(!fullLog.contains("SWIFTCI_TEST_HEADER_INPUT"))
            #expect(runner.tools.count == 1)
        }

        /// The mock runner receives the secret as it was declared. The value is revealed by the real runner only.
        @Test func runnerReceivesTheSecretNotItsValue() async throws {
            let restore = secretsSetUp(["SWIFTCI_TEST_RUNNER_TOKEN": "runner-value-1"])
            defer { restore() }
            let (_, runner) = registerToolMocks()

            try await Tool(command: "/usr/bin/fake-tool", environment: ["TOKEN": .secret(Secret("SWIFTCI_TEST_RUNNER_TOKEN"))]).run()

            #expect(runner.tools[0].environment["TOKEN"] == .secret(Secret("SWIFTCI_TEST_RUNNER_TOKEN")))
        }

        /// A secret in the environment reaches the child process through the real runner, and only the masked form
        /// reaches the console. The captured value is the raw value, because captured output is not masked.
        @Test func secretEnvironmentReachesTheChildAndIsMaskedInLogs() async throws {
            let name = "SWIFTCI_TEST_CHILD_ENV"
            let restore = secretsSetUp([name: "child-env-value-1"])
            defer { restore() }
            registerDependencies()
            let log = LogMock()
            register(Log.self, log)

            let output = try await Tool(
                shellCommand: #"printf %s "$SWIFTCI_TEST_CHILD_ENV""#,
                environment: [name: .secret(Secret(name))]
            ).output()

            #expect(output == "child-env-value-1")
            #expect(log.loggedLines == [SecretRegistry.mask])
        }

        /// A secret input reaches the child process through the real runner, and its value is masked in the logs.
        @Test func secretInputReachesTheChildAndIsMaskedInLogs() async throws {
            let restore = secretsSetUp(["SWIFTCI_TEST_CHILD_INPUT": "child-input-value-1"])
            defer { restore() }
            registerDependencies()
            let log = LogMock()
            register(Log.self, log)

            let output = try await Tool(
                command: "/bin/cat",
                input: .secret(Secret("SWIFTCI_TEST_CHILD_INPUT"))
            ).output()

            #expect(output == "child-input-value-1")
            #expect(log.loggedLines == [SecretRegistry.mask])
        }
    }
}
