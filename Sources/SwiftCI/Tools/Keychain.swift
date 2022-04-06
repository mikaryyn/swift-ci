public struct Keychain {
    public static func unlock(name: String, password: String) async throws {
        let tool = Tool(
            command: "/usr/bin/security",
            arguments: ["unlock-keychain", "-p", password, "\(name).keychain"],
            filters: []
        )
        try await tool.run()
        logSuccess("Unlocked keychain '\(name)'.")
    }
}
