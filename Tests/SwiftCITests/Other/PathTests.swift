@testable import SwiftCI
import Foundation
import Testing

/// Paths are Foundation URLs. These tests cover the `filePath` helper, the temporary directory and property list files.
/// Each test removes the directory it creates under the temporary directory.
@Suite struct PathTests {
    @Test func filePathIsThePlainPathWithoutSchemeOrEncoding() {
        let url = URL(fileURLWithPath: "/tmp/My Dir/Äpp ✓/cert.cer")

        #expect(url.filePath == "/tmp/My Dir/Äpp ✓/cert.cer")
        // The encoded form that `filePath` avoids.
        #expect(url.absoluteString.hasPrefix("file:///tmp/My%20Dir/"))
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

    @Test func childURLIsInsideTheDirectoryAndIsNotCreated() throws {
        let dir = try TemporaryDirectory(name: "PathTests-$UUID")
        defer { try? FileManager.default.removeItem(at: dir.url) }

        let child = dir.childURL(name: "Äpp ✓.plist")

        #expect(child.deletingLastPathComponent().filePath == dir.url.filePath)
        #expect(child.lastPathComponent == "Äpp ✓.plist")
        #expect(!FileManager.default.fileExists(atPath: child.filePath))
    }

    @Test func plistSetAndGetStringRoundTripOnATemporaryFile() throws {
        let dir = try TemporaryDirectory(name: "PathTests-$UUID")
        defer { try? FileManager.default.removeItem(at: dir.url) }
        let url = dir.childURL(name: "Info.plist")
        _ = try Plist.save(to: url, contents: ["CFBundleName": "Old"])

        let plist = Plist(url: url)
        try plist.set("CFBundleName", "Äpp ✓")

        #expect(try plist.getString("CFBundleName") == "Äpp ✓")
        #expect(try Plist.read(url: url)["CFBundleName"] as? String == "Äpp ✓")
    }

    @Test func plistSaveAndReadRoundTripReturnsTheWrittenLines() throws {
        let dir = try TemporaryDirectory(name: "PathTests-$UUID")
        defer { try? FileManager.default.removeItem(at: dir.url) }
        let url = dir.childURL(name: "export_options.plist")

        let lines = try Plist.save(to: url, contents: ["method": "ad-hoc", "compileBitcode": false])

        #expect(lines.first?.hasPrefix("<?xml") == true)
        let read = try Plist.read(url: url)
        #expect(read["method"] as? String == "ad-hoc")
        #expect(read["compileBitcode"] as? Bool == false)
    }

    /// A read error names the plain file path, not the `file://` URL.
    @Test func plistReadErrorShowsThePlainPath() throws {
        let dir = try TemporaryDirectory(name: "PathTests-$UUID")
        defer { try? FileManager.default.removeItem(at: dir.url) }
        let url = dir.childURL(name: "Missing Äpp.plist")

        do {
            _ = try Plist.read(url: url)
            Issue.record("Expected a read error")
        } catch let error as BuildError {
            #expect(error.message == "Failed to read plist file at '\(url.filePath)'.")
        }
    }
}
