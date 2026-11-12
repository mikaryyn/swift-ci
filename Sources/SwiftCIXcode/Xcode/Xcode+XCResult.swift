import Foundation
import SwiftCI

extension Xcode {
    /// Reads one part of a result bundle with `xcrun xcresulttool get <subcommand> --path <bundle> --format json` and
    /// decodes it. A query, so it does not open a step. `what` names the part in the messages, such as "test results".
    ///
    /// - Throws: ``BuildError`` that names the bundle if `xcresulttool` fails or its output cannot be decoded.
    static func readXCResult<T: Decodable>(
        _ what: String,
        subcommand: [String],
        of resultBundleURL: URL,
        as type: T.Type
    ) async throws -> T {
        let path = resultBundleURL.filePath
        let tool = Tool(
            command: xcrunPath,
            arguments: ["xcresulttool", "get"] + subcommand + ["--path", path, "--format", "json"],
            filters: [filter(#/./#)]
        )
        let result = try await tool.result()
        guard result.exitCode == 0 else {
            let details = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw BuildError(
                message: "Failed to read the \(what) of the result bundle at '\(path)'. "
                    + "xcresulttool exited with code \(result.exitCode)."
                    + (details.isEmpty ? "" : " Details: \(details)")
            )
        }
        do {
            return try JSONDecoder().decode(T.self, from: Data(result.stdout.utf8))
        } catch {
            throw BuildError(message: "Failed to decode the \(what) of the result bundle at '\(path)'. Details: \(error)")
        }
    }

    /// Adds the failure of a result bundle that could not be read to the run report. The reason is on one line, because
    /// the text of a finding is one paragraph.
    static func reportUnreadable(_ what: String, error: BuildError) {
        let reason = error.message
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        Report.failure("\(what) could not be read: \(reason)")
    }
}
