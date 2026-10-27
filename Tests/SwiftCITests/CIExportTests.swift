@_spi(Testing) import SwiftCI
@testable import SwiftCI
@testable import SwiftCITestSupport
import Foundation
import SwiftCITesting
import Testing

extension GlobalStateTests {
    /// `CI.export`: the exporter of each runner, the checks of the name, the value and secrets, and the files that the
    /// dotenv and GitHub exporters write.
    @Suite(.serialized) struct CIExportTests {
        private let jenkins = ["JENKINS_URL": "https://jenkins.example.com/", "BUILD_NUMBER": "12"]

        @Test func bitriseCLIInsideJenkinsExportsToEnvman() async throws {
            let folder = try makeFolder()
            defer { removeFolder(folder) }
            let runner = ProcessRunnerMock()
            let environment = jenkins.merging(["ENVMAN_ENVSTORE_PATH": "/tmp/envman/envstore.yml"]) { $1 }

            let result = await exportRun(environment, folder, runner: runner, [("MYAPP_IPA_PATH", "/tmp/out/MyApp.ipa")])

            #expect(result.exitCode == 0)
            #expect(runner.tools.count == 1)
            let tool = try #require(runner.tools.first)
            #expect(tool.command == "envman")
            #expect(tool.arguments == ["add", "--key", "MYAPP_IPA_PATH"])
            #expect(tool.input == .text("/tmp/out/MyApp.ipa"))
            #expect(tool.environment["ENVMAN_ENVSTORE_PATH"] == .text("/tmp/envman/envstore.yml"))
            #expect(!tool.arguments.contains { $0.contains("/tmp/out/MyApp.ipa") })
            #expect(!FileManager.default.fileExists(atPath: outputsFile(folder).filePath))
            #expect(result.log.contains { stripANSI($0) == "Exported MYAPP_IPA_PATH" })
        }

        @Test func bitriseOnBitriseIOExportsToEnvman() async throws {
            let folder = try makeFolder()
            defer { removeFolder(folder) }
            let runner = ProcessRunnerMock()
            let environment = ["BITRISE_IO": "true", "ENVMAN_ENVSTORE_PATH": "/tmp/envman/envstore.yml"]

            let result = await exportRun(environment, folder, runner: runner, [("A", "1")])

            #expect(result.exitCode == 0)
            #expect(runner.tools.map(\.command) == ["envman"])
        }

        /// The Bitrise CLI inside a GitHub Actions job is the innermost runner, so its later steps get the value.
        @Test func bitriseCLIInsideGitHubActionsExportsToEnvman() async throws {
            let folder = try makeFolder()
            defer { removeFolder(folder) }
            let runner = ProcessRunnerMock()
            let githubEnv = folder.appending(path: "github_env")
            let environment = [
                "GITHUB_ACTIONS": "true",
                "GITHUB_ENV": githubEnv.filePath,
                "ENVMAN_ENVSTORE_PATH": "/tmp/envman/envstore.yml",
            ]

            let result = await exportRun(environment, folder, runner: runner, [("A", "1")])

            #expect(result.exitCode == 0)
            #expect(runner.tools.map(\.command) == ["envman"])
            #expect(!FileManager.default.fileExists(atPath: githubEnv.filePath))
        }

        @Test func envmanOutputShowsOnlyErrorsAndWarnings() async throws {
            let folder = try makeFolder()
            defer { removeFolder(folder) }
            let runner = ProcessRunnerMock()
            runner.responses = [ProcessRunnerMock.Response(lines: [stdoutLine("noise line"), stderrLine("warning: store is slow")])]

            let result = await exportRun(["ENVMAN_ENVSTORE_PATH": "/tmp/envstore.yml"], folder, runner: runner, [("A", "1")])

            #expect(result.exitCode == 0)
            let plain = result.plainLog
            #expect(plain.contains { $0.contains("warning: store is slow") })
            #expect(!plain.contains { $0.contains("noise line") })
        }

        @Test func envmanFailureFailsTheCommand() async throws {
            let folder = try makeFolder()
            defer { removeFolder(folder) }
            let runner = ProcessRunnerMock()
            runner.respond(to: "envman", with: response(stderr: "no store", exitCode: 1))

            let result = await exportRun(["ENVMAN_ENVSTORE_PATH": "/tmp/envstore.yml"], folder, runner: runner, [("A", "1")])

            #expect(result.exitCode == 1)
            #expect(result.log.contains { stripANSI($0).contains("envman exited with code 1") })
        }

        @Test func githubWritesEnvAndOutputFiles() async throws {
            let folder = try makeFolder()
            defer { removeFolder(folder) }
            let envFile = folder.appending(path: "github_env")
            let outputFile = folder.appending(path: "github_output")
            try "".write(to: envFile, atomically: true, encoding: .utf8)
            try "".write(to: outputFile, atomically: true, encoding: .utf8)
            let environment = ["GITHUB_ACTIONS": "true", "GITHUB_ENV": envFile.filePath, "GITHUB_OUTPUT": outputFile.filePath]

            let result = await exportRun(environment, folder, [("A", "1"), ("B", "two words")])

            #expect(result.exitCode == 0)
            #expect(try String(contentsOf: envFile, encoding: .utf8) == "A=1\nB=two words\n")
            #expect(try String(contentsOf: outputFile, encoding: .utf8) == "A=1\nB=two words\n")
        }

        @Test func githubAppendsAndKeepsExistingLines() async throws {
            let folder = try makeFolder()
            defer { removeFolder(folder) }
            let envFile = folder.appending(path: "github_env")
            try "EXISTING=yes\n".write(to: envFile, atomically: true, encoding: .utf8)

            let result = await exportRun(["GITHUB_ENV": envFile.filePath], folder, [("A", "1"), ("A", "2")])

            #expect(result.exitCode == 0)
            #expect(try String(contentsOf: envFile, encoding: .utf8) == "EXISTING=yes\nA=1\nA=2\n")
        }

        @Test func githubWithoutOutputFileWritesOnlyTheEnvFile() async throws {
            let folder = try makeFolder()
            defer { removeFolder(folder) }
            let envFile = folder.appending(path: "github_env")

            let result = await exportRun(["GITHUB_ENV": envFile.filePath], folder, [("A", "1")])

            #expect(result.exitCode == 0)
            #expect(try String(contentsOf: envFile, encoding: .utf8) == "A=1\n")
            #expect(!FileManager.default.fileExists(atPath: outputsFile(folder).filePath))
        }

        @Test func dotenvCreatesTheFileAndReplacesANameInPlace() async throws {
            let folder = try makeFolder()
            defer { removeFolder(folder) }

            let result = await exportRun([:], folder, [("A", "1"), ("B", "2"), ("A", "3")])

            #expect(result.exitCode == 0)
            #expect(try String(contentsOf: outputsFile(folder), encoding: .utf8) == "A=3\nB=2\n")
        }

        @Test func dotenvKeepsNamesOfAnEarlierBuildAndDropsBlankAndDuplicateLines() async throws {
            let folder = try makeFolder()
            defer { removeFolder(folder) }
            try FileManager.default.createDirectory(at: folder.appending(path: "artifacts"), withIntermediateDirectories: true)
            try "OLD=1\n\nA=0\nDUP=x\nA=7\n".write(to: outputsFile(folder), atomically: true, encoding: .utf8)

            let result = await exportRun([:], folder, [("A", "5"), ("NEW", "value")])

            #expect(result.exitCode == 0)
            #expect(try String(contentsOf: outputsFile(folder), encoding: .utf8) == "OLD=1\nA=5\nDUP=x\nNEW=value\n")
        }

        @Test func jenkinsWithoutAnEnvstoreExportsToDotenv() async throws {
            let folder = try makeFolder()
            defer { removeFolder(folder) }
            let runner = ProcessRunnerMock()

            let result = await exportRun(jenkins, folder, runner: runner, [("MYAPP_IPA_PATH", "/tmp/MyApp.ipa")])

            #expect(result.exitCode == 0)
            #expect(runner.tools.isEmpty)
            #expect(try String(contentsOf: outputsFile(folder), encoding: .utf8) == "MYAPP_IPA_PATH=/tmp/MyApp.ipa\n")
        }

        @Test func scriptAdapterExporterWinsOverGitHub() async throws {
            let folder = try makeFolder()
            defer { removeFolder(folder) }
            let envFile = folder.appending(path: "github_env")
            let recorder = ExportRecorder()

            let result = await exportRun(
                ["GITHUB_ENV": envFile.filePath],
                folder,
                ciAdapters: [ExporterAdapter(recorder: recorder)],
                [("A", "1")]
            )

            #expect(result.exitCode == 0)
            #expect(recorder.exports.map { "\($0.name)=\($0.value)" } == ["A=1"])
            #expect(!FileManager.default.fileExists(atPath: envFile.filePath))
        }

        @Test func scriptAdapterWithoutExporterLeavesTheExportToTheBuiltIn() async throws {
            let folder = try makeFolder()
            defer { removeFolder(folder) }
            let envFile = folder.appending(path: "github_env")
            try "".write(to: envFile, atomically: true, encoding: .utf8)

            let result = await exportRun(
                ["GITHUB_ENV": envFile.filePath],
                folder,
                ciAdapters: [EnvironmentOnlyAdapter()],
                [("A", "1")]
            )

            #expect(result.exitCode == 0)
            #expect(try String(contentsOf: envFile, encoding: .utf8) == "A=1\n")
        }

        @Test(arguments: ["1BAD", "bad-name", "A B", "", "NAME=x"])
        func invalidNameIsAUsageError(name: String) async throws {
            let folder = try makeFolder()
            defer { removeFolder(folder) }

            let error = await SwiftCITest.withMocks([:], artifactsDirectory: artifactsOf(folder)) {
                await thrownError { try await CI.export(name, "value") }
            }

            #expect(error?.code == .usage)
            #expect(error?.message.contains("is not a variable name") == true)
        }

        @Test(arguments: ["first\nsecond", "first\rsecond", "first\r\nsecond"])
        func lineBreakIsAUsageErrorThatPointsToAFile(value: String) async throws {
            let folder = try makeFolder()
            defer { removeFolder(folder) }

            let error = await SwiftCITest.withMocks([:], artifactsDirectory: artifactsOf(folder)) {
                await thrownError { try await CI.export("NOTES", value) }
            }

            #expect(error?.code == .usage)
            #expect(error?.message.contains("Artifacts.url") == true)
        }

        @Test func valueWithASecretIsAUsageErrorThatDoesNotShowIt() async throws {
            let folder = try makeFolder()
            defer { removeFolder(folder) }

            let error = await SwiftCITest.withMocks([:], artifactsDirectory: artifactsOf(folder)) {
                _ = Secret(value: "hunter22")
                return await thrownError { try await CI.export("TOKEN_COPY", "prefix-hunter22-suffix") }
            }

            #expect(error?.code == .usage)
            #expect(error?.message.contains("hunter22") == false)
            #expect(!FileManager.default.fileExists(atPath: outputsFile(folder).filePath))
        }

        @Test func usageErrorsExitWithCodeTwoAndWriteNothing() async throws {
            let folder = try makeFolder()
            defer { removeFolder(folder) }
            let runner = ProcessRunnerMock()

            let result = await SwiftCITest.run(["export"], environment: ["ENVMAN_ENVSTORE_PATH": "/tmp/envstore.yml"], artifactsDirectory: folder.appending(path: "artifacts"), runner: runner) {
                command(Command("export") {
                    try await CI.export("A", "1")
                    try await CI.export("bad-name", "2")
                })
            }

            #expect(result.exitCode == 2)
            #expect(runner.tools.map(\.arguments) == [["add", "--key", "A"]])
            #expect(result.log.contains { stripANSI($0).contains("bad-name") })
        }

        @Test func secretInValueExitsWithCodeTwo() async throws {
            let folder = try makeFolder()
            defer { removeFolder(folder) }

            let result = await SwiftCITest.run(["export"], artifactsDirectory: artifactsOf(folder)) {
                _ = Secret(value: "hunter22")
                command(Command("export") {
                    try await CI.export("A", "x hunter22 y")
                })
            }

            #expect(result.exitCode == 2)
            #expect(!result.log.contains { $0.contains("hunter22") })
            #expect(!FileManager.default.fileExists(atPath: outputsFile(folder).filePath))
        }

        @Test func lineBreakExitsWithCodeTwoAndWritesNothing() async throws {
            let folder = try makeFolder()
            defer { removeFolder(folder) }

            let result = await exportRun([:], folder, [("NOTES", "one\ntwo")])

            #expect(result.exitCode == 2)
            #expect(!FileManager.default.fileExists(atPath: outputsFile(folder).filePath))
        }
    }
}

/// The folder of one test. Its `artifacts` child is not created, and the caller removes the folder.
private func makeFolder() throws -> URL {
    let folder = temporaryArtifactsDirectory().deletingLastPathComponent()
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

private func removeFolder(_ folder: URL) {
    try? FileManager.default.removeItem(at: folder)
}

/// The artifacts directory of a test folder. It is not created.
private func artifactsOf(_ folder: URL) -> URL {
    folder.appending(path: "artifacts", directoryHint: .isDirectory)
}

private func outputsFile(_ folder: URL) -> URL {
    artifactsOf(folder).appending(path: "outputs.env")
}

/// Runs one command that exports `exports` in order, with `environment`, and the artifacts directory in `folder`.
private func exportRun(
    _ environment: [String: String],
    _ folder: URL,
    runner: ProcessRunnerMock = ProcessRunnerMock(),
    ciAdapters: [any CIAdapter] = [],
    _ exports: [(String, String)]
) async -> SwiftCITestResult {
    await SwiftCITest.run(
        ["export"],
        environment: environment,
        artifactsDirectory: artifactsOf(folder),
        ciAdapters: ciAdapters,
        runner: runner
    ) {
        command(Command("export") {
            for (name, value) in exports {
                try await CI.export(name, value)
            }
        })
    }
}

/// Records each export it receives, in order.
private final class ExportRecorder: CIExporter {
    private(set) var exports: [(name: String, value: String)] = []

    func export(name: String, value: String) async throws {
        exports.append((name, value))
    }
}

/// A script adapter that answers only the exporter, with `exporter`.
private struct ExporterAdapter: CIAdapter {
    let recorder: ExportRecorder

    func environment(from variables: [String: String]) -> CIEnvironment? { nil }

    func exporter(from variables: [String: String]) -> (any CIExporter)? { recorder }
}

/// A script adapter that answers only the environment, so the exporter comes from the built-in adapters.
private struct EnvironmentOnlyAdapter: CIAdapter {
    func environment(from variables: [String: String]) -> CIEnvironment? {
        CIEnvironment(system: CISystem(id: "example-ci", name: "Example CI"))
    }
}
