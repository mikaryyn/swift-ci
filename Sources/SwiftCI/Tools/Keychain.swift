public protocol Keychain {
    func unlock(name: String, password: String) async throws
}

public struct KeychainImpl: Keychain {
    public func unlock(name: String, password: String) async throws {
        @Use var log: Log
        @Use var shell: Shell

        try await shell.exec(ShellCommand(
            command: "/usr/bin/security",
            arguments: ["unlock-keychain", "-p", password, "\(name).keychain"],
            filters: []
        ))
        log.success("Unlocked keychain '\(name)'.")
    }
}
