import Foundation
import SwiftCI

/// The temporary clone of a match repository, which the selection reads its files from.
enum MatchCheckout {
    /// Clones the repository once, shallow, into a new temporary directory with mode 0700, runs `body` with the
    /// checkout's URL, and deletes the directory afterwards, also when `body` or the clone throws.
    ///
    /// The clone uses `credentials`: its URL has no user information, and its header is in its environment. A failed clone
    /// throws, and `body` does not run. A failure to delete the directory after a successful `body` throws a
    /// ``BuildError`` that names the directory. After a failed `body`, the error of `body` is thrown.
    static func withCheckout<T>(
        branch: String,
        credentials: GitCredentials,
        _ body: (URL) async throws -> T
    ) async throws -> T {
        try await TemporaryDirectory.withDirectory(name: "match-$UUID", holding: "the match repository") { directory in
            let checkout = directory.childURL(name: "repository")
            // `--` ends the options, so a URL that starts with a dash is not read as one.
            try await Tool(
                command: "/usr/bin/git",
                arguments: ["clone", "--depth", "1", "--branch", branch, "--", credentials.url, checkout.filePath],
                environment: credentials.environment,
                filters: [consoleFilter]
            ).run()
            return try await body(checkout)
        }
    }

    /// Hides the line `Cloning into '<temporary directory>'...`. The step logs the clone itself, and the line only shows
    /// a temporary path. Other lines, such as errors and warnings, are shown. The full log keeps every line.
    static let consoleFilter: Filter = { line in
        line.hasPrefix("Cloning into ") ? nil : line
    }
}
