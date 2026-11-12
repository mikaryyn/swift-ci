import Foundation

/// A Git repository, as `git` sees it from a working directory. Its methods run `git`.
///
/// ```swift
/// let git = Git()
/// let hash = try await git.commitHash()
/// ```
///
/// A query, such as ``commitHash()``, does not open a step. A check that adds findings to the run report, such as
/// ``reportLines(matching:in:message:severity:step:)``, opens one.
public struct Git {
    /// The working directory of every `git` call: a folder inside the repository. `nil` is the current directory at the
    /// time of each call, not at the time of `init`.
    public let repository: URL?

    /// Creates a repository value. Nothing runs yet.
    ///
    /// - Parameter repository: A folder inside the repository. The current directory if `nil`.
    public init(repository: URL? = nil) {
        self.repository = repository
    }

    /// Returns the short hash of `HEAD`.
    ///
    /// A query: does not open a step. The output of `git` is hidden from the console.
    public func commitHash() async throws -> String {
        try await gitTool(["rev-parse", "--short", "HEAD"]).output()
    }

    /// Returns the tag that points at `HEAD`, or `nil` if there is none.
    ///
    /// If several tags point at `HEAD`, the newest one is returned, by creation date. Of two tags with the same date,
    /// the one that comes first in the alphabet is.
    ///
    /// A query: does not open a step. The output of `git` is hidden from the console.
    public func commitTag() async throws -> String? {
        let output = try await gitTool(["tag", "--points-at", "HEAD", "--sort=-creatordate"]).output()
        return output.split(separator: "\n").first.map(String.init)
    }

    /// Runs `body` in a temporary detached worktree of `revision`, and removes the worktree when `body` returns or
    /// throws. If `git` cannot remove it, the folder is deleted and the worktrees are pruned, with a warning. The
    /// worktree is removed also when the task is cancelled.
    ///
    /// A query: does not open a step. The output of `git` is hidden from the console.
    ///
    /// - Parameters:
    ///   - revision: The commit to check out, `HEAD` by default.
    ///   - body: The work to do in the worktree. It gets the URL of the worktree, which is a repository too:
    ///     `Git(repository: url)`.
    /// - Returns: The result of `body`.
    public func withTemporaryWorktree<T>(of revision: String = "HEAD", _ body: (URL) async throws -> T) async throws -> T {
        let worktree = try TemporaryDirectory(name: "git-worktree-$UUID").url
        do {
            try await gitTool(["worktree", "add", "--detach", "--quiet", worktree.filePath, revision]).run()
        } catch {
            try? FileManager.default.removeItem(at: worktree)
            throw error
        }

        let result: T
        do {
            result = try await body(worktree)
        } catch {
            await removeWorktree(worktree)
            throw error
        }
        await removeWorktree(worktree)
        return result
    }

    /// Removes a worktree of ``withTemporaryWorktree(of:_:)``. A new task is not cancelled with the caller, so the
    /// removal runs also when the caller was cancelled.
    private func removeWorktree(_ worktree: URL) async {
        await Task { await removeWorktreeUncancelled(worktree) }.value
    }

    /// Removes the worktree with `git`. If `git` cannot, deletes the folder and prunes the worktrees, with a warning.
    private func removeWorktreeUncancelled(_ worktree: URL) async {
        @Use var log: Log

        do {
            try await gitTool(["worktree", "remove", "--force", worktree.filePath]).run()
        } catch {
            log.warning("Could not remove the temporary Git worktree \(worktree.filePath): \(error)")
            try? FileManager.default.removeItem(at: worktree)
            try? await gitTool(["worktree", "prune"]).run()
        }
    }

    /// A `git` process in the repository, whose output is hidden from the console.
    func gitTool(_ arguments: [String]) -> Tool {
        Tool(command: "git", arguments: arguments, workingDirectory: repository, filters: [hideAllLines])
    }
}
