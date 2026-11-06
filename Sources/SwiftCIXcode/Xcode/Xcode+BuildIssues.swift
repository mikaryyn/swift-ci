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
    /// If `xcresulttool` cannot read the bundle, because it is missing or unreadable, the report gets the failure
    /// `Build results were not found in <path>.` and the function does not throw, as
    /// ``reportTestFailures(resultBundleURL:step:)`` does. The reason, the exit code or the decoding error, is logged as a
    /// warning. Any other error is thrown.
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
                results = try await buildResults(resultBundleURL: resultBundleURL)
            } catch is BuildError {
                Report.failure("Build results were not found in \(resultBundleURL.filePath).")
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

    /// Reads the build results of a result bundle with
    /// `xcrun xcresulttool get build-results --path <bundle> --format json` (Xcode 16 and later).
    /// A query, so it does not open a step.
    ///
    /// - Throws: ``BuildError`` that names the bundle if `xcresulttool` fails or its output cannot be read. The reason is
    ///   also logged as a warning.
    private static func buildResults(resultBundleURL: URL) async throws -> BuildResults {
        @Use var log: Log

        let path = resultBundleURL.filePath
        let tool = Tool(
            command: xcrunPath,
            arguments: ["xcresulttool", "get", "build-results", "--path", path, "--format", "json"],
            filters: [filter(#/./#)]
        )
        let result = try await tool.result()
        guard result.exitCode == 0 else {
            let details = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let message = "Failed to read the build results of the result bundle at '\(path)'. "
                + "xcresulttool exited with code \(result.exitCode)."
                + (details.isEmpty ? "" : " Details: \(details)")
            log.warning(message)
            throw BuildError(message: message)
        }
        do {
            return try JSONDecoder().decode(BuildResults.self, from: Data(result.stdout.utf8))
        } catch {
            let message = "Failed to decode the build results of the result bundle at '\(path)'. Details: \(error)"
            log.warning(message)
            throw BuildError(message: message)
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
        return (repositoryPath(url.filePath), line)
    }

    private static let xcrunPath = "/usr/bin/xcrun"
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
