@testable import SwiftCI
@testable import SwiftCITestSupport
import SwiftCITesting
import Testing

extension GlobalStateTests {
    @Suite(.serialized) struct StepTests {
        @Test func stepReturnsValueOfBody() async {
            var value: Int?
            let result = await SwiftCITest.run(["test"]) {
                command(Command("test") { value = try await step("Compute") { 6 * 7 } })
            }

            #expect(result.exitCode == 0)
            #expect(value == 42)
        }

        @Test func failedStepThrowsAndLaterCodeDoesNotRun() async {
            var ranAfter = false
            let result = await SwiftCITest.run(["test"]) {
                command(Command("test") {
                    try await step("Fail") { throw TestError.boom }
                    ranAfter = true
                })
            }

            #expect(result.exitCode == 1)
            #expect(!ranAfter)
        }

        @Test func nestedFailureFailsOuterStepAndLogsMessageOnce() async {
            let result = await SwiftCITest.run(["test"]) {
                command(Command("test") {
                    try await step("Outer") {
                        try await step("Inner") { throw BuildError(message: "Boom.") }
                    }
                })
            }

            let lines = result.log.map(stripANSI)
            #expect(result.exitCode == 1)
            #expect(lines.contains("  Step [Inner] failed"))
            #expect(lines.contains("Step [Outer] failed"))
            #expect(lines.filter { $0.contains("Boom.") } == ["<Error> Boom."])
        }

        @Test func callerCanCatchOriginalErrorType() async {
            var caught: TestError?
            let result = await SwiftCITest.run(["test"]) {
                command(Command("test") {
                    do {
                        try await step("Fail") { throw TestError.boom }
                    } catch let error as TestError {
                        caught = error
                    }
                })
            }

            #expect(caught == .boom)
            #expect(result.exitCode == 0)
        }

        /// A caught error leaves the command running. The step is logged as failed, and SwiftCI
        /// does not log the error message, because the script handled it.
        @Test func caughtStepErrorLetsCommandContinue() async {
            var ranAfter = false
            let result = await SwiftCITest.run(["test"]) {
                command(Command("test") {
                    do {
                        try await step("Flaky") { throw TestError.boom }
                    } catch {
                    }
                    ranAfter = true
                })
            }

            let lines = result.log.map(stripANSI)
            #expect(result.exitCode == 0)
            #expect(ranAfter)
            #expect(lines.contains("Step [Flaky] failed"))
            #expect(!lines.contains { $0.contains("boom") })
            #expect(!lines.contains("Command [test] failed"))
        }

        @Test func nestedStepLinesAreIndentedByTwoSpaces() async {
            let result = await SwiftCITest.run(["test"]) {
                command(Command("test") {
                    try await step("Outer") {
                        try await step("Inner") { }
                    }
                })
            }

            let lines = result.log.map(stripANSI)
            let innerIndex = lines.firstIndex(of: "  Entering step [Inner]")
            #expect(innerIndex != nil)
            #expect(innerIndex.map { lines[$0 - 1] } == "Entering step [Outer]")
            #expect(lines.contains { $0.hasPrefix("  Finished step [Inner] in ") })
            #expect(lines.contains { $0.hasPrefix("Finished step [Outer] in ") })
        }

        /// Compile-time check: these bodies must infer their type without annotations.
        @Test func stepInfersTypesWithoutAnnotations() async {
            func doWork() async throws { }
            func compute() async throws -> Int { 1 }

            var number: Int?
            var multiStatement: Int?
            var fromCall: Int?
            let result = await SwiftCITest.run(["test"]) {
                command(Command("test") {
                    try await step("Empty") { }
                    number = try await step("Single expression") { 42 }
                    multiStatement = try await step("Multi statement") {
                        let base = 20
                        let extra = 22
                        return base + extra
                    }
                    try await step("Calls async function") { try await doWork() }
                    fromCall = try await step("Returns async value") { try await compute() }
                })
            }

            #expect(result.exitCode == 0)
            #expect(number == 42)
            #expect(multiStatement == 42)
            #expect(fromCall == 1)
        }
    }
}
