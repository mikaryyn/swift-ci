@testable import SwiftCIXcode
@testable import SwiftCITestSupport
import Foundation
@testable import SwiftCI
import SwiftCITesting
import Testing

extension GlobalStateTests {
    /// `Simulator.shutdownAll` with a mock runner, so no `simctl` is started.
    @Suite(.serialized) struct SimulatorTests {
        @Test func shutdownAllRunsSimctlWithTheExpectedArguments() async throws {
            let (_, runner) = registerToolMocks()

            try await Simulator.shutdownAll()

            #expect(runner.tools.count == 1)
            #expect(runner.tools[0].command == "/usr/bin/xcrun")
            #expect(runner.tools[0].arguments == ["simctl", "shutdown", "all"])
        }

        /// The step opens its default name at the top level of a command.
        @Test func shutdownAllOpensItsDefaultStepName() async {
            let runner = ProcessRunnerMock()

            let result = await SwiftCITest.run(["shutdown"]) {
                register(ProcessRunner.self, runner)
                command(Command("shutdown") {
                    try await Simulator.shutdownAll()
                })
            }

            #expect(result.exitCode == 0)
            #expect(enteredSteps(in: result.log) == ["Entering step [Shut down simulators]"])
            #expect(runner.tools.count == 1)
        }

        /// `step:` renames the step.
        @Test func shutdownAllStepNameCanBeChanged() async {
            let runner = ProcessRunnerMock()

            let result = await SwiftCITest.run(["named"]) {
                register(ProcessRunner.self, runner)
                command(Command("named") {
                    try await Simulator.shutdownAll(step: "Stop the simulators")
                })
            }

            #expect(result.exitCode == 0)
            #expect(enteredSteps(in: result.log) == ["Entering step [Stop the simulators]"])
        }

        /// A non-zero exit code fails the step, and so the command.
        @Test func shutdownAllFailsTheStepOnANonZeroExitCode() async {
            let runner = ProcessRunnerMock()
            runner.responses = [response(stderr: "simctl failed", exitCode: 1)]

            let result = await SwiftCITest.run(["shutdown"]) {
                register(ProcessRunner.self, runner)
                command(Command("shutdown") {
                    try await Simulator.shutdownAll()
                })
            }

            #expect(result.exitCode != 0)
            #expect(enteredSteps(in: result.log) == ["Entering step [Shut down simulators]"])
            #expect(runner.tools.count == 1)
        }
    }
}
