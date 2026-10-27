@testable import SwiftCI
@testable import SwiftCITestSupport
import Foundation
import SwiftCITesting
import Testing

extension GlobalStateTests {
    @Suite(.serialized) struct HandlerTests {
        @Test func cleanupRunsInReverseOrderThenOnFailureInReverseOrder() async {
            var events: [String] = []
            let result = await SwiftCITest.run(["test"]) {
                command(Command("test") {
                    cleanup { events.append("c1") }
                    onFailure { events.append("o1") }
                    cleanup { events.append("c2") }
                    onFailure { events.append("o2") }
                    throw BuildError(message: "Body failed.")
                })
            }

            #expect(result.exitCode == 1)
            #expect(events == ["c2", "c1", "o2", "o1"])
        }

        @Test func handlerWhoseRegistrationWasNotReachedDoesNotRun() async {
            var events: [String] = []
            let result = await SwiftCITest.run(["test"]) {
                command(Command("test") {
                    try await step("Fail") { throw TestError.boom }
                    cleanup { events.append("cleanup") }
                    onFailure { events.append("onFailure") }
                })
            }

            #expect(result.exitCode == 1)
            #expect(events.isEmpty)
        }

        @Test func onFailureDoesNotRunAfterSuccess() async {
            var events: [String] = []
            let result = await SwiftCITest.run(["test"]) {
                command(Command("test") {
                    onFailure { events.append("onFailure") }
                    cleanup { events.append("cleanup") }
                })
            }

            #expect(result.exitCode == 0)
            #expect(events == ["cleanup"])
        }

        /// The cleanup handler was registered before the onFailure handler and fails. The
        /// onFailure handler still runs, because the command has failed.
        @Test func onFailureRunsAfterFailedCleanup() async {
            var events: [String] = []
            let result = await SwiftCITest.run(["test"]) {
                command(Command("test") {
                    cleanup {
                        events.append("cleanup")
                        throw TestError.boom
                    }
                    onFailure { events.append("onFailure") }
                })
            }

            #expect(result.exitCode == 1)
            #expect(events == ["cleanup", "onFailure"])
        }

        @Test func failedHandlerFailsSuccessfulCommandAndOthersStillRun() async {
            var events: [String] = []
            let result = await SwiftCITest.run(["test"]) {
                command(Command("test") {
                    cleanup { events.append("a") }
                    cleanup {
                        events.append("b")
                        throw BuildError(message: "Handler b failed.")
                    }
                    cleanup { events.append("c") }
                })
            }

            let lines = result.log.map(stripANSI)
            #expect(result.exitCode == 1)
            #expect(events == ["c", "b", "a"])
            #expect(lines.contains("Step [Cleanup] failed"))
            #expect(lines.filter { $0 == "<Error> Handler b failed." }.count == 1)
            #expect(lines.contains("Command [test] failed"))
        }

        @Test func allowedHandlerFailureKeepsCommandSuccessful() async {
            let result = await SwiftCITest.run(["test"]) {
                command(Command("test") {
                    cleanup(failure: .allowed) { throw TestError.boom }
                })
            }

            let lines = result.log.map(stripANSI)
            #expect(result.exitCode == 0)
            #expect(lines.contains("Step [Cleanup] failed (allowed)"))
            #expect(lines.filter { $0 == "<Warning> boom" }.count == 1)
            #expect(!lines.contains { $0.hasPrefix("<Error>") })
            #expect(!lines.contains("Command [test] failed"))
        }

        /// The body's error decides the exit code. Both messages are logged once.
        @Test func bodyFailureDecidesExitCodeOverHandlerFailure() async {
            let result = await SwiftCITest.run(["test"]) {
                command(Command("test") {
                    cleanup { throw BuildError(message: "Cleanup failed.", code: .internal) }
                    throw BuildError(message: "Body failed.", code: .usage)
                })
            }

            let lines = result.log.map(stripANSI)
            #expect(result.exitCode == 2)
            #expect(lines.filter { $0 == "<Error> Body failed." }.count == 1)
            #expect(lines.filter { $0 == "<Error> Cleanup failed." }.count == 1)
        }

        /// Without a body failure, the handler that ran first decides the exit code.
        @Test func firstRunHandlerDecidesExitCodeWhenBodySucceeded() async {
            var events: [String] = []
            let result = await SwiftCITest.run(["test"]) {
                command(Command("test") {
                    cleanup {
                        events.append("first registered")
                        throw BuildError(message: "First registered failed.", code: .usage)
                    }
                    cleanup {
                        events.append("second registered")
                        throw BuildError(message: "Second registered failed.", code: .internal)
                    }
                })
            }

            let lines = result.log.map(stripANSI)
            #expect(result.exitCode == 3)
            #expect(events == ["second registered", "first registered"])
            #expect(lines.filter { $0 == "<Error> First registered failed." }.count == 1)
            #expect(lines.filter { $0 == "<Error> Second registered failed." }.count == 1)
        }

        @Test func allowedHandlerFailureAfterSuccessfulBodyIsOneWarning() async {
            var events: [String] = []
            let result = await SwiftCITest.run(["test"]) {
                command(Command("test") {
                    onFailure { events.append("onFailure") }
                    cleanup(failure: .allowed) { throw TestError.boom }
                    events.append("body")
                })
            }

            let lines = result.log.map(stripANSI)
            #expect(result.exitCode == 0)
            #expect(events == ["body"])
            #expect(lines.filter { $0 == "<Warning> boom" }.count == 1)
            #expect(lines.contains("Step [Cleanup] failed (allowed)"))
            #expect(!lines.contains { $0.hasPrefix("<Error>") })
        }

        @Test func allowedHandlerFailureAfterFailedBodyIsOneWarning() async {
            let result = await SwiftCITest.run(["test"]) {
                command(Command("test") {
                    cleanup(failure: .allowed) { throw BuildError(message: "Allowed failed.") }
                    throw BuildError(message: "Body failed.", code: .usage)
                })
            }

            let lines = result.log.map(stripANSI)
            #expect(result.exitCode == 2)
            #expect(lines.filter { $0 == "<Warning> Allowed failed." }.count == 1)
            #expect(lines.filter { $0 == "<Error> Body failed." }.count == 1)
            #expect(!lines.contains { $0 == "<Error> Allowed failed." })
            #expect(lines.contains("Step [Cleanup] failed (allowed)"))
        }

        @Test func allowedFailingCleanupDoesNotTriggerOnFailure() async {
            var events: [String] = []
            let result = await SwiftCITest.run(["test"]) {
                command(Command("test") {
                    onFailure { events.append("onFailure") }
                    cleanup(failure: .allowed) { throw TestError.boom }
                })
            }

            #expect(result.exitCode == 0)
            #expect(events.isEmpty)
        }

        /// A handler registered inside a step runs at the end of the command, after the later body code.
        @Test func handlerRegisteredInStepRunsAtEndOfCommand() async {
            var events: [String] = []
            let result = await SwiftCITest.run(["test"]) {
                command(Command("test") {
                    try await step("Setup") {
                        cleanup { events.append("cleanup") }
                    }
                    events.append("body after step")
                })
            }

            #expect(result.exitCode == 0)
            #expect(events == ["body after step", "cleanup"])
        }

        @Test func stepsInsideHandlerAreNested() async {
            let result = await SwiftCITest.run(["test"]) {
                command(Command("test") {
                    cleanup {
                        try await step("Inner") { }
                    }
                })
            }

            let lines = result.log.map(stripANSI)
            #expect(result.exitCode == 0)
            #expect(lines.contains("Entering step [Cleanup]"))
            #expect(lines.contains("  Entering step [Inner]"))
            #expect(lines.contains { $0.hasPrefix("  Finished step [Inner] in ") })
        }

        /// The handler body still runs when its status line cannot be written. The status error is
        /// recorded and fails the command with code 3, as the recorded error is logged once.
        @Test func handlerBodyRunsWhenItsStatusWriteFails() async {
            var events: [String] = []
            let result = await SwiftCITest.run(["test"]) {
                command(Command("test") {
                    cleanup { events.append("cleanup") }
                    try FullLog.file?.close()
                    if let path = FullLog.path {
                        FullLog.file = FileHandle(forReadingAtPath: path.filePath)
                    }
                })
            }

            let lines = result.log.map(stripANSI)
            #expect(result.exitCode == 3)
            #expect(events == ["cleanup"])
            #expect(lines.filter { $0.hasPrefix("<Error> Failed to write into the build log") }.count == 1)
        }

        /// The body fails with `.usage`. The first `onFailure` handler to run fails too, and the handler
        /// registered before it still runs. The body's code wins, and each message is logged once.
        @Test func failingOnFailureHandlerDoesNotStopOtherOnFailureHandlers() async {
            var events: [String] = []
            let result = await SwiftCITest.run(["test"]) {
                command(Command("test") {
                    onFailure { events.append("o1") }
                    onFailure {
                        events.append("o2")
                        throw BuildError(message: "On failure o2 failed.", code: .internal)
                    }
                    throw BuildError(message: "Body failed.", code: .usage)
                })
            }

            let lines = result.log.map(stripANSI)
            #expect(result.exitCode == 2)
            #expect(events == ["o2", "o1"])
            #expect(lines.filter { $0 == "<Error> Body failed." }.count == 1)
            #expect(lines.filter { $0 == "<Error> On failure o2 failed." }.count == 1)
            #expect(lines.filter { $0.hasPrefix("<Error>") }.count == 2)
            #expect(lines.filter { $0 == "Step [On failure] failed" }.count == 1)
        }

        /// The cleanup handler fails with `.usage`, so it decides the code. The `onFailure` handler fails
        /// with `.internal`, which does not change it. Each message is logged once.
        @Test func failingOnFailureAfterFailedCleanupKeepsCleanupCode() async {
            var events: [String] = []
            let result = await SwiftCITest.run(["test"]) {
                command(Command("test") {
                    cleanup {
                        events.append("cleanup")
                        throw BuildError(message: "Cleanup failed.", code: .usage)
                    }
                    onFailure {
                        events.append("onFailure")
                        throw BuildError(message: "On failure failed.", code: .internal)
                    }
                })
            }

            let lines = result.log.map(stripANSI)
            #expect(result.exitCode == 2)
            #expect(events == ["cleanup", "onFailure"])
            #expect(lines.filter { $0 == "<Error> Cleanup failed." }.count == 1)
            #expect(lines.filter { $0 == "<Error> On failure failed." }.count == 1)
            #expect(lines.filter { $0.hasPrefix("<Error>") }.count == 2)
        }

        /// The allowed `onFailure` handler fails after a failed body. It is logged as a single warning and
        /// does not change the exit code of the body.
        @Test func allowedFailingOnFailureKeepsBodyCode() async {
            var events: [String] = []
            let result = await SwiftCITest.run(["test"]) {
                command(Command("test") {
                    onFailure(failure: .allowed) {
                        events.append("onFailure")
                        throw BuildError(message: "Allowed on failure failed.")
                    }
                    throw BuildError(message: "Body failed.", code: .usage)
                })
            }

            let lines = result.log.map(stripANSI)
            #expect(result.exitCode == 2)
            #expect(events == ["onFailure"])
            #expect(lines.filter { $0 == "<Warning> Allowed on failure failed." }.count == 1)
            #expect(lines.contains("Step [On failure] failed (allowed)"))
            #expect(!lines.contains { $0 == "<Error> Allowed on failure failed." })
            #expect(lines.filter { $0 == "<Error> Body failed." }.count == 1)
        }

        @Test func runContextAndHandlersAreResetBetweenRuns() async {
            var firstRuns = 0
            let first = await SwiftCITest.run(["first"]) {
                command(Command("first") {
                    cleanup { firstRuns += 1 }
                    throw TestError.boom
                })
            }
            #expect(first.exitCode == 1)
            #expect(firstRuns == 1)

            var handlersAtStart: Int?
            let second = await SwiftCITest.run(["second"]) {
                command(Command("second") {
                    handlersAtStart = RunContext.current?.handlers.count
                })
            }

            #expect(second.exitCode == 0)
            #expect(handlersAtStart == 0)
            #expect(firstRuns == 1)
            #expect(RunContext.current == nil)
        }

        /// With `./ci a b`, the handlers of `a` run before `b` starts, and `b` does not see them.
        @Test func handlersOfFirstCommandRunBeforeSecondCommandStarts() async {
            var events: [String] = []
            let result = await SwiftCITest.run(["a", "b"]) {
                command(Command("a") {
                    cleanup { events.append("a cleanup") }
                    events.append("a body")
                })
                command(Command("b") {
                    events.append("b body, handlers: \(RunContext.current?.handlers.count ?? -1)")
                })
            }

            #expect(result.exitCode == 0)
            #expect(events == ["a body", "a cleanup", "b body, handlers: 0"])
        }

        /// The first status-line error is absorbed as a failure of the body. `onFailure` still runs.
        @Test func internalErrorFromAllowedStepFailsCommandAndRunsOnFailure() async {
            var events: [String] = []
            let result = await SwiftCITest.run(["test"]) {
                command(Command("test") {
                    onFailure { events.append("onFailure") }
                    try FullLog.file?.close()
                    if let path = FullLog.path {
                        FullLog.file = FileHandle(forReadingAtPath: path.filePath)
                    }
                    await step("Notify", failure: .allowed) { }
                })
            }

            let lines = result.log.map(stripANSI)
            #expect(result.exitCode == 3)
            #expect(events == ["onFailure"])
            #expect(lines.contains { $0.hasPrefix("<Error> Failed to write into the build log") })
            #expect(lines.contains("Command [test] failed"))
        }

        /// The allowed step's failed status writes are recorded. Only the first is logged once
        /// at the body checkpoint. Without handlers, no other checkpoint logs it.
        @Test func internalErrorFromAllowedStepIsLoggedOnce() async {
            let result = await SwiftCITest.run(["test"]) {
                command(Command("test") {
                    try FullLog.file?.close()
                    if let path = FullLog.path {
                        FullLog.file = FileHandle(forReadingAtPath: path.filePath)
                    }
                    await step("Notify", failure: .allowed) { }
                })
            }

            let lines = result.log.map(stripANSI)
            #expect(result.exitCode == 3)
            #expect(lines.filter { $0.hasPrefix("<Error> Failed to write into the build log") }.count == 1)
        }
    }
}
