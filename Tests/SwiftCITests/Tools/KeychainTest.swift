@testable import SwiftCI
import Testing

final class KeychainTest {
    var log: LogMock!
    var shell: ShellMock!

    init() {
        registerDependencies()
        log = LogMock()
        shell = ShellMock()
        register(Log.self, log)
        register(Shell.self, shell)
    }

    @Test func testUnlock() async throws {
        @Use var keychain: Keychain
        try await keychain.unlock(name: "name", password: "pw")

        #expect(self.shell.execCommands.count == 1)
        #expect(self.shell.execCommands[0].command == "/usr/bin/security")
        #expect(self.shell.execCommands[0].arguments == ["unlock-keychain", "-p", "pw", "name.keychain"])
        #expect(self.log.loggedLines == ["Unlocked keychain 'name'.".success])
    }
}
