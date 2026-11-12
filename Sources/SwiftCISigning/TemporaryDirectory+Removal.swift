import Foundation
import SwiftCI

extension TemporaryDirectory {
    /// Runs `body` with a new directory, and removes the directory afterwards, also when `body` throws. The directory
    /// has mode 0700.
    ///
    /// After a failed `body`, its error is thrown, and a failed removal does not replace it. A failure to remove the
    /// directory after a successful `body` throws a ``BuildError`` that names the directory and says what it holds.
    ///
    /// - Parameters:
    ///   - name: The template of the directory name, as in ``init(name:)``.
    ///   - holding: What the directory holds, for the error of a failed removal, such as `the match repository`.
    static func withDirectory<T>(
        name: String,
        holding: String,
        _ body: (TemporaryDirectory) async throws -> T
    ) async throws -> T {
        let directory = try TemporaryDirectory(name: name)
        let value: T
        do {
            value = try await body(directory)
        } catch {
            try? directory.remove()
            throw error
        }
        do {
            try directory.remove()
        } catch {
            throw BuildError(
                message: "Couldn't remove the temporary directory \(directory.url.filePath), which holds \(holding). "
                    + "Remove it by hand."
            )
        }
        return value
    }
}
