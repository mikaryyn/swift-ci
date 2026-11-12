@testable import SwiftCIXcode
@testable import SwiftCITestSupport
import Foundation
@testable import SwiftCI
import SwiftCITesting
import Testing

extension GlobalStateTests {
    /// The DerivedData helpers of `Xcode`. Only a temporary folder is removed, never the real DerivedData.
    @Suite(.serialized) struct XcodeDerivedDataTests {
        /// A temporary DerivedData folder that holds one file. The test removes the folder.
        static func temporaryDerivedData() throws -> URL {
            let folder = temporaryArtifactsDirectory().deletingLastPathComponent().appending(path: "DerivedData")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("build product".utf8).write(to: folder.appending(path: "Build.txt"))
            return folder
        }

        /// The DerivedData folder is in the Xcode folder of the user's Library.
        @Test func derivedDataURLIsInTheUserLibrary() {
            let url = Xcode.derivedDataURL

            #expect(url.filePath.hasPrefix(FileManager.default.homeDirectoryForCurrentUser.filePath))
            #expect(url.filePath.hasSuffix("/Library/Developer/Xcode/DerivedData"))
        }

        /// The folder and everything in it are removed.
        @Test func deleteDerivedDataRemovesTheFolder() async throws {
            _ = registerToolMocks()
            let folder = try Self.temporaryDerivedData()
            defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }

            try await Xcode.deleteDerivedData(at: folder)

            #expect(!FileManager.default.fileExists(atPath: folder.filePath))
        }

        /// A missing folder is not an error.
        @Test func deleteDerivedDataSucceedsWhenTheFolderIsMissing() async {
            let folder = temporaryArtifactsDirectory().deletingLastPathComponent().appending(path: "DerivedData")

            let result = await SwiftCITest.run(["delete"]) {
                command(Command("delete") {
                    try await Xcode.deleteDerivedData(at: folder)
                })
            }

            #expect(result.exitCode == 0)
            #expect(result.plainLog.contains { $0.contains("No DerivedData at") })
        }

        /// The step opens its default name at the top level of a command, and `step:` renames it.
        @Test func deleteDerivedDataOpensItsDefaultStepName() async throws {
            let folder = try Self.temporaryDerivedData()
            defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }

            let result = await SwiftCITest.run(["delete"]) {
                command(Command("delete") {
                    try await Xcode.deleteDerivedData(at: folder)
                })
            }
            let renamed = await SwiftCITest.run(["renamed"]) {
                command(Command("renamed") {
                    try await Xcode.deleteDerivedData(at: folder, step: "Clear DerivedData")
                })
            }

            #expect(result.exitCode == 0)
            #expect(enteredSteps(in: result.log) == ["Entering step [Delete DerivedData]"])
            #expect(enteredSteps(in: renamed.log) == ["Entering step [Clear DerivedData]"])
        }
    }
}
