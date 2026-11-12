import Foundation
import SwiftCI

public extension Xcode {
    /// Runs `xcodebuild test` and writes the result bundle to `resultBundleURL`.
    ///
    /// `destination` is passed as `-destination`. Without it, the destination of this `Xcode` value is used. A test run
    /// needs a concrete destination, such as `platform=iOS Simulator,name=iPhone 17,OS=latest`. The default destination,
    /// `generic/platform=iOS`, fails in `xcodebuild` for tests.
    ///
    /// An existing bundle at `resultBundleURL` is removed first, because `xcodebuild` refuses to write over it. Its parent
    /// directory is created if it is missing. `enableCodeCoverage` sets `-enableCodeCoverage` to `YES` or `NO`.
    /// `testPlan` is passed as `-testPlan`, to run a test plan of the scheme other than its default one.
    ///
    /// The console shows the failing and skipped tests with their issues, and the summary lines. Passing tests are
    /// hidden. It also shows the lines of the test infrastructure that report a failure, such as a lost connection to
    /// the simulator or a test runner that exited early. See ``testOutputFilter()``.
    /// If `rawLogURL` is set, every line of the output goes to that file unfiltered (see ``Tool/outputFile``).
    ///
    /// If `xcodebuild` exits with a non-zero code, the error names the scheme and the exit code, and gives the path of the
    /// result bundle if the bundle exists. The bundle and the raw log are complete then, so a caller can catch the error,
    /// read them, and rethrow.
    ///
    /// `timeout` ends `xcodebuild` after that duration. The error then says the tests did not finish, and names the
    /// result bundle and the raw log if they exist. There is no default timeout: a run that is stuck, for example while
    /// the simulator diagnostics are collected, is not ended without one.
    ///
    /// Opens a step named "Test MyApp" when called at the top level of a command. `step` renames it.
    func test(
        destination: String? = nil,
        testPlan: String? = nil,
        resultBundleURL: URL,
        rawLogURL: URL? = nil,
        enableCodeCoverage: Bool = true,
        timeout: Duration? = nil,
        step name: String? = nil
    ) async throws {
        try await step(default: "Test \(stepSubject)", name: name) {
            try prepareResultBundle(at: resultBundleURL)
            var baseArguments = [
                "test",
                "-resultBundlePath", resultBundleURL.filePath,
                "-enableCodeCoverage", enableCodeCoverage ? "YES" : "NO"
            ]
            if let testPlan {
                baseArguments += ["-testPlan", testPlan]
            }
            let result: ToolResult
            do {
                result = try await withArguments(baseArguments, destination: destination) { arguments in
                    let tool = Tool(
                        command: Self.xcodebuildPath,
                        arguments: arguments,
                        timeout: timeout,
                        filters: [Self.testOutputFilter()],
                        outputFile: rawLogURL
                    )
                    return try await tool.result()
                }
            } catch let error as BuildError where error.code == .timeout {
                let outcome = "did not finish within \(timeout ?? .zero), so it was ended. The tests did not complete."
                throw BuildError(
                    message: testRunMessage(outcome, resultBundleURL: resultBundleURL, rawLogURL: rawLogURL),
                    code: .timeout
                )
            }
            guard result.exitCode == 0 else {
                let outcome = "exited with code \(result.exitCode)."
                throw BuildError(message: testRunMessage(outcome, resultBundleURL: resultBundleURL))
            }
        }
    }
}

extension Xcode {
    /// Removes an existing result bundle at `url`, and creates its parent directory.
    private func prepareResultBundle(at url: URL) throws {
        if FileManager.default.fileExists(atPath: url.filePath) {
            log("Removing existing result bundle \(url.filePath)")
            try FileManager.default.removeItem(at: url)
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    /// The message of a test run that ended with `outcome`. It names the scheme, and gives the paths of the result bundle
    /// and the raw log if they exist.
    private func testRunMessage(_ outcome: String, resultBundleURL: URL, rawLogURL: URL? = nil) -> String {
        let subject = scheme.map { "scheme '\($0)'" } ?? "the Xcode project"
        var message = "xcodebuild test of \(subject) \(outcome)"
        if FileManager.default.fileExists(atPath: resultBundleURL.filePath) {
            message += " The result bundle is at '\(resultBundleURL.filePath)'."
        }
        if let rawLogURL, FileManager.default.fileExists(atPath: rawLogURL.filePath) {
            message += " The raw log is at '\(rawLogURL.filePath)'."
        }
        return message
    }
}
