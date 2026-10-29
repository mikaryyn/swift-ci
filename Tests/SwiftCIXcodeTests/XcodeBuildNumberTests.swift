@testable import SwiftCIXcode
@testable import SwiftCITestSupport
import Foundation
@testable import SwiftCI
import SwiftCITesting
import Testing

extension GlobalStateTests {
    /// `Xcode.setBuildNumber` writes the Info.plist in place. The files are in a temporary directory that each test
    /// removes. The step tests run inside a command, so the step's name is checked in the log.
    @Suite(.serialized) struct XcodeBuildNumberTests {
        static let xmlInfoPlist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>CFBundleIdentifier</key>
            <string>com.example.myapp</string>
            <key>CFBundleShortVersionString</key>
            <string>1.2</string>
            <key>CFBundleVersion</key>
            <string>1</string>
        </dict>
        </plist>
        """

        /// Runs `body` in a temporary directory that is removed afterwards. `body` gets the path of `Info.plist` in it.
        func withInfoPlist(_ contents: Data, _ body: (URL) async throws -> Void) async throws {
            let dir = try TemporaryDirectory(name: "XcodeBuildNumberTests-$UUID")
            defer { try? FileManager.default.removeItem(at: dir.url) }
            let url = dir.childURL(name: "Info.plist")
            try contents.write(to: url)
            try await body(url)
        }

        func readPlist(_ url: URL) throws -> [String: Any] {
            try #require(
                try PropertyListSerialization.propertyList(from: Data(contentsOf: url), options: [], format: nil)
                    as? [String: Any]
            )
        }

        @Test func writesTheValueAndKeepsTheOtherKeysInXML() async throws {
            _ = registerToolMocks()
            try await withInfoPlist(Data(Self.xmlInfoPlist.utf8)) { url in
                try await Xcode.setBuildNumber("42", infoPlist: url)

                let plist = try readPlist(url)
                #expect(plist["CFBundleVersion"] as? String == "42")
                #expect(plist["CFBundleShortVersionString"] as? String == "1.2")
                #expect(plist["CFBundleIdentifier"] as? String == "com.example.myapp")
                #expect(plist.count == 3)
                #expect(try String(contentsOf: url, encoding: .utf8).hasPrefix("<?xml"))
            }
        }

        @Test func keepsTheBinaryFormat() async throws {
            _ = registerToolMocks()
            let binary = try PropertyListSerialization.data(
                fromPropertyList: ["CFBundleIdentifier": "com.example.myapp", "CFBundleVersion": "1"],
                format: .binary,
                options: 0
            )
            try await withInfoPlist(binary) { url in
                try await Xcode.setBuildNumber("42", infoPlist: url)

                let data = try Data(contentsOf: url)
                #expect(data.starts(with: Data("bplist00".utf8)))
                let plist = try readPlist(url)
                #expect(plist["CFBundleVersion"] as? String == "42")
                #expect(plist["CFBundleIdentifier"] as? String == "com.example.myapp")
            }
        }

        /// The value is written as it is. It is not checked, so a value that App Store Connect rejects is written too.
        @Test func writesTheValueLiterallyWithoutValidation() async throws {
            _ = registerToolMocks()
            try await withInfoPlist(Data(Self.xmlInfoPlist.utf8)) { url in
                try await Xcode.setBuildNumber("dev $(CURRENT_PROJECT_VERSION)", infoPlist: url)

                #expect(try readPlist(url)["CFBundleVersion"] as? String == "dev $(CURRENT_PROJECT_VERSION)")
            }
        }

        @Test func opensOneStepWithTheDefaultName() async throws {
            let result = await SwiftCITest.run(["number"]) {
                command(Command("number") {
                    try await withInfoPlist(Data(Self.xmlInfoPlist.utf8)) { url in
                        try await Xcode.setBuildNumber("42", infoPlist: url)
                    }
                })
            }

            #expect(result.exitCode == 0)
            #expect(enteredSteps(in: result.log) == ["Entering step [Set build number to 42]"])
        }

        /// The step name can be changed with `step:`.
        @Test func stepNameCanBeChanged() async throws {
            let result = await SwiftCITest.run(["named"]) {
                command(Command("named") {
                    try await withInfoPlist(Data(Self.xmlInfoPlist.utf8)) { url in
                        try await Xcode.setBuildNumber("42", infoPlist: url, step: "Write the build number")
                    }
                })
            }

            #expect(result.exitCode == 0)
            #expect(enteredSteps(in: result.log) == ["Entering step [Write the build number]"])
        }

        @Test func missingFileIsABuildErrorThatNamesTheFile() async throws {
            _ = registerToolMocks()
            let dir = try TemporaryDirectory(name: "XcodeBuildNumberTests-$UUID")
            defer { try? FileManager.default.removeItem(at: dir.url) }
            let url = dir.childURL(name: "Missing Info.plist")

            let error = await thrownError {
                try await Xcode.setBuildNumber("42", infoPlist: url)
            }

            #expect(error?.message.contains("'\(url.filePath)'") == true)
            #expect(!FileManager.default.fileExists(atPath: url.filePath))
        }

        /// A directory at the path cannot be read as a file, so it is an error that names the path.
        @Test func unreadableFileIsABuildErrorThatNamesTheFile() async throws {
            _ = registerToolMocks()
            let dir = try TemporaryDirectory(name: "XcodeBuildNumberTests-$UUID")
            defer { try? FileManager.default.removeItem(at: dir.url) }
            let url = dir.childURL(name: "Info.plist")
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)

            let error = await thrownError {
                try await Xcode.setBuildNumber("42", infoPlist: url)
            }

            #expect(error?.message.contains("'\(url.filePath)'") == true)
        }

        @Test func notAPropertyListIsABuildError() async throws {
            _ = registerToolMocks()
            try await withInfoPlist(Data("not a plist".utf8)) { url in
                let error = await thrownError {
                    try await Xcode.setBuildNumber("42", infoPlist: url)
                }

                #expect(error?.message == "Failed to read plist file at '\(url.filePath)'.")
                let contents = try String(contentsOf: url, encoding: .utf8)
                #expect(contents == "not a plist")
            }
        }
    }
}
