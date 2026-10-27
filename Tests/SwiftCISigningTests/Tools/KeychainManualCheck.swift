@testable import SwiftCISigning
@testable import SwiftCITestSupport
@testable import SwiftCI
import Foundation
import SwiftCITesting
import Testing

extension GlobalStateTests {
    /// Runs SwiftCI's real keychain code against a throwaway keychain. It is skipped unless the environment variable
    /// `SWIFTCI_MANUAL_KEYCHAIN_CHECK` is `1`:
    ///
    ///     SWIFTCI_MANUAL_KEYCHAIN_CHECK=1 swift test --disable-sandbox --filter KeychainManualCheck
    ///
    /// The keychains are created in a new temporary directory, and their passwords go to `security -i` on standard input.
    /// The keychain is locked before each unlock, so that a wrong password is really checked: unlocking an unlocked
    /// keychain succeeds with any password. The check unlocks with the right password and refuses a wrong one.
    ///
    /// The partition list runs with a separate ASCII password that has spaces, quotes and a backslash. On macOS 26 the
    /// `set-key-partition-list -k` tool rejects a non-ASCII password, even when it is passed as a plain argument, so
    /// the non-ASCII password is only used for unlocking. The throwaway keychain has no key item, so the partition
    /// list ends with "could not be found in the keychain" after the passphrase is accepted. The check accepts that
    /// result, and any other failure fails the check.
    ///
    /// Cleanup is unconditional. Every throwaway keychain that exists is deleted, the directory is removed, and the
    /// search list and the default keychain are restored, each attempted even if another step fails. Then the final
    /// state is queried and compared with the snapshot taken before the check. Every cleanup failure is recorded as a
    /// test failure. The check changes nothing in the user's keychains except through those restorations.
    @Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["SWIFTCI_MANUAL_KEYCHAIN_CHECK"] == "1"))
    struct KeychainManualCheck {
        /// Spaces, single and double quotes, a backslash and a non-ASCII character. Used for unlocking.
        static let password = "pass word'\"\\é-1"
        /// Spaces, single and double quotes and a backslash, without non-ASCII characters. Used for the partition list.
        static let partitionPassword = "pass word'\"\\1"

        @Test func unlockPartitionListAndWrongPasswordWorkAgainstAThrowawayKeychain() async throws {
            let restore = secretsSetUp()
            defer { restore() }
            registerDependencies()
            register(Log.self, LogMock())
            _ = Secret(value: Self.password)

            let directory = FileManager.default.temporaryDirectory.appending(
                path: "swift-ci-keychain-check-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
            // One keychain per password: the unlock check uses the non-ASCII password, the partition check the ASCII one.
            let unlockKeychain = directory.appending(path: "unlock.keychain-db").path
            let partitionKeychain = directory.appending(path: "partition.keychain-db").path

            // Snapshot first. If this fails, nothing has been changed yet, so the test just fails.
            let searchBefore = try await Self.security(Self.listQuery)
            let defaultBefore = try await Self.security(Self.defaultQuery)

            var bodyFailure: Error?
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try await Self.checkUnlock(keychain: unlockKeychain, password: Self.password)
                try await Self.checkPartitionList(keychain: partitionKeychain, password: Self.partitionPassword)
            } catch {
                bodyFailure = error
            }

            // Cleanup. Every step is attempted, and each failure is collected instead of stopping the cleanup.
            var cleanupFailures: [String] = []
            for keychain in [unlockKeychain, partitionKeychain] where FileManager.default.fileExists(atPath: keychain) {
                if let failure = await Self.attempt("deleting \(URL(fileURLWithPath: keychain).lastPathComponent)", {
                    try await Tool(command: "/usr/bin/security", arguments: ["delete-keychain", keychain]).run()
                }) {
                    cleanupFailures.append(failure)
                }
                if FileManager.default.fileExists(atPath: keychain) {
                    cleanupFailures.append("The throwaway keychain \(URL(fileURLWithPath: keychain).lastPathComponent) still exists.")
                }
            }
            if FileManager.default.fileExists(atPath: directory.path) {
                do {
                    try FileManager.default.removeItem(at: directory)
                } catch {
                    cleanupFailures.append("Removing the temporary directory failed: \(error)")
                }
            }

            // Restore both settings. Neither depends on the other: a failed search-list restore does not skip the default.
            if let failure = await Self.attempt("restoring the search list", {
                try await Self.restoreSearchList(searchBefore)
            }) {
                cleanupFailures.append(failure)
            }
            if let failure = await Self.attempt("restoring the default keychain", {
                try await Self.restoreDefault(defaultBefore)
            }) {
                cleanupFailures.append(failure)
            }

            // Verify the final state against the snapshot. A failed query is itself a failure.
            for (label, query, before) in [
                ("The keychain search list", Self.listQuery, searchBefore),
                ("The default keychain", Self.defaultQuery, defaultBefore),
            ] {
                do {
                    let after = try await Self.security(query)
                    if after != before {
                        cleanupFailures.append("\(label) differs from its snapshot after cleanup.")
                    }
                } catch {
                    cleanupFailures.append("\(label) could not be queried after cleanup: \(error)")
                }
            }

            for failure in cleanupFailures {
                Issue.record(Comment(rawValue: failure))
            }
            if let bodyFailure {
                throw bodyFailure
            }
        }

        static let listQuery = ["list-keychains", "-d", "user"]
        static let defaultQuery = ["default-keychain", "-d", "user"]

        /// Runs `body`, and returns a description of its failure, or `nil` if it succeeded.
        static func attempt(_ label: String, _ body: () async throws -> Void) async -> String? {
            do {
                try await body()
                return nil
            } catch {
                return "\(label) failed: \(error)"
            }
        }

        static func createKeychain(_ keychain: String, password: String) async throws {
            let create = try SecurityInteractive.tool(for: [
                SecurityArgument(kind: "command", value: "create-keychain"),
                SecurityArgument(kind: "option", value: "-p"),
                SecurityArgument(kind: "keychain password", value: password),
                SecurityArgument(kind: "keychain path", value: keychain),
            ])
            try await create.run()
        }

        /// Unlocks a locked keychain with the right password, and refuses a wrong one.
        static func checkUnlock(keychain: String, password: String) async throws {
            try await createKeychain(keychain, password: password)

            // Lock first, so that each unlock really checks the password.
            try await lock(keychain)
            try await Keychain.unlockKeychain(path: keychain, password: Secret(value: password))

            try await lock(keychain)
            let wrong = await thrownError {
                try await Keychain.unlockKeychain(path: keychain, password: Secret(value: password + "-wrong"))
            }
            #expect(wrong?.code == .failure, "A wrong password must fail the unlock.")
        }

        /// The partition list must accept the passphrase. It may then fail only because the keychain has no key item.
        static func checkPartitionList(keychain: String, password: String) async throws {
            try await createKeychain(keychain, password: password)
            try await lock(keychain)

            let partitionSecret = Secret(value: password)
            let partition = await thrownError {
                try await Fastlane().partitionListTool(keychainURL: URL(fileURLWithPath: keychain), password: partitionSecret).run()
            }
            if let partition {
                #expect(partition.message.contains("could not be found in the keychain"), "The partition list failed for another reason.")
                #expect(!partition.message.contains("not correct"), "The partition list rejected the passphrase.")
                #expect(!partition.message.contains(password))
            }
        }

        static func lock(_ keychain: String) async throws {
            try await Tool(command: "/usr/bin/security", arguments: ["lock-keychain", keychain]).run()
        }

        /// The output of a `security` query: the keychain paths in quotes, one per line.
        static func security(_ arguments: [String]) async throws -> String {
            try await Tool(command: "/usr/bin/security", arguments: arguments).output()
        }

        /// The paths in a `list-keychains` or `default-keychain` output, without spaces and quotes.
        static func paths(in output: String) -> [String] {
            output.split(separator: "\n").map {
                $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            }.filter { !$0.isEmpty }
        }

        static func restoreSearchList(_ output: String) async throws {
            try await Tool(
                command: "/usr/bin/security",
                arguments: ["list-keychains", "-d", "user", "-s"] + paths(in: output)
            ).run()
        }

        static func restoreDefault(_ output: String) async throws {
            guard let path = paths(in: output).first else { return }
            try await Tool(command: "/usr/bin/security", arguments: ["default-keychain", "-d", "user", "-s", path]).run()
        }
    }
}
