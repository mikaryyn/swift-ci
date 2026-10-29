import Foundation
@_spi(Testing) import SwiftCI
@testable import SwiftCISigning
@testable import SwiftCITestSupport
@testable import SwiftCI
import SwiftCITesting
import Testing

extension GlobalStateTests {
    @Suite(.serialized) struct KeychainTest {
        /// The password is on standard input, as an escaped line. It is not an argument, and the exact line is known.
        @Test func testUnlockSendsThePasswordOnStandardInput() async throws {
            let restore = secretsSetUp()
            defer { restore() }
            let (log, runner) = registerToolMocks()

            try await Keychain.unlock(name: "name", password: Secret(value: "pw-VALUE-1"))

            #expect(runner.tools.count == 1)
            #expect(runner.tools[0].command == "/usr/bin/security")
            #expect(runner.tools[0].arguments == ["-i"])
            #expect(!runner.tools[0].arguments.contains { $0.contains("pw-VALUE-1") })
            #expect(try securityLine(of: runner.tools[0]) == "\\u\\n\\l\\o\\c\\k\\-\\k\\e\\y\\c\\h\\a\\i\\n \\-\\p \\p\\w\\-\\V\\A\\L\\U\\E\\-\\1 \\n\\a\\m\\e\\.\\k\\e\\y\\c\\h\\a\\i\\n\n")
            #expect(splitSecurityLine(try securityLine(of: runner.tools[0])) == ["unlock-keychain", "-p", "pw-VALUE-1", "name.keychain"])
            #expect(log.loggedLines == ["Unlocked keychain 'name'.".success])
        }

        @Test func passwordWithSpecialCharactersRoundTrips() async throws {
            let restore = secretsSetUp()
            defer { restore() }
            let (_, runner) = registerToolMocks()
            let password = "pass word'\"\\é-1"

            try await Keychain.unlock(name: "name", password: Secret(value: password))

            #expect(splitSecurityLine(try securityLine(of: runner.tools[0])) == ["unlock-keychain", "-p", password, "name.keychain"])
        }

        /// A name that already has a keychain extension is passed to `security` unchanged.
        @Test(arguments: [
            ("login", "login.keychain"),
            ("login.keychain", "login.keychain"),
            ("login.keychain-db", "login.keychain-db"),
        ])
        func nameWithExtensionIsUsedAsItIs(name: String, path: String) async throws {
            let restore = secretsSetUp()
            defer { restore() }
            let (_, runner) = registerToolMocks()

            try await Keychain.unlock(name: name, password: Secret(value: "pw-VALUE-3"))

            #expect(splitSecurityLine(try securityLine(of: runner.tools[0])) == ["unlock-keychain", "-p", "pw-VALUE-3", path])
        }

        /// A line feed in the password is refused before any process is started.
        @Test func passwordWithLineFeedIsAUsageErrorAndTheRunnerIsNotCalled() async {
            let restore = secretsSetUp()
            defer { restore() }
            let (_, runner) = registerToolMocks()

            let error = await thrownError {
                try await Keychain.unlock(name: "name", password: Secret(value: "one\ntwo-VALUE"))
            }

            #expect(error?.code == .usage)
            #expect(error?.message.contains("keychain password") == true)
            #expect(error?.message.contains("VALUE") == false)
            #expect(runner.tools.isEmpty)
        }

        /// A `step` name renames the step, and the password stays out of the step name and the console.
        @Test func stepNameRenamesTheStepWithoutThePassword() async {
            let restore = secretsSetUp()
            defer { restore() }
            let (log, runner) = registerToolMocks()

            let artifacts = temporaryArtifactsDirectory()
            defer { try? FileManager.default.removeItem(at: artifacts) }
            let exitCode = await runSwiftCI(arguments: ["test"], artifactsDirectory: artifacts) {
                command(Command("test") {
                    try await Keychain.unlock(name: "name", password: Secret(value: "pw-VALUE-2"), step: "Open login")
                })
            }

            #expect(exitCode == 0)
            #expect(runner.tools.count == 1)
            #expect(enteredSteps(in: log.loggedLines) == ["Entering step [Open login]"])
            #expect(log.loggedLines.allSatisfy { !$0.contains("pw-VALUE-2") })
        }
    }
}
