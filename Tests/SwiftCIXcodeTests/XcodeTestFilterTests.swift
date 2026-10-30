@testable import SwiftCIXcode
@testable import SwiftCITestSupport
import Foundation
@testable import SwiftCI
import SwiftCITesting
import Testing

extension GlobalStateTests {
    /// The console filter of `Xcode.test` (``Xcode/testOutputFilter()``): small cases, the recording of a failing run
    /// (`Fixtures/XcodebuildTest`) through `Xcode.test`, and `--verbose`.
    @Suite(.serialized) struct XcodeTestFilterTests {
        /// The lines that a tool shows for `lines`, with one new filter.
        private func shown(_ lines: [String]) -> [String] {
            let filter = Xcode.testOutputFilter()
            return lines.flatMap(filter)
        }

        /// The console lines that the tool printed in the step: the lines between "Entering step [" and the line that
        /// reports the failed step. The log lines around them are not the tool's.
        private func toolLines(_ result: SwiftCITestResult) -> [String] {
            let lines = result.plainLog
            let start = lines.firstIndex { $0.hasPrefix("Entering step [") }.map { $0 + 1 } ?? 0
            let end = lines[start...].firstIndex { $0.hasPrefix("Step [") } ?? lines.count
            return Array(lines[start..<end])
        }

        /// The lines of the recording, as the runner delivers them: stdout, one line per entry.
        private func recordingLines() throws -> [String] {
            let url = try #require(
                Bundle.module.resourceURL?.appending(path: "Fixtures/XcodebuildTest/xcodebuild-test-failing.log")
            )
            var lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
            if lines.last == "" {
                lines.removeLast()
            }
            return lines
        }

        /// Runs `Xcode.test` on the recording with a mock runner, in a command, with the given arguments. The run
        /// fails with exit code 65, as `xcodebuild` did when the recording was made.
        private func runTestOnRecording(arguments: [String]) async throws -> SwiftCITestResult {
            let runner = ProcessRunnerMock()
            runner.responses = [ProcessRunnerMock.Response(
                lines: try recordingLines().map(stdoutLine),
                result: ToolResult(stdout: "", stderr: "", exitCode: 65)
            )]
            let xcode = Xcode(
                workspace: URL(filePath: "/work/SampleApp.xcworkspace"),
                scheme: "SampleApp",
                config: .init(xcconfig: [:])
            )
            let root = FileManager.default.temporaryDirectory
                .appending(path: "xcode-test-filter-\(UUID().uuidString)", directoryHint: .isDirectory)
            defer { try? FileManager.default.removeItem(at: root) }
            let bundle = root.appending(path: "Sample.xcresult", directoryHint: .isDirectory)

            return await SwiftCITest.run(arguments) {
                register(ProcessRunner.self, runner)
                command(Command("check") {
                    try await xcode.test(resultBundleURL: bundle)
                })
            }
        }

        /// The console of the recorded failing run: the warning of the build, the XCTest and Swift Testing failures with
        /// their issues and detail lines, the skipped tests and their reasons, the summaries, and the failing tests list.
        /// The passing tests, the started and finished lines, the Swift Testing progress and the
        /// `↳ Testing Library Version` and `↳ Target Platform` lines are hidden.
        @Test func consoleShowsTheFailuresOfTheRecording() async throws {
            let result = try await runTestOnRecording(arguments: ["check"])

            #expect(toolLines(result) == [
                "/private/tmp/sci-sample/Sources/SampleKit/SampleKit.swift:10:9: warning: initialization of immutable "
                    + "value 'unused' was never used; consider replacing with assignment to '_' or removing it [#NoUsage]",
                "/tmp/sci-sample/Tests/SampleXCTests/SampleXCTests.swift:10: error: "
                    + "-[SampleXCTests.SampleXCTests testFailsOnMismatch] : XCTAssertEqual failed: (\"2\") is not equal to "
                    + "(\"3\") - addition is wrong",
                "Test Case '-[SampleXCTests.SampleXCTests testFailsOnMismatch]' failed (1.079 seconds).",
                "/tmp/sci-sample/Tests/SampleXCTests/SampleXCTests.swift:18: error: "
                    + "-[SampleXCTests.SampleXCTests testFailsTwice] : XCTAssertEqual failed: (\"Hello, A\") is not equal to "
                    + "(\"Hello, B\") - first message",
                "/tmp/sci-sample/Tests/SampleXCTests/SampleXCTests.swift:19: error: "
                    + "-[SampleXCTests.SampleXCTests testFailsTwice] : XCTAssertTrue failed - second message",
                "Test Case '-[SampleXCTests.SampleXCTests testFailsTwice]' failed (0.003 seconds).",
                "/tmp/sci-sample/Tests/SampleXCTests/SampleXCTests.swift:14: "
                    + "-[SampleXCTests.SampleXCTests testSkipped] : Test skipped - skipped on purpose",
                "Test Case '-[SampleXCTests.SampleXCTests testSkipped]' skipped (0.012 seconds).",
                "\t Executed 4 tests, with 1 test skipped and 3 failures (0 unexpected) in 1.095 (1.097) seconds",
                "\t Executed 4 tests, with 1 test skipped and 3 failures (0 unexpected) in 1.095 (1.098) seconds",
                "\t Executed 4 tests, with 1 test skipped and 3 failures (0 unexpected) in 1.095 (1.100) seconds",
                "\t Executed 0 tests, with 0 failures (0 unexpected) in 0.000 (0.001) seconds",
                "\u{200B}➜ Test disabled() skipped: \"disabled on purpose\"",
                "✘ Test parameterized(value:) recorded an issue with 1 argument value → 2 at "
                    + "SampleSwiftTestingTests.swift:22:9: Expectation failed: value != 2",
                "↳ argument 2 is rejected",
                "↳ value != 2 → false",
                "↳   value → 2",
                "\u{200B}✘ Test throwsError() recorded an issue at SampleSwiftTestingTests.swift:25:6: "
                    + "Caught error: SampleError()",
                "✘ Test parameterized(value:) with 3 test cases failed after 0.008 seconds with 1 issue.",
                "✘ Test failsOnMismatch() recorded an issue at SampleSwiftTestingTests.swift:12:9: "
                    + "Expectation failed: sum(1, 1) == 3",
                "↳ addition is wrong",
                "↳ sum(1, 1) == 3 → false",
                "↳   sum(1, 1) → 2",
                "✘ Test throwsError() failed after 0.009 seconds with 1 issue.",
                "✘ Test failsOnMismatch() failed after 0.009 seconds with 1 issue.",
                "✘ Suite SampleSwiftTestingTests failed after 0.009 seconds with 3 issues.",
                "✘ Test run with 5 tests in 1 suite failed after 0.012 seconds with 3 issues.",
                "Test session results, code coverage, and logs:",
                "\t/tmp/sci-sample/out/Sample.xcresult",
                "Failing tests:",
                "\tSampleXCTests.testFailsOnMismatch()",
                "\tSampleXCTests.testFailsTwice()",
                "\tSampleXCTests.testFailsTwice()",
                "\tSampleSwiftTestingTests.throwsError()",
                "\t-[SampleSwiftTestingTests parameterized(value:)]",
                "\tSampleSwiftTestingTests.failsOnMismatch()",
                "** TEST FAILED **",
            ])
        }

        /// `--verbose` shows every line of the recording, the passing tests included, as the tool printed it.
        @Test func verboseShowsEveryLineOfTheRecording() async throws {
            let result = try await runTestOnRecording(arguments: ["check", "--verbose"])
            let lines = try recordingLines()

            #expect(toolLines(result) == lines)
        }

        /// The zero-width space that Swift Testing puts before a line is kept, and the line is shown as it was written.
        @Test func zeroWidthSpaceIsKeptOnShownLines() {
            let issue = "\u{200B}✘ Test throwsError() recorded an issue at MyAppTests.swift:25:6: Caught error: SampleError()"
            let detail = "↳ argument 2 is rejected"

            #expect(shown([issue, detail]) == [issue, detail])
        }

        /// The colour codes do not hide a line, and the shown line keeps them.
        @Test func colourCodesDoNotHideALine() {
            let issue = "\u{1B}[31m✘ Test failsOnMismatch() recorded an issue at MyAppTests.swift:12:9: Expectation failed\u{1B}[0m"
            let detail = "\u{1B}[2m↳ addition is wrong\u{1B}[0m"

            #expect(shown([issue, detail]) == [issue, detail])
        }

        /// Passing tests and their progress lines are hidden, in XCTest and in Swift Testing.
        @Test(arguments: [
            "Test Suite 'All tests' started at 2026-10-30 11:36:03.483.",
            "Test Case '-[MyAppTests testPasses]' started.",
            "Test Case '-[MyAppTests testPasses]' passed (0.001 seconds).",
            "Test Suite 'MyAppTests' passed at 2026-10-30 11:36:04.582.",
            "◇ Test passes() started.",
            "\u{200B}✔ Test passes() passed after 0.001 seconds.",
        ])
        func passingTestsAreHidden(line: String) {
            #expect(shown([line]).isEmpty)
        }

        /// A `↳` line shows only after an issue line. Here it follows the run start and a `✘` line that is not an issue.
        @Test func detailLinesAfterANonIssueLineAreHidden() {
            let lines = [
                "◇ Test run started.",
                "↳ Testing Library Version: 2403",
                "↳ Target Platform: arm64-apple-ios17.0-simulator",
                "✘ Test throwsError() failed after 0.009 seconds with 1 issue.",
                "↳ something that follows a failed test",
            ]

            #expect(shown(lines) == ["✘ Test throwsError() failed after 0.009 seconds with 1 issue."])
        }

        /// The indented lines after "Failing tests:" are shown, up to the blank line that ends the list.
        @Test func indentedListEndsAtTheFirstLineThatIsNotIndented() {
            let lines = ["Failing tests:", "\tMyAppTests.testFails()", "", "\tMyAppTests.testOther()"]

            #expect(shown(lines) == ["Failing tests:", "\tMyAppTests.testFails()"])
        }
    }
}
