import Foundation
import SwiftCI

/// The keychain of a match install, found by its name or by its path.
enum MatchKeychainPath {
    /// The file of the keychain `name`. A `name` with a `/` is a path, and it is used as it is. Otherwise the keychain is
    /// `<keychainsDirectory>/<name>-db` if that file exists, or else `<keychainsDirectory>/<name>`. Throws a ``BuildError``
    /// if no such file exists.
    static func resolve(name: String, keychainsDirectory: URL) throws -> URL {
        let candidates = name.contains("/")
            ? [URL(fileURLWithPath: name)]
            : [keychainsDirectory.appending(path: "\(name)-db"), keychainsDirectory.appending(path: name)]
        if let existing = candidates.first(where: { FileManager.default.fileExists(atPath: $0.filePath) }) {
            return existing
        }
        if name.contains("/") {
            throw BuildError(message: "Keychain \(name) not found. Create it, or pass the path of an existing keychain.")
        }
        throw BuildError(
            message: "Keychain \(name) not found in \(keychainsDirectory.filePath). "
                + "Create it, or pass the name of an existing keychain, such as login.keychain."
        )
    }
}
