@testable import SwiftCI
@testable import SwiftCITestSupport
import SwiftCITesting
import Testing

extension GlobalStateTests {
    @Suite(.serialized) struct ConditionalCleanupTests {
        /// A met condition registers the handler, which runs at the end of the command.
        @Test func metConditionRegistersHandler() async {
            var events: [String] = []
            let result = await SwiftCITest.run(["test"]) {
                command(Command("test") {
                    cleanup(when: StepCondition(true, skipReason: "unused")) { events.append("cleanup") }
                    events.append("body")
                })
            }

            #expect(result.exitCode == 0)
            #expect(events == ["body", "cleanup"])
            #expect(!result.plainLog.contains { $0.hasPrefix("Skipped step") })
        }

        /// A false condition registers nothing: the handler does not run, and the skip is logged with the reason.
        @Test func falseConditionDoesNotRegisterHandlerAndLogsSkip() async {
            var events: [String] = []
            var handlerCount: Int?
            let result = await SwiftCITest.run(["test"]) {
                command(Command("test") {
                    cleanup(when: StepCondition(false, skipReason: "not running on CI")) { events.append("cleanup") }
                    handlerCount = RunContext.current?.handlers.count
                    events.append("body")
                })
            }

            #expect(result.exitCode == 0)
            #expect(handlerCount == 0)
            #expect(events == ["body"])
            #expect(result.plainLog.contains("Skipped step [Cleanup]: not running on CI"))
            #expect(!result.plainLog.contains { $0.contains("[Cleanup]") && !$0.hasPrefix("Skipped step") })
        }

        /// A skipped handler is not registered, so a failure of the body does not run it either.
        @Test func skippedHandlerDoesNotRunOnFailure() async {
            var events: [String] = []
            let result = await SwiftCITest.run(["test"]) {
                command(Command("test") {
                    cleanup(when: .onCI) { events.append("cleanup") }
                    onFailure { events.append("onFailure") }
                    throw TestError.boom
                })
            }

            #expect(result.exitCode == 1)
            #expect(events == ["onFailure"])
            #expect(result.plainLog.contains("Skipped step [Cleanup]: not running on CI"))
        }

        /// `.onCI` registers the handler when a CI system runs the build.
        @Test func onCIRegistersHandlerOnCI() async {
            var events: [String] = []
            let result = await SwiftCITest.run(["test"], environment: ["GITLAB_CI": "true"]) {
                command(Command("test") {
                    cleanup(when: .onCI) { events.append("cleanup") }
                })
            }

            #expect(result.exitCode == 0)
            #expect(events == ["cleanup"])
        }

        /// A failure of a met handler with `failure: .allowed` keeps the command successful, as for `cleanup`.
        @Test func metConditionKeepsFailureMode() async {
            let result = await SwiftCITest.run(["test"]) {
                command(Command("test") {
                    cleanup(when: StepCondition(true, skipReason: "unused"), failure: .allowed) { throw TestError.boom }
                })
            }

            #expect(result.exitCode == 0)
            #expect(result.plainLog.contains("Step [Cleanup] failed (allowed)"))
        }
    }
}
