@testable import SwiftCI
@testable import SwiftCITestSupport
import Foundation
import SwiftCITesting
import Testing

extension GlobalStateTests {
    @Suite(.serialized) struct GitReportTests {
        /// The paths of `git diff HEAD --name-only -z` come from stdout, split on NUL. The check runs in the repository.
        @Test func uncommittedChangesRunsGitDiffInRepository() async throws {
            let repository = try makeRepository()
            defer { removeRepository(repository) }
            let runner = ProcessRunnerMock()
            runner.responses = [response(stdout: "")]

            let result = await SwiftCITest.run(["test"], runner: runner) {
                command(Command("test") {
                    try await Git.reportUncommittedChanges(message: "Commit first.", repository: repository)
                })
            }

            #expect(result.exitCode == 0)
            #expect(runner.tools.count == 1)
            #expect(runner.tools[0].command == "git")
            #expect(runner.tools[0].arguments == ["diff", "HEAD", "--name-only", "-z"])
            #expect(runner.tools[0].workingDirectory == repository)
        }

        /// No changes: nothing is added to the report, and the result is empty.
        @Test func noUncommittedChangesAddsNothingAndReturnsEmpty() async throws {
            let repository = try makeRepository()
            defer { removeRepository(repository) }
            let runner = ProcessRunnerMock()
            var paths: [String]?
            var seen: RunReport?

            let result = await SwiftCITest.run(["test"], runner: runner) {
                command(Command("test") {
                    onReport { seen = $0 }
                    paths = try await Git.reportUncommittedChanges(message: "Commit first.", repository: repository)
                })
            }

            #expect(result.exitCode == 0)
            #expect(paths == [])
            #expect(seen?.findings == [])
            #expect(seen?.sections == [])
        }

        /// Patterns match the whole path, so `*.png` also drops nested files. An exact path drops only that path.
        @Test func ignoredPatternsAreDroppedFromFailureAndSection() async throws {
            let repository = try makeRepository()
            defer { removeRepository(repository) }
            let runner = ProcessRunnerMock()
            runner.responses = [response(stdout: "assets/icon.png\0Sources/App.swift\0nested/deep/logo.png\0Package.resolved\0Sources/Package.resolved\0")]
            var paths: [String]?
            var seen: RunReport?

            let result = await SwiftCITest.run(["test"], runner: runner) {
                command(Command("test") {
                    onReport { seen = $0 }
                    paths = try await Git.reportUncommittedChanges(
                        ignoring: ["*.png", "Package.resolved"],
                        message: "Commit first.",
                        repository: repository
                    )
                })
            }

            #expect(result.exitCode == 1)
            #expect(paths == ["Sources/App.swift", "Sources/Package.resolved"])
            #expect(seen?.failures == [ReportFinding(severity: .failure, text: "Commit first.")])
            #expect(seen?.sections == [ReportSection(
                title: "Uncommitted changes",
                markdown: "- `Sources/App.swift`\n- `Sources/Package.resolved`"
            )])
        }

        /// A path that contains a backtick is wrapped in a longer code fence, so the code span stays valid.
        @Test func pathWithBacktickIsWrappedInLongerCodeFence() async throws {
            let repository = try makeRepository()
            defer { removeRepository(repository) }
            let runner = ProcessRunnerMock()
            runner.responses = [response(stdout: "Notes/with`tick.md\0")]
            var seen: RunReport?

            let result = await SwiftCITest.run(["test"], runner: runner) {
                command(Command("test") {
                    onReport { seen = $0 }
                    try await Git.reportUncommittedChanges(message: "Commit first.", repository: repository)
                })
            }

            #expect(result.exitCode == 1)
            #expect(seen?.sections == [ReportSection(title: "Uncommitted changes", markdown: "- ``Notes/with`tick.md``")])
        }

        /// The step has the default name, or the name that the caller chose.
        @Test func uncommittedChangesStepHasDefaultOrCustomName() async throws {
            let repository = try makeRepository()
            defer { removeRepository(repository) }
            let runner = ProcessRunnerMock()

            let defaultResult = await SwiftCITest.run(["test"], runner: runner) {
                command(Command("test") {
                    try await Git.reportUncommittedChanges(message: "Commit first.", repository: repository)
                })
            }
            let namedResult = await SwiftCITest.run(["test"], runner: runner) {
                command(Command("test") {
                    try await Git.reportUncommittedChanges(
                        message: "Commit first.",
                        repository: repository,
                        step: "Check the tree"
                    )
                })
            }

            #expect(enteredSteps(in: defaultResult.log) == ["Entering step [Check for uncommitted changes]"])
            #expect(enteredSteps(in: namedResult.log) == ["Entering step [Check the tree]"])
        }

        /// A git failure is thrown as an error of the tool, and no finding is added.
        @Test func uncommittedChangesGitFailureThrowsWithoutFinding() async throws {
            let repository = try makeRepository()
            defer { removeRepository(repository) }
            let runner = ProcessRunnerMock()
            runner.responses = [response(stderr: "fatal: not a git repository", exitCode: 128)]
            var caught: BuildError?
            var seen: RunReport?

            let result = await SwiftCITest.run(["test"], runner: runner) {
                command(Command("test") {
                    onReport { seen = $0 }
                    do {
                        try await Git.reportUncommittedChanges(message: "Commit first.", repository: repository)
                    } catch {
                        caught = error as? BuildError
                    }
                })
            }

            #expect(result.exitCode == 0)
            #expect(caught?.message.hasPrefix("git exited with code 128.") == true)
            #expect(seen?.findings == [])
            #expect(seen?.sections == [])
        }

        /// Matches are found in every tracked file, with 1-based line numbers. A CR before the LF is not part of a line,
        /// so a pattern anchored with `$` matches a CRLF line.
        @Test func linesMatchingPatternAreReportedWithFileAndLine() async throws {
            let repository = try makeRepository()
            defer { removeRepository(repository) }
            try writeFile("import Foundation\nlet date = \"YYYY\"\nlet other = \"YYYY\"\n", at: "Sources/App.swift", in: repository)
            try writeFile("let x = 1\r\nlet d = \"YYYY\"\r\nlet e = 2\r\n", at: "Sources/Other.swift", in: repository)
            let runner = ProcessRunnerMock()
            runner.responses = [response(stdout: "Sources/App.swift\0Sources/Other.swift\0")]
            var seen: RunReport?

            let result = await SwiftCITest.run(["test"], runner: runner) {
                command(Command("test") {
                    onReport { seen = $0 }
                    try await Git.reportLines(
                        matching: #"Y{4}"$"#,
                        in: ["*.swift"],
                        message: "Use a fixed date.",
                        repository: repository
                    )
                })
            }

            let expected = [
                ReportFinding(severity: .failure, text: "Use a fixed date.", file: "Sources/App.swift", line: 2),
                ReportFinding(severity: .failure, text: "Use a fixed date.", file: "Sources/App.swift", line: 3),
                ReportFinding(severity: .failure, text: "Use a fixed date.", file: "Sources/Other.swift", line: 2),
            ]
            #expect(result.exitCode == 1)
            #expect(seen?.findings == expected)
            #expect(runner.tools[0].command == "git")
            #expect(runner.tools[0].arguments == ["ls-files", "-z", "--", "*.swift"])
            #expect(runner.tools[0].workingDirectory == repository)
        }

        /// The function returns the findings it added, and the console shows them with their location.
        @Test func linesReturnsAddedFindingsAndLogsThem() async throws {
            let repository = try makeRepository()
            defer { removeRepository(repository) }
            try writeFile("let date = \"YYYY\"\n", at: "App.swift", in: repository)
            let runner = ProcessRunnerMock()
            runner.responses = [response(stdout: "App.swift\0")]
            var returned: [ReportFinding]?

            let result = await SwiftCITest.run(["test"], runner: runner) {
                command(Command("test") {
                    returned = try await Git.reportLines(matching: "Y{4}", in: [], message: "Use a fixed date.", repository: repository)
                })
            }

            let finding = ReportFinding(severity: .failure, text: "Use a fixed date.", file: "App.swift", line: 1)
            #expect(returned == [finding])
            #expect(runner.tools[0].arguments == ["ls-files", "-z", "--"])
            #expect(result.log.map(stripANSI).contains("<Error> App.swift:1: Use a fixed date."))
        }

        @Test func linesWithoutMatchAddNothing() async throws {
            let repository = try makeRepository()
            defer { removeRepository(repository) }
            try writeFile("let date = 2026\n", at: "App.swift", in: repository)
            let runner = ProcessRunnerMock()
            runner.responses = [response(stdout: "App.swift\0")]
            var returned: [ReportFinding]?
            var seen: RunReport?

            let result = await SwiftCITest.run(["test"], runner: runner) {
                command(Command("test") {
                    onReport { seen = $0 }
                    returned = try await Git.reportLines(matching: "Y{4}", in: ["*.swift"], message: "Use a fixed date.", repository: repository)
                })
            }

            #expect(result.exitCode == 0)
            #expect(returned == [])
            #expect(seen?.findings == [])
            #expect(!result.log.map(stripANSI).contains { $0.hasPrefix("<Warning>") || $0.hasPrefix("<Error>") })
        }

        /// A `.warning` match is a finding of severity warning: it does not fail the command.
        @Test func warningSeverityIsHonoured() async throws {
            let repository = try makeRepository()
            defer { removeRepository(repository) }
            try writeFile("let date = \"YYYY\"\n", at: "App.swift", in: repository)
            let runner = ProcessRunnerMock()
            runner.responses = [response(stdout: "App.swift\0")]
            var seen: RunReport?

            let result = await SwiftCITest.run(["test"], runner: runner) {
                command(Command("test") {
                    onReport { seen = $0 }
                    try await Git.reportLines(
                        matching: "Y{4}",
                        in: ["*.swift"],
                        message: "Prefer a fixed date.",
                        severity: .warning,
                        repository: repository
                    )
                })
            }

            let lines = result.log.map(stripANSI)
            #expect(result.exitCode == 0)
            #expect(seen?.warnings == [ReportFinding(severity: .warning, text: "Prefer a fixed date.", file: "App.swift", line: 1)])
            #expect(seen?.failures == [])
            #expect(lines.contains("<Warning> App.swift:1: Prefer a fixed date."))
        }

        /// The pattern is compiled before git runs, so an invalid pattern throws without a tool run. The message names the
        /// pattern.
        @Test func invalidPatternThrowsBeforeGitRuns() async throws {
            let repository = try makeRepository()
            defer { removeRepository(repository) }
            let runner = ProcessRunnerMock()
            var caught: BuildError?

            let result = await SwiftCITest.run(["test"], runner: runner) {
                command(Command("test") {
                    do {
                        try await Git.reportLines(matching: "Y(", in: ["*.swift"], message: "Use a fixed date.", repository: repository)
                    } catch {
                        caught = error as? BuildError
                    }
                })
            }

            #expect(result.exitCode == 0)
            #expect(runner.tools.isEmpty)
            #expect(caught?.message.contains("\"Y(\"") == true)
        }

        /// A file that is not UTF-8 text, and a tracked file that is missing, are skipped with one warning each.
        /// Other files are still checked.
        @Test func unreadableFilesAreSkippedWithWarning() async throws {
            let repository = try makeRepository()
            defer { removeRepository(repository) }
            try writeFile(Data([0xFF, 0xFE, 0x59, 0x59, 0x59, 0x59]), at: "Sources/Latin1.swift", in: repository)
            try writeFile("let date = \"YYYY\"\n", at: "Sources/App.swift", in: repository)
            let runner = ProcessRunnerMock()
            runner.responses = [response(stdout: "Sources/Latin1.swift\0Sources/Deleted.swift\0Sources/App.swift\0")]
            var seen: RunReport?

            let result = await SwiftCITest.run(["test"], runner: runner) {
                command(Command("test") {
                    onReport { seen = $0 }
                    try await Git.reportLines(matching: "Y{4}", in: ["*.swift"], message: "Use a fixed date.", repository: repository)
                })
            }

            let lines = result.log.map(stripANSI)
            #expect(result.exitCode == 1)
            #expect(seen?.findings == [ReportFinding(severity: .failure, text: "Use a fixed date.", file: "Sources/App.swift", line: 1)])
            #expect(lines.filter { $0 == "<Warning> Skipped Sources/Latin1.swift in the line check: it cannot be read as UTF-8 text." }.count == 1)
            #expect(lines.filter { $0 == "<Warning> Skipped Sources/Deleted.swift in the line check: it cannot be read as UTF-8 text." }.count == 1)
            #expect(lines.filter { $0.hasPrefix("<Warning>") }.count == 2)
        }

        /// A failure of the check fails the command, and it is in the report that `onReport` receives.
        @Test func failureFromLinesFailsCommandAndReachesReport() async throws {
            let repository = try makeRepository()
            defer { removeRepository(repository) }
            try writeFile("let date = \"YYYY\"\n", at: "Sources/App.swift", in: repository)
            let runner = ProcessRunnerMock()
            runner.responses = [response(stdout: "Sources/App.swift\0")]
            var seen: RunReport?

            let result = await SwiftCITest.run(["test"], runner: runner) {
                command(Command("test") {
                    onReport { seen = $0 }
                    try await Git.reportLines(matching: "Y{4}", in: ["*.swift"], message: "Use a fixed date.", repository: repository)
                })
            }

            let lines = result.log.map(stripANSI)
            #expect(result.exitCode == 1)
            #expect(seen?.failures == [ReportFinding(severity: .failure, text: "Use a fixed date.", file: "Sources/App.swift", line: 1)])
            #expect(seen?.outcome == .failed(message: "The run report has 1 failure(s)."))
            #expect(lines.contains("<Error> Sources/App.swift:1: Use a fixed date."))
        }

        /// The step has the default name, which includes the pattern, or the name that the caller chose.
        @Test func linesStepHasDefaultOrCustomName() async throws {
            let repository = try makeRepository()
            defer { removeRepository(repository) }
            let runner = ProcessRunnerMock()

            let defaultResult = await SwiftCITest.run(["test"], runner: runner) {
                command(Command("test") {
                    try await Git.reportLines(matching: "Y{4}", in: ["*.swift"], message: "Use a fixed date.", repository: repository)
                })
            }
            let namedResult = await SwiftCITest.run(["test"], runner: runner) {
                command(Command("test") {
                    try await Git.reportLines(
                        matching: "Y{4}",
                        in: ["*.swift"],
                        message: "Use a fixed date.",
                        repository: repository,
                        step: "Check dates"
                    )
                })
            }

            #expect(enteredSteps(in: defaultResult.log) == ["Entering step [Check lines matching Y{4}]"])
            #expect(enteredSteps(in: namedResult.log) == ["Entering step [Check dates]"])
        }

        /// A git failure is thrown as an error of the tool, and no finding is added.
        @Test func linesGitFailureThrowsWithoutFinding() async throws {
            let repository = try makeRepository()
            defer { removeRepository(repository) }
            let runner = ProcessRunnerMock()
            runner.responses = [response(stderr: "fatal: not a git repository", exitCode: 128)]
            var caught: BuildError?
            var seen: RunReport?

            let result = await SwiftCITest.run(["test"], runner: runner) {
                command(Command("test") {
                    onReport { seen = $0 }
                    do {
                        try await Git.reportLines(matching: "Y{4}", in: ["*.swift"], message: "Use a fixed date.", repository: repository)
                    } catch {
                        caught = error as? BuildError
                    }
                })
            }

            #expect(result.exitCode == 0)
            #expect(caught?.message.hasPrefix("git exited with code 128.") == true)
            #expect(seen?.findings == [])
        }

        /// A new folder for the file contents of a test. Its files are written with `writeFile`. The test removes it.
        private func makeRepository() throws -> URL {
            try TemporaryDirectory(name: "git-report-$UUID").url
        }

        private func removeRepository(_ repository: URL) {
            try? FileManager.default.removeItem(at: repository)
        }

        /// Writes `text` as UTF-8 to `path` inside `repository`, creating the folders of `path`.
        private func writeFile(_ text: String, at path: String, in repository: URL) throws {
            try writeFile(Data(text.utf8), at: path, in: repository)
        }

        private func writeFile(_ data: Data, at path: String, in repository: URL) throws {
            let url = repository.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
    }
}
