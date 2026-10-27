import Foundation
@_spi(Testing) import SwiftCI
@testable import SwiftCI
@testable import SwiftCISigning
@testable import SwiftCITestSupport
import SwiftCITesting
import Testing

extension GlobalStateTests {
    /// The Keychain case of `IntegrationStepTests`. It lives with the signing tests because `Keychain` does.
    @Suite(.serialized) struct IntegrationStepKeychainTests {
        @Test func unlockOpensStepWithoutPasswordInLog() async {
            let restore = secretsSetUp()
            defer { restore() }
            registerDependencies()
            let (log, runner) = registerToolMocks()

            let artifacts = temporaryArtifactsDirectory()
            defer { try? FileManager.default.removeItem(at: artifacts) }
            let exitCode = await runSwiftCI(arguments: ["test"], artifactsDirectory: artifacts) {
                command(Command("test") {
                    try await Keychain.unlock(name: "MyKeychain", password: Secret(value: "s3cret-pw"))
                })
            }

            let lines = log.loggedLines.map(stripANSI)
            #expect(exitCode == 0)
            #expect(runner.tools.count == 1)
            #expect(enteredSteps(in: log.loggedLines) == ["Entering step [Unlock keychain MyKeychain]"])
            #expect(lines.allSatisfy { !$0.contains("s3cret-pw") })
        }
    }
}
