@testable import SwiftCISigning
@testable import SwiftCITestSupport
@testable import SwiftCI
import Foundation
import SwiftCITesting
import Testing

extension GlobalStateTests {
    /// The clone of the repository: one shallow clone into a temporary directory, which is removed afterwards. The Tool
    /// runs through the mock, so nothing is cloned.
    @Suite(.serialized) struct MatchCheckoutTests {
        static let url = "https://git.example.com/certs.git"

        /// The credentials of the clone, with a header in the environment as a secret.
        static func credentials() -> GitCredentials {
            GitCredentials(url: url, environment: [
                "GIT_CONFIG_COUNT": .text("1"),
                "GIT_CONFIG_KEY_0": .text("http.\(url).extraHeader"),
                "GIT_CONFIG_VALUE_0": .secret(Secret(value: "Authorization: Basic Y2k6dG9rZW4=")),
            ])
        }

        /// The temporary directory of a clone, found from the clone's arguments: the parent of its last argument.
        static func directory(of runner: ProcessRunnerMock) throws -> URL {
            let checkout = try #require(runner.tools.first?.arguments.last)
            return URL(filePath: checkout).deletingLastPathComponent()
        }

        @Test func clonesOnceShallowIntoAChildOfATemporaryDirectory() async throws {
            let restore = isolatedGlobalState()
            defer { restore() }
            let (_, runner) = registerToolMocks()
            var checkoutURL: URL?

            try await MatchCheckout.withCheckout(branch: "main", credentials: Self.credentials()) { url in
                checkoutURL = url
            }

            let checkout = try #require(checkoutURL)
            #expect(runner.tools.count == 1)
            #expect(runner.tools[0].command == "/usr/bin/git")
            #expect(runner.tools[0].arguments == ["clone", "--depth", "1", "--branch", "main", "--", Self.url, checkout.filePath])
            #expect(runner.tools[0].environment == Self.credentials().environment)
            #expect(checkout.lastPathComponent == "repository")
            #expect(checkout.deletingLastPathComponent().lastPathComponent.hasPrefix("match-"))
        }

        @Test func theDirectoryIsOwnerOnlyWhileBodyRunsAndIsRemovedAfterwards() async throws {
            let restore = isolatedGlobalState()
            defer { restore() }
            let (_, runner) = registerToolMocks()
            var mode: Int?
            var directoryExisted = false

            try await MatchCheckout.withCheckout(branch: "main", credentials: Self.credentials()) { url in
                let directory = url.deletingLastPathComponent()
                directoryExisted = FileManager.default.fileExists(atPath: directory.filePath)
                let attributes = try FileManager.default.attributesOfItem(atPath: directory.filePath)
                mode = (attributes[.posixPermissions] as? NSNumber)?.intValue
            }

            let directory = try Self.directory(of: runner)
            #expect(directoryExisted)
            #expect(mode == 0o700)
            #expect(!FileManager.default.fileExists(atPath: directory.filePath))
        }

        @Test func aThrowingBodyPropagatesItsErrorAndRemovesTheDirectory() async throws {
            let restore = isolatedGlobalState()
            defer { restore() }
            let (_, runner) = registerToolMocks()
            var thrown: BuildError?

            do {
                try await MatchCheckout.withCheckout(branch: "main", credentials: Self.credentials()) { _ in
                    throw BuildError(message: "body failed")
                }
            } catch let error as BuildError {
                thrown = error
            }

            let directory = try Self.directory(of: runner)
            #expect(thrown?.message == "body failed")
            #expect(!FileManager.default.fileExists(atPath: directory.filePath))
        }

        /// A failed clone throws, `body` does not run, and the directory is removed.
        @Test func aFailedCloneThrowsWithoutRunningBodyAndRemovesTheDirectory() async throws {
            let restore = isolatedGlobalState()
            defer { restore() }
            let (_, runner) = registerToolMocks()
            runner.respond(to: "/usr/bin/git", with: .init(
                result: ToolResult(stdout: "", stderr: "fatal: Remote branch main not found", exitCode: 128)
            ))
            var bodyRan = false
            var thrown: BuildError?

            do {
                try await MatchCheckout.withCheckout(branch: "main", credentials: Self.credentials()) { _ in
                    bodyRan = true
                }
            } catch let error as BuildError {
                thrown = error
            }

            let directory = try Self.directory(of: runner)
            #expect(thrown?.message.contains("exited with code 128") == true)
            #expect(!bodyRan)
            #expect(!FileManager.default.fileExists(atPath: directory.filePath))
        }

        /// The console shows no `Cloning into` line, which only names a temporary path, and shows every other line.
        @Test func consoleFilterHidesOnlyTheCloningLine() {
            #expect(MatchCheckout.consoleFilter("Cloning into '/var/folders/x/match-1/repository'...") == nil)
            #expect(MatchCheckout.consoleFilter("fatal: Remote branch main not found") == "fatal: Remote branch main not found")
            #expect(MatchCheckout.consoleFilter("warning: redirecting to https://git.example.com/certs.git/")
                == "warning: redirecting to https://git.example.com/certs.git/")
        }

        /// The clone runs through the filter, so the tool carries it.
        @Test func theCloneToolHasTheConsoleFilter() async throws {
            let restore = isolatedGlobalState()
            defer { restore() }
            let (_, runner) = registerToolMocks()

            try await MatchCheckout.withCheckout(branch: "main", credentials: Self.credentials()) { _ in }

            #expect(runner.tools[0].filters.count == 1)
        }
    }
}
