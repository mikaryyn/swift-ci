@testable import SwiftCI
@testable import SwiftCITestSupport
import Foundation
import SwiftCITesting
import Testing

extension GlobalStateTests {
    /// `outputFile` of `Tool` writes a copy of every output line to a file: unfiltered, without the `[stderr] ` prefix,
    /// with secrets masked as in the full log. The console and the full log do not change.
    @Suite(.serialized) struct ToolOutputFileTests {
        /// A new folder for one test. The test removes it.
        private func makeTemporaryFolder() -> URL {
            FileManager.default.temporaryDirectory
                .appending(path: "swift-ci-tests", directoryHint: .isDirectory)
                .appending(path: "tool-output-\(UUID().uuidString)", directoryHint: .isDirectory)
        }

        private func fileText(_ url: URL) throws -> String {
            try String(contentsOfFile: url.filePath, encoding: .utf8)
        }

        /// A script that runs one tool with a filter that hides `hide-me` and a block filter that hides `warn`, and
        /// writes the copy to `outputFile`.
        private func runFilteredTool(
            _ arguments: [String] = ["log"],
            outputFile: URL,
            runner: ProcessRunnerMock,
            artifactsDirectory: URL? = nil
        ) async -> SwiftCITestResult {
            await SwiftCITest.run(arguments, artifactsDirectory: artifactsDirectory, runner: runner) {
                command(Command("log") {
                    try await Tool(
                        command: "/usr/bin/fake-tool",
                        filters: [filter("hide-me")],
                        blockFilter: { line in line == "warn" ? [] : [line] },
                        outputFile: outputFile
                    ).run()
                })
            }
        }

        /// The console hides `hide-me` and the block filter hides `warn`, but the file has every line, without the prefix.
        @Test func linesReachTheFileUnfilteredAndWithoutPrefix() async throws {
            let folder = makeTemporaryFolder()
            defer { try? FileManager.default.removeItem(at: folder) }
            let file = folder.appending(path: "tool.log")
            let runner = ProcessRunnerMock()
            runner.responses = [.init(lines: [
                stdoutLine("keep"),
                stdoutLine("hide-me"),
                stderrLine("warn"),
                stderrLine("hide-me"),
            ])]

            let result = await runFilteredTool(outputFile: file, runner: runner)

            let consoleLines = result.log.map(stripANSI)
            #expect(result.exitCode == 0)
            #expect(try fileText(file) == "keep\nhide-me\nwarn\nhide-me\n")
            #expect(consoleLines.contains("keep"))
            #expect(!consoleLines.contains("hide-me"))
            #expect(!consoleLines.contains("warn"))
        }

        /// A secret is masked in the file as it is in the full log, and its value is never written.
        @Test func secretIsMaskedInTheFileAsInTheFullLog() async throws {
            let folder = makeTemporaryFolder()
            defer { try? FileManager.default.removeItem(at: folder) }
            let file = folder.appending(path: "tool.log")
            let runner = ProcessRunnerMock()
            runner.responses = [.init(lines: [
                stdoutLine("token token-value-123 end"),
                stderrLine("error token-value-123"),
            ])]
            var fullLog = ""

            let result = await SwiftCITest.run(["log"], environment: ["SWIFTCI_TEST_OUTPUT_TOKEN": "token-value-123"], runner: runner) {
                _ = Secret("SWIFTCI_TEST_OUTPUT_TOKEN")
                command(Command("log") {
                    try await Tool(command: "/usr/bin/fake-tool", outputFile: file).run()
                    fullLog = try readFullLog()
                })
            }

            let text = try fileText(file)
            #expect(result.exitCode == 0)
            #expect(text == "token \(SecretRegistry.mask) end\nerror \(SecretRegistry.mask)\n")
            #expect(fullLog.contains("[stderr] error \(SecretRegistry.mask)"))
            #expect(!text.contains("token-value-123"))
        }

        /// A second run with the same file replaces the first run's lines.
        @Test func aSecondRunTruncatesTheFile() async throws {
            let folder = makeTemporaryFolder()
            defer { try? FileManager.default.removeItem(at: folder) }
            let file = folder.appending(path: "tool.log")
            let runner = ProcessRunnerMock()
            runner.responses = [
                .init(lines: [stdoutLine("first run"), stdoutLine("first run, more")]),
                .init(lines: [stdoutLine("second run")]),
            ]

            _ = await runFilteredTool(outputFile: file, runner: runner)
            #expect(try fileText(file) == "first run\nfirst run, more\n")

            _ = await runFilteredTool(outputFile: file, runner: runner)
            #expect(try fileText(file) == "second run\n")
        }

        /// The directory of the file is created when it is missing, however many levels it has.
        @Test func missingParentDirectoryIsCreated() async throws {
            let folder = makeTemporaryFolder()
            defer { try? FileManager.default.removeItem(at: folder) }
            let file = folder.appending(path: "missing/nested/tool.log")
            let runner = ProcessRunnerMock()
            runner.responses = [.init(lines: [stdoutLine("line")])]
            #expect(!FileManager.default.fileExists(atPath: file.filePath))

            let result = await runFilteredTool(outputFile: file, runner: runner)

            #expect(result.exitCode == 0)
            #expect(try fileText(file) == "line\n")
        }

        /// The console and the full log of a run are the same with and without the copy.
        @Test func consoleAndFullLogAreUnchangedByTheFile() async throws {
            let folder = makeTemporaryFolder()
            defer { try? FileManager.default.removeItem(at: folder) }
            let artifacts = folder.appending(path: "artifacts", directoryHint: .isDirectory)
            let file = folder.appending(path: "tool.log")
            let lines = [stdoutLine("keep"), stdoutLine("hide-me"), stderrLine("warn")]

            func run(outputFile: URL?) async throws -> (console: [String], fullLog: String) {
                let runner = ProcessRunnerMock()
                runner.responses = [.init(lines: lines)]
                var fullLog = ""
                let result = await SwiftCITest.run(["log"], artifactsDirectory: artifacts, runner: runner) {
                    command(Command("log") {
                        try await Tool(
                            command: "/usr/bin/fake-tool",
                            filters: [filter("hide-me")],
                            outputFile: outputFile
                        ).run()
                        fullLog = try readFullLog()
                    })
                }
                return (result.log, fullLog)
            }

            let without = try await run(outputFile: nil)
            let with = try await run(outputFile: file)

            #expect(with.console == without.console)
            #expect(with.fullLog == without.fullLog)
            #expect(with.fullLog.contains("[stderr] warn"))
            #expect(try fileText(file) == "keep\nhide-me\nwarn\n")
        }

        /// `--verbose` changes the console only. The file is the same, with every line, as without it.
        @Test func verboseDoesNotChangeTheFile() async throws {
            let folder = makeTemporaryFolder()
            defer { try? FileManager.default.removeItem(at: folder) }
            var texts: [String] = []

            for arguments in [["log"], ["log", "--verbose"]] {
                let file = folder.appending(path: "\(UUID().uuidString).log")
                let runner = ProcessRunnerMock()
                runner.responses = [.init(lines: [stdoutLine("keep"), stdoutLine("hide-me"), stderrLine("warn")])]
                _ = await runFilteredTool(arguments, outputFile: file, runner: runner)
                texts.append(try fileText(file))
            }

            #expect(texts == ["keep\nhide-me\nwarn\n", "keep\nhide-me\nwarn\n"])
        }

        /// The shell form takes the same parameter. The filter hides the stdout line on the console only.
        @Test func shellCommandWritesTheFileToo() async throws {
            let folder = makeTemporaryFolder()
            defer { try? FileManager.default.removeItem(at: folder) }
            let file = folder.appending(path: "shell.log")
            let runner = ProcessRunnerMock()
            runner.responses = [.init(lines: [stdoutLine("out"), stderrLine("err")])]

            _ = await SwiftCITest.run(["shell"], runner: runner) {
                command(Command("shell") {
                    try await Tool(shellCommand: "echo out", filters: [filter("out")], outputFile: file).run()
                })
            }

            #expect(try fileText(file) == "out\nerr\n")
        }
    }
}
