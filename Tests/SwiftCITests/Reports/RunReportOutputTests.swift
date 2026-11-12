@testable import SwiftCI
@testable import SwiftCITestSupport
import Foundation
import SwiftCITesting
import Testing

extension GlobalStateTests {
    /// The summary of the run report on the console and in the full log, and the Markdown file in the artifacts directory.
    @Suite(.serialized) struct RunReportOutputTests {
        /// An artifacts directory of a test, inside a folder that the test removes.
        private func artifacts() -> URL {
            temporaryArtifactsDirectory()
        }

        private func removeFolder(of artifacts: URL) {
            try? FileManager.default.removeItem(at: artifacts.deletingLastPathComponent())
        }

        private func text(_ url: URL) throws -> String {
            try String(contentsOf: url, encoding: .utf8)
        }

        @Test func emptyReportPrintsAndWritesNothing() async throws {
            let artifacts = artifacts()
            defer { removeFolder(of: artifacts) }

            let result = await SwiftCITest.run(["test"], artifactsDirectory: artifacts) {
                command(Command("test") { try await step("Work") { } })
            }

            let files = try FileManager.default.contentsOfDirectory(atPath: artifacts.filePath)
            #expect(result.exitCode == 0)
            #expect(!result.plainLog.contains("Report"))
            #expect(!result.plainLog.contains { $0.hasPrefix("Saved report") })
            #expect(files == ["logs"])
        }

        /// The summary of a report with every kind of line: a failure with a location, a multi-line warning, a message,
        /// and a titled section with a blank line in its Markdown.
        @Test func consoleSummaryLinesAreExact() async throws {
            let artifacts = artifacts()
            defer { removeFolder(of: artifacts) }

            let result = await SwiftCITest.run(["test"], artifactsDirectory: artifacts) {
                command(Command("test") {
                    Report.warning("Line one\nline two", file: "README.md", line: 3)
                    Report.message("Checked 3 files.")
                    Report.failure("Force unwrap.", file: "Sources/A.swift", line: 12)
                    Report.markdown("| a |\n\nB", title: "Coverage")
                })
            }

            let lines = result.plainLog
            let start = try #require(lines.firstIndex(of: "Report"))
            let end = try #require(lines.firstIndex { $0.hasPrefix("Saved report to file://") })
            #expect(result.exitCode == 1)
            #expect(lines[start - 1] == "")
            #expect(Array(lines[start..<end]) == [
                "Report",
                "  failure  Sources/A.swift:12: Force unwrap.",
                "  warning  README.md:3: Line one",
                "           line two",
                "  message  Checked 3 files.",
                "",
                "  ### Coverage",
                "  | a |",
                "",
                "  B",
            ])
        }

        /// The summary is coloured on the console, and the full log gets it without colours.
        @Test func fullLogHasSummaryWithoutColours() async throws {
            let artifacts = artifacts()
            defer { removeFolder(of: artifacts) }

            let result = await SwiftCITest.run(["test"], artifactsDirectory: artifacts) {
                command(Command("test") { Report.warning("Careful.", file: "a.swift") })
            }

            let fullLog = try text(artifacts.appending(path: "logs/test.log"))
            #expect(result.exitCode == 0)
            #expect(fullLog.contains("\nReport\n  warning  a.swift: Careful.\n"))
            #expect(!fullLog.contains("\u{1B}"))
            #expect(result.log.contains { $0.contains("\u{1B}") && $0.hasSuffix("Careful.") })
        }

        /// The summary comes after the report check, before `onReport`, and before the failed line.
        @Test func summaryComesBeforeReportStepAndFailedLine() async throws {
            let artifacts = artifacts()
            defer { removeFolder(of: artifacts) }

            let result = await SwiftCITest.run(["test"], artifactsDirectory: artifacts) {
                command(Command("test") {
                    onReport { _ in }
                    Report.failure("Lint failed.")
                })
            }

            let lines = result.plainLog
            let summary = try #require(lines.firstIndex(of: "Report"))
            let saved = try #require(lines.firstIndex { $0.hasPrefix("Saved report to file://") })
            let reportStep = try #require(lines.firstIndex(of: "Entering step [Report]"))
            let failed = try #require(lines.firstIndex(of: "Command [test] failed"))
            #expect(summary < saved)
            #expect(saved < reportStep)
            #expect(reportStep < failed)
        }

        /// The file is the Markdown of the report that the `onReport` handler received.
        @Test func artifactFileMatchesReportHandlersReport() async throws {
            let artifacts = artifacts()
            defer { removeFolder(of: artifacts) }

            var received: RunReport?
            let result = await SwiftCITest.run(["build"], artifactsDirectory: artifacts) {
                command(Command("build") {
                    onReport { received = $0 }
                    Report.warning("Careful.", file: "a.swift", line: 1)
                    Report.markdown("Body.", title: "Notes")
                })
            }

            let report = try #require(received)
            let file = try text(artifacts.appending(path: "report-build.md"))
            #expect(result.exitCode == 0)
            #expect(report.outcome == .succeeded)
            #expect(file == MarkdownReport(title: "build").render(report))
        }

        /// A failed command with no findings still writes a file, and the file has the rule-4 failure.
        @Test func failedCommandWithoutFindingsWritesRule4Failure() async throws {
            let artifacts = artifacts()
            defer { removeFolder(of: artifacts) }

            let result = await SwiftCITest.run(["build"], artifactsDirectory: artifacts) {
                command(Command("build") { throw TestError.boom })
            }

            let file = try text(artifacts.appending(path: "report-build.md"))
            #expect(result.exitCode == 1)
            #expect(file.hasPrefix("## build failed\n"))
            #expect(file.contains("|  | The command failed: boom |\n"))
            #expect(result.plainLog.contains("  failure  The command failed: boom"))
        }

        @Test func commandNameIsMadeFileSafe() {
            #expect(fileNameComponent("ship/app:beta") == "ship-app-beta")
            #expect(fileNameComponent("build.test_1-x") == "build.test_1-x")
            #expect(fileNameComponent("a b\\c") == "a-b-c")
        }

        @Test func commandNameWithColonIsUsedInFileName() async throws {
            let artifacts = artifacts()
            defer { removeFolder(of: artifacts) }

            let result = await SwiftCITest.run(["beta:ci"], artifactsDirectory: artifacts) {
                command(Command("beta:ci") { Report.message("Done.") })
            }

            #expect(result.exitCode == 0)
            #expect(FileManager.default.fileExists(atPath: artifacts.appending(path: "report-beta-ci.md").filePath))
        }

        /// A registered secret is masked in the console summary, in the full log and in the file.
        @Test func registeredSecretIsMaskedInSummaryFullLogAndFile() async throws {
            let restore = isolatedGlobalState()
            defer { restore() }
            _ = Secret(value: "s3cret-value")
            let artifacts = artifacts()
            defer { removeFolder(of: artifacts) }

            let result = await SwiftCITest.run(["test"], artifactsDirectory: artifacts) {
                command(Command("test") {
                    Report.failure("Leak s3cret-value here.")
                    Report.markdown("Section s3cret-value.", title: "Notes")
                })
            }

            let fullLog = try text(artifacts.appending(path: "logs/test.log"))
            let file = try text(artifacts.appending(path: "report-test.md"))
            #expect(result.plainLog.contains("  failure  Leak \(SecretRegistry.mask) here."))
            #expect(!result.log.contains { $0.contains("s3cret-value") })
            #expect(fullLog.contains("  failure  Leak \(SecretRegistry.mask) here."))
            #expect(!fullLog.contains("s3cret-value"))
            #expect(file.contains("Section \(SecretRegistry.mask)."))
            #expect(!file.contains("s3cret-value"))
        }

        /// The report file cannot be written because a folder has its name. The command, which succeeded, fails once
        /// with exit code 3. The `onReport` handler still sees the successful outcome.
        @Test func writeFailureFailsSuccessfulCommandOnceAndKeepsOutcome() async throws {
            let artifacts = artifacts()
            defer { removeFolder(of: artifacts) }
            let blocker = artifacts.appending(path: "report-test.md", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: blocker, withIntermediateDirectories: true)

            var seen: CommandOutcome?
            let result = await SwiftCITest.run(["test"], artifactsDirectory: artifacts) {
                command(Command("test") {
                    onReport { seen = $0.outcome }
                    Report.message("Done.")
                })
            }

            let lines = result.log.map(stripANSI)
            #expect(result.exitCode == 3)
            #expect(seen == .succeeded)
            #expect(lines.filter { $0.hasPrefix("<Error>") && $0.contains("Failed to write the run report 'report-test.md'") }.count == 1)
            #expect(lines.contains("Command [test] failed"))
        }
    }
}
