public struct Git {
    public static func getCommitHash() async throws -> String {
        let tool = Tool(shellCommand: "git rev-parse --short HEAD")
        let result = try await tool.runAndGetOutput()
        return result
    }

    public static func getCommitTag() async throws -> String? {
        let tool = Tool(
            shellCommand: "git describe --tags --exact-match",
            filters: [
                filter(#/^fatal:/#)
            ],
            allowFailure: true
        )
        let result = try await tool.runAndGetOutput()
        return result.isEmpty || result.hasPrefix("fatal:") ? nil : result
    }
}
