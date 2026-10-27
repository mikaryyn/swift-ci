@testable import SwiftCI
@testable import SwiftCITestSupport
import Foundation
import SwiftCITesting
import Testing

extension GlobalStateTests {
    /// The full log is stored in `logs/<command>.log` of the artifacts directory. Failures are simulated through the
    /// internal seams `FullLog.makeDirectory` and `FullLog.closeHandle`, which each test restores.
    @Suite(.serialized) struct FullLogTests {
        @Test func successfulCommandSavesFullLog() async {
            let result = await SwiftCITest.run(["saved"]) {
                command(Command("saved") { try await step("Work") { } })
            }

            let lines = result.log.map(stripANSI)
            #expect(result.exitCode == 0)
            #expect(lines.contains { $0.hasPrefix("Saved full log to file://") })
            #expect(FullLog.path == nil)
            #expect(FullLog.file == nil)
        }

        @Test func directoryCreationFailureExitsWithThree() async {
            let original = FullLog.makeDirectory
            FullLog.makeDirectory = { _ in throw TestError.boom }
            defer { FullLog.makeDirectory = original }

            let result = await SwiftCITest.run(["dir"]) {
                command(Command("dir") { })
            }

            let lines = result.log.map(stripANSI)
            #expect(result.exitCode == 3)
            #expect(lines.contains { $0.hasPrefix("<Error> Failed to create the build log directory") && $0.contains("/logs'") })
            #expect(lines.contains("Command [dir] failed"))
            #expect(FullLog.path == nil)
            #expect(FullLog.file == nil)
        }

        /// The log file is switched to a read-only handle, so the next write fails inside the step.
        @Test func writeFailureExitsWithThree() async {
            let result = await SwiftCITest.run(["write"]) {
                command(Command("write") {
                    try FullLog.file?.close()
                    if let path = FullLog.path {
                        FullLog.file = FileHandle(forReadingAtPath: path.filePath)
                    }
                    try await step("Work") { }
                })
            }

            let lines = result.log.map(stripANSI)
            #expect(result.exitCode == 3)
            #expect(lines.filter { $0.hasPrefix("<Error> Failed to write into the build log") }.count == 1)
            #expect(lines.contains("Command [write] failed"))
            #expect(FullLog.path == nil)
            #expect(FullLog.file == nil)
        }

        @Test func closeFailureAfterSuccessfulBodyExitsWithThree() async {
            let original = FullLog.closeHandle
            FullLog.closeHandle = { _ in throw TestError.boom }
            defer { FullLog.closeHandle = original }

            let result = await SwiftCITest.run(["close"]) {
                command(Command("close") { })
            }

            let lines = result.log.map(stripANSI)
            #expect(result.exitCode == 3)
            #expect(lines.filter { $0.hasPrefix("<Error> Failed to close the build log") }.count == 1)
            #expect(lines.contains("Command [close] failed"))
            #expect(FullLog.path == nil)
            #expect(FullLog.file == nil)
        }

        /// The body succeeds, so the close failure decides exit code 3. The `onFailure` handler has not run
        /// yet, so it runs after the close. Its output goes to the console only, and the close error is logged once.
        @Test func closeFailureAfterSuccessfulBodyRunsOnFailureOnce() async {
            let original = FullLog.closeHandle
            FullLog.closeHandle = { _ in throw TestError.boom }
            defer { FullLog.closeHandle = original }

            var events: [String] = []
            let result = await SwiftCITest.run(["close"]) {
                command(Command("close") {
                    onFailure { events.append("onFailure") }
                })
            }

            let lines = result.log.map(stripANSI)
            #expect(result.exitCode == 3)
            #expect(events == ["onFailure"])
            #expect(lines.filter { $0.hasPrefix("<Error> Failed to close the build log") }.count == 1)
            #expect(lines.filter { $0.hasPrefix("<Error>") }.count == 1)
            #expect(lines.last == "Command [close] failed")
            #expect(FullLog.path == nil)
            #expect(FullLog.file == nil)
        }

        /// A failed body keeps its own exit code and message. The close failure is still logged once.
        @Test func bodyFailureKeepsItsCodeWhenCloseAlsoFails() async {
            let original = FullLog.closeHandle
            FullLog.closeHandle = { _ in throw TestError.boom }
            defer { FullLog.closeHandle = original }

            let result = await SwiftCITest.run(["both"]) {
                command(Command("both") { throw BuildError(message: "Body failed.", code: .usage) })
            }

            let lines = result.log.map(stripANSI)
            #expect(result.exitCode == 2)
            #expect(lines.filter { $0 == "<Error> Body failed." }.count == 1)
            #expect(lines.filter { $0.hasPrefix("<Error> Failed to close the build log") }.count == 1)
            #expect(FullLog.path == nil)
            #expect(FullLog.file == nil)
        }
    }
}
