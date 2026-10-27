@_spi(Testing) import SwiftCI
@testable import SwiftCI
@testable import SwiftCITestSupport
import Foundation
import SwiftCITesting
import Testing

extension GlobalStateTests {
    /// The artifacts directory: its resolution, its creation and the full log in it. Tests that need the working
    /// directory change it to a temporary folder and restore it, so that no test writes `artifacts/` into the repository.
    @Suite(.serialized) struct ArtifactsTests {
        @Test func defaultIsArtifactsInTheWorkingDirectory() async throws {
            try await inTemporaryWorkingDirectory { folder in
                var seen: URL?
                let (exitCode, _) = await runDirectly(["build"]) {
                    command(Command("build") {
                        seen = Artifacts.directory
                        try await step("Work") { }
                    })
                }

                let artifacts = folder.appending(path: "artifacts", directoryHint: .isDirectory)
                #expect(exitCode == 0)
                #expect(samePath(seen, artifacts))
                #expect(FileManager.default.fileExists(atPath: artifacts.appending(path: "logs/build.log").filePath))
                #expect(ArtifactsLocation.current == nil)
            }
        }

        @Test func emptyEnvironmentVariableIsUnset() async throws {
            try await inTemporaryWorkingDirectory { folder in
                var seen: URL?
                let (exitCode, _) = await runDirectly(["build"], environment: ["SWIFTCI_ARTIFACTS_DIR": ""]) {
                    command(Command("build") { seen = Artifacts.directory })
                }

                #expect(exitCode == 0)
                #expect(samePath(seen, folder.appending(path: "artifacts", directoryHint: .isDirectory)))
            }
        }

        @Test func relativeEnvironmentVariableResolvesAgainstWorkingDirectory() async throws {
            try await inTemporaryWorkingDirectory { folder in
                var seen: URL?
                let (exitCode, _) = await runDirectly(["build"], environment: ["SWIFTCI_ARTIFACTS_DIR": "rel/dir"]) {
                    command(Command("build") { seen = Artifacts.directory })
                }

                #expect(exitCode == 0)
                #expect(samePath(seen, folder.appending(path: "rel/dir", directoryHint: .isDirectory)))
            }
        }

        /// A relative `artifactsDirectory:` resolves against the working directory at start, not against a later one.
        @Test func relativeScriptParameterResolvesAgainstWorkingDirectoryAtStart() async throws {
            try await inTemporaryWorkingDirectory { folder in
                var seen: URL?
                let result = await SwiftCITest.run(["build"], artifactsDirectory: URL(filePath: "custom/out")) {
                    command(Command("build") {
                        seen = Artifacts.directory
                        // Moving the working directory must not move the artifacts directory.
                        FileManager.default.changeCurrentDirectoryPath(NSTemporaryDirectory())
                    })
                }

                #expect(result.exitCode == 0)
                #expect(samePath(seen, folder.appending(path: "custom/out", directoryHint: .isDirectory)))
                #expect(samePath(result.artifactsDirectory, folder.appending(path: "custom/out", directoryHint: .isDirectory)))
            }
        }

        @Test func absoluteScriptParameterIsUsedAsGiven() async {
            let directory = uniqueTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }

            var seen: URL?
            let result = await SwiftCITest.run(["build"], artifactsDirectory: directory) {
                command(Command("build") { seen = Artifacts.directory })
            }

            #expect(result.exitCode == 0)
            #expect(samePath(seen, directory))
            #expect(samePath(result.artifactsDirectory, directory))
        }

        @Test func environmentVariableOverridesScriptParameter() async {
            let fromEnvironment = uniqueTemporaryDirectory()
            let fromScript = uniqueTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: fromEnvironment) }

            var seen: URL?
            let result = await SwiftCITest.run(
                ["build"],
                environment: ["SWIFTCI_ARTIFACTS_DIR": fromEnvironment.filePath],
                artifactsDirectory: fromScript
            ) {
                command(Command("build") { seen = Artifacts.directory })
            }

            #expect(result.exitCode == 0)
            #expect(samePath(seen, fromEnvironment))
            #expect(samePath(result.artifactsDirectory, fromEnvironment))
            #expect(!FileManager.default.fileExists(atPath: fromScript.filePath))
        }

        /// An existing file at the path fails the run with exit code 2, and the message names the source. The body does
        /// not run.
        @Test func existingFileAtPathExitsWithTwoAndNamesTheSource() async throws {
            try await inTemporaryWorkingDirectory { folder in
                let fromEnvironment = folder.appending(path: "env-file")
                let fromScript = folder.appending(path: "script-file")
                let fromDefault = folder.appending(path: "artifacts")
                try "file".write(to: fromEnvironment, atomically: true, encoding: .utf8)
                try "file".write(to: fromScript, atomically: true, encoding: .utf8)
                try "file".write(to: fromDefault, atomically: true, encoding: .utf8)

                var ran = false
                let environmentRun = await runDirectly(["build"], environment: ["SWIFTCI_ARTIFACTS_DIR": "env-file"]) {
                    command(Command("build") { ran = true })
                }
                let scriptRun = await runDirectly(["build"], artifactsDirectory: URL(filePath: "script-file")) {
                    command(Command("build") { ran = true })
                }
                let defaultRun = await runDirectly(["build"]) {
                    command(Command("build") { ran = true })
                }

                #expect(environmentRun.exitCode == 2)
                #expect(environmentRun.log.map(stripANSI).contains { $0.hasPrefix("<Error> The artifacts directory") && $0.contains("from SWIFTCI_ARTIFACTS_DIR") })
                #expect(scriptRun.exitCode == 2)
                #expect(scriptRun.log.map(stripANSI).contains { $0.hasPrefix("<Error> The artifacts directory") && $0.contains("from the artifactsDirectory: argument") })
                #expect(defaultRun.exitCode == 2)
                #expect(defaultRun.log.map(stripANSI).contains { $0.hasPrefix("<Error> The artifacts directory") && $0.contains("from the default artifacts directory") })
                #expect(!ran)
                #expect(ArtifactsLocation.current == nil)
            }
        }

        /// The full log of a command is `logs/<command>.log`, and a second run of the same command overwrites it.
        @Test func fullLogIsLogsCommandLogAndIsOverwritten() async {
            let directory = uniqueTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let log = directory.appending(path: "logs/build.log")

            let first = await SwiftCITest.run(["build"], artifactsDirectory: directory) {
                command(Command("build") { try await step("Alpha") { } })
            }
            let firstText = try? String(contentsOf: log, encoding: .utf8)
            #expect(first.exitCode == 0)
            #expect(first.plainLog.contains { $0.hasPrefix("Saved full log to file://") && $0.hasSuffix("/logs/build.log") })
            #expect(firstText?.contains("Entering step [Alpha]") == true)

            let second = await SwiftCITest.run(["build"], artifactsDirectory: directory) {
                command(Command("build") { try await step("Beta") { } })
            }
            let secondText = try? String(contentsOf: log, encoding: .utf8)
            #expect(second.exitCode == 0)
            #expect(secondText?.contains("Entering step [Beta]") == true)
            #expect(secondText?.contains("Alpha") == false)
        }

        /// A run adds its own files and keeps the others, including other logs.
        @Test func secondRunKeepsUnrelatedFiles() async throws {
            let directory = uniqueTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            try FileManager.default.createDirectory(at: directory.appending(path: "logs"), withIntermediateDirectories: true)
            try "keep".write(to: directory.appending(path: "keep.txt"), atomically: true, encoding: .utf8)
            try "other".write(to: directory.appending(path: "logs/other.log"), atomically: true, encoding: .utf8)

            let result = await SwiftCITest.run(["build"], artifactsDirectory: directory) {
                command(Command("build") { })
            }

            #expect(result.exitCode == 0)
            #expect(try String(contentsOf: directory.appending(path: "keep.txt"), encoding: .utf8) == "keep")
            #expect(try String(contentsOf: directory.appending(path: "logs/other.log"), encoding: .utf8) == "other")
            #expect(FileManager.default.fileExists(atPath: directory.appending(path: "logs/build.log").filePath))
        }

        @Test func urlCreatesParentsButNotTheFile() async {
            let directory = uniqueTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }

            var made: URL?
            let result = await SwiftCITest.run(["build"], artifactsDirectory: directory) {
                command(Command("build") { made = try Artifacts.url("reports/junit/out.xml") })
            }

            #expect(result.exitCode == 0)
            #expect(samePath(made, directory.appending(path: "reports/junit/out.xml")))
            #expect(FileManager.default.fileExists(atPath: directory.appending(path: "reports/junit").filePath))
            #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "reports/junit/out.xml").filePath))
        }

        /// Absolute paths, empty paths and paths that leave the directory are rejected, and nothing is created outside.
        @Test func urlRejectsAbsoluteAndEscapingPaths() async {
            let directory = uniqueTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let outside = directory.deletingLastPathComponent().appending(path: "outside.txt")

            var errors: [BuildError?] = []
            let result = await SwiftCITest.run(["build"], artifactsDirectory: directory) {
                command(Command("build") {
                    for path in ["/etc/outside.txt", "", "../outside.txt", "a/../../outside.txt"] {
                        errors.append(await thrownError { _ = try Artifacts.url(path) })
                    }
                })
            }

            #expect(result.exitCode == 0)
            #expect(errors.count == 4)
            #expect(errors.allSatisfy { $0?.code == .failure })
            #expect(!FileManager.default.fileExists(atPath: outside.filePath))
        }

        @Test func urlFailsWhenAParentIsAFile() async throws {
            let directory = uniqueTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try "file".write(to: directory.appending(path: "blocked"), atomically: true, encoding: .utf8)

            var error: BuildError?
            let result = await SwiftCITest.run(["build"], artifactsDirectory: directory) {
                command(Command("build") { error = await thrownError { _ = try Artifacts.url("blocked/x.txt") } })
            }

            #expect(result.exitCode == 0)
            #expect(error?.message.contains("blocked") == true)
        }
    }
}

/// Runs the script through `runSwiftCI` with the mocks, so that the working directory and the artifacts setting are the
/// ones of the test. The environment is given, so that the test does not read the variables of the shell.
@MainActor
private func runDirectly(
    _ arguments: [String],
    environment: [String: String] = [:],
    artifactsDirectory: URL? = nil,
    script: () async throws -> Void
) async -> (exitCode: Int32, log: [String]) {
    let snapshot = isolateGlobalState(environment: environment)
    defer { restoreGlobalState(snapshot) }
    let (log, _) = registerToolMocks()
    let exitCode = await runSwiftCI(arguments: arguments, artifactsDirectory: artifactsDirectory, script: script)
    return (exitCode, log.loggedLines)
}

/// Runs `body` with the working directory set to a new temporary folder, then restores the working directory and removes
/// the folder. `body` receives the folder.
private func inTemporaryWorkingDirectory(_ body: (URL) async throws -> Void) async throws {
    let original = FileManager.default.currentDirectoryPath
    let folder = uniqueTemporaryDirectory()
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    FileManager.default.changeCurrentDirectoryPath(folder.filePath)
    defer {
        FileManager.default.changeCurrentDirectoryPath(original)
        try? FileManager.default.removeItem(at: folder)
    }
    try await body(folder)
}

/// A new path in the temporary directory. Nothing is created.
private func uniqueTemporaryDirectory() -> URL {
    URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appending(path: "swift-ci-artifacts-\(UUID().uuidString)", directoryHint: .isDirectory)
}

/// Whether `url` names the same file system path as `expected`, ignoring a trailing slash and symbolic links.
private func samePath(_ url: URL?, _ expected: URL) -> Bool {
    guard let url else { return false }
    return normalizedPath(url) == normalizedPath(expected)
}

private func normalizedPath(_ url: URL) -> String {
    var path = url.resolvingSymlinksInPath().filePath
    while path.count > 1, path.hasSuffix("/") {
        path.removeLast()
    }
    return path
}
