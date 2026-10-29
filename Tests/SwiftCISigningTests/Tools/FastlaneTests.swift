@testable import SwiftCISigning
@testable import SwiftCITestSupport
import Foundation
@testable import SwiftCI
import SwiftCITesting
import Testing

extension GlobalStateTests {
    @Suite(.serialized) struct FastlaneTests {
        @Test func matchRunsFastlaneByNameWithTheArgumentArray() async throws {
            let (_, runner) = registerToolMocks()

            try await Fastlane.match(type: .appstore, appIdentifiers: ["com.example.myapp"], teamId: "TEAM123")

            #expect(runner.tools.count == 1)
            #expect(runner.tools[0].command == "fastlane")
            #expect(runner.tools[0].arguments == [
                "match", "appstore", "--readonly", "--app_identifier", "com.example.myapp", "--team_id", "TEAM123",
            ])
        }

        @Test func matchUpdateRunsFastlaneByNameWithForce() async throws {
            let (_, runner) = registerToolMocks()

            try await Fastlane.matchUpdate(type: .adhoc, appIdentifiers: ["com.example.myapp"], teamId: "TEAM123")

            #expect(runner.tools.count == 1)
            #expect(runner.tools[0].command == "fastlane")
            #expect(runner.tools[0].arguments == [
                "match", "adhoc", "--force", "--app_identifier", "com.example.myapp", "--team_id", "TEAM123",
            ])
        }

        @Test func verbosePassesTheVerboseFlagAfterTheMode() async throws {
            let (_, runner) = registerToolMocks()

            try await Fastlane.match(type: .adhoc, appIdentifiers: ["com.example.myapp"], teamId: "TEAM123", verbose: true)
            try await Fastlane.matchUpdate(
                type: .adhoc, appIdentifiers: ["com.example.myapp"], teamId: "TEAM123", verbose: true
            )

            #expect(runner.tools.count == 2)
            #expect(runner.tools[0].arguments == [
                "match", "adhoc", "--readonly", "--verbose", "--app_identifier", "com.example.myapp", "--team_id", "TEAM123",
            ])
            #expect(runner.tools[1].arguments == [
                "match", "adhoc", "--force", "--verbose", "--app_identifier", "com.example.myapp", "--team_id", "TEAM123",
            ])
        }

        @Test func severalAppIdentifiersAreJoinedWithCommas() async throws {
            let (_, runner) = registerToolMocks()

            try await Fastlane.match(
                type: .adhoc, appIdentifiers: ["com.example.myapp", "com.example.other"], teamId: "TEAM123"
            )
            try await Fastlane.matchUpdate(
                type: .adhoc, appIdentifiers: ["com.example.myapp", "com.example.other"], teamId: "TEAM123"
            )

            #expect(runner.tools.map(\.arguments) == [
                ["match", "adhoc", "--readonly", "--app_identifier", "com.example.myapp,com.example.other", "--team_id", "TEAM123"],
                ["match", "adhoc", "--force", "--app_identifier", "com.example.myapp,com.example.other", "--team_id", "TEAM123"],
            ])
        }

        /// An empty list is a usage error that stops the call before the step opens and before any process runs.
        @Test func emptyAppIdentifiersIsAUsageErrorBeforeAnyProcessRuns() async {
            let (log, runner) = registerToolMocks()
            var matchError: BuildError?
            var updateError: BuildError?

            do {
                try await Fastlane.match(type: .appstore, appIdentifiers: [], teamId: "TEAM123")
            } catch let error as BuildError {
                matchError = error
            } catch {}
            do {
                try await Fastlane.matchUpdate(type: .appstore, appIdentifiers: [], teamId: "TEAM123")
            } catch let error as BuildError {
                updateError = error
            } catch {}

            #expect(matchError?.code == .usage)
            #expect(updateError?.code == .usage)
            #expect(runner.tools.isEmpty)
            #expect(log.loggedLines.isEmpty)
        }

        @Test func bundlerRunsFastlaneThroughBundleExec() async throws {
            let (_, runner) = registerToolMocks()

            try await Fastlane.match(
                type: .appstore, appIdentifiers: ["com.example.myapp"], teamId: "TEAM123", invocation: .bundler()
            )

            #expect(runner.tools.count == 1)
            #expect(runner.tools[0].command == "bundle")
            #expect(runner.tools[0].arguments == [
                "exec", "fastlane", "match", "appstore", "--readonly", "--app_identifier", "com.example.myapp", "--team_id", "TEAM123",
            ])
            #expect(runner.tools[0].environment.isEmpty)
        }

        /// `BUNDLE_GEMFILE` is set to the Gemfile's path, and it overrides the same variable given in `environment`.
        @Test func bundlerWithGemfileSetsBundleGemfile() async throws {
            let (_, runner) = registerToolMocks()
            let gemfile = URL(fileURLWithPath: "/tmp/project/Gemfile")

            try await Fastlane.matchUpdate(
                type: .adhoc,
                appIdentifiers: ["com.example.myapp"],
                teamId: "TEAM123",
                invocation: .bundler(gemfile: gemfile),
                environment: ["BUNDLE_GEMFILE": "/elsewhere/Gemfile", "LC_ALL": "en_US.UTF-8"]
            )

            #expect(runner.tools[0].command == "bundle")
            #expect(runner.tools[0].arguments == [
                "exec", "fastlane", "match", "adhoc", "--force", "--app_identifier", "com.example.myapp", "--team_id", "TEAM123",
            ])
            #expect(runner.tools[0].environment == [
                "BUNDLE_GEMFILE": .text("/tmp/project/Gemfile"),
                "LC_ALL": .text("en_US.UTF-8"),
            ])
        }

        /// The variables reach the process. A secret is revealed only in the process environment, and it is in neither
        /// the arguments nor any log.
        @Test func environmentReachesTheToolAndSecretStaysOutOfArgumentsAndLog() async throws {
            let restore = secretsSetUp()
            defer { restore() }
            let runner = ProcessRunnerMock()
            let password = Secret(value: "match-PW-VALUE")
            var fullLog = ""

            let result = await SwiftCITest.run(["match"]) {
                register(ProcessRunner.self, runner)
                command(Command("match") {
                    try await Fastlane.match(
                        type: .appstore,
                        appIdentifiers: ["com.example.myapp"],
                        teamId: "TEAM123",
                        environment: ["LC_ALL": "en_US.UTF-8", "MATCH_PASSWORD": .secret(password)]
                    )
                    fullLog = try String(contentsOfFile: FullLog.path?.filePath ?? "", encoding: .utf8)
                })
            }

            #expect(result.exitCode == 0)
            #expect(runner.tools[0].environment == ["LC_ALL": .text("en_US.UTF-8"), "MATCH_PASSWORD": .secret(password)])
            let environment = try runner.tools[0].effectiveEnvironment()
            #expect(environment["LC_ALL"] == "en_US.UTF-8")
            #expect(environment["MATCH_PASSWORD"] == "match-PW-VALUE")
            #expect(!runner.tools[0].arguments.contains { $0.contains("match-PW-VALUE") })
            #expect(!result.log.contains { $0.contains("match-PW-VALUE") })
            #expect(!fullLog.contains("match-PW-VALUE"))
            #expect(fullLog.contains("MATCH_PASSWORD"))
        }

        /// With several identifiers the default step name gives their count, not the list.
        @Test func severalAppIdentifiersNameTheStepByCount() async {
            let runner = ProcessRunnerMock()
            let identifiers = (1...25).map { "com.example.app\($0)" }

            let result = await SwiftCITest.run(["match"]) {
                register(ProcessRunner.self, runner)
                command(Command("match") {
                    try await Fastlane.match(type: .adhoc, appIdentifiers: identifiers, teamId: "TEAM123")
                })
            }

            #expect(result.exitCode == 0)
            #expect(enteredSteps(in: result.log) == [
                "Entering step [Install signing assets with fastlane match (adhoc, 25 app identifiers)]",
            ])
        }

        @Test func matchOpensItsDefaultStepAtTopLevel() async {
            let runner = ProcessRunnerMock()

            let result = await SwiftCITest.run(["match"]) {
                register(ProcessRunner.self, runner)
                command(Command("match") {
                    try await Fastlane.match(type: .appstore, appIdentifiers: ["com.example.myapp"], teamId: "TEAM123")
                })
            }

            #expect(result.exitCode == 0)
            #expect(enteredSteps(in: result.log) == [
                "Entering step [Install signing assets with fastlane match (appstore, com.example.myapp)]",
            ])
        }

        /// A tolerated failure is a warning that names the tool and the code, and the install continues.
        @Test func toleratedFailureLogsAWarningAndContinues() async throws {
            let (log, runner) = registerToolMocks()
            runner.responses = [response(exitCode: 1)]

            try await Fastlane().runTolerated(
                Tool(command: "/usr/bin/security", arguments: ["import"]),
                what: "importing 'cert.cer'"
            )

            #expect(runner.tools.count == 1)
            #expect(log.loggedLines.map(stripANSI) == [
                "<Warning> security exited with code 1 while importing 'cert.cer'. The install continues.",
            ])
        }

        @Test func toleratedSuccessLogsNothing() async throws {
            let (log, runner) = registerToolMocks()
            runner.responses = [response(stdout: "ok")]

            try await Fastlane().runTolerated(Tool(command: "/usr/bin/security"), what: "importing")

            #expect(log.loggedLines == ["ok"])
        }

        /// A tool that cannot be started is still an error, so the tolerated call does not hide it. The error is
        /// thrown by the mock runner, and it reaches the caller unchanged.
        @Test func toleratedCallPropagatesStartFailureUnchanged() async {
            let (log, runner) = registerToolMocks()
            runner.responses = [.init(error: TestError.boom)]

            await #expect(throws: TestError.boom) {
                try await Fastlane().runTolerated(Tool(command: "/usr/bin/security"), what: "importing")
            }

            #expect(runner.tools.count == 1)
            #expect(log.loggedLines.isEmpty)
        }

        static let duplicateStderr = "security: SecKeychainItemImport: The specified item already exists in the keychain."

        /// Re-running an install imports an item that is already there. That is success: no warning, and the duplicate
        /// line does not reach the console. The full log keeps it, and that path is not covered here.
        @Test func importOfExistingItemIsSilentSuccess() async throws {
            let (log, runner) = registerToolMocks()
            runner.responses = [.init(
                lines: [stderrLine(Self.duplicateStderr)],
                result: ToolResult(stdout: "", stderr: Self.duplicateStderr, exitCode: 1)
            )]

            try await Fastlane().runImport(
                item: URL(fileURLWithPath: "/tmp/cert.cer"),
                keychainURL: URL(fileURLWithPath: "/tmp/login.keychain-db"),
                itemPassword: ""
            )

            #expect(runner.tools.count == 1)
            #expect(runner.tools[0].command == "/usr/bin/security")
            #expect(runner.tools[0].arguments.prefix(2) == ["import", "/tmp/cert.cer"])
            #expect(log.loggedLines.isEmpty)
        }

        /// Any other failure of the import still warns, and its stderr line is shown as before.
        @Test func importFailureWithAnotherCauseStillWarns() async throws {
            let (log, runner) = registerToolMocks()
            let other = "security: SecKeychainItemImport: Unknown format."
            runner.responses = [.init(
                lines: [stderrLine(other)],
                result: ToolResult(stdout: "", stderr: other, exitCode: 1)
            )]

            try await Fastlane().runImport(
                item: URL(fileURLWithPath: "/tmp/cert.cer"),
                keychainURL: URL(fileURLWithPath: "/tmp/login.keychain-db"),
                itemPassword: ""
            )

            #expect(log.loggedLines.map(stripANSI) == [
                other,
                "<Warning> security exited with code 1 while importing 'cert.cer'. The install continues.",
            ])
        }

        /// A successful import logs its output and no warning.
        @Test func successfulImportLogsNoWarning() async throws {
            let (log, runner) = registerToolMocks()
            runner.responses = [.init(result: ToolResult(stdout: "", stderr: "", exitCode: 0))]

            try await Fastlane().runImport(
                item: URL(fileURLWithPath: "/tmp/cert.cer"),
                keychainURL: URL(fileURLWithPath: "/tmp/login.keychain-db"),
                itemPassword: ""
            )

            #expect(runner.tools.count == 1)
            #expect(log.loggedLines.isEmpty)
        }

        /// The partition list runs `security -i` with the password on standard input only, and the arguments are fixed.
        @Test func partitionListSendsThePasswordOnStandardInput() throws {
            let restore = secretsSetUp()
            defer { restore() }

            let tool = try Fastlane().partitionListTool(
                keychainURL: URL(fileURLWithPath: "/tmp/keychains/login.keychain-db"),
                password: Secret(value: "kc-VALUE pass")
            )

            #expect(tool.command == "/usr/bin/security")
            #expect(tool.arguments == ["-i"])
            #expect(!tool.arguments.contains { $0.contains("kc-VALUE") })
            #expect(splitSecurityLine(try securityLine(of: tool)) == [
                "set-key-partition-list", "-S", "apple-tool:,apple:,codesign:", "-s", "-k", "kc-VALUE pass",
                "/tmp/keychains/login.keychain-db",
            ])
        }

        /// A keychain path with spaces and non-ASCII characters reaches the `security` argument as a plain path.
        @Test func partitionListKeychainPathIsPassedUnencoded() throws {
            let restore = secretsSetUp()
            defer { restore() }

            let tool = try Fastlane().partitionListTool(
                keychainURL: URL(fileURLWithPath: "/tmp/My Dir/Äpp ✓/login.keychain-db"),
                password: Secret(value: "kc-VALUE")
            )

            #expect(splitSecurityLine(try securityLine(of: tool)).last == "/tmp/My Dir/Äpp ✓/login.keychain-db")
        }

        /// The import passes the item and keychain paths as plain paths, not as `file://` URLs or percent-encoded text.
        @Test func importPathsWithSpacesAndNonASCIIReachTheToolUnencoded() async throws {
            let (_, runner) = registerToolMocks()
            runner.responses = [.init(result: ToolResult(stdout: "", stderr: "", exitCode: 0))]

            try await Fastlane().runImport(
                item: URL(fileURLWithPath: "/tmp/My Dir/Äpp ✓/cert.cer"),
                keychainURL: URL(fileURLWithPath: "/tmp/My Dir/Äpp ✓/login.keychain-db"),
                itemPassword: ""
            )

            #expect(runner.tools[0].arguments.prefix(4) == [
                "import", "/tmp/My Dir/Äpp ✓/cert.cer", "-k", "/tmp/My Dir/Äpp ✓/login.keychain-db",
            ])
        }

        @Test func partitionListWithAMissingPasswordIsAUsageError() {
            let restore = secretsSetUp()
            defer { restore() }

            do {
                _ = try Fastlane().partitionListTool(keychainURL: URL(fileURLWithPath: "/tmp/x.keychain-db"), password: Secret("SWIFTCI_TEST_MISSING_KC"))
                Issue.record("Expected a usage error")
            } catch let error as BuildError {
                #expect(error.code == .usage)
                #expect(error.message.contains("SWIFTCI_TEST_MISSING_KC"))
            } catch {
                Issue.record("Expected a BuildError, got \(error)")
            }
        }

        /// An invalid keychain password (here one with a line feed) stops the native install before anything runs: no
        /// clone, no import and no tool is started. The message names the kind of the argument, not its value.
        @Test func invalidPartitionPasswordStopsTheNativeInstallBeforeAnyTool() async {
            let restore = secretsSetUp([
                "MATCH_GIT_URL": "https://example.invalid/match.git",
                "MATCH_KEYCHAIN_PASSWORD": "kc-first\nkc-second-VALUE",
                "MATCH_PASSWORD": "match-password-VALUE",
            ])
            defer { restore() }
            let (log, runner) = registerToolMocks()

            let error = await thrownError {
                try await Fastlane().matchUpdateBuiltin(type: .appstore, appIdentifier: "com.example.myapp", teamId: "TEAM123")
            }

            #expect(error?.code == .usage)
            #expect(error?.message.contains("keychain password") == true)
            #expect(error?.message.contains("kc-second-VALUE") == false)
            #expect(runner.tools.isEmpty)
            #expect(log.loggedLines.isEmpty)
        }
    }
}
