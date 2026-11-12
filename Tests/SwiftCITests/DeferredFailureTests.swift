@testable import SwiftCI
@testable import SwiftCITestSupport
import SwiftCITesting
import Testing

extension GlobalStateTests {
    @Suite(.serialized) struct DeferredFailureTests {
        @Test func successReturnsTrueAndCommandPasses() async {
            var returned: Bool?
            let result = await SwiftCITest.run(["test"]) {
                command(Command("test") {
                    returned = await deferringFailure { }
                })
            }

            #expect(result.exitCode == 0)
            #expect(returned == true)
            #expect(!result.plainLog.contains("Command [test] failed"))
        }

        /// The later lines run. The command fails with the code and the message of the deferred error.
        @Test func deferredFailureLetsLaterLinesRunAndFailsWithItsCode() async {
            var events: [String] = []
            let result = await SwiftCITest.run(["test"]) {
                command(Command("test") {
                    let passed = await deferringFailure {
                        throw BuildError(message: "Tests failed.", code: .usage)
                    }
                    events.append("later, passed: \(passed)")
                })
            }

            let lines = result.plainLog
            #expect(result.exitCode == 2)
            #expect(events == ["later, passed: false"])
            #expect(lines.filter { $0 == "<Error> Tests failed." }.count == 1)
            #expect(lines.contains("Command [test] failed"))
            #expect(lines.contains("Exit code 2"))
        }

        /// A step that fails inside the deferred body is logged as a failed step, and the command fails with its error.
        @Test func failedStepInsideDeferredBodyIsLoggedAsFailedStep() async {
            let result = await SwiftCITest.run(["test"]) {
                command(Command("test") {
                    await deferringFailure {
                        try await step("Run tests") { throw BuildError(message: "Run failed.") }
                    }
                })
            }

            let lines = result.plainLog
            #expect(result.exitCode == 1)
            #expect(lines.contains("Step [Run tests] failed"))
            #expect(lines.filter { $0 == "<Error> Run failed." }.count == 1)
        }

        /// The `onFailure` and `cleanup` handlers run for a deferred failure, as they do for an escaped error.
        @Test func onFailureAndCleanupRunForDeferredFailure() async {
            var events: [String] = []
            let result = await SwiftCITest.run(["test"]) {
                command(Command("test") {
                    onFailure { events.append("onFailure") }
                    cleanup { events.append("cleanup") }
                    await deferringFailure { throw TestError.boom }
                })
            }

            #expect(result.exitCode == 1)
            #expect(events == ["cleanup", "onFailure"])
        }

        /// The report handlers see the command as failed with the message of the deferred error.
        @Test func reportHandlersSeeDeferredFailure() async {
            var outcome: CommandOutcome?
            let result = await SwiftCITest.run(["test"]) {
                command(Command("test") {
                    onReport { report in
                        outcome = report.outcome
                    }
                    await deferringFailure { throw BuildError(message: "Deferred.") }
                })
            }

            #expect(result.exitCode == 1)
            #expect(outcome == .failed(message: "Deferred."))
        }

        /// The first deferred error decides the exit code. Both messages are logged once.
        @Test func firstDeferredErrorWinsOverLaterDeferredError() async {
            let result = await SwiftCITest.run(["test"]) {
                command(Command("test") {
                    await deferringFailure { throw BuildError(message: "First failed.", code: .usage) }
                    await deferringFailure { throw BuildError(message: "Second failed.", code: .internal) }
                })
            }

            let lines = result.plainLog
            #expect(result.exitCode == 2)
            #expect(lines.filter { $0 == "<Error> First failed." }.count == 1)
            #expect(lines.filter { $0 == "<Error> Second failed." }.count == 1)
        }

        /// The first deferred error wins over an error that the body throws later. Both are logged once.
        @Test func firstDeferredErrorWinsOverLaterThrownError() async {
            let result = await SwiftCITest.run(["test"]) {
                command(Command("test") {
                    await deferringFailure { throw BuildError(message: "Deferred failed.", code: .usage) }
                    throw BuildError(message: "Body failed.", code: .internal)
                })
            }

            let lines = result.plainLog
            #expect(result.exitCode == 2)
            #expect(lines.filter { $0 == "<Error> Deferred failed." }.count == 1)
            #expect(lines.filter { $0 == "<Error> Body failed." }.count == 1)
        }

        /// A deferred error stays in its run. The next run starts with none, and its `deferringFailure` succeeds.
        @Test func deferredErrorsDoNotLeakIntoNextRun() async {
            let first = await SwiftCITest.run(["first"]) {
                command(Command("first") {
                    await deferringFailure { throw TestError.boom }
                })
            }
            #expect(first.exitCode == 1)

            var returned: Bool?
            let second = await SwiftCITest.run(["second"]) {
                command(Command("second") {
                    returned = await deferringFailure { }
                })
            }

            #expect(second.exitCode == 0)
            #expect(returned == true)
            #expect(RunContext.current == nil)
        }
    }
}
