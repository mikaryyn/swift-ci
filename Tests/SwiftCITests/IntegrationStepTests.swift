import Foundation
@testable import SwiftCI
@testable import SwiftCITestSupport
import SwiftCITesting
import Testing

/// A fake integration that opens a step when it does work, as the real integrations do.
struct FakeTool {
    var failure: TestError? = nil

    func run(step name: String? = nil) async throws -> Int {
        try await step(default: "Run fake", name: name) {
            if let failure {
                throw failure
            }
            return 42
        }
    }
}

/// A fake integration that calls another integration internally, as `archiveAndExport` calls `getBuildSettings`.
struct WrapperTool {
    let tool: FakeTool

    func run(step name: String? = nil) async throws -> Int {
        try await step(default: "Run wrapper", name: name) {
            try await tool.run()
        }
    }
}

extension GlobalStateTests {
    @Suite(.serialized) struct IntegrationStepTests {
        @Test func topLevelCallOpensOneStepWithDefaultName() async {
            var value: Int?
            let result = await SwiftCITest.run(["test"]) {
                command(Command("test") {
                    value = try await FakeTool().run()
                })
            }

            let lines = result.log.map(stripANSI)
            #expect(result.exitCode == 0)
            #expect(value == 42)
            #expect(enteredSteps(in: result.log) == ["Entering step [Run fake]"])
            #expect(lines.contains { $0.hasPrefix("Finished step [Run fake] in ") })
        }

        @Test func stepParameterRenamesTheStep() async {
            let result = await SwiftCITest.run(["test"]) {
                command(Command("test") {
                    _ = try await FakeTool().run(step: "Custom name")
                })
            }

            #expect(result.exitCode == 0)
            #expect(enteredSteps(in: result.log) == ["Entering step [Custom name]"])
        }

        @Test func callInsideStepOpensNoStepOfItsOwn() async {
            let result = await SwiftCITest.run(["test"]) {
                command(Command("test") {
                    try await step("Outer") {
                        _ = try await FakeTool().run()
                    }
                })
            }

            #expect(result.exitCode == 0)
            #expect(enteredSteps(in: result.log) == ["Entering step [Outer]"])
        }

        @Test func integrationCallingAnotherIntegrationProducesOneStep() async {
            var value: Int?
            let result = await SwiftCITest.run(["test"]) {
                command(Command("test") {
                    value = try await WrapperTool(tool: FakeTool()).run()
                })
            }

            #expect(result.exitCode == 0)
            #expect(value == 42)
            #expect(enteredSteps(in: result.log) == ["Entering step [Run wrapper]"])
        }

        @Test func callInsideCleanupHandlerOpensNoStepOfItsOwn() async {
            let result = await SwiftCITest.run(["test"]) {
                command(Command("test") {
                    cleanup {
                        _ = try await FakeTool().run()
                    }
                })
            }

            #expect(result.exitCode == 0)
            #expect(enteredSteps(in: result.log) == ["Entering step [Cleanup]"])
        }

        @Test func callInsideAllowedStepOpensNoStepOfItsOwn() async {
            var value: Int?
            let result = await SwiftCITest.run(["test"]) {
                command(Command("test") {
                    value = await step("Outer", failure: .allowed) {
                        try await FakeTool().run()
                    }
                })
            }

            #expect(result.exitCode == 0)
            #expect(value == 42)
            #expect(enteredSteps(in: result.log) == ["Entering step [Outer]"])
        }

        @Test func failingCallInsideAllowedStepIsOnlyAFailedAllowedStep() async {
            let result = await SwiftCITest.run(["test"]) {
                command(Command("test") {
                    await step("Outer", failure: .allowed) {
                        try await FakeTool(failure: .boom).run()
                    }
                })
            }

            let lines = result.log.map(stripANSI)
            #expect(result.exitCode == 0)
            #expect(enteredSteps(in: result.log) == ["Entering step [Outer]"])
            #expect(lines.contains("Step [Outer] failed (allowed)"))
            #expect(lines.filter { $0.contains("boom") } == ["<Warning> boom"])
        }

        /// The script catches the error, so the command succeeds. The step is still logged as failed.
        @Test func failingTopLevelCallIsLoggedAndErrorIsRethrownUnchanged() async {
            var caught: TestError?
            let result = await SwiftCITest.run(["test"]) {
                command(Command("test") {
                    do {
                        _ = try await FakeTool(failure: .boom).run()
                    } catch let error as TestError {
                        caught = error
                    }
                })
            }

            #expect(caught == .boom)
            #expect(result.exitCode == 0)
            #expect(result.log.map(stripANSI).contains("Step [Run fake] failed"))
        }

        @Test func uncaughtFailingTopLevelCallFailsTheCommand() async {
            var ranAfter = false
            let result = await SwiftCITest.run(["test"]) {
                command(Command("test") {
                    _ = try await FakeTool(failure: .boom).run()
                    ranAfter = true
                })
            }

            let lines = result.log.map(stripANSI)
            #expect(result.exitCode == 1)
            #expect(!ranAfter)
            #expect(lines.filter { $0.contains("boom") } == ["<Error> boom"])
            #expect(lines.contains("Command [test] failed"))
        }

        /// Outside a running command, the body runs directly and nothing is logged as a step.
        @Test func callOutsideCommandRunsBodyWithoutStep() async throws {
            registerDependencies()
            let log = LogMock()
            register(Log.self, log)

            let value = try await FakeTool().run()

            #expect(value == 42)
            #expect(log.loggedLines.isEmpty)
        }

        /// Compile-time check: the three `step` overloads, next to each other, infer their types
        /// without annotations for bodies that return `Void` and bodies that return a value.
        @Test func stepOverloadsInferTypesWithoutAnnotations() async {
            var value: Int?
            let result = await SwiftCITest.run(["test"]) {
                command(Command("test") {
                    try await step(default: "Void body", name: nil) {
                        let base = 20
                        _ = base + 22
                    }
                    value = try await step(default: "Value body", name: "Named") {
                        let base = 20
                        return base + 22
                    }
                    try await step("Throwing") { }
                    await step("Allowed", failure: .allowed) {
                        let base = 20
                        _ = base + 22
                    }
                })
            }

            #expect(result.exitCode == 0)
            #expect(value == 42)
            #expect(enteredSteps(in: result.log) == [
                "Entering step [Void body]",
                "Entering step [Named]",
                "Entering step [Throwing]",
                "Entering step [Allowed]"
            ])
        }
    }
}
