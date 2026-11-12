@testable import SwiftCISigning
@testable import SwiftCITestSupport
@testable import SwiftCI
import Foundation
import Testing

/// The keychain path of a match install, resolved in a temporary directory that holds empty files.
@Suite struct MatchKeychainPathTests {
    @Test func dbFileIsPreferredOverThePlainName() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try makeEmptyFile(in: directory, named: "login")
        try makeEmptyFile(in: directory, named: "login-db")

        let url = try MatchKeychainPath.resolve(name: "login", keychainsDirectory: directory)

        #expect(url.filePath == directory.appending(path: "login-db").filePath)
    }

    @Test func plainNameIsUsedWhenThereIsNoDbFile() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try makeEmptyFile(in: directory, named: "login")

        let url = try MatchKeychainPath.resolve(name: "login", keychainsDirectory: directory)

        #expect(url.filePath == directory.appending(path: "login").filePath)
    }

    /// A name that already ends in `-db` is found by the second rule, under its own name.
    @Test func nameEndingInDbIsFoundUnderItsOwnName() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try makeEmptyFile(in: directory, named: "login.keychain-db")

        let url = try MatchKeychainPath.resolve(name: "login.keychain-db", keychainsDirectory: directory)

        #expect(url.filePath == directory.appending(path: "login.keychain-db").filePath)
    }

    @Test func pathWithSlashIsUsedAsItIs() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try makeEmptyFile(in: directory, named: "custom.keychain-db")
        let path = directory.appending(path: "custom.keychain-db").filePath

        let url = try MatchKeychainPath.resolve(name: path, keychainsDirectory: URL(fileURLWithPath: "/elsewhere"))

        #expect(url.filePath == path)
    }

    @Test func missingNameIsAnErrorThatNamesTheDirectory() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let error = matchBuildError {
            _ = try MatchKeychainPath.resolve(name: "missing", keychainsDirectory: directory)
        }

        #expect(error?.message == "Keychain missing not found in \(directory.filePath). Create it, or pass the name of an existing keychain, such as login.keychain.")
    }

    @Test func missingPathIsAnError() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appending(path: "missing.keychain-db").filePath

        let error = matchBuildError {
            _ = try MatchKeychainPath.resolve(name: path, keychainsDirectory: directory)
        }

        #expect(error?.message == "Keychain \(path) not found. Create it, or pass the path of an existing keychain.")
    }
}
