import Foundation
import SwiftCI

extension Xcode {
    /// Adds the build issues of a result bundle to the run report: each error of the build as a failure, and with
    /// `includeWarnings` each warning and analyzer warning as a warning.
    ///
    /// Each entry of `errors` adds one failure, as ``Report/failure(_:file:line:)``, with its message. Each entry of
    /// `warnings` and `analyzerWarnings` adds one warning, as ``Report/warning(_:file:line:)``. Warnings are off by
    /// default, because a project that gates its warnings with its own allowlist would see them twice.
    ///
    /// An entry with a `sourceURL` gets its file, relative to the current directory when it is inside it, and its line.
    /// The line in the URL is zero-based, so the report shows the line that the compiler prints: one higher. An entry
    /// without a `sourceURL` has no file and no line. The build's "Testing cancelled because the build failed." is such
    /// an entry, so it is a failure without a location.
    ///
    /// If `xcresulttool` cannot read the bundle, because it is missing, unreadable or in a format that is not understood,
    /// the report gets the failure `Build results could not be read: <reason>` and the function does not throw, as
    /// ``reportTestFailures(resultBundleURL:step:)`` does. The reason is the message of the ``BuildError``: the exit code
    /// and the output of `xcresulttool`, or the decoding error. Any other error is thrown.
    ///
    /// Opens a step named "Report build issues" when called at the top level of a command. `step` renames it.
    public static func reportBuildIssues(
        resultBundleURL: URL,
        includeWarnings: Bool = false,
        step name: String? = nil
    ) async throws {
        try await step(default: "Report build issues", name: name) {
            let results: BuildResults
            do {
                results = try await readXCResult(
                    "build results", subcommand: ["build-results"], of: resultBundleURL, as: BuildResults.self
                )
            } catch let error as BuildError {
                reportUnreadable("Build results", error: error)
                return
            }

            for issue in results.errors ?? [] {
                let location = sourceLocation(of: issue.sourceURL)
                Report.failure(issue.message, file: location?.file, line: location?.line)
            }
            guard includeWarnings else {
                return
            }
            for issue in (results.warnings ?? []) + (results.analyzerWarnings ?? []) {
                let location = sourceLocation(of: issue.sourceURL)
                Report.warning(issue.message, file: location?.file, line: location?.line)
            }
        }
    }

    /// The file and line of a `sourceURL`, such as
    /// `file:///path#EndingColumnNumber=…&StartingColumnNumber=…&StartingLineNumber=…`.
    /// The line is zero-based in the URL and is returned one higher. Without a readable `StartingLineNumber`, only the
    /// file is returned. Returns nil if there is no file URL.
    private static func sourceLocation(of sourceURL: String?) -> (file: String, line: Int?)? {
        guard let sourceURL, let url = URL(string: sourceURL), url.isFileURL, !url.filePath.isEmpty else {
            return nil
        }
        let fields = Dictionary(
            (url.fragment ?? "").split(separator: "&").compactMap { field -> (String, String)? in
                let parts = field.split(separator: "=", maxSplits: 1)
                return parts.count == 2 ? (String(parts[0]), String(parts[1])) : nil
            },
            uniquingKeysWith: { first, _ in first }
        )
        let line = fields["StartingLineNumber"].flatMap { Int($0) }.map { $0 + 1 }
        return (repositoryRelativePath(url), line)
    }

}

/// The part of the `xcresulttool get build-results` JSON that the report uses. Other fields are ignored. A list that is
/// missing from the output counts as empty.
private struct BuildResults: Decodable {
    var errors: [BuildIssue]?
    var warnings: [BuildIssue]?
    var analyzerWarnings: [BuildIssue]?
}

/// An error or a warning of the build. `sourceURL` is missing for an issue without a location.
private struct BuildIssue: Decodable {
    var message: String
    var sourceURL: String?
}
