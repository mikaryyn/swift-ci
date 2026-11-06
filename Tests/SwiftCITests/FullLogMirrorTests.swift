@testable import SwiftCI
@testable import SwiftCITestSupport
import Foundation
import SwiftCITesting
import Testing

extension GlobalStateTests {
    /// The full log has every console line as plain text, the raw tool output, the exit codes and the failures of a
    /// command, in the order they happen. The log is read inside the command, or from the artifacts directory after the run.
    @Suite(.serialized) struct FullLogMirrorTests {
        @Test func consoleLinesAreWrittenAsPlainText() async throws {
            var fullLog = ""
            _ = await SwiftCITest.run(["plain"]) {
                command(Command("plain") {
                    @Use var log: Log
                    log.warning("careful")
                    log.success("done")
                    log.error("bad")
                    fullLog = try readFullLog()
                })
            }

            let lines = fullLog.components(separatedBy: "\n")
            #expect(!fullLog.contains("\u{1B}"))
            #expect(lines.contains("<Warning> careful"))
            #expect(lines.contains("✔︎ done"))
            #expect(lines.contains("<Error> bad"))
        }

        /// A line that a filter hides is still in the full log, once, as raw tool output. The console copy of a line is not
        /// written a second time.
        @Test func filteredToolOutputIsWrittenOnceAsRawText() async throws {
            let runner = ProcessRunnerMock()
            runner.responses = [.init(lines: [stdoutLine("keep"), stdoutLine("hide-me")])]
            var fullLog = ""
            let result = await SwiftCITest.run(["tool"], runner: runner) {
                command(Command("tool") {
                    try await Tool(command: "/usr/bin/fake-tool", filters: [{ $0 == "keep" ? $0 : nil }]).run()
                    fullLog = try readFullLog()
                })
            }

            let lines = fullLog.components(separatedBy: "\n")
            #expect(result.plainLog.filter { $0 == "keep" }.count == 1)
            #expect(!result.plainLog.contains("hide-me"))
            #expect(lines.filter { $0 == "keep" }.count == 1)
            #expect(lines.filter { $0 == "hide-me" }.count == 1)
        }

        @Test func exitCodeOfAToolIsWrittenAfterItsOutput() async throws {
            let runner = ProcessRunnerMock()
            runner.respond(to: "/usr/bin/fake-tool", with: response(stdout: "out", exitCode: 3))
            var fullLog = ""
            _ = await SwiftCITest.run(["exit"], runner: runner) {
                command(Command("exit") {
                    _ = try await Tool(command: "/usr/bin/fake-tool").result()
                    fullLog = try readFullLog()
                })
            }

            let lines = fullLog.components(separatedBy: "\n")
            let output = try #require(lines.firstIndex(of: "out"))
            let exit = try #require(lines.firstIndex(of: "➤ Exit code 3"))
            #expect(output < exit)
        }

        /// A runner that throws writes the reason to the full log before the error reaches the step.
        @Test func runnerFailureIsWrittenBeforeTheStepFails() async throws {
            let runner = ProcessRunnerMock()
            runner.responses = [.init(error: BuildError(message: "fake-tool timed out after 1 seconds."))]
            var fullLog = ""
            let result = await SwiftCITest.run(["slow"], runner: runner) {
                command(Command("slow") {
                    do {
                        try await step("Run") { try await Tool(command: "/usr/bin/fake-tool").run() }
                    } catch {
                        fullLog = try readFullLog()
                        throw error
                    }
                })
            }

            let lines = fullLog.components(separatedBy: "\n")
            let reason = try #require(lines.firstIndex(of: "➤ Error: fake-tool timed out after 1 seconds."))
            let failed = try #require(lines.firstIndex(of: "Step [Run] failed"))
            #expect(result.exitCode == 1)
            #expect(reason < failed)
        }

        @Test func nulCharactersAreWrittenAsLineBreaks() async throws {
            let runner = ProcessRunnerMock()
            runner.responses = [.init(lines: [stdoutLine("one\0two")])]
            var fullLog = ""
            _ = await SwiftCITest.run(["nul"], runner: runner) {
                command(Command("nul") {
                    try await Tool(command: "/usr/bin/fake-tool").run()
                    fullLog = try readFullLog()
                })
            }

            let lines = fullLog.components(separatedBy: "\n")
            #expect(lines.contains("one"))
            #expect(lines.contains("two"))
            #expect(!fullLog.contains("\0"))
        }

        @Test func timeoutIsWrittenToTheHeader() async throws {
            var fullLog = ""
            _ = await SwiftCITest.run(["timeout"]) {
                command(Command("timeout") {
                    _ = try? await Tool(command: "/usr/bin/fake-tool", timeout: .seconds(5)).run()
                    fullLog = try readFullLog()
                })
            }

            #expect(fullLog.components(separatedBy: "\n").contains("➤ Timeout 5 s"))
        }

        /// With the real runner, a program name found on `PATH` gets its resolved path in the full log.
        @Test func resolvedExecutableIsWrittenForAProgramNameFromPath() async throws {
            var fullLog = ""
            _ = await SwiftCITest.run(["resolve"]) {
                command(Command("resolve") {
                    register(ProcessRunner.self, ProcessRunnerImpl())
                    try await Tool(command: "true").run()
                    fullLog = try readFullLog()
                })
            }

            let line = try #require(fullLog.components(separatedBy: "\n").first { $0.hasPrefix("➤ Executable ") })
            #expect(line.hasSuffix("/true"))
        }

        @Test func argumentsAndInputsAreWrittenOnce() async throws {
            var fullLog = ""
            _ = await SwiftCITest.run(["build", "--track=beta"]) {
                command(Command("build") {
                    let track: String = try input("track")
                    let device: String = try input("device", default: "iPhone 17")
                    _ = (track, device)
                    fullLog = try readFullLog()
                })
            }

            let lines = fullLog.components(separatedBy: "\n")
            #expect(lines.filter { $0.hasPrefix("➤ Arguments ") } == ["➤ Arguments build --track=beta"])
            #expect(lines.contains("➤ Input track=beta"))
            #expect(lines.contains("➤ Input device=iPhone 17"))
        }

        /// The failure and its exit code are in the full log before it is closed, after the unread options warning.
        @Test func failureAndExitCodeAreWrittenBeforeTheLogIsClosed() async throws {
            let directory = temporaryArtifactsDirectory()
            let result = await SwiftCITest.run(["build", "--unused=1"], artifactsDirectory: directory) {
                command(Command("build") { throw BuildError(message: "Body failed.", code: .usage) })
            }

            let fullLog = try String(contentsOf: directory.appending(path: "logs/build.log"), encoding: .utf8)
            let lines = fullLog.components(separatedBy: "\n")
            let error = try #require(lines.firstIndex(of: "<Error> Body failed."))
            let unread = try #require(lines.firstIndex { $0.hasPrefix("<Warning> No input read these options: --unused") })
            let failed = try #require(lines.firstIndex(of: "Command [build] failed"))
            let exit = try #require(lines.firstIndex(of: "Exit code 2"))
            #expect(result.exitCode == 2)
            #expect(error < unread)
            #expect(unread < failed)
            #expect(failed < exit)
        }

        /// A command that runs again in the same run gets its own log, and the first log is kept.
        @Test func secondRunOfACommandGetsANumberedLog() async {
            let directory = temporaryArtifactsDirectory()
            _ = await SwiftCITest.run(["build", "build"], artifactsDirectory: directory) {
                command(Command("build") { })
            }

            let logs = directory.appending(path: "logs")
            #expect(FileManager.default.fileExists(atPath: logs.appending(path: "build.log").filePath))
            #expect(FileManager.default.fileExists(atPath: logs.appending(path: "build-2.log").filePath))
        }

        @Test func exportIsWrittenWithItsNameOnly() async throws {
            var fullLog = ""
            _ = await SwiftCITest.run(["export"]) {
                command(Command("export") {
                    try await CI.export("MY_NAME", "secret-looking-value")
                    fullLog = try readFullLog()
                })
            }

            let lines = fullLog.components(separatedBy: "\n")
            #expect(lines.contains("Exported MY_NAME"))
            #expect(!fullLog.contains("secret-looking-value"))
        }
    }
}
