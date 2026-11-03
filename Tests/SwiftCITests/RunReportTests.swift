@testable import SwiftCI
@testable import SwiftCITestSupport
import Foundation
import SwiftCITesting
import Testing

extension GlobalStateTests {
    @Suite(.serialized) struct RunReportTests {
        @Test func countsFindingsBySeverity() {
            let report = RunReport(
                commandName: "lint",
                findings: [
                    ReportFinding(severity: .failure, text: "A."),
                    ReportFinding(severity: .failure, text: "B.", file: "a.swift", line: 2),
                    ReportFinding(severity: .warning, text: "C."),
                    ReportFinding(severity: .message, text: "D."),
                ],
                outcome: .succeeded
            )

            #expect(report.failures.map(\.text) == ["A.", "B."])
            #expect(report.warnings.map(\.text) == ["C."])
            #expect(report.messages.map(\.text) == ["D."])
            #expect(!report.isClean)
        }

        @Test func isCleanOnlyWithoutFailuresWarningsAndWithSuccess() {
            let messagesOnly = RunReport(
                commandName: "lint",
                findings: [ReportFinding(severity: .message, text: "Done.")],
                outcome: .succeeded
            )
            let warningOnly = RunReport(
                commandName: "lint",
                findings: [ReportFinding(severity: .warning, text: "Careful.")],
                outcome: .succeeded
            )
            let failedWithoutFindings = RunReport(commandName: "lint", outcome: .failed(message: "Boom."))
            let running = RunReport(commandName: "lint")

            #expect(messagesOnly.isClean)
            #expect(!warningOnly.isClean)
            #expect(!failedWithoutFindings.isClean)
            #expect(!running.isClean)
            #expect(RunReport(commandName: "lint", outcome: .succeeded).isClean)
        }

        @Test func reportFailureFailsCommandWhoseBodySucceeded() async {
            let result = await SwiftCITest.run(["test"]) {
                command(Command("test") {
                    Report.failure("Lint failed.")
                })
            }

            let lines = result.log.map(stripANSI)
            #expect(result.exitCode == 1)
            #expect(lines.filter { $0 == "<Error> Lint failed." }.count == 1)
            #expect(lines.filter { $0 == "<Error> The run report has 1 failure(s)." }.count == 1)
            #expect(lines.contains("Command [test] failed"))
        }

        @Test func warningsAndMessagesAloneKeepExitCodeZero() async {
            let result = await SwiftCITest.run(["test"]) {
                command(Command("test") {
                    Report.warning("Careful.")
                    Report.message("Checked 3 files.")
                })
            }

            let lines = result.log.map(stripANSI)
            #expect(result.exitCode == 0)
            #expect(lines.contains("<Warning> Careful."))
            #expect(lines.contains("▸ Checked 3 files."))
            #expect(!lines.contains("Command [test] failed"))
        }

        /// The body's error decides the exit code, and the report failure is not added as a second error.
        @Test func bodyErrorDecidesExitCodeOverReportFailure() async {
            let result = await SwiftCITest.run(["test"]) {
                command(Command("test") {
                    Report.failure("Lint failed.")
                    throw BuildError(message: "Body failed.", code: .usage)
                })
            }

            let lines = result.log.map(stripANSI)
            #expect(result.exitCode == 2)
            #expect(lines.filter { $0 == "<Error> Lint failed." }.count == 1)
            #expect(lines.filter { $0 == "<Error> Body failed." }.count == 1)
            #expect(!lines.contains { $0.hasPrefix("<Error> The run report has") })
            #expect(lines.filter { $0.hasPrefix("<Error>") }.count == 2)
        }

        @Test func failureAddedInCleanupFailsCommand() async {
            let result = await SwiftCITest.run(["test"]) {
                command(Command("test") {
                    cleanup { Report.failure("Cleanup finding.") }
                })
            }

            let lines = result.log.map(stripANSI)
            #expect(result.exitCode == 1)
            #expect(lines.filter { $0 == "<Error> Cleanup finding." }.count == 1)
            #expect(lines.filter { $0 == "<Error> The run report has 1 failure(s)." }.count == 1)
        }

        @Test func onFailureRunsWhenOnlyTheReportFailed() async {
            var events: [String] = []
            let result = await SwiftCITest.run(["test"]) {
                command(Command("test") {
                    onFailure { events.append("onFailure") }
                    cleanup { events.append("cleanup") }
                    Report.failure("Lint failed.")
                })
            }

            #expect(result.exitCode == 1)
            #expect(events == ["cleanup", "onFailure"])
        }

        @Test func findingsAreLoggedWhenAdded() async {
            let result = await SwiftCITest.run(["test"]) {
                command(Command("test") {
                    Report.failure("Failure.", file: "Sources/App.swift", line: 12)
                    Report.warning("Warning.", file: "Sources/App.swift")
                    Report.message("Message.", line: 4)
                    Report.failure("Plain failure.")
                })
            }

            let lines = result.log.map(stripANSI)
            #expect(lines.contains("<Error> Sources/App.swift:12: Failure."))
            #expect(lines.contains("<Warning> Sources/App.swift: Warning."))
            #expect(lines.contains("▸ Message."))
            #expect(lines.contains("<Error> Plain failure."))
            #expect(lines.filter { $0.hasPrefix("<Error>") }.count == 3)
        }

        /// `Report.current` in a cleanup handler sees what the body added.
        @Test func currentReportInCleanupSeesBodyFindingsAndSections() async {
            var seen: RunReport?
            let result = await SwiftCITest.run(["test"]) {
                command(Command("test") {
                    Report.warning("Careful.", file: "a.swift", line: 3)
                    Report.markdown("| a |", title: "Table")
                    cleanup { seen = Report.current }
                })
            }

            #expect(result.exitCode == 0)
            #expect(seen?.commandName == "test")
            #expect(seen?.findings == [ReportFinding(severity: .warning, text: "Careful.", file: "a.swift", line: 3)])
            #expect(seen?.sections == [ReportSection(title: "Table", markdown: "| a |")])
            #expect(seen?.outcome == nil)
        }

        /// The report belongs to one command. The second command starts with an empty report.
        @Test func findingsDoNotLeakIntoNextCommand() async {
            var secondFindings: [ReportFinding]?
            let result = await SwiftCITest.run(["a", "b"]) {
                command(Command("a") {
                    Report.warning("From a.")
                })
                command(Command("b") {
                    secondFindings = Report.current.findings
                })
            }

            #expect(result.exitCode == 0)
            #expect(secondFindings == [])
        }

        /// Cleanup handlers run in reverse order, then onFailure handlers in reverse order, then onReport handlers in
        /// registration order, last.
        @Test func reportHandlersRunLastInRegistrationOrder() async {
            var events: [String] = []
            let result = await SwiftCITest.run(["test"]) {
                command(Command("test") {
                    onReport { _ in events.append("r1") }
                    onFailure { events.append("o1") }
                    cleanup { events.append("c1") }
                    onReport { _ in events.append("r2") }
                    onFailure { events.append("o2") }
                    cleanup { events.append("c2") }
                    throw BuildError(message: "Body failed.")
                })
            }

            #expect(result.exitCode == 1)
            #expect(events == ["c2", "c1", "o2", "o1", "r1", "r2"])
        }

        @Test func cleanRunSetsSucceededOutcomeForReportHandler() async {
            var seen: RunReport?
            let result = await SwiftCITest.run(["test"]) {
                command(Command("test") {
                    onReport { seen = $0 }
                })
            }

            #expect(result.exitCode == 0)
            #expect(seen?.outcome == .succeeded)
            #expect(seen?.isClean == true)
        }

        @Test func failedBodySetsFailedOutcomeWithItsMessage() async {
            var seen: RunReport?
            let result = await SwiftCITest.run(["test"]) {
                command(Command("test") {
                    onReport { seen = $0 }
                    throw BuildError(message: "Body failed.", code: .usage)
                })
            }

            #expect(result.exitCode == 2)
            #expect(seen?.outcome == .failed(message: "Body failed."))
        }

        /// The body failed without a report failure, so the command adds the failure once, and does not log it again.
        @Test func rule4AddsCommandFailedFindingOnlyWithoutReportFailures() async {
            var seen: RunReport?
            let result = await SwiftCITest.run(["test"]) {
                command(Command("test") {
                    onReport { seen = $0 }
                    throw TestError.boom
                })
            }

            let lines = result.log.map(stripANSI)
            #expect(result.exitCode == 1)
            #expect(seen?.failures == [ReportFinding(severity: .failure, text: "The command failed: boom")])
            #expect(lines.filter { $0 == "<Error> boom" }.count == 1)
            #expect(!lines.contains { $0.hasPrefix("<Error>") && $0.contains("The command failed:") })
            #expect(lines.filter { $0 == "  failure  The command failed: boom" }.count == 1)
        }

        /// The body failed after a report failure. The report keeps only the failure that was added, and no rule-4 finding.
        @Test func rule4IsNotAppliedWhenReportAlreadyHasFailures() async {
            var seen: RunReport?
            let result = await SwiftCITest.run(["test"]) {
                command(Command("test") {
                    onReport { seen = $0 }
                    Report.failure("Lint failed.")
                    throw BuildError(message: "Body failed.", code: .usage)
                })
            }

            #expect(result.exitCode == 2)
            #expect(seen?.failures.map(\.text) == ["Lint failed."])
            #expect(seen?.outcome == .failed(message: "Body failed."))
        }

        @Test func reportCheckFailureSetsFailedOutcomeWithoutRule4Finding() async {
            var seen: RunReport?
            let result = await SwiftCITest.run(["test"]) {
                command(Command("test") {
                    onReport { seen = $0 }
                    Report.failure("Lint failed.")
                })
            }

            #expect(result.exitCode == 1)
            #expect(seen?.outcome == .failed(message: "The run report has 1 failure(s)."))
            #expect(seen?.findings == [ReportFinding(severity: .failure, text: "Lint failed.")])
        }

        /// The cleanup and onFailure handlers add findings, and the report that onReport receives has them.
        @Test func findingsFromCleanupAndOnFailureReachReportHandler() async {
            var seen: RunReport?
            let result = await SwiftCITest.run(["test"]) {
                command(Command("test") {
                    onReport { seen = $0 }
                    onFailure { Report.message("From onFailure.") }
                    cleanup { Report.warning("From cleanup.") }
                    throw TestError.boom
                })
            }

            #expect(result.exitCode == 1)
            #expect(seen?.warnings.map(\.text) == ["From cleanup."])
            #expect(seen?.messages.map(\.text) == ["From onFailure."])
        }

        /// A failing report handler fails a successful command, and the next report handler still runs and sees the
        /// outcome as it was. The onFailure handlers do not run because of it.
        @Test func failingReportHandlerFailsSuccessfulCommand() async {
            var events: [String] = []
            var secondOutcome: CommandOutcome?
            let result = await SwiftCITest.run(["test"]) {
                command(Command("test") {
                    onFailure { events.append("onFailure") }
                    onReport { _ in
                        events.append("first")
                        throw TestError.boom
                    }
                    onReport { secondOutcome = $0.outcome }
                })
            }

            let lines = result.log.map(stripANSI)
            #expect(result.exitCode == 1)
            #expect(events == ["first"])
            #expect(secondOutcome == .succeeded)
            #expect(lines.contains("Step [Report] failed"))
            #expect(lines.filter { $0 == "<Error> boom" }.count == 1)
            #expect(lines.contains("Command [test] failed"))
        }

        @Test func allowedFailingReportHandlerKeepsExitCodeZero() async {
            var secondRan = false
            let result = await SwiftCITest.run(["test"]) {
                command(Command("test") {
                    onReport(failure: .allowed) { _ in throw TestError.boom }
                    onReport { _ in secondRan = true }
                })
            }

            let lines = result.log.map(stripANSI)
            #expect(result.exitCode == 0)
            #expect(secondRan)
            #expect(lines.contains("Step [Report] failed (allowed)"))
            #expect(lines.filter { $0 == "<Warning> boom" }.count == 1)
            #expect(!lines.contains { $0.hasPrefix("<Error>") })
            #expect(!lines.contains("Command [test] failed"))
        }

        /// The body's failure decides the exit code, so a failing report handler does not change it.
        @Test func failingReportHandlerAfterFailedBodyKeepsBodyCode() async {
            let result = await SwiftCITest.run(["test"]) {
                command(Command("test") {
                    onReport { _ in throw BuildError(message: "Report failed.", code: .internal) }
                    throw BuildError(message: "Body failed.", code: .usage)
                })
            }

            let lines = result.log.map(stripANSI)
            #expect(result.exitCode == 2)
            #expect(lines.filter { $0 == "<Error> Body failed." }.count == 1)
            #expect(lines.filter { $0 == "<Error> Report failed." }.count == 1)
        }

        @Test func reportHandlerIsLoggedAsReportStep() async {
            let result = await SwiftCITest.run(["test"]) {
                command(Command("test") {
                    onReport { _ in }
                })
            }

            #expect(result.exitCode == 0)
            #expect(enteredSteps(in: result.log) == ["Entering step [Report]"])
        }
    }
}
