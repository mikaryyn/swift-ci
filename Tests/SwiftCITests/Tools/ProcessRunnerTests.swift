@testable import SwiftCI
@testable import SwiftCITestSupport
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import SwiftCITesting
import Testing

extension GlobalStateTests {
    /// The real runner, with harmless programs. Timeouts are fractions of a second, and the SIGKILL grace period is
    /// shortened where a test needs it. Programs that would run for a long time are replaced with `exec sleep 30`, so
    /// the process ending is the child that SwiftCI ends. Tests with a background child wait for it to end by
    /// itself, without signaling it, so no process outlives the test.
    @Suite(.serialized) struct ProcessRunnerTests {
        @Test func stdoutAndStderrAreKeptApartInOrderWithinEachStream() async throws {
            let (result, lines) = try await runProcess(Tool(shellCommand: "echo o1; echo e1 >&2; echo o2; echo e2 >&2"))

            #expect(result.stdout == "o1\no2")
            #expect(result.stderr == "e1\ne2")
            #expect(result.exitCode == 0)
            #expect(lines.filter { $0.stream == .stdout }.map(\.text) == ["o1", "o2"])
            #expect(lines.filter { $0.stream == .stderr }.map(\.text) == ["e1", "e2"])
        }

        @Test func aFinalLineWithoutLineFeedIsALine() async throws {
            let (result, lines) = try await runProcess(Tool(shellCommand: #"printf 'a\nb'"#))

            #expect(result.stdout == "a\nb")
            #expect(lines.map(\.text) == ["a", "b"])
        }

        @Test func crlfLineEndsAreStrippedButALoneCarriageReturnIsKept() async throws {
            let (result, lines) = try await runProcess(Tool(shellCommand: #"printf 'a\r\nb\r\nc\rd\n'"#))

            #expect(lines.map(\.text) == ["a", "b", "c\rd"])
            #expect(result.stdout == "a\nb\nc\rd")
        }

        @Test func invalidUTF8IsReplaced() async throws {
            let (_, lines) = try await runProcess(Tool(shellCommand: #"printf 'a\377b\n'"#))

            #expect(lines.map(\.text) == ["a\u{FFFD}b"])
        }

        /// The program writes the two bytes of `é` in two writes with a pause between them, so they arrive in
        /// different reads.
        @Test func multiByteCharacterSplitAcrossReadsIsDecodedWhole() async throws {
            let (_, lines) = try await runProcess(Tool(shellCommand: #"printf '\303'; sleep 0.2; printf '\251\n'"#))

            #expect(lines.map(\.text) == ["é"])
        }

        @Test func lineSplitterKeepsACharacterSplitAcrossChunks() {
            var splitter = LineSplitter()

            #expect(splitter.append(Data([0xC3])) == [])
            #expect(splitter.append(Data([0xA9, 0x0A, 0x61])) == ["é"])
            #expect(splitter.finish() == "a")
            #expect(splitter.finish() == nil)
        }

        /// Each line is 63 bytes and 16384 lines make exactly 1 MiB. The lines are read at the same time from both
        /// streams, so neither pipe can fill up while the other is read.
        @Test func moreThanOneMegabyteOnBothStreamsAtOnceIsReadCompletely() async throws {
            let payload = String(repeating: "0123456789", count: 6) + "abc"
            let script = "yes '\(payload)' | head -c 1048576 & yes '\(payload)' | head -c 1048576 >&2; wait"

            let (result, lines) = try await runProcess(Tool(shellCommand: script))

            let stdout = lines.filter { $0.stream == .stdout }.map(\.text)
            let stderr = lines.filter { $0.stream == .stderr }.map(\.text)
            #expect(result.exitCode == 0)
            #expect(stdout.count == 16384)
            #expect(stderr.count == 16384)
            #expect(Set(stdout) == [payload])
            #expect(Set(stderr) == [payload])
        }

        @Test func oneMegabyteOfInputIsWrittenWhileTheOutputIsRead() async throws {
            let payload = String(repeating: "0123456789", count: 6) + "abc"
            let input = Data(String(repeating: payload + "\n", count: 16384).utf8)
            #expect(input.count == 1048576)

            let (result, lines) = try await runProcess(Tool(command: "/bin/cat", input: .data(input)))

            #expect(result.exitCode == 0)
            #expect(lines.count == 16384)
            #expect(lines.allSatisfy { $0.stream == .stdout && $0.text == payload })
        }

        /// The program closes its standard input before reading it. The write fails with EPIPE, which is not an error
        /// of the run, and the process exits normally. SwiftCI leaves the process's SIGPIPE disposition unchanged.
        @Test func childClosingStdinEarlyExitsNormallyAndKeepsSIGPIPE() async throws {
            let handlerBefore = sigpipeHandler()
            let input = Data(repeating: 0x61, count: 1048576)

            let (result, _) = try await runProcess(Tool(shellCommand: "exec 0<&-; echo done", input: .data(input)))

            #expect(result.exitCode == 0)
            #expect(result.stdout == "done")
            #expect(sigpipeHandler() == handlerBefore)
        }

        @Test func withoutInputStandardInputIsEmpty() async throws {
            let (result, _) = try await runProcess(Tool(command: "/bin/cat"))

            #expect(result.stdout == "")
            #expect(result.exitCode == 0)
        }

        @Test func environmentAddsToAndOverridesTheInheritedEnvironment() async throws {
            setenv("SWIFTCI_TEST_INHERITED", "inherited", 1)
            setenv("SWIFTCI_TEST_SHARED", "inherited", 1)
            defer {
                unsetenv("SWIFTCI_TEST_INHERITED")
                unsetenv("SWIFTCI_TEST_SHARED")
            }
            let tool = Tool(
                shellCommand: ##"echo "$SWIFTCI_TEST_SHARED $SWIFTCI_TEST_ADDED $SWIFTCI_TEST_INHERITED""##,
                environment: ["SWIFTCI_TEST_SHARED": "override", "SWIFTCI_TEST_ADDED": "added"]
            )

            let (result, _) = try await runProcess(tool)

            #expect(result.stdout == "override added inherited")
        }

        @Test func workingDirectoryAppliesToTheProcess() async throws {
            let scratch = try ScratchDirectory()
            try "here".write(to: scratch.url.appending(path: "marker"), atomically: true, encoding: .utf8)

            let (result, _) = try await runProcess(Tool(shellCommand: "cat marker", workingDirectory: scratch.url))

            #expect(result.stdout == "here")
        }

        @Test func relativeCommandPathIsResolvedAgainstWorkingDirectory() async throws {
            let scratch = try ScratchDirectory()
            try scratch.writeProgram("swift-ci-prog", body: "echo found")

            let (result, _) = try await runProcess(Tool(command: "./swift-ci-prog", workingDirectory: scratch.url))

            #expect(result.stdout == "found")
        }

        // MARK: Program lookup

        @Test func programNameIsFoundInTheEnvironmentPath() async throws {
            let scratch = try ScratchDirectory()
            try scratch.writeProgram("bin/swift-ci-prog", body: "echo found")
            let bin = scratch.url.appending(path: "bin")

            let (result, _) = try await runProcess(Tool(command: "swift-ci-prog", environment: ["PATH": .text(bin.path)]))

            #expect(result.stdout == "found")
        }

        @Test func theFirstPathDirectoryWithTheProgramWins() async throws {
            let scratch = try ScratchDirectory()
            try scratch.writeProgram("first/swift-ci-prog", body: "echo first")
            try scratch.writeProgram("second/swift-ci-prog", body: "echo second")
            let path = [scratch.url.appending(path: "first").path, scratch.url.appending(path: "second").path]

            let (result, _) = try await runProcess(Tool(command: "swift-ci-prog", environment: ["PATH": .text(path.joined(separator: ":"))]))

            #expect(result.stdout == "first")
        }

        @Test func aFileThatIsNotExecutableIsNotFoundByName() async throws {
            let scratch = try ScratchDirectory()
            try scratch.writeProgram("bin/swift-ci-prog", body: "echo found", executable: false)
            let bin = scratch.url.appending(path: "bin").path

            let error = await thrownError {
                _ = try await runProcess(Tool(command: "swift-ci-prog", environment: ["PATH": .text(bin)]))
            }

            #expect(error?.message == "Failed to execute tool 'swift-ci-prog': no executable with this name in PATH '\(bin)'. Check the name, or pass the full path.")
            #expect(error?.code == .failure)
        }

        @Test func aMissingProgramNamesTheCommandAndTheSearchedPath() async throws {
            let scratch = try ScratchDirectory()
            let bin = scratch.url.appending(path: "bin").path

            let error = await thrownError {
                _ = try await runProcess(Tool(command: "swift-ci-missing", environment: ["PATH": .text(bin)]))
            }

            #expect(error?.message.contains("'swift-ci-missing'") == true)
            #expect(error?.message.contains("PATH '\(bin)'") == true)
        }

        /// A relative `PATH` entry is skipped. It is not resolved against the working directory, so the program in
        /// `rel` is not found.
        @Test func relativePathEntriesAreSkipped() async throws {
            let scratch = try ScratchDirectory()
            try scratch.writeProgram("rel/swift-ci-prog", body: "echo relative")

            let error = await thrownError {
                _ = try await runProcess(Tool(
                    command: "swift-ci-prog",
                    environment: ["PATH": .text("rel")],
                    workingDirectory: scratch.url
                ))
            }

            #expect(error?.message.hasPrefix("Failed to execute tool 'swift-ci-prog'") == true)
        }

        @Test func emptyPathEntriesAreSkipped() async throws {
            let scratch = try ScratchDirectory()
            try scratch.writeProgram("bin/swift-ci-prog", body: "echo found")
            let bin = scratch.url.appending(path: "bin").path

            let (result, _) = try await runProcess(Tool(command: "swift-ci-prog", environment: ["PATH": .text("::\(bin):")]))

            #expect(result.stdout == "found")
        }

        /// Without `PATH` in the effective environment, `/usr/bin:/bin` is searched. The expected value is the first
        /// candidate in that order that exists on this host, so the test holds on macOS and Linux. The lookup gets an
        /// empty environment, so the host's `PATH` does not matter.
        @Test func missingPathUsesTheDefaultSearchPath() throws {
            let expected = ["/usr/bin/sh", "/bin/sh"].first { FileManager.default.isExecutableFile(atPath: $0) }
            #expect(expected != nil)

            let path = try ProcessRunnerImpl.programPath(for: Tool(command: "sh"), environment: [:])

            #expect(path == expected)
        }

        /// A FIFO named like the program sits in the first `PATH` directory. It is executable, but not a regular file,
        /// so the lookup skips it and finds the program in the second directory.
        @Test func specialFileEarlierInPathIsSkipped() async throws {
            let scratch = try ScratchDirectory()
            let first = scratch.url.appending(path: "first")
            try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
            #expect(mkfifo(first.appending(path: "swift-ci-prog").path, 0o755) == 0)
            try scratch.writeProgram("second/swift-ci-prog", body: "echo second")
            let path = [first.path, scratch.url.appending(path: "second").path].joined(separator: ":")

            let (result, _) = try await runProcess(Tool(command: "swift-ci-prog", environment: ["PATH": .text(path)]))

            #expect(result.stdout == "second")
        }

        /// A symbolic link to an executable regular file counts as that file.
        @Test func symbolicLinkToAnExecutableIsFound() async throws {
            let scratch = try ScratchDirectory()
            let target = try scratch.writeProgram("real/swift-ci-target", body: "echo linked")
            let bin = scratch.url.appending(path: "bin")
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: bin.appending(path: "swift-ci-prog"), withDestinationURL: target)

            let (result, _) = try await runProcess(Tool(command: "swift-ci-prog", environment: ["PATH": .text(bin.path)]))

            #expect(result.stdout == "linked")
        }

        /// The program exists, but the working directory does not, so `posix_spawn` fails. The error names the command,
        /// and every descriptor the run created is closed again.
        @Test func spawnFailureNamesTheCommandAndLeaksNoDescriptors() async throws {
            let scratch = try ScratchDirectory()
            let descriptorsBefore = try openDescriptorCount()

            let error = await thrownError {
                _ = try await runProcess(Tool(
                    command: "/bin/sh",
                    arguments: ["-c", "exit 0"],
                    workingDirectory: scratch.url.appending(path: "missing")
                ))
            }

            #expect(error?.message.hasPrefix("Failed to execute tool '/bin/sh': Details: ") == true)
            #expect(error?.code == .failure)
            #expect(try openDescriptorCount() == descriptorsBefore)
            #expect(ProcessRunnerImpl.openWorkerCount == 0)
        }

        @Test func aPathWithSlashThatIsNotExecutableIsRejected() async throws {
            let scratch = try ScratchDirectory()
            try scratch.writeProgram("swift-ci-prog", body: "echo found", executable: false)

            let error = await thrownError {
                _ = try await runProcess(Tool(command: "./swift-ci-prog", workingDirectory: scratch.url))
            }

            #expect(error?.message.hasPrefix("Failed to execute tool './swift-ci-prog': there is no executable file at this path.") == true)
        }

        // MARK: Timeouts, signals and ending the process

        @Test func timeoutEndsTheProcessAndThrows() async throws {
            let start = ContinuousClock.now
            let descriptorsBefore = try openDescriptorCount()

            let error = await thrownError {
                _ = try await runProcess(Tool(command: "/bin/sleep", arguments: ["30"], timeout: .milliseconds(200)))
            }

            #expect(error?.message.hasPrefix("sleep timed out after ") == true)
            #expect(error?.code == .failure)
            #expect(ContinuousClock.now - start < .seconds(5))
            #expect(try openDescriptorCount() == descriptorsBefore)
            #expect(ProcessRunnerImpl.openWorkerCount == 0)
        }

        /// The timeout covers the whole run. The shell exits at once, but a background subshell keeps stdout open, and
        /// the deadline still ends the run. The subshell writes a marker file after its 3-second sleep. The run must
        /// return well before that, and the test waits for the marker, so the subshell ends inside the test.
        @Test func timeoutAppliesWhenOnlyADescendantHoldsThePipes() async throws {
            let scratch = try ScratchDirectory()
            let marker = scratch.url.appending(path: "done")
            let descriptorsBefore = try openDescriptorCount()
            let start = ContinuousClock.now

            let error = await thrownError {
                _ = try await runProcess(Tool(
                    shellCommand: "(sleep 3; touch '\(marker.path)') & exit 0",
                    timeout: .milliseconds(300)
                ))
            }
            let elapsed = ContinuousClock.now - start

            #expect(error?.message.hasPrefix("Shell command timed out after ") == true)
            #expect(elapsed < .seconds(2))
            #expect(!FileManager.default.fileExists(atPath: marker.path))
            #expect(try openDescriptorCount() == descriptorsBefore)
            #expect(ProcessRunnerImpl.openWorkerCount == 0)

            #expect(try await waitForFile(marker, limit: .seconds(10)))
        }

        /// Input larger than the pipe capacity, and a background child that holds the read end of stdin without
        /// reading it. The program exits with 0 at once. Its output ends, so the run completes, releases the blocked
        /// writer and returns without waiting for the child. The unread input is dropped. The subshell writes a
        /// marker after its 3-second sleep, and the test waits for it.
        @Test func unreadInputHeldByADescendantDoesNotBlockCompletion() async throws {
            let scratch = try ScratchDirectory()
            let marker = scratch.url.appending(path: "done")
            let descriptorsBefore = try openDescriptorCount()
            let input = Data(repeating: 0x61, count: 1048576)
            let start = ContinuousClock.now

            let (result, _) = try await runProcess(Tool(
                shellCommand: "exec 3<&0; (sleep 3; touch '\(marker.path)') <&3 >/dev/null 2>&1 & exit 0",
                input: .data(input)
            ))
            let elapsed = ContinuousClock.now - start

            #expect(result.exitCode == 0)
            #expect(elapsed < .seconds(2))
            #expect(!FileManager.default.fileExists(atPath: marker.path))
            #expect(try openDescriptorCount() == descriptorsBefore)
            #expect(ProcessRunnerImpl.openWorkerCount == 0)

            #expect(try await waitForFile(marker, limit: .seconds(10)))
        }

        /// The process ignores SIGTERM, so it is killed with SIGKILL after the grace period. The grace period is
        /// shortened for this test. Without SIGKILL the run would wait for the 30-second `sleep`.
        @Test func processThatIgnoresSIGTERMIsKilledAfterTheGracePeriod() async throws {
            let original = ProcessRunnerImpl.killGrace
            ProcessRunnerImpl.killGrace = .milliseconds(200)
            defer { ProcessRunnerImpl.killGrace = original }
            let start = ContinuousClock.now

            let error = await thrownError {
                _ = try await runProcess(Tool(shellCommand: #"trap "" TERM; exec sleep 30"#, timeout: .milliseconds(200)))
            }

            #expect(error?.message.hasPrefix("Shell command timed out after ") == true)
            #expect(ContinuousClock.now - start < .seconds(5))
        }

        /// A program that kills itself with SIGTERM ends with 128 + 15 = 143, as a shell reports it.
        @Test func exitedBySIGTERMGivesCode143() async throws {
            let (result, _) = try await runProcess(Tool(shellCommand: "kill -TERM $$"))

            #expect(result.exitCode == 143)
        }

        /// A program that kills itself with SIGKILL ends with 128 + 9 = 137.
        @Test func exitedBySIGKILLGivesCode137() async throws {
            let (result, _) = try await runProcess(Tool(shellCommand: "kill -KILL $$"))

            #expect(result.exitCode == 137)
        }

        /// Sustained output with a slow `onLine`. Each callback blocks for 0.2 seconds, so buffered lines pile up. The
        /// deadline is still enforced on time, because the supervisor thread does not wait for the main actor. The
        /// run ends within a bounded time, not after the backlog.
        @Test func slowOnLineDoesNotDelayTheTimeout() async throws {
            let descriptorsBefore = try openDescriptorCount()
            let start = ContinuousClock.now

            let error = await thrownError {
                _ = try await ProcessRunnerImpl().run(
                    Tool(shellCommand: "while true; do echo line; done", timeout: .milliseconds(500))
                ) { _ in
                    Thread.sleep(forTimeInterval: 0.2)
                }
            }

            #expect(error?.message.hasPrefix("Shell command timed out after ") == true)
            #expect(ContinuousClock.now - start < .seconds(3))
            #expect(try openDescriptorCount() == descriptorsBefore)
            #expect(ProcessRunnerImpl.openWorkerCount == 0)
        }

        /// An error from `onLine` ends the process the same way as a timeout, and is rethrown unchanged.
        @Test func errorFromOnLineEndsTheProcessAndIsRethrown() async throws {
            let start = ContinuousClock.now
            let descriptorsBefore = try openDescriptorCount()
            var caught: Error?

            do {
                _ = try await ProcessRunnerImpl().run(Tool(shellCommand: "echo first; exec sleep 30")) { _ in
                    throw TestError.boom
                }
            } catch {
                caught = error
            }

            #expect(caught as? TestError == .boom)
            #expect(ContinuousClock.now - start < .seconds(5))
            #expect(try openDescriptorCount() == descriptorsBefore)
            #expect(ProcessRunnerImpl.openWorkerCount == 0)
        }

        // MARK: Cancellation

        /// Cancelling the calling task ends a running process, waits for it to be reaped, and throws
        /// `CancellationError`. No descriptor or worker of the run remains.
        @Test func cancellingARunningProcessStopsItAndThrowsCancellation() async throws {
            let descriptorsBefore = try openDescriptorCount()
            let start = ContinuousClock.now
            let task = Task { try await ProcessRunnerImpl().run(Tool(shellCommand: "echo first; exec sleep 30")) { _ in } }

            try await Task.sleep(for: .milliseconds(200))
            task.cancel()

            #expect(await throwsCancellation { _ = try await task.value })
            #expect(ContinuousClock.now - start < .seconds(5))
            #expect(try openDescriptorCount() == descriptorsBefore)
            #expect(ProcessRunnerImpl.openWorkerCount == 0)
        }

        /// The task is cancelled right after the child has started, inside the run. The run still ends the child and
        /// throws `CancellationError`.
        @Test func cancellingRightAfterSpawnStopsTheProcess() async throws {
            var task: Task<ToolResult, Error>?
            ProcessRunnerImpl.afterSpawnHook = { task?.cancel() }
            defer { ProcessRunnerImpl.afterSpawnHook = nil }
            let descriptorsBefore = try openDescriptorCount()
            let start = ContinuousClock.now

            task = Task { try await ProcessRunnerImpl().run(Tool(shellCommand: "exec sleep 30")) { _ in } }

            #expect(await throwsCancellation { _ = try await task?.value })
            #expect(ContinuousClock.now - start < .seconds(5))
            #expect(try openDescriptorCount() == descriptorsBefore)
            #expect(ProcessRunnerImpl.openWorkerCount == 0)
        }

        // MARK: SIGCHLD

        /// The host ignores SIGCHLD, so the kernel would reap the child. The run refuses to start, and no process is
        /// started. The disposition is restored afterwards.
        @Test func runRefusesToStartWhenSIGCHLDIsIgnored() async throws {
            let old = replaceSIGCHLD(ignore: true, noChildWait: false)
            defer { restoreSIGCHLD(old) }

            let error = await thrownError {
                _ = try await runProcess(Tool(command: "/bin/echo", arguments: ["started"]))
            }

            #expect(error?.code == .internal)
            #expect(error?.message.contains("SwiftCI must own child reaping") == true)
        }

        /// The same with `SA_NOCLDWAIT`, which also makes the kernel reap children.
        @Test func runRefusesToStartWhenSIGCHLDHasNoCldWait() async throws {
            let old = replaceSIGCHLD(ignore: false, noChildWait: true)
            defer { restoreSIGCHLD(old) }

            let error = await thrownError {
                _ = try await runProcess(Tool(command: "/bin/echo", arguments: ["started"]))
            }

            #expect(error?.code == .internal)
            #expect(error?.message.contains("SwiftCI must own child reaping") == true)
        }

        // MARK: Tool on the real runner

        @Test func resultReturnsStderrAndTheExitCodeOfAFailingProgram() async throws {
            let (result, _) = try await runProcess(Tool(shellCommand: "echo x >&2; exit 4"))

            #expect(result.exitCode == 4)
            #expect(result.stderr == "x")
        }

        @Test func runThrowsNamingTheShellCommandWithTheStderrLines() async {
            let log = LogMock()
            registerDependencies()
            register(Log.self, log)

            let error = await thrownError {
                try await Tool(shellCommand: "echo before; echo x >&2; exit 4").run()
            }

            #expect(error?.message == "Shell command exited with code 4.\nx")
            #expect(log.loggedLines.sorted() == ["before", "x"])
        }
    }
}

/// Runs `body` and returns true if it throws `CancellationError`. Records an issue for any other error.
func throwsCancellation(_ body: () async throws -> Void) async -> Bool {
    do {
        try await body()
        return false
    } catch is CancellationError {
        return true
    } catch {
        Issue.record("Expected CancellationError, got \(error)")
        return false
    }
}

/// Sets the disposition of SIGCHLD and returns the previous one, so that a test can restore it.
func replaceSIGCHLD(ignore: Bool, noChildWait: Bool) -> sigaction {
    var new = sigaction()
    #if canImport(Darwin)
    new.__sigaction_u.__sa_handler = ignore ? SIG_IGN : nil
    #else
    new.__sigaction_handler.sa_handler = ignore ? SIG_IGN : nil
    #endif
    new.sa_flags = noChildWait ? SA_NOCLDWAIT : 0
    var old = sigaction()
    sigaction(SIGCHLD, &new, &old)
    return old
}

func restoreSIGCHLD(_ old: sigaction) {
    var old = old
    sigaction(SIGCHLD, &old, nil)
}

/// Runs `tool` with the real runner and returns the result, and every line in the order it was delivered.
@MainActor
func runProcess(_ tool: Tool) async throws -> (result: ToolResult, lines: [ToolOutputLine]) {
    var lines: [ToolOutputLine] = []
    let result = try await ProcessRunnerImpl().run(tool) { lines.append($0) }
    return (result, lines)
}

/// A new directory under the system temporary directory, removed when the test ends.
final class ScratchDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appending(
            path: "swift-ci-tests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    /// Writes a shell script at `relativePath`, creating its directories, and makes it executable unless
    /// `executable` is `false`.
    @discardableResult
    func writeProgram(_ relativePath: String, body: String, executable: Bool = true) throws -> URL {
        let file = url.appending(path: relativePath)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\n\(body)\n".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: executable ? 0o755 : 0o644], ofItemAtPath: file.path)
        return file
    }
}

/// The number of open descriptors of this process, read from `/dev/fd`. Throws if the directory cannot be read, so a
/// failed measurement fails the test instead of matching another failed measurement.
func openDescriptorCount() throws -> Int {
    try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count
}

/// The current disposition of SIGPIPE, as an address. Read only: the disposition is not changed.
func sigpipeHandler() -> UInt {
    var action = sigaction()
    sigaction(SIGPIPE, nil, &action)
    #if canImport(Darwin)
    return unsafeBitCast(action.__sigaction_u.__sa_handler, to: UInt.self)
    #else
    return unsafeBitCast(action.__sigaction_handler.sa_handler, to: UInt.self)
    #endif
}

/// Waits until `file` exists, for at most `limit`. Used to wait for a background child that ends by itself. Returns
/// whether the file exists.
func waitForFile(_ file: URL, limit: Duration) async throws -> Bool {
    let start = ContinuousClock.now
    while ContinuousClock.now - start < limit {
        if FileManager.default.fileExists(atPath: file.path) {
            return true
        }
        try await Task.sleep(for: .milliseconds(50))
    }
    return FileManager.default.fileExists(atPath: file.path)
}
