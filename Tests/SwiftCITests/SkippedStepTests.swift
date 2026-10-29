@testable import SwiftCI
@testable import SwiftCITestSupport
import SwiftCITesting
import Testing

extension GlobalStateTests {
    @Suite(.serialized) struct SkippedStepTests {
        /// A false condition logs the step as skipped, with the reason, in the console and the full log, where it is a
        /// step header between "=" dividers. The body does not run, and the command continues.
        @Test func falseConditionSkipsTheBodyAndLogsTheReason() async {
            var ranBody = false
            var ranAfter = false
            var value: Int? = 0
            var fullLog = ""
            let result = await SwiftCITest.run(["test"]) {
                command(Command("test") {
                    value = try await step("Unlock keychains", when: false, skipReason: "not running on CI") {
                        ranBody = true
                        return 42
                    }
                    ranAfter = true
                    fullLog = try readFullLog()
                })
            }

            #expect(result.exitCode == 0)
            #expect(value == nil)
            #expect(!ranBody)
            #expect(ranAfter)
            #expect(result.plainLog.contains("Skipped step [Unlock keychains]: not running on CI"))
            #expect(!result.plainLog.contains { $0.contains("Entering step [Unlock keychains]") })
            let header = "Skipped step [Unlock keychains]: not running on CI"
            let divider = String(repeating: "=", count: header.count)
            #expect(fullLog.contains("\(divider)\n\(header)\n\(divider)"))
        }

        /// A true condition runs the step as usual and returns its value.
        @Test func trueConditionRunsTheStep() async {
            var value: Int?
            let result = await SwiftCITest.run(["test"]) {
                command(Command("test") {
                    value = try await step("Compute", when: true, skipReason: "unused") { 42 }
                })
            }

            #expect(result.exitCode == 0)
            #expect(value == 42)
            #expect(result.plainLog.contains { $0.hasPrefix("Finished step [Compute] in ") })
            #expect(!result.plainLog.contains { $0.hasPrefix("Skipped step") })
        }

        /// A true condition still fails the command when the body throws.
        @Test func trueConditionKeepsTheFailure() async {
            let result = await SwiftCITest.run(["test"]) {
                command(Command("test") {
                    try await step("Broken", when: true, skipReason: "unused") { () async throws -> Void in
                        throw BuildError(message: "Broke.")
                    }
                })
            }

            #expect(result.exitCode != 0)
            #expect(result.plainLog.contains("Step [Broken] failed"))
        }

        /// The allowed-failure variant skips the same way, and runs as ``step(_:failure:_:)`` when the condition holds.
        @Test func allowedVariantSkipsOrRuns() async {
            var skipped: Int? = 0
            var failed: Int? = 0
            let result = await SwiftCITest.run(["test"]) {
                command(Command("test") {
                    skipped = await step("Notify", when: false, skipReason: "not running on CI", failure: .allowed) {
                        42
                    }
                    failed = await step("Notify again", when: true, skipReason: "unused", failure: .allowed) {
                        () async throws -> Int in
                        throw BuildError(message: "Slack is down.")
                    }
                })
            }

            #expect(result.exitCode == 0)
            #expect(skipped == nil)
            #expect(failed == nil)
            #expect(result.plainLog.contains("Skipped step [Notify]: not running on CI"))
            #expect(result.plainLog.contains("Step [Notify again] failed (allowed)"))
        }

        /// A skip inside a step is indented to its depth, and a top-level skip starts a new group with a blank line.
        @Test func skipStepUsesTheCurrentDepth() async {
            let log = LogMock()
            let result = await SwiftCITest.run(["test"]) {
                register(Log.self, log)
                command(Command("test") {
                    skipStep("Top", reason: "not needed")
                    try await step("Outer") {
                        skipStep("Inner", reason: "not needed either")
                    }
                })
            }

            #expect(result.exitCode == 0)
            #expect(log.steps.contains(.skipped(name: "Top", reason: "not needed", depth: 0)))
            #expect(log.steps.contains(.skipped(name: "Inner", reason: "not needed either", depth: 1)))
            let lines = log.loggedLines.map(stripANSI)
            guard let topIndex = lines.firstIndex(of: "Skipped step [Top]: not needed") else {
                Issue.record("Expected the top-level skip line.")
                return
            }
            #expect(topIndex > 0 && lines[topIndex - 1].isEmpty)
            #expect(lines.contains("  Skipped step [Inner]: not needed either"))
        }

        /// A secret in the name or the reason is masked.
        @Test func secretsInTheNameAndReasonAreMasked() async {
            let result = await SwiftCITest.run(["test"]) {
                command(Command("test") {
                    let secret = Secret(value: "skip-SECRET-1")
                    _ = secret
                    skipStep("Use skip-SECRET-1", reason: "no skip-SECRET-1")
                })
            }

            #expect(result.exitCode == 0)
            #expect(!result.log.contains { $0.contains("skip-SECRET-1") })
            #expect(result.plainLog.contains { $0.hasPrefix("Skipped step [") })
        }
    }
}
