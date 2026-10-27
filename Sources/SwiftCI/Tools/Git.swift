public struct Git {
    /// Returns the short hash of `HEAD`.
    ///
    /// A query: does not open a step.
    public static func getCommitHash() async throws -> String {
        try await Tool(
            command: "git",
            arguments: ["rev-parse", "--short", "HEAD"],
            filters: [filter(#/.*/#)]
        ).output()
    }

    /// Returns the tag that points exactly at `HEAD`, or `nil` if there is none.
    ///
    /// A query: does not open a step.
    public static func getCommitTag() async throws -> String? {
        // "No tag" is expected, so a non-zero exit is not an error and gets no warning.
        let result = try await Tool(
            command: "git",
            arguments: ["describe", "--tags", "--exact-match"],
            filters: [filter(#/^fatal:/#)]
        ).result()
        guard result.exitCode == 0, !result.stdout.isEmpty else { return nil }
        return result.stdout
    }
}
