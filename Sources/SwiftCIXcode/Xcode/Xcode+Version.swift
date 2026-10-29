import Foundation
import SwiftCI

extension Xcode {
    /// The version and build number of an app, from its Info.plist.
    public struct AppVersion {
        /// The marketing version, from `CFBundleShortVersionString`, for example `1.2`.
        public let marketingVersion: String
        /// The build number, from `CFBundleVersion`, for example `42`.
        public let buildNumber: String
    }

    /// Reads `CFBundleShortVersionString` and `CFBundleVersion` from the Info.plist at `infoPlist`.
    ///
    /// A value may refer to build settings with `$(NAME)` or `${NAME}`, for example `$(MARKETING_VERSION)` or
    /// `1.$(MINOR)`. The references are resolved from the build settings of the scheme and configuration, or of
    /// `target` when it is given. The build settings are read only if a value needs them. A reference that the build
    /// settings do not define is a ``BuildError`` that names the variable and the file.
    ///
    /// A query: does not open a step.
    public func getVersion(infoPlist: URL, target: String? = nil) async throws -> AppVersion {
        let plist = try Plist.read(url: infoPlist)
        let marketingVersion = try Self.plistString("CFBundleShortVersionString", in: plist, file: infoPlist)
        let buildNumber = try Self.plistString("CFBundleVersion", in: plist, file: infoPlist)

        let needsBuildSettings = [marketingVersion, buildNumber].contains { $0.contains(#/\$(\(|\{)[A-Za-z_]/#) }
        var buildSettings = BuildSettings.empty
        if needsBuildSettings {
            buildSettings = try await getBuildSettings(target: target)
        }

        return AppVersion(
            marketingVersion: try Self.resolve(marketingVersion, file: infoPlist, buildSettings: buildSettings),
            buildNumber: try Self.resolve(buildNumber, file: infoPlist, buildSettings: buildSettings)
        )
    }

    private static func plistString(_ key: String, in plist: [String: Any], file: URL) throws -> String {
        guard let value = plist[key] as? String else {
            throw BuildError(message: "Failed to read key '\(key)' from Plist file at '\(file.filePath)'.")
        }
        return value
    }

    /// Replaces each `$(NAME)` and `${NAME}` in `value` with the build setting `NAME`. Text around the references is kept.
    private static func resolve(_ value: String, file: URL, buildSettings: BuildSettings) throws -> String {
        var result = ""
        var index = value.startIndex
        for match in value.matches(of: #/\$\(([A-Za-z_][A-Za-z0-9_]*)\)|\$\{([A-Za-z_][A-Za-z0-9_]*)\}/#) {
            result += value[index..<match.range.lowerBound]
            let name = String(match.output.1 ?? match.output.2 ?? "")
            guard let setting = buildSettings.all[name] else {
                throw BuildError(
                    message: "Failed to find build setting '\(name)' referenced in the Info.plist at '\(file.filePath)'. "
                        + "Check the scheme, configuration and target."
                )
            }
            result += setting
            index = match.range.upperBound
        }
        result += value[index...]
        return result
    }
}
