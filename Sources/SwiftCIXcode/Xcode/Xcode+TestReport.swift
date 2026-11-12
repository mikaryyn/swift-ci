import Foundation
import SwiftCI

extension Xcode {
    /// Reads the test results of a result bundle with `xcrun xcresulttool get test-results tests` (Xcode 16 and
    /// later) and maps them to a ``TestReport``.
    ///
    /// The mapping:
    /// - A "Unit test bundle" or "UI test bundle" node names the bundle. A "Test Suite" node adds its name, so a
    ///   nested suite is `Bundle.Outer.Inner`. The suite name is the bundle prefix of the class name, for example
    ///   `MyAppTests.LoginTests`. A test case that is not in a suite, as a top-level Swift Testing test, takes the
    ///   bundle name only.
    /// - A "Test Case" node becomes a case, with the test's name, such as `testLogin()` or `parameterized(value:)`, and
    ///   `durationInSeconds` (0 if missing). Its class name is the suite name.
    /// - The result is `Passed` or `Expected Failure`: passed. `Failed`: failed, with the messages of all runs.
    ///   `Skipped`: skipped, with the first "Skip Message".
    /// - Each "Failure Message" below the case, in "Arguments", "Repetition", "Test Case Run" or any other node, is one
    ///   message. A source location is added on a second line as `path:line`.
    /// - "Device" nodes are flattened. When the tree has more than one device, the device name is appended to the suite
    ///   name, as `Bundle.Suite (iPhone 17)`.
    /// - Suites with the same name are one suite, in the order of the tree. Other node types are not mapped, but their
    ///   children are searched, so a case below them is still found.
    ///
    /// A query: does not open a step.
    ///
    /// - Throws: ``BuildError`` that names the bundle if `xcresulttool` fails or its output cannot be read.
    public static func testReport(resultBundleURL: URL) async throws -> TestReport {
        try await testResults(resultBundleURL: resultBundleURL).report
    }

    /// Reads the test results of a result bundle, as ``testReport(resultBundleURL:)`` does, and keeps the failed cases
    /// with the location of each message. A query, so it does not open a step.
    ///
    /// - Throws: ``BuildError`` that names the bundle, as ``testReport(resultBundleURL:)`` does.
    static func testResults(resultBundleURL: URL) async throws -> TestResults {
        let results = try await readXCResult(
            "test results", subcommand: ["test-results", "tests"], of: resultBundleURL, as: TestResultsJSON.self
        )
        return TestResultsMapping.map(results.testNodes)
    }

    /// Writes the test report of a result bundle as JUnit XML to `url`, with ``testReport(resultBundleURL:)`` and
    /// ``JUnit/write(_:to:)``.
    ///
    /// Opens a step named "Write JUnit report" when called at the top level of a command. `step` renames it.
    public static func writeJUnitReport(resultBundleURL: URL, to url: URL, step name: String? = nil) async throws {
        try await step(default: "Write JUnit report", name: name) {
            let report = try await testReport(resultBundleURL: resultBundleURL)
            try JUnit.write(report, to: url)
        }
    }
}
