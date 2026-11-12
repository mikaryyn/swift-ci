import Foundation
import SwiftCI

extension Xcode {
    /// The build settings of one target of a scheme, as `xcodebuild -showBuildSettings` reports them. Read them with
    /// ``getBuildSettings(target:)``.
    public struct BuildSettings: Decodable {
        /// Every build setting of the target, by name.
        public let all: [String: String]

        /// The value of the build setting `key`. A build setting that the target does not have is a ``BuildError``.
        public func value(for key: String) throws -> String {
            guard let result = all[key] else {
                throw BuildError(message: "Failed to find the build setting '\(key)'. Check the scheme, configuration and target.")
            }
            return result
        }

        /// The value of the build setting `key`, or `defaultValue` if the target does not have it.
        public func value(for key: String, default defaultValue: String) -> String {
            all[key] ?? defaultValue
        }

        /// The value of `MARKETING_VERSION`.
        public var marketingVersion: String {
            get throws { try value(for: "MARKETING_VERSION") }
        }

        /// The value of `PROVISIONING_PROFILE_SPECIFIER`.
        public var provisioningProfileSpecifier: String {
            get throws { try value(for: "PROVISIONING_PROFILE_SPECIFIER") }
        }

        /// The value of `BUILT_PRODUCTS_DIR`.
        public var builtProductsDir: String {
            get throws { try value(for: "BUILT_PRODUCTS_DIR") }
        }

        /// The target of the entry. `nil` when `xcodebuild` reports no target for it.
        internal let target: String?

        private enum CodingKeys: String, CodingKey {
            case all = "buildSettings"
            case target
        }
    }
}

extension Xcode {
    /// Reads the build settings of the scheme, or of the project if no scheme is set.
    ///
    /// The scheme has one entry per target. Without `target`, the first entry is used. With `target`, the entry of that
    /// target is used, and a target that the entries do not list is a ``BuildError`` that lists the available targets.
    ///
    /// The result of `xcodebuild -showBuildSettings` is cached for the run, which is the process of one `./ci` run. A
    /// second call with the same workspace or project, scheme, configuration, destination and build settings uses the
    /// cached entries, and `xcodebuild` is not run again. Only the entries are cached, so each call still selects its
    /// target. A run that fails is not cached. A script that changes the project's build settings during the run, for
    /// example by editing an .xcconfig file, and reads them again gets the earlier values. There is no way to refresh the
    /// cache.
    ///
    /// A query: does not open a step.
    public func getBuildSettings(target: String? = nil) async throws -> BuildSettings {
        let entries = try await buildSettingsEntries()
        guard let target else {
            return entries[0]
        }
        if let entry = entries.first(where: { $0.target == target }) {
            return entry
        }
        let available = entries.compactMap(\.target)
        let list = available.isEmpty ? "none" : available.joined(separator: ", ")
        throw BuildError(message: "Failed to find target '\(target)' in the build settings. Available targets: \(list).")
    }

    /// The decoded entries of `xcodebuild -showBuildSettings -json`, from the cache if the same run was made before. The
    /// entries are never empty.
    private func buildSettingsEntries() async throws -> [BuildSettings] {
        let key = BuildSettingsKey(
            workspace: workspace?.filePath,
            project: project?.filePath,
            scheme: scheme,
            config: config,
            destination: destination,
            buildSettings: buildSettings.map { BuildSettingsKey.Override(key: $0.key, value: $0.value) }
                .sorted { $0.key < $1.key }
        )
        if let cached = Self.buildSettingsCache[key] {
            return cached
        }
        log.completion("Getting Xcode build settings…")
        let output = try await withArguments(["-showBuildSettings", "-json"]) { arguments in
            let tool = Tool(command: Self.xcodebuildPath, arguments: arguments, filters: [filter(#/./#)])
            return try await tool.output()
        }
        let entries: [BuildSettings]
        do {
            entries = try JSONDecoder().decode([BuildSettings].self, from: Data(output.utf8))
        } catch {
            throw BuildError(
                message: "Failed to read the build settings of \(stepSubject) from the output of "
                    + "'xcodebuild -showBuildSettings -json'. Check that the scheme and the destination exist. Details: \(error)"
            )
        }
        guard !entries.isEmpty else {
            throw BuildError(
                message: "xcodebuild reported no build settings for \(stepSubject). Check that the scheme and the destination exist."
            )
        }
        Self.buildSettingsCache[key] = entries
        return entries
    }

    /// Removes the cached build settings, so the next call of ``getBuildSettings(target:)`` runs `xcodebuild` again. Tests
    /// use it to start from an empty cache.
    static func clearBuildSettingsCache() {
        buildSettingsCache = [:]
    }

    /// The arguments that determine the output of `xcodebuild -showBuildSettings`. The temporary xcconfig path is not part
    /// of the key: its content is, so two values with the same build settings share one entry.
    private struct BuildSettingsKey: Hashable {
        struct Override: Hashable {
            let key: String
            let value: String
        }

        let workspace: String?
        let project: String?
        let scheme: String?
        let config: String?
        let destination: String?
        let buildSettings: [Override]
    }

    /// The entries of each run of `xcodebuild -showBuildSettings`, by the arguments that determine them. Lives as long as
    /// the process.
    private static var buildSettingsCache: [BuildSettingsKey: [BuildSettings]] = [:]
}
