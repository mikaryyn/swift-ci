@testable import SwiftCISigning
import Foundation
import SwiftCI
import Testing

/// `TemporaryDirectory.withDirectory`, which the match clone and the match import use. It runs in the real temporary
/// directory and writes only below it.
@Suite struct TemporaryDirectoryRemovalTests {
    @Test func theDirectoryExistsWithOwnerOnlyModeWhileBodyRunsAndIsRemovedAfterwards() async throws {
        var url: URL?
        var mode: Int?

        let result = try await TemporaryDirectory.withDirectory(
            name: "removal-test-$UUID", holding: "test files"
        ) { directory in
            url = directory.url
            let attributes = try FileManager.default.attributesOfItem(atPath: directory.url.filePath)
            mode = (attributes[.posixPermissions] as? NSNumber)?.intValue
            return 42
        }

        #expect(result == 42)
        #expect(mode == 0o700)
        #expect(try !FileManager.default.fileExists(atPath: #require(url).filePath))
    }

    @Test func aThrowingBodyPropagatesItsErrorAndRemovesTheDirectory() async throws {
        var url: URL?
        var thrown: BuildError?

        do {
            try await TemporaryDirectory.withDirectory(name: "removal-test-$UUID", holding: "test files") { directory in
                url = directory.url
                throw BuildError(message: "body failed")
            }
        } catch let error as BuildError {
            thrown = error
        }

        #expect(thrown?.message == "body failed")
        #expect(try !FileManager.default.fileExists(atPath: #require(url).filePath))
    }

    /// The body makes the removal fail: a directory without write permission cannot lose its file.
    @Test func aFailedRemovalAfterASuccessfulBodyNamesTheDirectoryAndWhatItHolds() async throws {
        var url: URL?
        var thrown: BuildError?

        do {
            try await TemporaryDirectory.withDirectory(name: "removal-test-$UUID", holding: "test files") { directory in
                url = directory.url
                try Data().write(to: directory.childURL(name: "file"))
                try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.url.filePath)
            }
        } catch let error as BuildError {
            thrown = error
        }

        let leftover = try #require(url)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: leftover.filePath)
            try? FileManager.default.removeItem(at: leftover)
        }
        #expect(thrown?.message == "Couldn't remove the temporary directory \(leftover.filePath), which holds test "
            + "files. Remove it by hand.")
    }
}
