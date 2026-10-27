@testable import SwiftCI
@testable import SwiftCITestSupport
import SwiftCITesting
import Testing

extension GlobalStateTests {
    @Suite(.serialized) struct RunnerTests {
        @Test func successfulCommandExitsWithZero() async {
            let result = await SwiftCITest.run(["test"]) {
                command(Command("test") { try await step("Work") { } })
            }

            let lines = result.log.map(stripANSI)
            #expect(result.exitCode == 0)
            #expect(lines.contains("Entering step [Work]"))
            #expect(lines.contains { $0.hasPrefix("Finished step [Work] in ") })
        }

        @Test func unknownCommandExitsWithUsageCode() async {
            let result = await SwiftCITest.run(["missing"]) {
                command(Command("test") { })
            }

            #expect(result.exitCode == 2)
            #expect(result.log.map(stripANSI).contains("<Error> Unsupported command 'missing'."))
        }

        @Test func noCommandNameExitsWithUsageCode() async {
            let result = await SwiftCITest.run([]) {
                command(Command("test") { })
            }

            #expect(result.exitCode == 2)
            #expect(result.log.map(stripANSI).contains("<Error> No commands specified."))
        }

        @Test func missingCommandNameListsCommandsAfterTheError() async {
            let result = await SwiftCITest.run([]) {
                command(Command("test", description: "Run the unit tests.") { })
                command(Command("release") { })
            }

            let lines = result.log.map(stripANSI)
            #expect(result.exitCode == 2)
            #expect(Array(lines.suffix(5)) == [
                "<Error> No commands specified.",
                "",
                "Available commands:",
                "  test     Run the unit tests.",
                "  release",
            ])
        }

        @Test func unknownCommandListsCommandsAfterTheError() async {
            let result = await SwiftCITest.run(["missing"]) {
                command(Command("test", description: "Run the unit tests.") { })
            }

            let lines = result.log.map(stripANSI)
            #expect(result.exitCode == 2)
            #expect(Array(lines.suffix(4)) == [
                "<Error> Unsupported command 'missing'.",
                "",
                "Available commands:",
                "  test  Run the unit tests.",
            ])
        }

        @Test func listPrintsCommandsAndRunsNothing() async {
            var ran = false
            let result = await SwiftCITest.run(["test", "--list"]) {
                command(Command("test", description: "Run the unit tests.") { ran = true })
            }

            let lines = result.log.map(stripANSI)
            #expect(result.exitCode == 0)
            #expect(!ran)
            #expect(lines.suffix(2) == ["Available commands:", "  test  Run the unit tests."])
            #expect(!lines.contains { $0.hasPrefix("<Error>") })
        }

        @Test func listWithoutCommandsSaysSo() async {
            let result = await SwiftCITest.run(["--list"]) { }

            #expect(result.exitCode == 0)
            #expect(result.log.map(stripANSI).contains("No commands are registered."))
        }

        /// A failed step throws, so the command fails with the default `ErrorCode.failure` (1).
        @Test func failingStepExitsWithOne() async {
            let result = await SwiftCITest.run(["build"]) {
                command(Command("build") {
                    try await step("Compile") {
                        throw BuildError(message: "Compiler failed.")
                    }
                })
            }

            let lines = result.log.map(stripANSI)
            #expect(result.exitCode == 1)
            #expect(lines.contains("Step [Compile] failed"))
            #expect(lines.filter { $0.contains("Compiler failed.") } == ["<Error> Compiler failed."])
            #expect(lines.contains("Command [build] failed"))
        }

        @Test func buildErrorWithUsageCodeInsideStepExitsWithTwo() async {
            let result = await SwiftCITest.run(["build"]) {
                command(Command("build") {
                    try await step("Configure") {
                        throw BuildError(message: "Missing setting.", code: .usage)
                    }
                })
            }

            #expect(result.exitCode == 2)
            #expect(result.log.map(stripANSI).contains("<Error> Missing setting."))
        }

        @Test func internalErrorInsideStepExitsWithThree() async {
            let result = await SwiftCITest.run(["build"]) {
                command(Command("build") {
                    try await step("Internal") {
                        throw BuildError(message: "Internal problem.", code: .internal)
                    }
                })
            }

            #expect(result.exitCode == 3)
            #expect(result.log.map(stripANSI).contains("<Error> Internal problem."))
        }

        @Test func otherErrorInsideStepExitsWithOneAndIsLoggedOnce() async {
            let result = await SwiftCITest.run(["build"]) {
                command(Command("build") {
                    try await step("Work") { throw TestError.boom }
                })
            }

            let lines = result.log.map(stripANSI)
            #expect(result.exitCode == 1)
            #expect(lines.filter { $0 == "<Error> boom" }.count == 1)
            #expect(lines.contains("Step [Work] failed"))
        }

        @Test func errorOutsideAnyStepIsLoggedOnceAndExitsWithOne() async {
            let result = await SwiftCITest.run(["build"]) {
                command(Command("build") {
                    throw TestError.boom
                })
            }

            let lines = result.log.map(stripANSI)
            #expect(result.exitCode == 1)
            #expect(lines.filter { $0 == "<Error> boom" }.count == 1)
            #expect(lines.contains("Command [build] failed"))
        }

        @Test func errorInScriptOutsideCommandsExitsWithOne() async {
            let result = await SwiftCITest.run(["build"]) {
                throw TestError.boom
            }

            #expect(result.exitCode == 1)
            #expect(result.log.map(stripANSI).contains("<Error> boom"))
        }

        /// A name with a slash points the full log into a directory that does not exist,
        /// so opening the full log fails inside the temporary directory only.
        @Test func fullLogThatCannotBeOpenedExitsWithThree() async {
            let result = await SwiftCITest.run(["missing/dir"]) {
                command(Command("missing/dir") { })
            }

            let lines = result.log.map(stripANSI)
            #expect(result.exitCode == 3)
            #expect(lines.contains { $0.hasPrefix("<Error> Failed to create build log file") && $0.contains("/missing/dir.log'") })
            #expect(lines.contains("Command [missing/dir] failed"))
        }

        /// With `./ci a b c`, the run stops at the failed `b`, exits with its code and never runs `c`.
        @Test func failingCommandStopsTheRunWithItsExitCode() async {
            var ranC = false
            let result = await SwiftCITest.run(["a", "b", "c"]) {
                command(Command("a") { try await step("A") { } })
                command(Command("b") { try await step("B") { throw BuildError(message: "B failed.", code: .usage) } })
                command(Command("c") { ranC = true })
            }

            let lines = result.log.map(stripANSI)
            #expect(result.exitCode == 2)
            #expect(!ranC)
            #expect(lines.contains("Entering step [A]"))
            #expect(lines.contains("Command [b] failed"))
        }

        /// The run context of a failed command must not leak into the next run.
        @Test func runContextIsClearedAfterFailedCommand() async {
            let first = await SwiftCITest.run(["fail"]) {
                command(Command("fail") { try await step("Work") { throw BuildError(message: "Failed.") } })
            }
            #expect(first.exitCode == 1)
            #expect(RunContext.current == nil)

            var depthAtCommandStart: Int?
            let second = await SwiftCITest.run(["next"]) {
                command(Command("next") {
                    depthAtCommandStart = RunContext.current?.stepDepth
                    try await step("Next") { }
                })
            }
            #expect(second.exitCode == 0)
            #expect(depthAtCommandStart == 0)
            #expect(second.log.map(stripANSI).contains("Entering step [Next]"))
            #expect(RunContext.current == nil)
        }
    }
}
