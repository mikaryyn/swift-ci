public enum MatchType: String {
    case appstore, adhoc, enterprise
}

public struct Fastlane {
    public static func match(type: MatchType, appIdentifier: String, teamId: String) async throws {
        let tool = Tool(
            command: "/bin/sh",
            arguments: ["fastlane", "match", type.rawValue, "--readonly", "--app_identifier", appIdentifier, "--team_id", teamId],
            filters: []
        )
        try await tool.run()
    }

    public static func matchUpdate(type: MatchType, appIdentifier: String, teamId: String) async throws {
        let tool = Tool(
            command: "/bin/sh",
            arguments: ["fastlane", "match", type.rawValue, "--force", "--app_identifier", appIdentifier, "--team_id", teamId],
            filters: []
        )
        try await tool.run()
    }
}
