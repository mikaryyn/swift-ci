import Foundation
import SwiftCI

extension Xcode {
    /// Adds the failed tests of a result bundle to the run report, with the totals of the run.
    ///
    /// Each failed test case adds one failure, as ``Report/failure(_:file:line:)``:
    /// `` `Suite.testName()` failed: <message> ``. The suite and the name are the ones that the JUnit report uses, such
    /// as `` `MyAppTests.LoginTests.testLogin()` ``. The message is the first line of the first failure message. Each
    /// further message of the same test is added on a new line of the same text, with its first line. A Swift Testing
    /// parameterized test is one case, named `parameterized(value:)`, so its failure does not show the argument that
    /// failed. The failure has the file and line of the first failure message that has a location. The file is relative
    /// to the current directory when it is inside it.
    ///
    /// The last finding is a message with the totals: `N tests, M failed, K skipped`. A test with an expected failure
    /// counts as passed, and a disabled test counts as skipped, as in the JUnit report.
    ///
    /// If `xcresulttool` cannot read the bundle, because it is missing or unreadable, the report gets the failure
    /// `Test results were not found in <path>.` instead, and the function does not throw. The reason, the exit code or
    /// the decoding error, is logged as a warning. Any other error is thrown.
    ///
    /// Opens a step named "Report test results" when called at the top level of a command. `step` renames it.
    public static func reportTestFailures(resultBundleURL: URL, step name: String? = nil) async throws {
        try await step(default: "Report test results", name: name) {
            let results: TestResults
            do {
                results = try await testResults(resultBundleURL: resultBundleURL)
            } catch is BuildError {
                Report.failure("Test results were not found in \(resultBundleURL.filePath).")
                return
            }

            for test in results.failures {
                addFailure(test)
            }
            let report = results.report
            Report.message("\(report.tests) tests, \(report.failures) failed, \(report.skipped) skipped")
        }
    }

    /// Adds the failure of `test` to the run report, at the location of its first message that has one.
    private static func addFailure(_ test: FailedTest) {
        let identifier = "`\(test.className).\(test.name)`"
        let text = test.messages.isEmpty
            ? "\(identifier) failed."
            : "\(identifier) failed: " + test.messages.map { firstLine(of: $0.text) }.joined(separator: "\n")
        let location = test.messages.compactMap(\.location).first
        Report.failure(text, file: location.map { repositoryPath($0.filePath) }, line: location?.lineNumber)
    }

    /// The path relative to the current directory if it is inside it, otherwise the path itself.
    static func repositoryPath(_ path: String) -> String {
        let prefix = FileManager.default.currentDirectoryPath + "/"
        guard path.hasPrefix(prefix) else {
            return path
        }
        return String(path.dropFirst(prefix.count))
    }

    private static func firstLine(of text: String) -> String {
        text.components(separatedBy: .newlines).first ?? ""
    }
}
