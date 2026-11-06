@testable import SwiftCISigning
@testable import SwiftCITestSupport
@testable import SwiftCI
import Foundation
import SwiftCITesting
import Testing

/// The public install, `Signing.installMatchAssets`, through its internal seam with temporary folders. Both implementations
/// run with the tools answered by mocks. No keychain or profiles folder of the user is touched.
extension GlobalStateTests {
    @Suite(.serialized) struct SigningTests {
        static let repositoryURL = "https://git.example.com/certs.git"
        static let repository = MatchRepository(url: repositoryURL, branch: "main")
        static let adhocIdentifiers = ["com.example.app1", "com.example.app2"]
        static let plainAdhocProfiles = [
            "profiles/adhoc/AdHoc_com.example.app1.mobileprovision",
            "profiles/adhoc/AdHoc_com.example.app2.mobileprovision",
        ]
        static let certificateName = "SwiftCI Test Distribution (TEAMID1234)"
        static let app1UUID = GlobalStateTests.MatchInstallationTests.app1UUID
        static let app2UUID = GlobalStateTests.MatchInstallationTests.app2UUID
        static let keychainPassword = GlobalStateTests.MatchInstallationTests.keychainPassword
        static let versionWarning = "Couldn't read the fastlane version (its output names no version). The install continues. If fastlane can't run, the match call fails."

        // MARK: - Helpers

        /// Runs the public install's internal seam for the ad hoc profiles, with the keychain `login` of `workspace`.
        static func installAdhoc(
            _ implementation: MatchImplementation,
            workspace: InstallWorkspace,
            bundleIdentifiers: [String],
            repository: MatchRepository,
            step: String?
        ) async throws -> [InstalledProfile] {
            try await Signing.installMatchAssets(
                type: .adhoc,
                bundleIdentifiers: bundleIdentifiers,
                teamId: MatchSelectionTests.teamId,
                repository: repository,
                password: Secret(value: MatchSelectionTests.password),
                keychain: .existing(name: "login", password: Secret(value: keychainPassword)),
                using: implementation,
                step: step,
                keychainsDirectory: workspace.root,
                profilesDirectory: workspace.profiles,
                now: MatchSelectionTests.now
            )
        }

        /// Runs the install inside a command, so that the step and the console lines are recorded. Returns the console lines
        /// of the run and the profiles that the install returned.
        static func runCommand(
            _ implementation: MatchImplementation,
            runner: ProcessRunnerMock,
            workspace: InstallWorkspace,
            step: String? = nil
        ) async -> (result: SwiftCITestResult, installed: [InstalledProfile]) {
            var installed: [InstalledProfile] = []
            let result = await SwiftCITest.run(["install"]) {
                register(ProcessRunner.self, runner)
                command(Command("install") {
                    installed = try await Self.installAdhoc(
                        implementation,
                        workspace: workspace,
                        bundleIdentifiers: Self.adhocIdentifiers,
                        repository: Self.repository,
                        step: step
                    )
                })
            }
            return (result, installed)
        }

        /// A workspace whose keychain `login` exists, as `login-db` in its root, so that the keychain resolves.
        static func keychainWorkspace() throws -> InstallWorkspace {
            let workspace = try InstallWorkspace()
            try Data().write(to: workspace.root.appending(path: "login-db"))
            return workspace
        }

        /// The clone handler of the native install: `git clone` copies the v2 fixture into the destination, which is the last
        /// argument. The `security` runs are answered as in ``installHandler(identities:partition:importResponse:)``.
        static func cloneHandler(identities: String) -> ProcessRunnerMock.Handler {
            let security = installHandler(identities: identities)
            return { tool in
                guard tool.command == "/usr/bin/git" else {
                    return try security(tool)
                }
                guard let destination = tool.arguments.last else { throw TestError.boom }
                try FileManager.default.copyItem(at: matchFixtureURL("v2"), to: URL(filePath: destination))
                return .init()
            }
        }

        /// The fastlane runs. `fastlane --version`, or `bundle exec fastlane --version`, prints `version`. The match run
        /// writes the plain profiles at `copied` into `profiles` as `<UUID>.mobileprovision`, and also writes a notes file
        /// and a file that is not a profile, which the read-back must skip. Other tools get an empty success.
        static func fastlaneHandler(version: String, profiles: URL, copied: [String]) -> ProcessRunnerMock.Handler {
            { tool in
                if tool.arguments.last == "--version" {
                    return response(stdout: version)
                }
                guard tool.arguments.contains("match") else { return .init() }
                try FileManager.default.createDirectory(at: profiles, withIntermediateDirectories: true)
                for path in copied {
                    let data = try matchPlainData(path)
                    let uuid = try ProvisioningProfile(data: data, file: path).uuid
                    try data.write(to: profiles.appending(path: "\(uuid).mobileprovision"))
                }
                try Data("not a profile".utf8).write(to: profiles.appending(path: "broken.mobileprovision"))
                try Data("notes".utf8).write(to: profiles.appending(path: "notes.txt"))
                return .init()
            }
        }

        /// The revealed value of the environment variable `name` of `tool`, or `nil` if it is plain text or not set.
        static func secretValue(_ name: String, in tool: Tool) throws -> String? {
            guard case .secret(let secret)? = tool.environment[name] else { return nil }
            return try secret.revealedValue()
        }

        /// The command and the arguments of each tool, in order, for comparing the whole run.
        static func commandLines(_ runner: ProcessRunnerMock) -> [[String]] {
            runner.tools.map { [$0.command] + $0.arguments }
        }

        /// The arguments of `fastlane match` for the ad hoc profiles of the fixture, with `--verbose` when `verbose`.
        static func matchArguments(verbose: Bool = false) -> [String] {
            ["match", "adhoc", "--readonly"] + (verbose ? ["--verbose"] : []) + [
                "--app_identifier", "com.example.app1,com.example.app2",
                "--team_id", MatchSelectionTests.teamId,
                "--git_url", repositoryURL,
                "--git_branch", "main",
                "--keychain_name", "login",
            ]
        }

        // MARK: - Native

        @Test func nativeInstallsTheProfilesAndLogsTheImplementationAndEachProfile() async throws {
            let restore = secretsSetUp()
            defer { restore() }
            let assets = try fixtureInstallAssets()
            let runner = ProcessRunnerMock()
            runner.handler = Self.cloneHandler(identities: identityOutput(assets))
            let workspace = try Self.keychainWorkspace()

            let (result, installed) = await Self.runCommand(.native, runner: runner, workspace: workspace)

            #expect(result.exitCode == 0)
            #expect(enteredSteps(in: result.log) == ["Entering step [Install match adhoc signing assets]"])
            #expect(result.plainLog.contains("Implementation: native"))
            #expect(installed.map(\.bundleIdentifier) == Self.adhocIdentifiers)
            #expect(installed.map(\.name) == ["match AdHoc com.example.app1", "match AdHoc com.example.app2"])
            #expect(installed.map(\.uuid) == [Self.app1UUID, Self.app2UUID])
            #expect(installed.map(\.teamIdentifier) == [MatchSelectionTests.teamId, MatchSelectionTests.teamId])
            #expect(installed.map(\.certificateName) == [Self.certificateName, Self.certificateName])
            #expect(installed.map(\.expirationDate) == assets.profiles.map(\.profile.expirationDate))
            #expect(installed.map { $0.url.filePath } == [
                workspace.profiles.appending(path: "\(Self.app1UUID).mobileprovision").filePath,
                workspace.profiles.appending(path: "\(Self.app2UUID).mobileprovision").filePath,
            ])
            #expect(try installed.map { try Data(contentsOf: $0.url) } == assets.profiles.map(\.data))
            #expect(result.plainLog.contains(
                "match AdHoc com.example.app1, \(Self.app1UUID), expires 2046-10-30, \(Self.certificateName)"
            ))
            #expect(result.plainLog.contains(
                "match AdHoc com.example.app2, \(Self.app2UUID), expires 2046-10-30, \(Self.certificateName)"
            ))
        }

        @Test func nativeCustomStepNameRenamesTheStep() async throws {
            let restore = secretsSetUp()
            defer { restore() }
            let assets = try fixtureInstallAssets()
            let runner = ProcessRunnerMock()
            runner.handler = Self.cloneHandler(identities: identityOutput(assets))
            let workspace = try Self.keychainWorkspace()

            let (result, installed) = await Self.runCommand(.native, runner: runner, workspace: workspace, step: "Install the profiles")

            #expect(result.exitCode == 0)
            #expect(installed.count == 2)
            #expect(enteredSteps(in: result.log) == ["Entering step [Install the profiles]"])
        }

        // MARK: - Fastlane

        @Test func fastlaneRunsVersionThenMatchWithTheExactArgumentsAndReadsTheProfilesBack() async throws {
            let restore = secretsSetUp()
            defer { restore() }
            let workspace = try Self.keychainWorkspace()
            let runner = ProcessRunnerMock()
            runner.handler = Self.fastlaneHandler(version: "fastlane 2.232.2", profiles: workspace.profiles, copied: Self.plainAdhocProfiles)

            let assets = try fixtureInstallAssets()
            let (result, installed) = await Self.runCommand(.fastlane(), runner: runner, workspace: workspace)

            #expect(result.exitCode == 0)
            #expect(enteredSteps(in: result.log) == ["Entering step [Install match adhoc signing assets]"])
            #expect(result.plainLog.contains("Implementation: fastlane 2.232.2 (fastlane)"))
            #expect(Self.commandLines(runner) == [
                ["fastlane", "--version"],
                ["fastlane"] + Self.matchArguments(),
            ])
            #expect(installed.map(\.bundleIdentifier) == Self.adhocIdentifiers)
            #expect(installed.map(\.name) == ["match AdHoc com.example.app1", "match AdHoc com.example.app2"])
            #expect(installed.map(\.uuid) == [Self.app1UUID, Self.app2UUID])
            #expect(installed.map(\.teamIdentifier) == [MatchSelectionTests.teamId, MatchSelectionTests.teamId])
            #expect(installed.map(\.certificateName) == [Self.certificateName, Self.certificateName])
            #expect(installed.map(\.expirationDate) == assets.profiles.map(\.profile.expirationDate))
            #expect(installed.map { $0.url.filePath } == [
                workspace.profiles.appending(path: "\(Self.app1UUID).mobileprovision").filePath,
                workspace.profiles.appending(path: "\(Self.app2UUID).mobileprovision").filePath,
            ])
        }

        @Test func fastlaneWithVerboseAddsTheFlagAfterTheMode() async throws {
            let restore = secretsSetUp()
            defer { restore() }
            let workspace = try Self.keychainWorkspace()
            let runner = ProcessRunnerMock()
            runner.handler = Self.fastlaneHandler(version: "fastlane 2.232.2", profiles: workspace.profiles, copied: Self.plainAdhocProfiles)

            let (_, installed) = await Self.runCommand(.fastlane(verbose: true), runner: runner, workspace: workspace)

            #expect(installed.count == 2)
            #expect(runner.tools[1].arguments == Self.matchArguments(verbose: true))
        }

        /// The bundler run starts fastlane through `bundle exec`, and `BUNDLE_GEMFILE` is set from the Gemfile's path. The
        /// caller's variables reach the match run, and a caller's `MATCH_PASSWORD` is overwritten by the secret.
        @Test func bundlerRunsThroughBundleExecWithTheGemfileAndTheCallersEnvironment() async throws {
            let restore = secretsSetUp()
            defer { restore() }
            let workspace = try Self.keychainWorkspace()
            let runner = ProcessRunnerMock()
            runner.handler = Self.fastlaneHandler(version: "fastlane 2.232.2", profiles: workspace.profiles, copied: Self.plainAdhocProfiles)
            let gemfile = URL(fileURLWithPath: "/tmp/project/Gemfile")
            let implementation = MatchImplementation.fastlane(
                invocation: .bundler(gemfile: gemfile),
                environment: ["LC_ALL": "en_US.UTF-8", "MATCH_PASSWORD": "caller-plain-VALUE"]
            )

            let (result, installed) = await Self.runCommand(implementation, runner: runner, workspace: workspace)

            #expect(result.exitCode == 0)
            #expect(result.plainLog.contains("Implementation: fastlane 2.232.2 (bundle exec fastlane)"))
            #expect(Self.commandLines(runner) == [
                ["bundle", "exec", "fastlane", "--version"],
                ["bundle", "exec", "fastlane"] + Self.matchArguments(),
            ])
            let match = runner.tools[1]
            #expect(match.environment["LC_ALL"] == .text("en_US.UTF-8"))
            #expect(match.environment["BUNDLE_GEMFILE"] == .text(gemfile.filePath))
            #expect(try Self.secretValue("MATCH_PASSWORD", in: match) == MatchSelectionTests.password)
            #expect(try Self.secretValue("MATCH_KEYCHAIN_PASSWORD", in: match) == Self.keychainPassword)
            #expect(!match.arguments.contains { $0.contains("caller-plain-VALUE") })
            #expect(installed.count == 2)
        }

        /// The Git header goes to the environment as a secret. The URL in the argument has no user information.
        @Test func userinfoStaysOutOfTheArgumentsAndTheHeaderIsASecret() async throws {
            let restore = secretsSetUp()
            defer { restore() }
            let (_, runner) = registerToolMocks()
            let workspace = try Self.keychainWorkspace()
            runner.handler = Self.fastlaneHandler(version: "fastlane 2.232.2", profiles: workspace.profiles, copied: Self.plainAdhocProfiles)
            let repository = MatchRepository(url: "https://ci-user:ci-token-VALUE@git.example.com/certs.git", branch: "main")

            _ = try await Self.installAdhoc(.fastlane(), workspace: workspace, bundleIdentifiers: Self.adhocIdentifiers, repository: repository, step: nil)

            let match = runner.tools[1]
            #expect(match.arguments.contains(Self.repositoryURL))
            #expect(!runner.tools.flatMap(\.arguments).contains { $0.contains("ci-token-VALUE") || $0.contains("ci-user") })
            #expect(match.environment["GIT_CONFIG_COUNT"] == .text("1"))
            #expect(match.environment["GIT_CONFIG_KEY_0"] == .text("http.\(Self.repositoryURL).extraHeader"))
            let header = try Self.secretValue("GIT_CONFIG_VALUE_0", in: match)
            #expect(header == "Authorization: Basic \(Data("ci-user:ci-token-VALUE".utf8).base64EncodedString())")
        }

        /// The version is not readable: the install logs a warning, runs the match and reads the profiles back.
        @Test func unreadableVersionIsAWarningAndTheInstallStillRuns() async throws {
            let restore = secretsSetUp()
            defer { restore() }
            let (log, runner) = registerToolMocks()
            let workspace = try Self.keychainWorkspace()
            runner.handler = Self.fastlaneHandler(version: "fastlane: command not found", profiles: workspace.profiles, copied: Self.plainAdhocProfiles)

            let installed = try await Self.installAdhoc(.fastlane(), workspace: workspace, bundleIdentifiers: Self.adhocIdentifiers, repository: Self.repository, step: nil)

            #expect(runner.tools.count == 2)
            #expect(installed.count == 2)
            #expect(log.warnings == [Self.versionWarning])
            #expect(log.loggedLines.contains("Implementation: fastlane (fastlane)"))
        }

        /// A `fastlane --version` that exits non-zero: the warning gives the exit code, and the install still runs.
        @Test func versionExitCodeIsInTheWarning() async throws {
            let restore = secretsSetUp()
            defer { restore() }
            let (log, runner) = registerToolMocks()
            let workspace = try Self.keychainWorkspace()
            let match = Self.fastlaneHandler(version: "", profiles: workspace.profiles, copied: Self.plainAdhocProfiles)
            runner.handler = { tool in
                if tool.arguments.last == "--version" {
                    return response(stderr: "fastlane: broken", exitCode: 3)
                }
                return try match(tool)
            }

            let installed = try await Self.installAdhoc(.fastlane(), workspace: workspace, bundleIdentifiers: Self.adhocIdentifiers, repository: Self.repository, step: nil)

            #expect(installed.count == 2)
            #expect(log.warnings == ["Couldn't read the fastlane version (fastlane --version exited with code 3). The install continues. If fastlane can't run, the match call fails."])
        }

        /// A `fastlane --version` that cannot start: the warning gives the reason, and the install still runs.
        @Test func versionStartErrorIsInTheWarning() async throws {
            let restore = secretsSetUp()
            defer { restore() }
            let (log, runner) = registerToolMocks()
            let workspace = try Self.keychainWorkspace()
            let match = Self.fastlaneHandler(version: "", profiles: workspace.profiles, copied: Self.plainAdhocProfiles)
            runner.handler = { tool in
                if tool.arguments.last == "--version" {
                    throw BuildError(message: "SWIFTCI_TEST_START_FAILURE")
                }
                return try match(tool)
            }

            let installed = try await Self.installAdhoc(.fastlane(), workspace: workspace, bundleIdentifiers: Self.adhocIdentifiers, repository: Self.repository, step: nil)

            #expect(installed.count == 2)
            #expect(log.warnings.count == 1)
            #expect(log.warnings.first?.hasPrefix("Couldn't read the fastlane version (fastlane --version could not start. Details: ") == true)
            #expect(log.warnings.first?.contains("SWIFTCI_TEST_START_FAILURE") == true)
        }

        /// A profile that fastlane did not write is an error that names the identifier, the expected name and the folder.
        /// The unreadable file in the folder is counted.
        @Test func aMissingProfileAfterMatchNamesTheIdentifierTheNameAndTheFolder() async throws {
            let restore = secretsSetUp()
            defer { restore() }
            let (_, runner) = registerToolMocks()
            let workspace = try Self.keychainWorkspace()
            runner.handler = Self.fastlaneHandler(
                version: "fastlane 2.232.2",
                profiles: workspace.profiles,
                copied: ["profiles/adhoc/AdHoc_com.example.app1.mobileprovision"]
            )

            let error = await thrownError {
                _ = try await Self.installAdhoc(.fastlane(), workspace: workspace, bundleIdentifiers: Self.adhocIdentifiers, repository: Self.repository, step: nil)
            }

            #expect(error?.code == .failure)
            #expect(error?.message == "fastlane match finished, but the provisioning profile for com.example.app2 named \"match AdHoc com.example.app2\" for team TEAMID1234 isn't in \(workspace.profiles.filePath). A custom profile_name isn't supported, so the profile must have fastlane's default name. 1 profile file(s) in that folder couldn't be read.")
        }

        /// The newest profile is the latest creation date. A profile without one is the oldest, and on a tie the later expiry
        /// date wins. The profiles are built in memory from property lists, because a signed duplicate is not in the fixtures.
        @Test func newestProfileIsTheLatestCreationDateThenTheLatestExpiry() throws {
            func profile(created: Date?, expires: Date) throws -> ProvisioningProfile {
                var dictionary: [String: Any] = [
                    "UUID": "11111111-1111-4111-8111-111111111111",
                    "Name": "match AdHoc com.example.app1",
                    "TeamIdentifier": [MatchSelectionTests.teamId],
                    "ExpirationDate": expires,
                    "DeveloperCertificates": [Data([0x30, 0x00])],
                ]
                if let created {
                    dictionary["CreationDate"] = created
                }
                return try ProvisioningProfile(propertyList: dictionary, file: "test.mobileprovision")
            }
            let early = Date(timeIntervalSince1970: 1_700_000_000)
            let late = Date(timeIntervalSince1970: 1_800_000_000)
            let expiry = Date(timeIntervalSince1970: 2_000_000_000)
            let laterExpiry = Date(timeIntervalSince1970: 2_100_000_000)

            let undated = try profile(created: nil, expires: laterExpiry)
            let dated = try profile(created: early, expires: expiry)
            #expect(MatchFastlaneInstall.isOlder(undated, dated))
            #expect(!MatchFastlaneInstall.isOlder(dated, undated))
            #expect(MatchFastlaneInstall.isOlder(try profile(created: early, expires: expiry), try profile(created: late, expires: expiry)))
            #expect(MatchFastlaneInstall.isOlder(try profile(created: late, expires: expiry), try profile(created: late, expires: laterExpiry)))
            #expect(!MatchFastlaneInstall.isOlder(try profile(created: late, expires: laterExpiry), try profile(created: late, expires: expiry)))
        }

        // MARK: - Both implementations

        /// An empty list of identifiers is a usage error before any tool runs, for both implementations.
        @Test func emptyBundleIdentifiersIsAUsageErrorBeforeAnyToolForBothImplementations() async throws {
            let restore = secretsSetUp()
            defer { restore() }
            let (log, runner) = registerToolMocks()
            let workspace = try Self.keychainWorkspace()

            for implementation in [MatchImplementation.native, .fastlane()] {
                let error = await thrownError {
                    _ = try await Self.installAdhoc(implementation, workspace: workspace, bundleIdentifiers: [], repository: Self.repository, step: nil)
                }
                #expect(error?.code == .usage)
            }

            #expect(runner.tools.isEmpty)
            #expect(log.loggedLines.isEmpty)
        }

        /// A keychain that does not exist is an error before any tool runs, for both implementations. The message names
        /// the folder that was searched.
        @Test func missingKeychainIsAnErrorBeforeAnyToolForBothImplementations() async throws {
            let restore = secretsSetUp()
            defer { restore() }
            let (_, runner) = registerToolMocks()
            let workspace = try InstallWorkspace()

            for implementation in [MatchImplementation.native, .fastlane()] {
                let error = await thrownError {
                    _ = try await Self.installAdhoc(implementation, workspace: workspace, bundleIdentifiers: Self.adhocIdentifiers, repository: Self.repository, step: nil)
                }
                #expect(error?.message == "Keychain login not found in \(workspace.root.filePath). Create it, or pass the name of an existing keychain, such as login.keychain.")
            }

            #expect(runner.tools.isEmpty)
        }

        /// A keychain password with a line feed stops the native install before the clone: no tool runs, and the message
        /// names the kind of the argument, not its value.
        @Test func nativeKeychainPasswordWithALineFeedFailsBeforeAnyProcessRuns() async throws {
            let restore = secretsSetUp()
            defer { restore() }
            let (log, runner) = registerToolMocks()
            let workspace = try Self.keychainWorkspace()

            let error = await thrownError {
                _ = try await Signing.installMatchAssets(
                    type: .adhoc,
                    bundleIdentifiers: Self.adhocIdentifiers,
                    teamId: MatchSelectionTests.teamId,
                    repository: Self.repository,
                    password: Secret(value: MatchSelectionTests.password),
                    keychain: .existing(name: "login", password: Secret(value: "kc-first\nkc-second-VALUE")),
                    using: .native,
                    step: nil,
                    keychainsDirectory: workspace.root,
                    profilesDirectory: workspace.profiles,
                    now: MatchSelectionTests.now
                )
            }

            #expect(error?.code == .usage)
            #expect(error?.message.contains("keychain password") == true)
            #expect(error?.message.contains("kc-second-VALUE") == false)
            #expect(runner.tools.isEmpty)
            #expect(log.loggedLines.isEmpty)
        }

        /// The match password, the keychain password and the Git credential appear in no argument, no console line and no
        /// error message, for the fastlane path, where all three are passed on.
        @Test func secretsAppearInNoArgumentLogOrErrorMessage() async throws {
            let restore = secretsSetUp()
            defer { restore() }
            let (log, runner) = registerToolMocks()
            let workspace = try Self.keychainWorkspace()
            runner.handler = Self.fastlaneHandler(
                version: "fastlane 2.232.2",
                profiles: workspace.profiles,
                copied: ["profiles/adhoc/AdHoc_com.example.app1.mobileprovision"]
            )
            let repository = MatchRepository(url: "https://ci-user:ci-token-VALUE@git.example.com/certs.git", branch: "main")

            // app2 is missing, so the error path is covered as well.
            let error = await thrownError {
                _ = try await Self.installAdhoc(.fastlane(), workspace: workspace, bundleIdentifiers: Self.adhocIdentifiers, repository: repository, step: nil)
            }

            let secrets = [MatchSelectionTests.password, Self.keychainPassword, "ci-token-VALUE"]
            #expect(error != nil)
            for secret in secrets {
                #expect(!runner.tools.flatMap(\.arguments).contains { $0.contains(secret) }, "\(secret) is in an argument")
                #expect(!log.loggedLines.contains { $0.contains(secret) }, "\(secret) is in the log")
                #expect(!(error?.message.contains(secret) ?? false), "\(secret) is in the error")
            }
        }
    }
}
