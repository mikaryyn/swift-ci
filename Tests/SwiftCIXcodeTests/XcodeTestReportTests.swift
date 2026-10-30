@testable import SwiftCIXcode
@testable import SwiftCITestSupport
import Foundation
@testable import SwiftCI
import SwiftCITesting
import Testing

extension GlobalStateTests {
    /// `Xcode.testReport` and `Xcode.writeJUnitReport`, with a mock runner, so no `xcresulttool` is started. The
    /// mapping is tested with the recording in `Fixtures/XcodebuildTest` and with small JSON of the same schema.
    @Suite(.serialized) struct XcodeTestReportTests {
        static let resultBundleURL = URL(filePath: "/work/Sample.xcresult")

        /// The recorded `xcresulttool get test-results tests` output of the sample package (Xcode 27.2).
        static func fixtureJSON() throws -> String {
            let url = try #require(
                Bundle.module.resourceURL?.appending(path: "Fixtures/XcodebuildTest/test-results-tests.json")
            )
            return try String(contentsOf: url, encoding: .utf8)
        }

        @Test func testReportMapsTheRecordedResults() async throws {
            let (_, runner) = registerToolMocks()
            runner.responses = [response(stdout: try Self.fixtureJSON())]

            let report = try await Xcode.testReport(resultBundleURL: Self.resultBundleURL)

            #expect(report == Self.fixtureReport)
            #expect(report.tests == 9)
            #expect(report.failures == 5)
            #expect(report.skipped == 2)
            #expect(runner.tools.count == 1)
            #expect(runner.tools[0].command == "/usr/bin/xcrun")
            #expect(runner.tools[0].arguments == [
                "xcresulttool", "get", "test-results", "tests", "--path", "/work/Sample.xcresult", "--format", "json"
            ])
        }

        /// "Expected Failure" is a pass, and its messages are not reported.
        @Test func expectedFailureCountsAsPassed() async throws {
            let (_, runner) = registerToolMocks()
            runner.responses = [response(stdout: Self.expectedFailureJSON)]

            let report = try await Xcode.testReport(resultBundleURL: Self.resultBundleURL)

            #expect(report == TestReport(suites: [
                TestSuite(name: "AppTests.FlakyTests", cases: [
                    TestCase(className: "AppTests.FlakyTests", name: "testKnownBug()", duration: 0.5, result: .passed)
                ])
            ]))
        }

        /// Repetitions are one case, with the messages of all runs and the result of the case.
        @Test func repetitionsAreOneCaseWithTheMessagesOfAllRuns() async throws {
            let (_, runner) = registerToolMocks()
            runner.responses = [response(stdout: Self.repetitionsJSON)]

            let report = try await Xcode.testReport(resultBundleURL: Self.resultBundleURL)

            #expect(report == TestReport(suites: [
                TestSuite(name: "AppTests.RetryTests", cases: [
                    TestCase(
                        className: "AppTests.RetryTests",
                        name: "testRetried()",
                        duration: 2,
                        result: .failed(messages: [
                            "first run\n/work/AppTests/RetryTests.swift:7",
                            "second run"
                        ])
                    )
                ])
            ]))
        }

        /// Each device has its own suite, with the device name appended. Nodes that the mapping does not know are
        /// skipped, and their children are still searched.
        @Test func twoDevicesGiveOneSuitePerDevice() async throws {
            let (_, runner) = registerToolMocks()
            runner.responses = [response(stdout: Self.twoDevicesJSON)]

            let report = try await Xcode.testReport(resultBundleURL: Self.resultBundleURL)

            #expect(report == TestReport(suites: [
                TestSuite(name: "AppTests.LoginTests (iPhone 17)", cases: [
                    TestCase(
                        className: "AppTests.LoginTests (iPhone 17)",
                        name: "testLogin()",
                        duration: 1,
                        result: .passed
                    )
                ]),
                TestSuite(name: "AppTests.LoginTests (iPad Air)", cases: [
                    TestCase(
                        className: "AppTests.LoginTests (iPad Air)",
                        name: "testLogin()",
                        duration: 1.5,
                        result: .failed(messages: ["not logged in"])
                    )
                ])
            ]))
        }

        @Test func unknownNodeTypesAreSkippedButTheirChildrenAreSearched() async throws {
            let (_, runner) = registerToolMocks()
            runner.responses = [response(stdout: Self.unknownNodeJSON)]

            let report = try await Xcode.testReport(resultBundleURL: Self.resultBundleURL)

            #expect(report == TestReport(suites: [
                TestSuite(name: "AppTests.Unknown", cases: [
                    TestCase(className: "AppTests.Unknown", name: "testA()", duration: 0.1, result: .passed)
                ])
            ]))
        }

        /// A failing `xcresulttool` is a `BuildError` that names the bundle and gives its details.
        @Test func testReportFailingNamesTheBundle() async {
            let (_, runner) = registerToolMocks()
            runner.responses = [response(stderr: "error: unable to open the bundle", exitCode: 1)]

            let error = await thrownError {
                _ = try await Xcode.testReport(resultBundleURL: URL(filePath: "/work/NotABundle.xcresult"))
            }

            #expect(error?.message == """
                Failed to read the test results of the result bundle at '/work/NotABundle.xcresult'. \
                xcresulttool exited with code 1. Details: error: unable to open the bundle
                """)
        }

        @Test func testReportWithUnreadableOutputNamesTheBundle() async {
            let (_, runner) = registerToolMocks()
            runner.responses = [response(stdout: "not json")]

            let error = await thrownError {
                _ = try await Xcode.testReport(resultBundleURL: Self.resultBundleURL)
            }

            let prefix = "Failed to decode the test results of the result bundle "
                + "at '/work/Sample.xcresult'."
            #expect(error?.message.hasPrefix(prefix) == true)
        }

        /// The report is written to the file as the JUnit XML of the fixture, in a step named "Write JUnit report".
        @Test func writeJUnitReportWritesTheSuitesInAStep() async throws {
            let runner = ProcessRunnerMock()
            runner.responses = [response(stdout: try Self.fixtureJSON())]
            let dir = try TemporaryDirectory(name: "XcodeTestReportTests-$UUID")
            defer { try? FileManager.default.removeItem(at: dir.url) }
            let url = dir.childURL(name: "reports/junit.xml")

            let result = await SwiftCITest.run(["junit"]) {
                register(ProcessRunner.self, runner)
                command(Command("junit") {
                    try await Xcode.writeJUnitReport(resultBundleURL: Self.resultBundleURL, to: url)
                })
            }

            #expect(result.exitCode == 0)
            #expect(enteredSteps(in: result.log) == ["Entering step [Write JUnit report]"])
            #expect(runner.tools.count == 1)
            let written = try String(contentsOf: url, encoding: .utf8)
            #expect(written.contains(
                #"<testsuite name="SampleXCTests.SampleXCTests" tests="4" failures="2" skipped="1""#
            ))
            #expect(written.contains(
                #"<testsuite name="SampleSwiftTestingTests.SampleSwiftTestingTests" tests="5" failures="3" skipped="1""#
            ))
            #expect(written == JUnit.xml(for: Self.fixtureReport))
        }

        @Test func writeJUnitReportStepNameCanBeChanged() async throws {
            let runner = ProcessRunnerMock()
            runner.responses = [response(stdout: try Self.fixtureJSON())]
            let dir = try TemporaryDirectory(name: "XcodeTestReportTests-$UUID")
            defer { try? FileManager.default.removeItem(at: dir.url) }
            let url = dir.childURL(name: "junit.xml")

            let result = await SwiftCITest.run(["named"]) {
                register(ProcessRunner.self, runner)
                command(Command("named") {
                    try await Xcode.writeJUnitReport(
                        resultBundleURL: Self.resultBundleURL, to: url, step: "Report the tests"
                    )
                })
            }

            #expect(result.exitCode == 0)
            #expect(enteredSteps(in: result.log) == ["Entering step [Report the tests]"])
        }

        /// The JSON of the cases below, in the schema of `xcresulttool get test-results tests`.
        static let expectedFailureJSON = #"""
        {"testNodes":[{"nodeType":"Unit test bundle","name":"AppTests","children":[
          {"nodeType":"Test Suite","name":"FlakyTests","children":[
            {"nodeType":"Test Case","name":"testKnownBug()","result":"Expected Failure",
              "durationInSeconds":0.5,"children":[
              {"nodeType":"Failure Message","name":"XCTAssertTrue failed"}
            ]}
          ]}
        ]}]}
        """#

        static let repetitionsJSON = #"""
        {"testNodes":[{"nodeType":"Unit test bundle","name":"AppTests","children":[
          {"nodeType":"Test Suite","name":"RetryTests","children":[
            {"nodeType":"Test Case","name":"testRetried()","result":"Failed","durationInSeconds":2,"children":[
              {"nodeType":"Repetition","name":"Repetition 1 of 2","children":[
                {"nodeType":"Test Case Run","name":"Run 1","result":"Failed","children":[
                  {"nodeType":"Failure Message","name":"first run",
                   "sourceLocation":{"filePath":"/work/AppTests/RetryTests.swift","lineNumber":7}}
                ]}
              ]},
              {"nodeType":"Repetition","name":"Repetition 2 of 2","children":[
                {"nodeType":"Test Case Run","name":"Run 2","result":"Failed","children":[
                  {"nodeType":"Failure Message","name":"second run"}
                ]}
              ]}
            ]}
          ]}
        ]}]}
        """#

        static let twoDevicesJSON = #"""
        {"testNodes":[{"nodeType":"Test Plan","name":"App","children":[
          {"nodeType":"Test Plan Configuration","name":"Configuration 1","children":[
            {"nodeType":"Device","name":"iPhone 17","children":[
              {"nodeType":"Unit test bundle","name":"AppTests","children":[
                {"nodeType":"Test Suite","name":"LoginTests","children":[
                  {"nodeType":"Test Case","name":"testLogin()","result":"Passed","durationInSeconds":1}
                ]}
              ]}
            ]},
            {"nodeType":"Device","name":"iPad Air","children":[
              {"nodeType":"Unit test bundle","name":"AppTests","children":[
                {"nodeType":"Test Suite","name":"LoginTests","children":[
                  {"nodeType":"Test Case","name":"testLogin()","result":"Failed","durationInSeconds":1.5,"children":[
                    {"nodeType":"Failure Message","name":"not logged in"}
                  ]}
                ]}
              ]}
            ]}
          ]}
        ]}]}
        """#

        static let unknownNodeJSON = #"""
        {"testNodes":[{"nodeType":"Unit test bundle","name":"AppTests","children":[
          {"nodeType":"Something New","name":"wrapper","children":[
            {"nodeType":"Test Suite","name":"Unknown","children":[
              {"nodeType":"Test Case","name":"testA()","result":"Passed","durationInSeconds":0.1,"children":[
                {"nodeType":"Attachment","name":"screenshot.png"}
              ]}
            ]}
          ]}
        ]}]}
        """#
    }
}

extension GlobalStateTests.XcodeTestReportTests {
    /// The report of the recording. Each suite is named after its bundle and its type, for example
    /// `SampleXCTests.SampleXCTests`. `parameterized(value:)` fails for the argument 2, and that is its one
    /// message.
    static let fixtureReport = TestReport(suites: [
        TestSuite(name: "SampleXCTests.SampleXCTests", cases: [
            TestCase(
                className: "SampleXCTests.SampleXCTests",
                name: "testFailsOnMismatch()",
                duration: 1.07869291305542,
                result: .failed(messages: [
                    "XCTAssertEqual failed: (\"2\") is not equal to (\"3\") - addition is wrong\n" +
                        "/tmp/sci-sample/Tests/SampleXCTests/SampleXCTests.swift:10"
                ])
            ),
            TestCase(
                className: "SampleXCTests.SampleXCTests",
                name: "testFailsTwice()",
                duration: 0.002753019332885742,
                result: .failed(messages: [
                    "XCTAssertEqual failed: (\"Hello, A\") is not equal to (\"Hello, B\") - first message\n" +
                        "/tmp/sci-sample/Tests/SampleXCTests/SampleXCTests.swift:18",
                    "XCTAssertTrue failed - second message\n" +
                        "/tmp/sci-sample/Tests/SampleXCTests/SampleXCTests.swift:19"
                ])
            ),
            TestCase(
                className: "SampleXCTests.SampleXCTests",
                name: "testPasses()",
                duration: 0.0012160539627075195,
                result: .passed
            ),
            TestCase(
                className: "SampleXCTests.SampleXCTests",
                name: "testSkipped()",
                duration: 0.012356996536254883,
                result: .skipped(message: "Test skipped - skipped on purpose")
            )
        ]),
        TestSuite(name: "SampleSwiftTestingTests.SampleSwiftTestingTests", cases: [
            TestCase(
                className: "SampleSwiftTestingTests.SampleSwiftTestingTests",
                name: "disabled()",
                duration: 0,
                result: .skipped(message: "Test skipped: disabled on purpose")
            ),
            TestCase(
                className: "SampleSwiftTestingTests.SampleSwiftTestingTests",
                name: "throwsError()",
                duration: 0.008658170700073242,
                result: .failed(messages: [
                    "Caught error: SampleError()\n" +
                        "/tmp/sci-sample/Tests/SampleSwiftTestingTests/SampleSwiftTestingTests.swift:26"
                ])
            ),
            TestCase(
                className: "SampleSwiftTestingTests.SampleSwiftTestingTests",
                name: "parameterized(value:)",
                duration: 0.002878109614054362,
                result: .failed(messages: [
                    "Expectation failed: value != 2\n" +
                        "value → 2: argument 2 is rejected\n" +
                        "/tmp/sci-sample/Tests/SampleSwiftTestingTests/SampleSwiftTestingTests.swift:22"
                ])
            ),
            TestCase(
                className: "SampleSwiftTestingTests.SampleSwiftTestingTests",
                name: "passes()",
                duration: 1.2874603271484375e-05,
                result: .passed
            ),
            TestCase(
                className: "SampleSwiftTestingTests.SampleSwiftTestingTests",
                name: "failsOnMismatch()",
                duration: 0.009226799011230469,
                result: .failed(messages: [
                    "Expectation failed: sum(1, 1) == 3\n" +
                        "sum(1, 1) → 2: addition is wrong\n" +
                        "/tmp/sci-sample/Tests/SampleSwiftTestingTests/SampleSwiftTestingTests.swift:12"
                ])
            )
        ])
    ])
}
