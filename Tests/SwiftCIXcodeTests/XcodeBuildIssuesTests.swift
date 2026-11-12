@testable import SwiftCIXcode
@testable import SwiftCITestSupport
import Foundation
@testable import SwiftCI
import SwiftCITesting
import Testing

extension GlobalStateTests {
    /// `Xcode.reportBuildIssues` with a mock runner, so no `xcresulttool` is started. The findings are read from the
    /// run report. The mapping is fed with the recordings in `Fixtures/XcodebuildTest` and with small JSON of the same
    /// schema.
    @Suite(.serialized) struct XcodeBuildIssuesTests {
        static let resultBundleURL = URL(filePath: "/work/Sample.xcresult")

        /// Runs `reportBuildIssues` in a command and returns the run's result and the final report.
        static func run(
            _ runner: ProcessRunnerMock,
            resultBundleURL: URL = resultBundleURL,
            includeWarnings: Bool = false,
            step name: String? = nil
        ) async -> (result: SwiftCITestResult, report: RunReport?) {
            var seen: RunReport?
            let result = await SwiftCITest.run(["report"]) {
                register(ProcessRunner.self, runner)
                command(Command("report") {
                    onReport { seen = $0 }
                    try await Xcode.reportBuildIssues(
                        resultBundleURL: resultBundleURL,
                        includeWarnings: includeWarnings,
                        step: name
                    )
                })
            }
            return (result, seen)
        }

        /// The recorded `xcresulttool get build-results` output named `name` in `Fixtures/XcodebuildTest`.
        static func fixtureJSON(_ name: String) throws -> String {
            let url = try #require(Bundle.module.resourceURL?.appending(path: "Fixtures/XcodebuildTest/\(name)"))
            return try String(contentsOf: url, encoding: .utf8)
        }

        /// The recorded warning of the sample package, `unused` in `SampleKit`, with its path as the bundle gives it.
        static let warningPath = "/Users/ci/git/swift-ci/Tests/SwiftCIXcodeTests/Fixtures/XcodebuildTest/"
            + "sample/Sources/SampleKit/SampleKit.swift"

        /// The recorded compile error of a copy of the sample package in `/tmp`.
        static let compileErrorPath = "/private/tmp/sci-sample-compile-error/Sources/SampleKit/Broken.swift"

        /// The recorded warning is one warning at its line. The line is zero-based in the bundle and shown one higher.
        @Test func recordedWarningIsAddedWithItsLineWhenWarningsAreIncluded() async throws {
            let runner = ProcessRunnerMock()
            runner.responses = [.init(stdout: try Self.fixtureJSON("build-results-warning.json"))]

            let (result, report) = await Self.run(runner, includeWarnings: true)

            #expect(result.exitCode == 0)
            #expect(report?.failures.isEmpty == true)
            #expect(report?.warnings == [
                ReportFinding(
                    severity: .warning,
                    text: "Initialization of immutable value 'unused' was never used; "
                        + "consider replacing with assignment to '_' or removing it",
                    file: Self.warningPath,
                    line: 10
                )
            ])
        }

        /// Warnings are off by default, so the recorded warning adds nothing and the command passes.
        @Test func recordedWarningIsNotAddedUnlessRequested() async throws {
            let runner = ProcessRunnerMock()
            runner.responses = [.init(stdout: try Self.fixtureJSON("build-results-warning.json"))]

            let (result, report) = await Self.run(runner)

            #expect(result.exitCode == 0)
            #expect(report?.findings == [])
        }

        /// The recorded compile error adds one failure without a location, and one failure at its line.
        @Test func recordedCompileErrorAddsTheFailuresWithTheirLocations() async throws {
            let runner = ProcessRunnerMock()
            runner.responses = [.init(stdout: try Self.fixtureJSON("build-results-compile-error.json"))]

            let (result, report) = await Self.run(runner)

            #expect(result.exitCode == 1)
            #expect(report?.failures == [
                ReportFinding(severity: .failure, text: "Testing cancelled because the build failed."),
                ReportFinding(
                    severity: .failure,
                    text: "Cannot convert return expression of type 'String' to return type 'Int'",
                    file: Self.compileErrorPath,
                    line: 2
                )
            ])
            #expect(report?.warnings == [])
        }

        /// The exact `xcresulttool` arguments of the build results.
        @Test func readsTheBundleWithTheBuildResultsArguments() async throws {
            let runner = ProcessRunnerMock()
            runner.responses = [.init(stdout: try Self.fixtureJSON("build-results-warning.json"))]

            _ = await Self.run(runner)

            #expect(runner.tools.count == 1)
            #expect(runner.tools[0].command == "/usr/bin/xcrun")
            #expect(runner.tools[0].arguments == [
                "xcresulttool", "get", "build-results", "--path", "/work/Sample.xcresult", "--format", "json"
            ])
        }

        /// A location inside the current directory is written relative to it. The line is one higher than the URL's.
        @Test func locationInsideTheCurrentDirectoryIsRelative() async throws {
            let path = FileManager.default.currentDirectoryPath + "/Sources/App/App.swift"
            let inside = URL(filePath: path).absoluteString
            let runner = ProcessRunnerMock()
            runner.responses = [.init(stdout: Self.errorJSON(
                sourceURL: inside + "#StartingColumnNumber=2&StartingLineNumber=4"
            ))]

            let (_, report) = await Self.run(runner)

            #expect(report?.failures == [
                ReportFinding(
                    severity: .failure,
                    text: "Cannot find 'x' in scope",
                    file: "Sources/App/App.swift",
                    line: 5
                )
            ])
        }

        /// A location outside the current directory stays as the bundle gives it. A line of 0 is the first line.
        @Test func locationOutsideTheCurrentDirectoryIsKept() async throws {
            let runner = ProcessRunnerMock()
            runner.responses = [.init(stdout: Self.errorJSON(
                sourceURL: "file:///work/App/Sources/App.swift#StartingColumnNumber=0&StartingLineNumber=0"
            ))]

            let (_, report) = await Self.run(runner)

            #expect(report?.failures == [
                ReportFinding(
                    severity: .failure,
                    text: "Cannot find 'x' in scope",
                    file: "/work/App/Sources/App.swift",
                    line: 1
                )
            ])
        }

        /// A `sourceURL` without a readable line keeps the file and has no line. A URL without a fragment has no line.
        @Test func malformedFragmentKeepsTheFileWithoutLine() async throws {
            let runner = ProcessRunnerMock()
            runner.responses = [.init(stdout: """
            {"errors":[
              {"issueType":"Swift Compiler Error","message":"first",
               "sourceURL":"file:///work/App.swift#StartingLineNumber=x&StartingColumnNumber=4"},
              {"issueType":"Swift Compiler Error","message":"second","sourceURL":"file:///work/Other.swift"}
            ]}
            """)]

            let (_, report) = await Self.run(runner)

            #expect(report?.failures == [
                ReportFinding(severity: .failure, text: "first", file: "/work/App.swift"),
                ReportFinding(severity: .failure, text: "second", file: "/work/Other.swift")
            ])
        }

        /// An error without `sourceURL` is a failure without a file and line, and a source URL that is not a file URL
        /// gives no location either.
        @Test func errorWithoutSourceURLHasNoFileAndLine() async throws {
            let runner = ProcessRunnerMock()
            runner.responses = [.init(stdout: """
            {"errors":[
              {"issueType":"Uncategorized","message":"Testing cancelled because the build failed."},
              {"issueType":"Swift Compiler Error","message":"web",
               "sourceURL":"https://example.com/App.swift#StartingLineNumber=3"}
            ]}
            """)]

            let (_, report) = await Self.run(runner)

            #expect(report?.failures == [
                ReportFinding(severity: .failure, text: "Testing cancelled because the build failed."),
                ReportFinding(severity: .failure, text: "web")
            ])
        }

        /// Analyzer warnings are warnings, added after the warnings, and only with `includeWarnings`.
        @Test func analyzerWarningsAreWarningsWhenIncluded() async throws {
            let json = """
            {"warnings":[{"issueType":"NoUsage","message":"unused",
              "sourceURL":"file:///work/App.swift#StartingLineNumber=0"}],
             "analyzerWarnings":[{"issueType":"Analyzer","message":"never read",
              "sourceURL":"file:///work/App.swift#StartingLineNumber=2"}]}
            """
            let runner = ProcessRunnerMock()
            runner.responses = [.init(stdout: json), .init(stdout: json)]

            let (_, included) = await Self.run(runner, includeWarnings: true)
            let (_, excluded) = await Self.run(runner)

            #expect(included?.warnings == [
                ReportFinding(severity: .warning, text: "unused", file: "/work/App.swift", line: 1),
                ReportFinding(severity: .warning, text: "never read", file: "/work/App.swift", line: 3)
            ])
            #expect(excluded?.findings == [])
        }

        /// A list that the output does not have counts as empty, so a bundle without build issues passes.
        @Test func outputWithoutIssueListsAddsNothing() async throws {
            let runner = ProcessRunnerMock()
            runner.responses = [.init(stdout: "{}")]

            let (result, report) = await Self.run(runner, includeWarnings: true)

            #expect(result.exitCode == 0)
            #expect(report?.findings == [])
        }

        /// A bundle that `xcresulttool` cannot open, because it is missing, adds one failure with its path and does not
        /// throw. The exit code and the details of `xcresulttool` are logged as a warning.
        @Test func missingBundleAddsOneFailureAndDoesNotThrow() async throws {
            let runner = ProcessRunnerMock()
            runner.responses = [.init(stderr: "error: unable to open the bundle", exitCode: 1)]

            let (result, report) = await Self.run(runner, resultBundleURL: URL(filePath: "/work/Missing.xcresult"))

            #expect(result.exitCode == 1)
            #expect(runner.tools.count == 1)
            #expect(report?.findings == [
                ReportFinding(
                    severity: .failure,
                    text: "Build results could not be read: Failed to read the build results of the result bundle at '/work/Missing.xcresult'. xcresulttool exited with code 1. Details: error: unable to open the bundle"
                )
            ])
        }

        /// A bundle whose output is not JSON adds a failure with the decoding error and does not throw.
        @Test func unreadableOutputAddsOneFailureAndDoesNotThrow() async throws {
            let runner = ProcessRunnerMock()
            runner.responses = [.init(stdout: "not json")]

            let (result, report) = await Self.run(runner)

            #expect(result.exitCode == 1)
            #expect(report?.findings.count == 1)
            let text = try #require(report?.findings.first?.text)
            #expect(text.hasPrefix("Build results could not be read: Failed to decode the build results of the result bundle at '/work/Sample.xcresult'. Details: "))
        }

        /// The step opens "Report build issues" at the top level of a command, and `step:` renames it.
        @Test func stepNameIsLoggedAndCanBeChanged() async throws {
            let runner = ProcessRunnerMock()
            runner.responses = [
                .init(stdout: try Self.fixtureJSON("build-results-warning.json")),
                .init(stdout: try Self.fixtureJSON("build-results-warning.json"))
            ]

            let (defaultResult, _) = await Self.run(runner)
            let (namedResult, _) = await Self.run(runner, step: "Report the build")

            #expect(enteredSteps(in: defaultResult.log).first == "Entering step [Report build issues]")
            #expect(enteredSteps(in: namedResult.log).first == "Entering step [Report the build]")
        }

        /// A build error in the report fails the command, with the exit code of a failed command.
        @Test func errorFailsTheCommandInSwiftCITestRun() async throws {
            let runner = ProcessRunnerMock()
            runner.responses = [.init(stdout: try Self.fixtureJSON("build-results-compile-error.json"))]

            let (result, _) = await Self.run(runner)

            let lines = result.log.map(stripANSI)
            #expect(result.exitCode == 1)
            #expect(lines.contains(
                "<Error> \(Self.compileErrorPath):2: "
                    + "Cannot convert return expression of type 'String' to return type 'Int'"
            ))
            #expect(lines.contains("<Error> The run report has 2 failure(s)."))
        }

        /// The JSON of one error with `sourceURL`, as the bundle gives it.
        static func errorJSON(sourceURL: String) -> String {
            """
            {"errors":[{"issueType":"Swift Compiler Error","message":"Cannot find 'x' in scope",
              "sourceURL":"\(sourceURL)"}]}
            """
        }
    }
}
