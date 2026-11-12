@testable import SwiftCI
@testable import SwiftCITestSupport
import Foundation
import SwiftCITesting
import Testing

extension GlobalStateTests {
    @Suite(.serialized) struct GitTests {
        /// The hash comes from stdout. The console filter hides the output, so the hash is not shown.
        @Test func commitHashRunsGitAndReturnsTheHashQuietly() async throws {
            let (log, runner) = registerToolMocks()
            runner.responses = [.init(stdout: "a1b2c3d")]

            let hash = try await Git().commitHash()

            #expect(hash == "a1b2c3d")
            #expect(runner.tools.count == 1)
            #expect(runner.tools[0].command == "git")
            #expect(runner.tools[0].arguments == ["rev-parse", "--short", "HEAD"])
            #expect(log.loggedLines.isEmpty)
        }

        /// Every call runs in the repository folder of the value.
        @Test func callsRunInTheRepositoryFolder() async throws {
            let (_, runner) = registerToolMocks()
            runner.responses = [.init(stdout: "a1b2c3d"), .init()]
            let repository = URL(fileURLWithPath: "/tmp/repository")

            _ = try await Git(repository: repository).commitHash()
            _ = try await Git(repository: repository).commitTag()

            #expect(runner.tools.allSatisfy { $0.workingDirectory == repository })
        }

        /// The tag is the stdout of `git tag --points-at`. The console does not show it.
        @Test func commitTagReturnsTheTagQuietly() async throws {
            let (log, runner) = registerToolMocks()
            runner.responses = [.init(stdout: "v1.2.3")]

            let tag = try await Git().commitTag()

            #expect(tag == "v1.2.3")
            #expect(runner.tools[0].command == "git")
            #expect(runner.tools[0].arguments == ["tag", "--points-at", "HEAD", "--sort=-creatordate"])
            #expect(log.loggedLines.isEmpty)
        }

        /// With several tags the first line is the newest tag, because `git` sorts them.
        @Test func commitTagReturnsTheFirstOfSeveralTags() async throws {
            let (_, runner) = registerToolMocks()
            runner.responses = [.init(stdout: "v1.2.3\nv1.2.2")]

            #expect(try await Git().commitTag() == "v1.2.3")
        }

        /// No output with exit code 0 means that no tag points at `HEAD`.
        @Test func commitTagReturnsNilWithoutTags() async throws {
            let (log, runner) = registerToolMocks()
            runner.responses = [.init()]

            #expect(try await Git().commitTag() == nil)
            #expect(log.loggedLines.isEmpty)
        }

        /// A failure of `git`, such as a folder that is not a repository, is an error and not "no tag".
        @Test func commitTagThrowsWhenGitFails() async throws {
            let (_, runner) = registerToolMocks()
            runner.responses = [.init(stderr: "fatal: not a git repository", exitCode: 128)]

            await #expect(throws: BuildError.self) {
                try await Git().commitTag()
            }
        }

        /// The body runs in a detached worktree of `HEAD`, which is removed afterwards. Git's output is hidden.
        @Test func temporaryWorktreeRunsBodyAndRemovesTheWorktree() async throws {
            let (log, runner) = registerToolMocks()
            runner.responses = [.init(stdout: "Preparing worktree"), .init()]
            let repository = URL(fileURLWithPath: "/tmp/repository")

            var bodyURL: URL?
            let value = try await Git(repository: repository).withTemporaryWorktree { url in
                bodyURL = url
                return 42
            }

            let worktree = try #require(bodyURL)
            #expect(value == 42)
            #expect(runner.tools.map(\.arguments) == [
                ["worktree", "add", "--detach", "--quiet", worktree.filePath, "HEAD"],
                ["worktree", "remove", "--force", worktree.filePath],
            ])
            #expect(runner.tools.allSatisfy { $0.command == "git" && $0.workingDirectory == repository })
            #expect(log.loggedLines.isEmpty)
            try? FileManager.default.removeItem(at: worktree)
        }

        /// A failing body still removes the worktree, and its error is rethrown.
        @Test func temporaryWorktreeIsRemovedWhenTheBodyThrows() async throws {
            let (_, runner) = registerToolMocks()
            var bodyURL: URL?

            await #expect(throws: BuildError.self) {
                try await Git().withTemporaryWorktree(of: "main") { url in
                    bodyURL = url
                    throw BuildError(message: "Body failed.")
                }
            }

            let worktree = try #require(bodyURL)
            #expect(runner.tools.map(\.arguments) == [
                ["worktree", "add", "--detach", "--quiet", worktree.filePath, "main"],
                ["worktree", "remove", "--force", worktree.filePath],
            ])
            try? FileManager.default.removeItem(at: worktree)
        }

        /// If the worktree cannot be added, the body does not run and the error names the exit code and stderr.
        @Test func temporaryWorktreeThatCannotBeAddedThrowsWithoutRunningTheBody() async throws {
            let (_, runner) = registerToolMocks()
            runner.responses = [.init(stderr: "fatal: invalid reference: nope", exitCode: 128)]
            var bodyRan = false

            do {
                try await Git().withTemporaryWorktree(of: "nope") { _ in bodyRan = true }
                Issue.record("Expected an error")
            } catch {
                #expect("\(error)".contains("git exited with code 128."))
                #expect("\(error)".contains("fatal: invalid reference: nope"))
            }

            #expect(!bodyRan)
            #expect(runner.tools.count == 1)
            let worktree = URL(fileURLWithPath: runner.tools[0].arguments[4])
            #expect(!FileManager.default.fileExists(atPath: worktree.filePath))
        }

        /// If `git` cannot remove the worktree, the folder is deleted and the worktrees are pruned, with a warning. The
        /// result of the body is still returned.
        @Test func temporaryWorktreeThatGitCannotRemoveIsDeletedAndPruned() async throws {
            let (log, runner) = registerToolMocks()
            runner.responses = [.init(), .init(stderr: "fatal: locked", exitCode: 128), .init()]
            var bodyURL: URL?

            let value = try await Git().withTemporaryWorktree { url in
                bodyURL = url
                return "done"
            }

            let worktree = try #require(bodyURL)
            #expect(value == "done")
            #expect(runner.tools.map(\.arguments).last == ["worktree", "prune"])
            #expect(!FileManager.default.fileExists(atPath: worktree.filePath))
            #expect(log.warnings.count == 1)
            #expect(log.warnings.first?.contains("Could not remove the temporary Git worktree \(worktree.filePath)") == true)
        }

        /// A cancelled task still removes the worktree: `git` runs in a task that is not cancelled.
        @Test func temporaryWorktreeIsRemovedWhenTheTaskIsCancelled() async throws {
            _ = registerToolMocks()
            let probe = CancellationProbeRunner()
            register(ProcessRunner.self, probe)

            let task = Task {
                try await Git().withTemporaryWorktree { _ in
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            }
            try await task.value

            let worktree = try #require(probe.runs.first.map { URL(fileURLWithPath: $0.arguments[4]) })
            defer { try? FileManager.default.removeItem(at: worktree) }
            #expect(probe.runs.map(\.arguments.first) == ["worktree", "worktree"])
            #expect(probe.runs.map(\.arguments[1]) == ["add", "remove"])
            #expect(probe.runs.map(\.cancelled) == [false, false])
        }
    }
}

/// Starts nothing. Records the arguments of each run, and whether the calling task was cancelled.
private final class CancellationProbeRunner: ProcessRunner {
    var runs: [(arguments: [String], cancelled: Bool)] = []

    func run(_ tool: Tool, onLine: (ToolOutputLine) throws -> Void) async throws -> ToolResult {
        runs.append((tool.arguments, Task.isCancelled))
        return ToolResult(stdout: "", stderr: "", exitCode: 0)
    }
}
