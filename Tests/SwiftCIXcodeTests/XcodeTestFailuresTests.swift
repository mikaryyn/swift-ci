@testable import SwiftCIXcode
@testable import SwiftCITestSupport
import Foundation
@testable import SwiftCI
import SwiftCITesting
import Testing

extension GlobalStateTests {
    /// `Xcode.reportTestFailures` with a mock runner, so no `xcresulttool` is started. The findings are read from the
    /// run report. The mapping is fed with the recording in `Fixtures/XcodebuildTest` and with small JSON of the same
    /// schema.
    @Suite(.serialized) struct XcodeTestFailuresTests {
        static let resultBundleURL = URL(filePath: "/work/Sample.xcresult")

        /// Runs `reportTestFailures` in a command and returns the run's result and the final report.
        static func run(
            _ runner: ProcessRunnerMock,
            resultBundleURL: URL = resultBundleURL,
            step name: String? = nil
        ) async -> (result: SwiftCITestResult, report: RunReport?) {
            var seen: RunReport?
            let result = await SwiftCITest.run(["report"]) {
                register(ProcessRunner.self, runner)
                command(Command("report") {
                    onReport { seen = $0 }
                    try await Xcode.reportTestFailures(resultBundleURL: resultBundleURL, step: name)
                })
            }
            return (result, seen)
        }

        /// A result bundle with one XCTest class `AppTests.LoginTests` and one case, with `children` as its nodes.
        static func singleCaseJSON(result: String, children: String) -> String {
            """
            {"testNodes":[{"nodeType":"Unit test bundle","name":"AppTests","children":[
              {"nodeType":"Test Suite","name":"LoginTests","children":[
                {"nodeType":"Test Case","name":"testLogin()","result":"\(result)","durationInSeconds":1,"children":[
                  \(children)
                ]}
              ]}
            ]}]}
            """
        }

        static let fixtureFailures = [
            "`SampleXCTests.SampleXCTests.testFailsOnMismatch()` failed: "
                + "XCTAssertEqual failed: (\"2\") is not equal to (\"3\") - addition is wrong",
            "`SampleXCTests.SampleXCTests.testFailsTwice()` failed: "
                + "XCTAssertEqual failed: (\"Hello, A\") is not equal to (\"Hello, B\") - first message\n"
                + "XCTAssertTrue failed - second message",
            "`SampleSwiftTestingTests.SampleSwiftTestingTests.throwsError()` failed: Caught error: SampleError()",
            "`SampleSwiftTestingTests.SampleSwiftTestingTests.parameterized(value:)` failed: "
                + "Expectation failed: value != 2",
            "`SampleSwiftTestingTests.SampleSwiftTestingTests.failsOnMismatch()` failed: "
                + "Expectation failed: sum(1, 1) == 3"
        ]

        /// The recorded findings: one failure per failed case, and the totals.
        @Test func fixtureAddsOneFailurePerFailedCaseAndTheTotals() async throws {
            let runner = ProcessRunnerMock()
            runner.responses = [response(stdout: try GlobalStateTests.XcodeTestReportTests.fixtureJSON())]

            let (result, report) = await Self.run(runner)

            #expect(result.exitCode == 1)
            #expect(report?.findings.map(\.text) == Self.fixtureFailures + ["9 tests, 5 failed, 2 skipped"])
            let sample = "/tmp/sci-sample/Tests/"
            #expect(report?.failures.map { "\($0.file ?? ""):\($0.line ?? 0)" } == [
                "\(sample)SampleXCTests/SampleXCTests.swift:10",
                "\(sample)SampleXCTests/SampleXCTests.swift:18",
                "\(sample)SampleSwiftTestingTests/SampleSwiftTestingTests.swift:26",
                "\(sample)SampleSwiftTestingTests/SampleSwiftTestingTests.swift:22",
                "\(sample)SampleSwiftTestingTests/SampleSwiftTestingTests.swift:12"
            ])
            #expect(report?.messages.map(\.text) == ["9 tests, 5 failed, 2 skipped"])
        }

        /// The exact `xcresulttool` arguments, the same as `testReport`.
        @Test func readsTheBundleWithTheSameArgumentsAsTheJUnitReport() async throws {
            let runner = ProcessRunnerMock()
            runner.responses = [response(stdout: try GlobalStateTests.XcodeTestReportTests.fixtureJSON())]

            _ = await Self.run(runner)

            #expect(runner.tools.count == 1)
            #expect(runner.tools[0].command == "/usr/bin/xcrun")
            #expect(runner.tools[0].arguments == [
                "xcresulttool", "get", "test-results", "tests", "--path", "/work/Sample.xcresult", "--format", "json"
            ])
        }

        /// A failure without a source location has no file and no line.
        @Test func failureWithoutLocationHasNoFileAndLine() async throws {
            let runner = ProcessRunnerMock()
            runner.responses = [response(stdout: Self.singleCaseJSON(
                result: "Failed",
                children: #"{"nodeType":"Failure Message","name":"not logged in"}"#
            ))]

            let (_, report) = await Self.run(runner)

            #expect(report?.failures == [
                ReportFinding(severity: .failure, text: "`AppTests.LoginTests.testLogin()` failed: not logged in")
            ])
        }

        /// A location inside the current directory is written relative to it.
        @Test func locationInsideTheCurrentDirectoryIsRelative() async throws {
            let inside = FileManager.default.currentDirectoryPath + "/Tests/AppTests/LoginTests.swift"
            let runner = ProcessRunnerMock()
            runner.responses = [response(stdout: Self.singleCaseJSON(
                result: "Failed",
                children: """
                {"nodeType":"Failure Message","name":"not logged in",\
                "sourceLocation":{"filePath":"\(inside)","lineNumber":4}}
                """
            ))]

            let (_, report) = await Self.run(runner)

            #expect(report?.failures == [
                ReportFinding(
                    severity: .failure,
                    text: "`AppTests.LoginTests.testLogin()` failed: not logged in",
                    file: "Tests/AppTests/LoginTests.swift",
                    line: 4
                )
            ])
        }

        /// A location outside the current directory stays as the bundle gives it.
        @Test func locationOutsideTheCurrentDirectoryIsKept() async throws {
            let runner = ProcessRunnerMock()
            runner.responses = [response(stdout: Self.singleCaseJSON(
                result: "Failed",
                children: """
                {"nodeType":"Failure Message","name":"not logged in",\
                "sourceLocation":{"filePath":"/work/AppTests/LoginTests.swift","lineNumber":4}}
                """
            ))]

            let (_, report) = await Self.run(runner)

            #expect(report?.failures == [
                ReportFinding(
                    severity: .failure,
                    text: "`AppTests.LoginTests.testLogin()` failed: not logged in",
                    file: "/work/AppTests/LoginTests.swift",
                    line: 4
                )
            ])
        }

        /// The location is the first one of the messages. A message without a location is skipped for it, and the
        /// further messages are added on new lines, each with its first line only.
        @Test func severalMessagesAreOneFailureWithTheFirstLocation() async throws {
            let runner = ProcessRunnerMock()
            runner.responses = [response(stdout: Self.singleCaseJSON(
                result: "Failed",
                children: """
                {"nodeType":"Failure Message","name":"first\\nwith detail"},
                {"nodeType":"Failure Message","name":"second",\
                "sourceLocation":{"filePath":"/work/LoginTests.swift","lineNumber":9}},
                {"nodeType":"Failure Message","name":"third",\
                "sourceLocation":{"filePath":"/work/Other.swift","lineNumber":30}}
                """
            ))]

            let (_, report) = await Self.run(runner)

            #expect(report?.failures == [
                ReportFinding(
                    severity: .failure,
                    text: "`AppTests.LoginTests.testLogin()` failed: first\nsecond\nthird",
                    file: "/work/LoginTests.swift",
                    line: 9
                )
            ])
        }

        /// A test that expects a failure passes, so it adds no finding; the totals count it as passed.
        @Test func expectedFailureAddsNoFindingAndCountsAsPassed() async throws {
            let runner = ProcessRunnerMock()
            runner.responses = [response(stdout: Self.singleCaseJSON(
                result: "Expected Failure",
                children: #"{"nodeType":"Failure Message","name":"XCTAssertTrue failed"}"#
            ))]

            let (result, report) = await Self.run(runner)

            #expect(result.exitCode == 0)
            #expect(report?.findings == [
                ReportFinding(severity: .message, text: "1 tests, 0 failed, 0 skipped")
            ])
        }

        /// A failed case with no message still adds a failure, without a message after the name.
        @Test func failedCaseWithoutMessageAddsAFailure() async throws {
            let runner = ProcessRunnerMock()
            runner.responses = [response(stdout: Self.singleCaseJSON(result: "Failed", children: ""))]

            let (_, report) = await Self.run(runner)

            #expect(report?.failures.map(\.text) == ["`AppTests.LoginTests.testLogin()` failed."])
        }

        /// A bundle without failures adds only the totals, and the command succeeds.
        @Test func passingBundleAddsOnlyTheTotals() async throws {
            let runner = ProcessRunnerMock()
            runner.responses = [response(stdout: GlobalStateTests.XcodeTestReportTests.unknownNodeJSON)]

            let (result, report) = await Self.run(runner)

            #expect(result.exitCode == 0)
            #expect(report?.findings == [
                ReportFinding(severity: .message, text: "1 tests, 0 failed, 0 skipped")
            ])
        }

        /// A bundle that `xcresulttool` cannot open, because it is missing, adds one failure with its path and does not
        /// throw. The exit code and the details of `xcresulttool` are logged as a warning.
        @Test func missingBundleAddsOneFailureAndDoesNotThrow() async throws {
            let runner = ProcessRunnerMock()
            runner.responses = [response(stderr: "error: unable to open the bundle", exitCode: 1)]

            let (result, report) = await Self.run(runner, resultBundleURL: URL(filePath: "/work/Missing.xcresult"))

            let lines = result.log.map(stripANSI)
            #expect(result.exitCode == 1)
            #expect(runner.tools.count == 1)
            #expect(report?.findings == [
                ReportFinding(severity: .failure, text: "Test results were not found in /work/Missing.xcresult.")
            ])
            #expect(lines.contains(
                "<Warning> Failed to read the test results of the result bundle at '/work/Missing.xcresult'. xcresulttool exited with code 1. Details: error: unable to open the bundle"
            ))
        }

        /// A bundle whose output is not JSON adds the same failure and does not throw. The decoding error is logged as a
        /// warning.
        @Test func unreadableOutputAddsOneFailureAndDoesNotThrow() async throws {
            let runner = ProcessRunnerMock()
            runner.responses = [response(stdout: "not json")]

            let (result, report) = await Self.run(runner)

            let lines = result.log.map(stripANSI)
            #expect(result.exitCode == 1)
            #expect(report?.findings == [
                ReportFinding(severity: .failure, text: "Test results were not found in /work/Sample.xcresult.")
            ])
            #expect(lines.contains { $0.hasPrefix("<Warning> Failed to decode the test results of the result bundle at '/work/Sample.xcresult'. Details: ") })
        }

        /// The step opens "Report test results" at the top level of a command, and `step:` renames it.
        @Test func stepNameIsLoggedAndCanBeChanged() async throws {
            let runner = ProcessRunnerMock()
            runner.responses = [
                response(stdout: try GlobalStateTests.XcodeTestReportTests.fixtureJSON()),
                response(stdout: try GlobalStateTests.XcodeTestReportTests.fixtureJSON())
            ]

            let (defaultResult, _) = await Self.run(runner)
            let (namedResult, _) = await Self.run(runner, step: "Report the tests")

            #expect(enteredSteps(in: defaultResult.log).first == "Entering step [Report test results]")
            #expect(enteredSteps(in: namedResult.log).first == "Entering step [Report the tests]")
        }

        /// A failure in the report fails the command, with the exit code of a failed command.
        @Test func failureFailsTheCommandInSwiftCITestRun() async throws {
            let runner = ProcessRunnerMock()
            runner.responses = [response(stdout: try GlobalStateTests.XcodeTestReportTests.fixtureJSON())]

            let (result, _) = await Self.run(runner)

            let lines = result.log.map(stripANSI)
            let firstFailure = "/tmp/sci-sample/Tests/SampleXCTests/SampleXCTests.swift:10: " + Self.fixtureFailures[0]
            #expect(result.exitCode == 1)
            #expect(lines.contains("<Error> " + firstFailure))
            #expect(lines.contains("<Error> The run report has 5 failure(s)."))
            #expect(lines.contains("▸ 9 tests, 5 failed, 2 skipped"))
        }
    }
}
