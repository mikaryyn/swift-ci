@testable import SwiftCI
import Foundation

/// Helpers that the Xcode test suites share.
enum XcodeTestSupport {
    /// Runs `body` with an Info.plist that has the two version keys, in a temporary directory that is removed
    /// afterwards. `body` gets the path of the file.
    static func withInfoPlist(short: String, build: String, _ body: (URL) async throws -> Void) async throws {
        let dir = try TemporaryDirectory(name: "Info-plist-$UUID")
        defer { try? FileManager.default.removeItem(at: dir.url) }
        let url = dir.childURL(name: "Info.plist")
        try Plist.save(to: url, contents: [
            "CFBundleIdentifier": "com.example.myapp",
            "CFBundleShortVersionString": short,
            "CFBundleVersion": build,
        ])
        try await body(url)
    }
}
