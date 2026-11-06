@testable import SwiftCISigning
@testable import SwiftCITestSupport
@testable import SwiftCI
import Foundation
import SwiftCITesting
import Testing

/// The keychain path of a match install, resolved in a temporary directory that holds empty files.
@Suite struct MatchKeychainPathTests {
    @Test func dbFileIsPreferredOverThePlainName() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try makeEmptyFile(in: directory, named: "login")
        try makeEmptyFile(in: directory, named: "login-db")

        let url = try MatchKeychainPath.resolve(name: "login", keychainsDirectory: directory)

        #expect(url.filePath == directory.appending(path: "login-db").filePath)
    }

    @Test func plainNameIsUsedWhenThereIsNoDbFile() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try makeEmptyFile(in: directory, named: "login")

        let url = try MatchKeychainPath.resolve(name: "login", keychainsDirectory: directory)

        #expect(url.filePath == directory.appending(path: "login").filePath)
    }

    /// A name that already ends in `-db` is found by the second rule, under its own name.
    @Test func nameEndingInDbIsFoundUnderItsOwnName() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try makeEmptyFile(in: directory, named: "login.keychain-db")

        let url = try MatchKeychainPath.resolve(name: "login.keychain-db", keychainsDirectory: directory)

        #expect(url.filePath == directory.appending(path: "login.keychain-db").filePath)
    }

    @Test func pathWithSlashIsUsedAsItIs() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try makeEmptyFile(in: directory, named: "custom.keychain-db")
        let path = directory.appending(path: "custom.keychain-db").filePath

        let url = try MatchKeychainPath.resolve(name: path, keychainsDirectory: URL(fileURLWithPath: "/elsewhere"))

        #expect(url.filePath == path)
    }

    @Test func missingNameIsAnErrorThatNamesTheDirectory() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let error = matchBuildError {
            _ = try MatchKeychainPath.resolve(name: "missing", keychainsDirectory: directory)
        }

        #expect(error?.message == "Keychain missing not found in \(directory.filePath). Create it, or pass the name of an existing keychain, such as login.keychain.")
    }

    @Test func missingPathIsAnError() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appending(path: "missing.keychain-db").filePath

        let error = matchBuildError {
            _ = try MatchKeychainPath.resolve(name: path, keychainsDirectory: directory)
        }

        #expect(error?.message == "Keychain \(path) not found. Create it, or pass the path of an existing keychain.")
    }
}

/// The install of the signing assets: the imports, the partition list, the profiles, the identity check and the log.
extension GlobalStateTests {
    @Suite(.serialized) struct MatchInstallationTests {
        static let keychainPassword = "kc-VALUE-secret"
        static let app1UUID = "11111111-1111-4111-8111-111111111111"
        static let app2UUID = "22222222-2222-4222-8222-222222222222"

        @Test func importsTheCertificateThenItsKeyWithTheFixedArguments() async throws {
            let restore = secretsSetUp()
            defer { restore() }
            let (_, runner) = registerToolMocks()
            let assets = try fixtureInstallAssets()
            runner.handler = installHandler(identities: identityOutput(assets))
            let workspace = try InstallWorkspace()

            _ = try await install(assets, workspace: workspace)

            let imports = runner.tools.filter { $0.arguments.first == "import" }
            #expect(imports.count == 2)
            #expect(imports.allSatisfy { $0.command == "/usr/bin/security" })
            let certificate = try #require(imports.first?.arguments)
            let key = try #require(imports.last?.arguments)
            #expect(URL(filePath: certificate[1]).lastPathComponent == "CERTID1234.cer")
            #expect(URL(filePath: key[1]).lastPathComponent == "CERTID1234.p12")
            #expect(certificate == importArguments(certificate[1], keychain: workspace.keychain.filePath))
            #expect(key == importArguments(key[1], keychain: workspace.keychain.filePath))
        }

        /// At import time each file exists with mode 0600 in a 0700 directory, and the key file holds the decrypted key.
        @Test func filesExistWithOwnerOnlyModesAtImportTime() async throws {
            let restore = secretsSetUp()
            defer { restore() }
            let (_, runner) = registerToolMocks()
            let assets = try fixtureInstallAssets()
            var checks: [ImportFileCheck] = []
            runner.handler = installHandler(identities: identityOutput(assets), importResponse: { tool in
                let path = tool.arguments[1]
                let url = URL(filePath: path)
                let directory = url.deletingLastPathComponent()
                checks.append(ImportFileCheck(
                    name: url.lastPathComponent,
                    data: try? Data(contentsOf: url),
                    mode: posixMode(of: path),
                    directoryMode: posixMode(of: directory.filePath)
                ))
                return .init()
            })
            let workspace = try InstallWorkspace()

            _ = try await install(assets, workspace: workspace)

            #expect(checks.map(\.name) == ["CERTID1234.cer", "CERTID1234.p12"])
            #expect(checks[0].data == assets.certificates[0].certificateData)
            #expect(checks[1].data == assets.certificates[0].privateKeyData)
            #expect(checks.allSatisfy { $0.mode == 0o600 && $0.directoryMode == 0o700 })
        }

        @Test func theImportDirectoryIsRemovedAfterSuccess() async throws {
            let restore = secretsSetUp()
            defer { restore() }
            let (_, runner) = registerToolMocks()
            let assets = try fixtureInstallAssets()
            runner.handler = installHandler(identities: identityOutput(assets))
            let workspace = try InstallWorkspace()

            _ = try await install(assets, workspace: workspace)

            let directory = try importDirectory(of: runner)
            #expect(directory.lastPathComponent.hasPrefix("match-import-"))
            #expect(!FileManager.default.fileExists(atPath: directory.filePath))
        }

        @Test func theImportDirectoryIsRemovedAfterAFailedImport() async throws {
            let restore = secretsSetUp()
            defer { restore() }
            let (_, runner) = registerToolMocks()
            let assets = try fixtureInstallAssets()
            runner.handler = installHandler(identities: identityOutput(assets), importResponse: { _ in
                .init(result: ToolResult(stdout: "", stderr: "security: Unknown format.", exitCode: 2))
            })
            let workspace = try InstallWorkspace()

            _ = await thrownError { try await install(assets, workspace: workspace) }

            let directory = try importDirectory(of: runner)
            #expect(!FileManager.default.fileExists(atPath: directory.filePath))
        }

        /// Exit code 1 with the duplicate-item line is success: no error, no warning, and no line on the console.
        @Test func alreadyExistingItemIsSuccessWithoutAWarning() async throws {
            let restore = secretsSetUp()
            defer { restore() }
            let (log, runner) = registerToolMocks()
            let assets = try fixtureInstallAssets()
            let duplicate = "security: SecKeychainItemImport: The specified item already exists in the keychain."
            runner.handler = installHandler(identities: identityOutput(assets), importResponse: { _ in
                .init(
                    lines: [stderrLine(duplicate)],
                    result: ToolResult(stdout: "", stderr: duplicate, exitCode: 1)
                )
            })
            let workspace = try InstallWorkspace()

            let installed = try await install(assets, workspace: workspace)

            #expect(installed.count == 2)
            #expect(log.warnings.isEmpty)
            #expect(!log.loggedLines.contains { $0.contains("already exists") })
        }

        /// Any other exit code 1 throws at the first failed file, with its name, the keychain and the stderr text.
        @Test func otherFailureThrowsWithTheFileNameAndTheStderr() async throws {
            let restore = secretsSetUp()
            defer { restore() }
            let (_, runner) = registerToolMocks()
            let assets = try fixtureInstallAssets()
            let stderr = "security: SecKeychainItemImport: Unknown format."
            runner.handler = installHandler(identities: identityOutput(assets), importResponse: { _ in
                .init(lines: [stderrLine(stderr)], result: ToolResult(stdout: "", stderr: stderr, exitCode: 1))
            })
            let workspace = try InstallWorkspace()

            let error = await thrownError { try await install(assets, workspace: workspace) }

            #expect(error?.message == "security couldn't import CERTID1234.cer into \(workspace.keychain.filePath) (exit code 1). \(stderr)")
            #expect(runner.tools.filter { $0.arguments.first == "import" }.count == 1)
        }

        @Test func exitCodeTwoThrows() async throws {
            let restore = secretsSetUp()
            defer { restore() }
            let (_, runner) = registerToolMocks()
            let assets = try fixtureInstallAssets()
            runner.handler = installHandler(identities: identityOutput(assets), importResponse: { _ in
                .init(result: ToolResult(stdout: "", stderr: "security: usage", exitCode: 2))
            })
            let workspace = try InstallWorkspace()

            let error = await thrownError { try await install(assets, workspace: workspace) }

            #expect(error?.message.contains("exit code 2") == true)
            #expect(error?.message.contains("CERTID1234.cer") == true)
        }

        @Test func partitionListRunsOnceWithOneCertificateAndTwoProfiles() async throws {
            let restore = secretsSetUp()
            defer { restore() }
            let (_, runner) = registerToolMocks()
            let assets = try fixtureInstallAssets()
            runner.handler = installHandler(identities: identityOutput(assets))
            let workspace = try InstallWorkspace()

            _ = try await install(assets, workspace: workspace)

            let partitions = runner.tools.filter { $0.arguments == ["-i"] }
            #expect(partitions.count == 1)
        }

        /// The partition list runs once, after the imports of both certificates, with the password on standard input only.
        @Test func partitionListRunsOnceAfterAllImportsWithThePasswordOnStandardInput() async throws {
            let restore = secretsSetUp()
            defer { restore() }
            let (_, runner) = registerToolMocks()
            let assets = try twoCertificateAssets()
            runner.handler = installHandler(identities: identityOutput(assets))
            let workspace = try InstallWorkspace()

            _ = try await install(assets, workspace: workspace)

            let partitionIndexes = runner.tools.indices.filter { runner.tools[$0].arguments == ["-i"] }
            #expect(partitionIndexes.count == 1)
            let lastImportIndex = try #require(runner.tools.lastIndex(where: { $0.arguments.first == "import" }))
            let partitionIndex = try #require(partitionIndexes.first)
            #expect(partitionIndex > lastImportIndex)
            #expect(try splitSecurityLine(securityLine(of: runner.tools[partitionIndex])) == [
                "set-key-partition-list", "-S", "apple-tool:,apple:,codesign:", "-s", "-k", Self.keychainPassword,
                workspace.keychain.filePath,
            ])
            #expect(!runner.tools.flatMap(\.arguments).contains { $0.contains(Self.keychainPassword) })
        }

        /// A failed partition list is a warning, and the install continues to the profiles and the check.
        @Test func failedPartitionListIsAWarningAndTheInstallContinues() async throws {
            let restore = secretsSetUp()
            defer { restore() }
            let (log, runner) = registerToolMocks()
            let assets = try fixtureInstallAssets()
            runner.handler = installHandler(
                identities: identityOutput(assets),
                partition: .init(result: ToolResult(stdout: "", stderr: "", exitCode: 1))
            )
            let workspace = try InstallWorkspace()

            let installed = try await install(assets, workspace: workspace)

            #expect(installed.count == 2)
            #expect(log.warnings == ["security exited with code 1 while setting the key partition list. The install continues."])
        }

        /// The partition list is a `security -i` call whose header shows only `-i`, so the full log names the operation before
        /// it. The line names the keychain and holds no password.
        @Test func partitionListExplanationIsInTheFullLog() async throws {
            let restore = secretsSetUp()
            defer { restore() }
            let runner = ProcessRunnerMock()
            let assets = try fixtureInstallAssets()
            runner.handler = installHandler(identities: identityOutput(assets))
            let workspace = try InstallWorkspace()
            var fullLog = ""

            let result = await SwiftCITest.run(["install"]) {
                register(ProcessRunner.self, runner)
                command(Command("install") {
                    _ = try await install(assets, workspace: workspace)
                    fullLog = try String(contentsOfFile: FullLog.path?.filePath ?? "", encoding: .utf8)
                })
            }

            #expect(result.exitCode == 0)
            #expect(fullLog.contains("Setting the key partition list of keychain \(workspace.keychain.filePath) with security set-key-partition-list. The command is sent to security -i on standard input."))
            #expect(!fullLog.contains(GlobalStateTests.MatchInstallationTests.keychainPassword))
        }

        @Test func profilesAreWrittenAsUUIDFilesWithTheDecryptedBytes() async throws {
            let restore = secretsSetUp()
            defer { restore() }
            let (_, runner) = registerToolMocks()
            let assets = try fixtureInstallAssets()
            runner.handler = installHandler(identities: identityOutput(assets))
            let workspace = try InstallWorkspace()

            let installed = try await install(assets, workspace: workspace)

            let app1 = workspace.profiles.appending(path: "\(Self.app1UUID).mobileprovision")
            let app2 = workspace.profiles.appending(path: "\(Self.app2UUID).mobileprovision")
            #expect(try Data(contentsOf: app1) == assets.profiles[0].data)
            #expect(try Data(contentsOf: app2) == assets.profiles[1].data)
            #expect(installed.map { $0.url.filePath } == [app1.filePath, app2.filePath])
        }

        /// A file with the same UUID is replaced, and an unrelated file in the directory is untouched.
        @Test func existingProfileWithTheSameUUIDIsReplacedAndOtherFilesAreUntouched() async throws {
            let restore = secretsSetUp()
            defer { restore() }
            let (_, runner) = registerToolMocks()
            let assets = try fixtureInstallAssets()
            runner.handler = installHandler(identities: identityOutput(assets))
            let workspace = try InstallWorkspace()
            try FileManager.default.createDirectory(at: workspace.profiles, withIntermediateDirectories: true)
            let app1 = workspace.profiles.appending(path: "\(Self.app1UUID).mobileprovision")
            let notes = workspace.profiles.appending(path: "notes.txt")
            try Data("old".utf8).write(to: app1)
            try Data("keep".utf8).write(to: notes)

            _ = try await install(assets, workspace: workspace)

            #expect(try Data(contentsOf: app1) == assets.profiles[0].data)
            #expect(try Data(contentsOf: notes) == Data("keep".utf8))
            #expect(try FileManager.default.contentsOfDirectory(atPath: workspace.profiles.filePath).sorted() == [
                "\(Self.app1UUID).mobileprovision", "\(Self.app2UUID).mobileprovision", "notes.txt",
            ])
        }

        @Test func findIdentityArgumentsAreFixed() async throws {
            let restore = secretsSetUp()
            defer { restore() }
            let (_, runner) = registerToolMocks()
            let assets = try fixtureInstallAssets()
            runner.handler = installHandler(identities: identityOutput(assets))
            let workspace = try InstallWorkspace()

            _ = try await install(assets, workspace: workspace)

            let find = try #require(runner.tools.first { $0.arguments.first == "find-identity" })
            #expect(find.command == "/usr/bin/security")
            #expect(find.arguments == ["find-identity", "-v", "-p", "codesigning"])
        }

        /// The SHA-1 is matched without regard to case, so lower-case output is also a listed identity.
        @Test func checkPassesWithALowerCaseSHA1() async throws {
            let restore = secretsSetUp()
            defer { restore() }
            let (_, runner) = registerToolMocks()
            let assets = try fixtureInstallAssets()
            runner.handler = installHandler(identities: identityOutput(assets).lowercased())
            let workspace = try InstallWorkspace()

            let installed = try await install(assets, workspace: workspace)

            #expect(installed.count == 2)
        }

        @Test func checkFailsWithTheIdentityKeychainAndSearchListHint() async throws {
            let restore = secretsSetUp()
            defer { restore() }
            let (_, runner) = registerToolMocks()
            let assets = try fixtureInstallAssets()
            runner.handler = installHandler(identities: "     0 valid identities found")
            let workspace = try InstallWorkspace()
            let info = assets.certificates[0].info

            let error = await thrownError { try await install(assets, workspace: workspace) }

            #expect(error?.message == "The signing identity \(info.commonName) (\(info.sha1)) was imported into \(workspace.keychain.filePath), but codesign can't use it. Check that the keychain is unlocked and in the search list (security list-keychains -d user), and that Apple's intermediate certificates are installed.")
        }

        @Test func logsOneLinePerProfile() async throws {
            let restore = secretsSetUp()
            defer { restore() }
            let (log, runner) = registerToolMocks()
            let assets = try fixtureInstallAssets()
            runner.handler = installHandler(identities: identityOutput(assets))
            let workspace = try InstallWorkspace()

            _ = try await install(assets, workspace: workspace)

            let certificateName = "SwiftCI Test Distribution (TEAMID1234)"
            #expect(log.loggedLines == [
                "match AdHoc com.example.app1, \(Self.app1UUID), expires 2046-10-30, \(certificateName)",
                "match AdHoc com.example.app2, \(Self.app2UUID), expires 2046-10-30, \(certificateName)",
            ])
        }

        /// The keychain password stays out of the arguments, the console and the error, also when the install fails.
        @Test func keychainPasswordIsMaskedInArgumentsLogAndErrors() async throws {
            let restore = secretsSetUp()
            defer { restore() }
            let (log, runner) = registerToolMocks()
            let assets = try fixtureInstallAssets()
            runner.handler = installHandler(
                identities: "",
                partition: .init(result: ToolResult(stdout: "", stderr: "", exitCode: 1))
            )
            let workspace = try InstallWorkspace()

            let error = await thrownError { try await install(assets, workspace: workspace) }

            #expect(error?.message.contains(Self.keychainPassword) == false)
            #expect(!runner.tools.flatMap(\.arguments).contains { $0.contains(Self.keychainPassword) })
            #expect(!log.loggedLines.contains { $0.contains(Self.keychainPassword) })
            #expect(!log.warnings.contains { $0.contains(Self.keychainPassword) })
        }
    }
}

// MARK: - Helpers

/// What the import handler saw of a file: its name, its content, its mode and the mode of its directory.
private struct ImportFileCheck {
    let name: String
    let data: Data?
    let mode: Int?
    let directoryMode: Int?
}

/// The two ad hoc profiles of the v2 fixture, with their certificate.
func fixtureInstallAssets() throws -> MatchAssets {
    try MatchSelection.select(
        type: .adhoc,
        bundleIdentifiers: ["com.example.app1", "com.example.app2"],
        teamId: MatchSelectionTests.teamId,
        checkout: matchFixtureURL("v2"),
        password: MatchSelectionTests.password,
        now: MatchSelectionTests.now
    )
}

/// The fixture assets with a second certificate, CERTID9999, which no profile uses.
func twoCertificateAssets() throws -> MatchAssets {
    var assets = try fixtureInstallAssets()
    let file = "certs/distribution/CERTID9999.cer"
    let der = try matchPlainData(file)
    assets.certificates.append(MatchCertificate(
        file: file,
        certificateData: der,
        privateKeyData: try matchPlainData("certs/distribution/CERTID9999.p12"),
        info: try CertificateInfo(der: der, file: file)
    ))
    return assets
}

/// The output of `security find-identity -v -p codesigning` that lists each certificate of `assets`.
func identityOutput(_ assets: MatchAssets) -> String {
    let lines = assets.certificates.enumerated().map { index, certificate in
        "  \(index + 1)) \(certificate.info.sha1) \"\(certificate.info.commonName)\""
    }
    return (lines + ["     \(assets.certificates.count) valid identities found"]).joined(separator: "\n")
}

/// Answers the `security` runs of an install: `security -i` with `partition`, `security import` with `importResponse`
/// (called with the tool), and `find-identity` with `identities`. Other tools get an empty success.
func installHandler(
    identities: String,
    partition: ProcessRunnerMock.Response = .init(),
    importResponse: @escaping (Tool) -> ProcessRunnerMock.Response = { _ in .init() }
) -> ProcessRunnerMock.Handler {
    { tool in
        switch tool.arguments.first {
        case "import": return importResponse(tool)
        case "find-identity": return response(stdout: identities)
        case "-i": return partition
        default: return .init()
        }
    }
}

/// The arguments of `security import` for one file, as the install passes them.
private func importArguments(_ path: String, keychain: String) -> [String] {
    ["import", path, "-k", keychain, "-P", "", "-T", "/usr/bin/codesign", "-T", "/usr/bin/security",
     "-T", "/usr/bin/productbuild", "-T", "/usr/bin/productsign"]
}

/// The directory of the first import, found from the arguments of the import: the parent of its file.
private func importDirectory(of runner: ProcessRunnerMock) throws -> URL {
    let file = try #require(runner.tools.first { $0.arguments.first == "import" }?.arguments[1])
    return URL(filePath: file).deletingLastPathComponent()
}

/// Runs `install` for the workspace, with the fixture's keychain password.
private func install(_ assets: MatchAssets, workspace: InstallWorkspace) async throws -> [InstalledProfile] {
    try await MatchInstallation.install(
        assets,
        teamId: MatchSelectionTests.teamId,
        keychain: workspace.keychain,
        partitionTool: MatchInstallation.partitionListTool(
            keychainURL: workspace.keychain,
            password: Secret(value: GlobalStateTests.MatchInstallationTests.keychainPassword)
        ),
        profilesDirectory: workspace.profiles
    )
}

/// The POSIX mode of the file at `path`, or `nil` if it cannot be read.
private func posixMode(of path: String) -> Int? {
    let attributes = try? FileManager.default.attributesOfItem(atPath: path)
    return (attributes?[.posixPermissions] as? NSNumber)?.intValue
}

/// A new temporary directory, which the caller removes.
func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(
        path: "swiftci-match-install-\(UUID().uuidString)", directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func makeEmptyFile(in directory: URL, named name: String) throws {
    try Data().write(to: directory.appending(path: name))
}

/// A temporary root with a keychain path and a profiles folder in it. The root is removed when the value goes away.
final class InstallWorkspace {
    let root: URL
    let keychain: URL
    let profiles: URL

    init() throws {
        root = try makeTemporaryDirectory()
        keychain = root.appending(path: "login.keychain-db")
        profiles = root.appending(path: "Profiles", directoryHint: .isDirectory)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }
}
