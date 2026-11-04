@testable import SwiftCISigning
@testable import SwiftCITestSupport
@testable import SwiftCI
import Foundation
import SwiftCITesting
import Testing

extension GlobalStateTests {
    /// Runs SwiftCI's native match install with the real runner, against a local match repository and a throwaway
    /// keychain. It is skipped unless the environment variable `SWIFTCI_MANUAL_MATCH_CHECK` is `1`:
    ///
    ///     SWIFTCI_MANUAL_MATCH_CHECK=1 swift test --disable-sandbox --filter MatchInstallManualCheck
    ///
    /// The repository is a copy of the v2 fixture, committed in a new Git repository on branch `main`. The keychain is
    /// created in a new temporary keychains directory. `security create-keychain` adds it to the user's search list; the
    /// cleanup restores the search list from its snapshot.
    ///
    /// The check step is expected to fail here. The fixture certificate is self-signed, so `find-identity -v` (which
    /// lists only trusted identities) does not list it, whether or not the keychain is in the search list. The install
    /// therefore throws the "codesign can't use it" error, and the check asserts that error. The import is verified
    /// separately: `security find-identity -p codesigning <keychain>` (without `-v`) lists the identity, which is the
    /// certificate and its key paired, and the profiles are in the temporary profiles directory. A CI Mac run with a real,
    /// trusted certificate is what proves the passing case.
    ///
    /// Cleanup is unconditional. The throwaway keychain is deleted, the temporary directory is removed, and the search
    /// list and the default keychain are restored and compared with their snapshots, as ``KeychainManualCheck`` does.
    /// Every cleanup failure is recorded as a test failure.
    @Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["SWIFTCI_MANUAL_MATCH_CHECK"] == "1"))
    struct MatchInstallManualCheck {
        /// Only ASCII letters and digits: the keychain is created with it on standard input.
        static let keychainPassword = "manualkc1"
        static let keychainName = "swift-ci-manual-match.keychain-db"

        @Test func installFailsOnTheCodesignCheckAndTheImportIsVisibleToSecurity() async throws {
            let restore = secretsSetUp()
            defer { restore() }
            registerDependencies()
            register(Log.self, LogMock())

            let root = FileManager.default.temporaryDirectory.appending(
                path: "swift-ci-match-install-check-\(UUID().uuidString)", directoryHint: .isDirectory
            )
            let repository = root.appending(path: "repository", directoryHint: .isDirectory)
            let keychains = root.appending(path: "Keychains", directoryHint: .isDirectory)
            let profiles = root.appending(path: "Profiles", directoryHint: .isDirectory)
            let keychain = keychains.appending(path: Self.keychainName)

            // Snapshot first. If this fails, nothing has been changed yet, so the test just fails.
            let searchBefore = try await KeychainManualCheck.security(KeychainManualCheck.listQuery)
            let defaultBefore = try await KeychainManualCheck.security(KeychainManualCheck.defaultQuery)

            var bodyFailure: Error?
            do {
                try FileManager.default.createDirectory(at: keychains, withIntermediateDirectories: true)
                try await Self.makeRepository(at: repository)
                try await KeychainManualCheck.createKeychain(keychain.filePath, password: Self.keychainPassword)

                let assets = try MatchSelection.select(
                    type: .adhoc,
                    bundleIdentifiers: ["com.example.app1", "com.example.app2"],
                    teamId: "TEAMID1234",
                    checkout: matchFixtureURL("v2"),
                    password: "fixture-password"
                )
                let certificate = try #require(assets.certificates.first).info

                // The install must fail at the check, after the import and the profiles.
                let error = await thrownError {
                    _ = try await Signing.installMatchAssets(
                        type: .adhoc,
                        bundleIdentifiers: ["com.example.app1", "com.example.app2"],
                        teamId: "TEAMID1234",
                        repository: MatchRepository(url: "file://" + repository.filePath, branch: "main"),
                        password: Secret(value: "fixture-password"),
                        keychain: .existing(name: Self.keychainName, password: Secret(value: Self.keychainPassword)),
                        using: .native,
                        step: nil,
                        keychainsDirectory: keychains,
                        profilesDirectory: profiles,
                        now: Date()
                    )
                }
                #expect(error?.message.hasPrefix("The signing identity \(certificate.commonName) (\(certificate.sha1)) was imported into \(keychain.filePath), but codesign can't use it.") == true)

                // The import, checked without the trust filter: the identity is the certificate paired with its key.
                let identities = try await Tool(
                    command: "/usr/bin/security",
                    arguments: ["find-identity", "-p", "codesigning", keychain.filePath]
                ).output()
                #expect(identities.localizedCaseInsensitiveContains(certificate.sha1))

                for profile in assets.profiles {
                    let written = profiles.appending(path: "\(profile.profile.uuid).mobileprovision")
                    #expect(FileManager.default.fileExists(atPath: written.filePath), "\(profile.profile.uuid) was not written.")
                }
            } catch {
                bodyFailure = error
            }

            // Cleanup. Every step is attempted, and each failure is collected instead of stopping the cleanup.
            var cleanupFailures: [String] = []
            if FileManager.default.fileExists(atPath: keychain.filePath) {
                if let failure = await KeychainManualCheck.attempt("deleting the throwaway keychain", {
                    try await Tool(command: "/usr/bin/security", arguments: ["delete-keychain", keychain.filePath]).run()
                }) {
                    cleanupFailures.append(failure)
                }
                if FileManager.default.fileExists(atPath: keychain.filePath) {
                    cleanupFailures.append("The throwaway keychain still exists.")
                }
            }
            if FileManager.default.fileExists(atPath: root.filePath) {
                do {
                    try FileManager.default.removeItem(at: root)
                } catch {
                    cleanupFailures.append("Removing the temporary directory failed: \(error)")
                }
            }

            // Restore both settings. Neither depends on the other: a failed search-list restore does not skip the default.
            if let failure = await KeychainManualCheck.attempt("restoring the search list", {
                try await KeychainManualCheck.restoreSearchList(searchBefore)
            }) {
                cleanupFailures.append(failure)
            }
            if let failure = await KeychainManualCheck.attempt("restoring the default keychain", {
                try await KeychainManualCheck.restoreDefault(defaultBefore)
            }) {
                cleanupFailures.append(failure)
            }

            // Verify the final state against the snapshot. A failed query is itself a failure.
            for (label, query, before) in [
                ("The keychain search list", KeychainManualCheck.listQuery, searchBefore),
                ("The default keychain", KeychainManualCheck.defaultQuery, defaultBefore),
            ] {
                do {
                    let after = try await KeychainManualCheck.security(query)
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

        /// A new Git repository on branch `main`, with the v2 fixture committed as its only commit.
        static func makeRepository(at repository: URL) async throws {
            try FileManager.default.copyItem(at: matchFixtureURL("v2"), to: repository)
            try await Tool(command: "/usr/bin/git", arguments: ["init", "--quiet", "--initial-branch=main", repository.filePath]).run()
            try await Tool(command: "/usr/bin/git", arguments: ["-C", repository.filePath, "add", "."]).run()
            try await Tool(
                command: "/usr/bin/git",
                arguments: [
                    "-c", "user.name=SwiftCI Manual Check", "-c", "user.email=manual-check@example.invalid",
                    "-C", repository.filePath, "commit", "--quiet", "-m", "Fixture match repository",
                ]
            ).run()
        }
    }
}
