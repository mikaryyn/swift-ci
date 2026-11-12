import Foundation
import SwiftCI

extension Xcode {
    /// Writes `buildNumber` as the literal value of `CFBundleVersion` in the Info.plist at `infoPlist`. The other keys
    /// and the file's format (XML or binary) are kept.
    ///
    /// The value is not validated. Ad-hoc builds accept any string, for example `dev`, while App Store Connect requires
    /// numbers separated by periods.
    ///
    /// Opens a step named "Set build number to <n>" when called at the top level of a command. `step` renames it.
    public static func setBuildNumber(_ buildNumber: String, infoPlist: URL, step name: String? = nil) async throws {
        try await step(default: "Set build number to \(buildNumber)", name: name) {
            try writeBuildNumber(buildNumber, to: infoPlist)
        }
    }

    private static func writeBuildNumber(_ buildNumber: String, to url: URL) throws {
        @Use var log: Log

        try Plist(url: url).set("CFBundleVersion", buildNumber)
        log("Set CFBundleVersion in \(url.filePath)")
    }
}
