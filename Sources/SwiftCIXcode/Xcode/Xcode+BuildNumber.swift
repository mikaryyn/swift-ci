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
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw BuildError(message: "Failed to read file '\(url.filePath)'. Details: \(error)")
        }
        var format = PropertyListSerialization.PropertyListFormat.xml
        let parsed = try? PropertyListSerialization.propertyList(from: data, options: [], format: &format)
        guard var plist = parsed as? [String: Any] else {
            throw BuildError(message: "Failed to read plist file at '\(url.filePath)'.")
        }
        plist["CFBundleVersion"] = buildNumber
        do {
            let newData = try PropertyListSerialization.data(fromPropertyList: plist, format: format, options: 0)
            try newData.write(to: url, options: .atomic)
        } catch {
            throw BuildError(message: "Failed to write file '\(url.filePath)'. Details: \(error)")
        }
    }
}
