import Foundation
import SwiftCI
import SwiftCITesting
import Testing

/// These tests check the artifacts directory of `SwiftCITest` through its public API only. A test run never writes into
/// the working directory, and a temporary artifacts directory is removed after the run.
@Suite(.serialized) struct ArtifactsTestingTests {
    @Test func runUsesATemporaryArtifactsDirectoryAndRemovesIt() async throws {
        var written: URL?
        let result = await SwiftCITest.run(["build"]) {
            command(Command("build") {
                written = try Artifacts.url("release-notes.txt")
                try "notes".write(to: written!, atomically: true, encoding: .utf8)
            })
        }

        let directory = result.artifactsDirectory
        #expect(result.exitCode == 0)
        #expect(directory.isFileURL)
        #expect(directory.lastPathComponent == "artifacts")
        #expect(written?.path.hasPrefix(directory.path + "/") == true)
        // The run removed the temporary directory it created, so the files it wrote are gone too.
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        #expect(!FileManager.default.fileExists(atPath: directory.deletingLastPathComponent().path))
    }

    /// A test that needs the files passes its own directory. The run does not remove it.
    @Test func runWithOwnDirectoryKeepsTheFilesForInspection() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "swift-ci-testing-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }

        let result = await SwiftCITest.run(["build"], artifactsDirectory: directory) {
            command(Command("build") {
                try await step("Write") {
                    try "report".write(to: try Artifacts.url("reports/out.txt"), atomically: true, encoding: .utf8)
                }
            })
        }

        #expect(result.exitCode == 0)
        #expect(samePath(result.artifactsDirectory, directory))
        #expect(try String(contentsOf: directory.appending(path: "reports/out.txt"), encoding: .utf8) == "report")
        #expect(FileManager.default.fileExists(atPath: directory.appending(path: "logs/build.log").path))
    }

    /// The working directory of the process is not changed by a run, and the run writes no `artifacts/` into it.
    @Test func runNeverTouchesTheWorkingDirectory() async throws {
        let original = FileManager.default.currentDirectoryPath
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "swift-ci-cwd-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        FileManager.default.changeCurrentDirectoryPath(folder.path)
        defer {
            FileManager.default.changeCurrentDirectoryPath(original)
            try? FileManager.default.removeItem(at: folder)
        }

        let result = await SwiftCITest.run(["build"]) {
            command(Command("build") {
                try await step("Write") {
                    _ = try Artifacts.url("out.txt")
                }
            })
        }

        #expect(result.exitCode == 0)
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "artifacts").path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
    }

    /// `withMocks` sets `Artifacts.directory` for code that is not a command, and removes its temporary directory.
    @Test func withMocksSetsTheArtifactsDirectoryForItsBody() async throws {
        let directory = try await SwiftCITest.withMocks { () -> URL in
            let directory = Artifacts.directory
            _ = try Artifacts.url("file.txt")
            #expect(FileManager.default.fileExists(atPath: directory.deletingLastPathComponent().path))
            return directory
        }

        #expect(directory.lastPathComponent == "artifacts")
        #expect(!FileManager.default.fileExists(atPath: directory.deletingLastPathComponent().path))
    }

    /// `SWIFTCI_ARTIFACTS_DIR` in the test environment overrides the directory, as in a real run. The result shows the
    /// directory the run used.
    @Test func environmentVariableOverridesTheDirectoryOfTheTest() async throws {
        let override = FileManager.default.temporaryDirectory
            .appending(path: "swift-ci-override-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: override) }

        let result = await SwiftCITest.run(
            ["build"],
            environment: ["SWIFTCI_ARTIFACTS_DIR": override.path],
            artifactsDirectory: FileManager.default.temporaryDirectory.appending(path: "not-used-\(UUID().uuidString)")
        ) {
            command(Command("build") { })
        }

        #expect(result.exitCode == 0)
        #expect(samePath(result.artifactsDirectory, override))
        #expect(FileManager.default.fileExists(atPath: override.appending(path: "logs/build.log").path))
    }
}

/// Whether `url` names the same file system path as `expected`, ignoring a trailing slash and symbolic links.
private func samePath(_ url: URL, _ expected: URL) -> Bool {
    normalizedPath(url) == normalizedPath(expected)
}

private func normalizedPath(_ url: URL) -> String {
    var path = url.resolvingSymlinksInPath().path
    while path.count > 1, path.hasSuffix("/") {
        path.removeLast()
    }
    return path
}
