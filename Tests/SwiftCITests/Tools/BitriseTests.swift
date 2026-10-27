@_spi(Testing) import SwiftCI
@testable import SwiftCI
@testable import SwiftCITestSupport
import Foundation
import SwiftCITesting
import Testing

extension GlobalStateTests {
    /// `Bitrise.run`: the arguments of the CLI, the artifacts directory it gets, secrets, failures, and the output filter
    /// against recordings of a real `bitrise` run (`Fixtures/Bitrise`).
    @Suite(.serialized) struct BitriseTests {
        @Test func runsTheWorkflowInCIModeWithoutConfigOrInventory() async throws {
            let folder = try makeFolder()
            defer { removeFolder(folder) }
            let runner = ProcessRunnerMock()

            let result = await bitriseRun(folder, runner: runner)

            #expect(result.exitCode == 0)
            #expect(runner.tools.count == 1)
            let tool = try #require(runner.tools.first)
            #expect(tool.command == "bitrise")
            #expect(tool.arguments == ["--ci", "run", "fixture"])
        }

        @Test func passesConfigurationAndInventoryAsFilePaths() async throws {
            let folder = try makeFolder()
            defer { removeFolder(folder) }
            let runner = ProcessRunnerMock()
            let configuration = URL(fileURLWithPath: "/tmp/example/bitrise.yml")
            let inventory = URL(fileURLWithPath: "/tmp/example/inventory.yml")

            let result = await bitriseRun(folder, runner: runner, configuration: configuration, inventory: inventory)

            #expect(result.exitCode == 0)
            let tool = try #require(runner.tools.first)
            #expect(tool.arguments == [
                "--ci", "run", "fixture",
                "--config", "/tmp/example/bitrise.yml",
                "--inventory", "/tmp/example/inventory.yml",
            ])
        }

        /// The workflow and SwiftCI write to the same place, so `BITRISE_DEPLOY_DIR` is the artifacts directory.
        @Test func deployDirIsTheArtifactsDirectoryByDefault() async throws {
            let folder = try makeFolder()
            defer { removeFolder(folder) }
            let runner = ProcessRunnerMock()

            let result = await bitriseRun(folder, runner: runner)

            #expect(result.exitCode == 0)
            let tool = try #require(runner.tools.first)
            let deployDir = try #require(tool.environment["BITRISE_DEPLOY_DIR"])
            guard case .text(let path) = deployDir else {
                Issue.record("BITRISE_DEPLOY_DIR should be plain text, not a secret")
                return
            }
            #expect(URL(fileURLWithPath: path).standardizedFileURL == artifactsOf(folder).standardizedFileURL)
        }

        @Test func deployDirSetByTheCallerWins() async throws {
            let folder = try makeFolder()
            defer { removeFolder(folder) }
            let runner = ProcessRunnerMock()

            let result = await bitriseRun(folder, runner: runner, workflowEnvironment: ["BITRISE_DEPLOY_DIR": "/tmp/custom-deploy"])

            #expect(result.exitCode == 0)
            let tool = try #require(runner.tools.first)
            #expect(tool.environment["BITRISE_DEPLOY_DIR"] == .text("/tmp/custom-deploy"))
        }

        /// A secret reaches the process environment, but not the arguments or the console.
        @Test func secretEnvironmentValueIsPassedThroughButNotShown() async throws {
            let folder = try makeFolder()
            defer { removeFolder(folder) }
            let runner = ProcessRunnerMock()
            let secretValue = "s3cr3t-value"

            let result = await SwiftCITest.run(
                ["release"],
                artifactsDirectory: artifactsOf(folder),
                runner: runner
            ) {
                command(Command("release") {
                    try await Bitrise.run(
                        workflow: "fixture",
                        environment: ["API_TOKEN": .secret(Secret(value: secretValue))]
                    )
                })
            }

            #expect(result.exitCode == 0)
            let tool = try #require(runner.tools.first)
            #expect(tool.arguments.allSatisfy { !$0.contains(secretValue) })
            #expect(try tool.effectiveEnvironment()["API_TOKEN"] == secretValue)
            #expect(!result.log.contains { $0.contains(secretValue) })
        }

        /// The message names the workflow and the exit code, and the command fails with a non-zero exit code.
        @Test func failedWorkflowFailsTheCommandAndNamesTheWorkflow() async throws {
            let folder = try makeFolder()
            defer { removeFolder(folder) }
            let runner = ProcessRunnerMock()
            runner.respond(to: "bitrise", with: response(exitCode: 3))

            let result = await bitriseRun(folder, runner: runner, workflow: "upload")

            #expect(result.exitCode == 1)
            #expect(result.plainLog.contains { $0.contains("The Bitrise workflow 'upload' failed with exit code 3.") })
        }

        @Test func stepNameDefaultsToTheWorkflowAndCanBeChosen() async throws {
            let folder = try makeFolder()
            defer { removeFolder(folder) }

            let defaultResult = await bitriseRun(folder, runner: ProcessRunnerMock())
            #expect(enteredSteps(in: defaultResult.log) == ["Entering step [Run Bitrise workflow fixture]"])

            let namedResult = await bitriseRun(folder, runner: ProcessRunnerMock(), stepName: "Upload builds")
            #expect(enteredSteps(in: namedResult.log) == ["Entering step [Upload builds]"])
        }

        /// The mixed recording has a passing, a skipped and a failing step. The console keeps the headers, the step
        /// results, the summary, the final status, and the error and warning lines. The step output is hidden.
        @Test func filterKeepsTheStructureAndErrorsOfAFailingRun() async throws {
            let folder = try makeFolder()
            defer { removeFolder(folder) }
            let runner = ProcessRunnerMock()
            runner.responses = [ProcessRunnerMock.Response(
                lines: try recordingLines("run-mixed"),
                result: ToolResult(stdout: "", stderr: "", exitCode: 1)
            )]

            let result = await bitriseRun(folder, runner: runner)
            let plain = result.plainLog

            #expect(result.exitCode == 1)
            // Kept: headers, step results, summary and final status.
            #expect(plain.contains { $0.contains("Running workflow: fixture") })
            #expect(plain.contains { $0.contains("Switching to workflow: fixture") })
            #expect(plain.contains { $0.contains("| (0) Passing step") })
            #expect(plain.contains { $0.contains("| ✓ | Passing step") })
            #expect(plain.contains { $0.contains("| - | Skipped step (Skipped)") })
            #expect(plain.contains { $0.contains("| x | Failing step (Failed)") })
            #expect(plain.contains { $0.contains("bitrise summary: fixture") })
            #expect(plain.contains { $0.contains("| Total runtime") })
            #expect(plain.contains { $0.contains("Bitrise build failed (exit code: 1)") })
            // Kept: lines that look like a warning or an error, even inside a step.
            #expect(plain.contains { $0.contains("a warning: sample") })
            #expect(plain.contains { $0.contains("error: sample failure") })
            // Hidden: the step output that is neither, the step boxes and the links.
            #expect(!plain.contains { $0.contains("passing step output") })
            #expect(!plain.contains { $0.contains("failing step output") })
            #expect(!plain.contains { $0.contains("exit status 3") })
            #expect(!plain.contains { $0.contains("| id: ./steps/pass") })
            #expect(!plain.contains { $0.contains("This Step was skipped") })
            #expect(!plain.contains { $0.contains("Issue tracker:") })
            #expect(!plain.contains { $0.contains("Invocation started") })
        }

        /// The passing recording has only passing steps, so the final status is success and there are no errors.
        @Test func filterShowsTheSuccessfulFinalStatus() async throws {
            let folder = try makeFolder()
            defer { removeFolder(folder) }
            let runner = ProcessRunnerMock()
            runner.responses = [ProcessRunnerMock.Response(lines: try recordingLines("run-passing"))]

            let result = await bitriseRun(folder, runner: runner, workflow: "passing")
            let plain = result.plainLog

            #expect(result.exitCode == 0)
            #expect(plain.contains { $0.contains("| ✓ | Passing step") })
            #expect(plain.contains { $0.contains("Bitrise build successful") })
            #expect(!plain.contains { $0.contains("passing step output") })
        }
    }
}

/// Runs `Bitrise.run` in a command, with the artifacts directory of `folder`.
private func bitriseRun(
    _ folder: URL,
    runner: ProcessRunnerMock,
    workflow: String = "fixture",
    configuration: URL? = nil,
    inventory: URL? = nil,
    workflowEnvironment: [String: ToolEnvironmentValue] = [:],
    stepName: String? = nil
) async -> SwiftCITestResult {
    await SwiftCITest.run(
        ["release"],
        artifactsDirectory: artifactsOf(folder),
        runner: runner
    ) {
        command(Command("release") {
            try await Bitrise.run(
                workflow: workflow,
                configuration: configuration,
                inventory: inventory,
                environment: workflowEnvironment,
                step: stepName
            )
        })
    }
}

/// The lines of a recording in `Fixtures/Bitrise`, as the runner would deliver them: stdout, one line per entry.
private func recordingLines(_ name: String) throws -> [ToolOutputLine] {
    let url = try #require(Bundle.module.resourceURL?.appending(path: "Fixtures/Bitrise/\(name).txt"))
    let text = try String(contentsOf: url, encoding: .utf8)
    return text.components(separatedBy: "\n").map(stdoutLine)
}

private func makeFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appending(path: "bitrise-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

private func removeFolder(_ folder: URL) {
    try? FileManager.default.removeItem(at: folder)
}

private func artifactsOf(_ folder: URL) -> URL {
    folder.appending(path: "artifacts")
}
