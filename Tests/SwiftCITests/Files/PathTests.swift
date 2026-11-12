@testable import SwiftCI
import Foundation
import Testing

/// Paths are Foundation URLs. These tests cover the `filePath` helper, repository-relative paths and the temporary directory.
/// Each test removes the directory it creates under the temporary directory.
@Suite struct PathTests {
    @Test func filePathIsThePlainPathWithoutSchemeOrEncoding() {
        let url = URL(fileURLWithPath: "/tmp/My Dir/Äpp ✓/cert.cer")

        #expect(url.filePath == "/tmp/My Dir/Äpp ✓/cert.cer")
        // The encoded form that `filePath` avoids.
        #expect(url.absoluteString.hasPrefix("file:///tmp/My%20Dir/"))
    }

    @Test func repositoryRelativePathOfAFileInsideTheCurrentDirectoryIsRelative() {
        let directory = FileManager.default.currentDirectoryPath

        #expect(repositoryRelativePath(directory + "/Sources/App.swift") == "Sources/App.swift")
        #expect(repositoryRelativePath(directory + "/Sources/../Tests/./AppTests.swift") == "Tests/AppTests.swift")
        #expect(repositoryRelativePath("./Sources/App.swift") == "Sources/App.swift")
        #expect(repositoryRelativePath("Sources/App.swift") == "Sources/App.swift")
    }

    @Test func repositoryRelativePathOfAFileOutsideTheCurrentDirectoryIsUnchanged() {
        let outside = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .deletingLastPathComponent()
            .appending(path: "Other/App.swift")
            .filePath

        #expect(repositoryRelativePath(outside) == outside)
        #expect(repositoryRelativePath("/elsewhere/App.swift") == "/elsewhere/App.swift")
    }

    @Test func repositoryRelativePathOfAURLIsRelativeInsideTheCurrentDirectory() {
        let directory = URL.currentDirectory()

        #expect(repositoryRelativePath(directory.appending(path: "Sources/My App.swift")) == "Sources/My App.swift")
        #expect(repositoryRelativePath(URL(filePath: "/elsewhere/My App.swift")) == "/elsewhere/My App.swift")
    }

    /// Tools may report a path through a symbolic link, such as `/private/var` for `/var`, that the current directory
    /// does not use, or the reverse.
    @Test func relativePathFollowsSymbolicLinksToTheDirectory() throws {
        let dir = try TemporaryDirectory(name: "PathTests-$UUID")
        defer { try? FileManager.default.removeItem(at: dir.url) }
        let real = dir.childURL(name: "real")
        let link = dir.childURL(name: "link")
        try FileManager.default.createDirectory(at: real.appending(path: "Sources"), withIntermediateDirectories: true)
        try Data().write(to: real.appending(path: "Sources/App.swift"))
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        #expect(relativePath(of: link.filePath + "/Sources/App.swift", inside: real) == "Sources/App.swift")
        #expect(relativePath(of: real.filePath + "/Sources/App.swift", inside: link) == "Sources/App.swift")
        #expect(relativePath(of: dir.childURL(name: "other/App.swift").filePath, inside: real) == nil)
    }

    @Test func temporaryDirectoryIsCreatedUnderTheSwiftCIFolder() throws {
        let dir = try TemporaryDirectory(name: "PathTests-$UUID")
        defer { try? FileManager.default.removeItem(at: dir.url) }

        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appending(path: "swift-ci").filePath
        #expect(dir.url.filePath.hasPrefix(base + "/PathTests-"))
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: dir.url.filePath, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
    }

    @Test func temporaryDirectoryIsReadableOnlyByItsOwner() throws {
        let dir = try TemporaryDirectory(name: "PathTests-$UUID")
        defer { try? dir.remove() }

        let attributes = try FileManager.default.attributesOfItem(atPath: dir.url.filePath)

        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    }

    @Test func temporaryDirectoryNameReplacesDateAndUUID() throws {
        let dir = try TemporaryDirectory(name: "PathTests-$DATE-$UUID")
        defer { try? dir.remove() }

        let name = dir.url.lastPathComponent
        #expect(name.wholeMatch(of: /PathTests-\d{8}_\d{6}-[0-9A-F-]{36}/) != nil)
    }

    @Test func temporaryDirectoryRemoveDeletesTheContentsAndIsRepeatable() throws {
        let dir = try TemporaryDirectory(name: "PathTests-$UUID")
        try Data("x".utf8).write(to: dir.childURL(name: "file.txt"))

        try dir.remove()
        #expect(!FileManager.default.fileExists(atPath: dir.url.filePath))

        try dir.remove()
    }

    @Test func childURLIsInsideTheDirectoryAndIsNotCreated() throws {
        let dir = try TemporaryDirectory(name: "PathTests-$UUID")
        defer { try? FileManager.default.removeItem(at: dir.url) }

        let child = dir.childURL(name: "Äpp ✓.plist")

        #expect(child.deletingLastPathComponent().filePath == dir.url.filePath)
        #expect(child.lastPathComponent == "Äpp ✓.plist")
        #expect(!FileManager.default.fileExists(atPath: child.filePath))
    }
}
