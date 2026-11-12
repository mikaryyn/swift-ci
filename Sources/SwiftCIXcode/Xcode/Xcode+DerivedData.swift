import Foundation
import SwiftCI

extension Xcode {
    /// The default DerivedData folder of the current user, `~/Library/Developer/Xcode/DerivedData`, where Xcode writes
    /// build products, indexes and logs.
    ///
    /// This is the default location only. A location that the user chose in the Xcode settings, or `-derivedDataPath`
    /// of a build, is not read.
    ///
    /// A query: does not open a step.
    public static var derivedDataURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Developer/Xcode/DerivedData")
    }

    /// Removes the default DerivedData folder of the current user (``derivedDataURL``) with everything in it. A missing
    /// folder is not an error. A DerivedData folder in another location is not removed.
    ///
    /// Opens a step named "Delete DerivedData" when called at the top level of a command. `step` renames it.
    public static func deleteDerivedData(step name: String? = nil) async throws {
        try await deleteDerivedData(at: derivedDataURL, step: name)
    }

    /// ``deleteDerivedData(step:)`` for the folder at `url`. Tests use a temporary folder.
    static func deleteDerivedData(at url: URL, step name: String? = nil) async throws {
        @Use var log: Log

        try await step(default: "Delete DerivedData", name: name) {
            guard FileManager.default.fileExists(atPath: url.filePath) else {
                log("No DerivedData at '\(url.filePath)'")
                return
            }
            log("Removing DerivedData at '\(url.filePath)'")
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                throw BuildError(message: "Failed to remove '\(url.filePath)'. Details: \(error)")
            }
        }
    }
}
