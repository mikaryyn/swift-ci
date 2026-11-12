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
    /// `target` when it is given. The build settings are read only if a value needs them, through
    /// ``getBuildSettings(target:)``, so they are read once for the run and cached (see there). The Info.plist is read on
    /// every call. A reference that the build settings do not define is a ``BuildError`` that names the variable and the file.
    ///
    /// A query: does not open a step.
    public func getVersion(infoPlist: URL, target: String? = nil) async throws -> AppVersion {
        let plist = try Plist.read(url: infoPlist)
        let marketingVersion = try Self.plistString("CFBundleShortVersionString", in: plist, file: infoPlist)
        let buildNumber = try Self.plistString("CFBundleVersion", in: plist, file: infoPlist)

        try Self.rejectModifiers(in: marketingVersion, file: infoPlist)
        try Self.rejectModifiers(in: buildNumber, file: infoPlist)

        let needsBuildSettings = [marketingVersion, buildNumber].contains { $0.contains(#/\$(\(|\{)[A-Za-z_]/#) }
        let settings = needsBuildSettings ? try await getBuildSettings(target: target).all : [:]

        return AppVersion(
            marketingVersion: try Self.resolve(marketingVersion, file: infoPlist, settings: settings),
            buildNumber: try Self.resolve(buildNumber, file: infoPlist, settings: settings)
        )
    }

    private static func plistString(_ key: String, in plist: [String: Any], file: URL) throws -> String {
        guard let value = plist[key] as? String else {
            throw BuildError(message: "The property list file at '\(file.filePath)' has no string for the key '\(key)'.")
        }
        return value
    }

    /// Replaces each `$(NAME)` and `${NAME}` in `value` with the build setting `NAME`. Text around the references is kept.
    private static func resolve(_ value: String, file: URL, settings: [String: String]) throws -> String {
        var result = ""
        var index = value.startIndex
        for match in value.matches(of: #/\$\(([A-Za-z_][A-Za-z0-9_]*)\)|\$\{([A-Za-z_][A-Za-z0-9_]*)\}/#) {
            result += value[index..<match.range.lowerBound]
            let name = String(match.output.1 ?? match.output.2 ?? "")
            guard let setting = settings[name] else {
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

    /// A reference with a modifier, such as `$(PRODUCT_NAME:rfc1034identifier)`, is not resolved, and its text would end up
    /// in the version, so it is an error.
    private static func rejectModifiers(in value: String, file: URL) throws {
        if let reference = value.firstMatch(of: #/\$[({][A-Za-z_][A-Za-z0-9_]*:[^)}]*[)}]/#) {
            throw BuildError(
                message: "The Info.plist at '\(file.filePath)' uses the reference '\(reference.output)' with a modifier. "
                    + "Only plain $(NAME) and ${NAME} references are resolved."
            )
        }
    }
}
