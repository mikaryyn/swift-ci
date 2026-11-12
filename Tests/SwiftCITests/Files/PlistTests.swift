@testable import SwiftCI
import Foundation
import Testing

/// Each test removes the directory it creates under the temporary directory.
@Suite struct PlistTests {
    @Test func setAndStringRoundTripOnATemporaryFile() throws {
        let dir = try TemporaryDirectory(name: "PlistTests-$UUID")
        defer { try? dir.remove() }
        let url = dir.childURL(name: "Info.plist")
        try Plist.save(to: url, contents: ["CFBundleName": "Old"])

        let plist = Plist(url: url)
        try plist.set("CFBundleName", "Äpp ✓")

        #expect(try plist.string("CFBundleName") == "Äpp ✓")
        #expect(try Plist.read(url: url)["CFBundleName"] as? String == "Äpp ✓")
    }

    @Test func setKeepsTheOtherKeysAndAddsAMissingKey() throws {
        let dir = try TemporaryDirectory(name: "PlistTests-$UUID")
        defer { try? dir.remove() }
        let url = dir.childURL(name: "Info.plist")
        try Plist.save(to: url, contents: ["CFBundleName": "MyApp", "UIRequiresFullScreen": true])

        try Plist(url: url).set("CFBundleVersion", "42")

        let contents = try Plist.read(url: url)
        #expect(contents["CFBundleName"] as? String == "MyApp")
        #expect(contents["UIRequiresFullScreen"] as? Bool == true)
        #expect(contents["CFBundleVersion"] as? String == "42")
    }

    @Test func setKeepsTheBinaryFormat() throws {
        let dir = try TemporaryDirectory(name: "PlistTests-$UUID")
        defer { try? dir.remove() }
        let url = dir.childURL(name: "Info.plist")
        let binary = try PropertyListSerialization.data(fromPropertyList: ["CFBundleName": "MyApp"], format: .binary, options: 0)
        try binary.write(to: url)

        try Plist(url: url).set("CFBundleVersion", "42")

        let data = try Data(contentsOf: url)
        #expect(data.starts(with: Data("bplist".utf8)))
        #expect(try Plist.read(url: url)["CFBundleVersion"] as? String == "42")
    }

    @Test func stringUsesTheFallbackOnlyForAMissingKey() throws {
        let dir = try TemporaryDirectory(name: "PlistTests-$UUID")
        defer { try? dir.remove() }
        let url = dir.childURL(name: "Info.plist")
        try Plist.save(to: url, contents: ["CFBundleName": "MyApp"])
        let plist = Plist(url: url)

        #expect(try plist.string("CFBundleName", fallback: "Other") == "MyApp")
        #expect(try plist.string("CFBundleVersion", fallback: "1") == "1")
        do {
            _ = try plist.string("CFBundleVersion")
            Issue.record("Expected an error")
        } catch let error as BuildError {
            #expect(error.message == "The property list file at '\(url.filePath)' has no string for the key 'CFBundleVersion'.")
        }
    }

    @Test func saveAndReadRoundTripReturnsTheWrittenLines() throws {
        let dir = try TemporaryDirectory(name: "PlistTests-$UUID")
        defer { try? dir.remove() }
        let url = dir.childURL(name: "export_options.plist")

        let lines = try Plist.save(to: url, contents: ["method": "ad-hoc", "compileBitcode": false])

        #expect(lines.first?.hasPrefix("<?xml") == true)
        let read = try Plist.read(url: url)
        #expect(read["method"] as? String == "ad-hoc")
        #expect(read["compileBitcode"] as? Bool == false)
    }

    /// A read error names the plain file path, not the `file://` URL.
    @Test func readOfAMissingFileSaysThatItDoesNotExist() throws {
        let dir = try TemporaryDirectory(name: "PlistTests-$UUID")
        defer { try? dir.remove() }
        let url = dir.childURL(name: "Missing Äpp.plist")

        do {
            _ = try Plist.read(url: url)
            Issue.record("Expected a read error")
        } catch let error as BuildError {
            #expect(error.message == "The property list file at '\(url.filePath)' does not exist.")
        }
    }

    @Test func readOfAFileThatIsNotAPropertyListGivesTheDetails() throws {
        let dir = try TemporaryDirectory(name: "PlistTests-$UUID")
        defer { try? dir.remove() }
        let url = dir.childURL(name: "Info.plist")
        try Data("not a plist".utf8).write(to: url)

        do {
            _ = try Plist.read(url: url)
            Issue.record("Expected a read error")
        } catch let error as BuildError {
            #expect(error.message.hasPrefix("Failed to read the property list file at '\(url.filePath)'. Details: "))
        }
    }

    @Test func readOfAnArrayRootSaysThatTheRootIsNotADictionary() throws {
        let dir = try TemporaryDirectory(name: "PlistTests-$UUID")
        defer { try? dir.remove() }
        let url = dir.childURL(name: "Info.plist")
        try PropertyListSerialization.data(fromPropertyList: ["a", "b"], format: .xml, options: 0).write(to: url)

        do {
            _ = try Plist.read(url: url)
            Issue.record("Expected a read error")
        } catch let error as BuildError {
            #expect(error.message == "The property list file at '\(url.filePath)' does not have a dictionary as its root.")
        }
    }

    @Test func setLeavesAFileThatCannotBeReadUnchanged() throws {
        let dir = try TemporaryDirectory(name: "PlistTests-$UUID")
        defer { try? dir.remove() }
        let url = dir.childURL(name: "Info.plist")
        try Data("not a plist".utf8).write(to: url)

        #expect(throws: BuildError.self) {
            try Plist(url: url).set("CFBundleVersion", "42")
        }

        #expect(try String(contentsOf: url, encoding: .utf8) == "not a plist")
    }
}
