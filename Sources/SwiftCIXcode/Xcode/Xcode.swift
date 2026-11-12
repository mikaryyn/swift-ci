import Foundation
import SwiftCI

/// Runs `xcodebuild` on a workspace or project: clean, build, test, archive and export, and reading the build settings.
///
/// An `Xcode` value holds what every run of a project shares: the workspace or project, the scheme, the configuration,
/// the default destination and the build settings. Create one per project and call its methods in a command. The
/// methods that do work open a step. ``getBuildSettings(target:)`` is a query.
public struct Xcode {
    @Use internal var log: Log

    /// Creates a value that runs `xcodebuild` on a workspace or project.
    ///
    /// - Parameters:
    ///   - workspace: The workspace, passed as `-workspace`.
    ///   - project: The project, passed as `-project`.
    ///   - scheme: The scheme, passed as `-scheme`.
    ///   - config: The build configuration, passed as `-configuration`, such as `Release`. Without it, `xcodebuild`
    ///     chooses the configuration itself.
    ///   - destination: The destination, passed as `-destination`. A method with a `destination` parameter uses that one
    ///     instead.
    ///   - buildSettings: Build settings written to a temporary xcconfig file, which is passed as `-xcconfig`. An empty
    ///     dictionary passes no `-xcconfig`. The default turns off the index store (`COMPILER_INDEX_STORE_ENABLE`).
    public init(
        workspace: URL? = nil,
        project: URL? = nil,
        scheme: String? = nil,
        config: String? = nil,
        destination: String? = "generic/platform=iOS",
        buildSettings: [String: String] = ["COMPILER_INDEX_STORE_ENABLE": "NO"]
    ) {
        self.workspace = workspace
        self.project = project
        self.scheme = scheme
        self.config = config
        self.destination = destination
        self.buildSettings = buildSettings
    }

    /// Runs `xcodebuild clean`.
    ///
    /// Opens a step named "Clean MyApp" when called at the top level of a command. `step` renames it.
    public func clean(step name: String? = nil) async throws {
        try await step(default: "Clean \(stepSubject)", name: name) {
            try await runXcodebuild(["clean"])
        }
    }

    /// Runs `xcodebuild build`.
    ///
    /// Opens a step named "Build MyApp" when called at the top level of a command. `step` renames it.
    public func build(step name: String? = nil) async throws {
        try await step(default: "Build \(stepSubject)", name: name) {
            try await runXcodebuild(["build"])
        }
    }

    /// Resolves the Swift package dependencies with `xcodebuild -resolvePackageDependencies`.
    ///
    /// Opens a step named "Resolve packages for MyApp" when called at the top level of a command. `step` renames it.
    public func resolvePackages(step name: String? = nil) async throws {
        try await step(default: "Resolve packages for \(stepSubject)", name: name) {
            try await runXcodebuild(["-resolvePackageDependencies"])
        }
    }

    /// Runs `xcodebuild` with the arguments of this value added to `baseArguments`, and the console filter.
    internal func runXcodebuild(_ baseArguments: [String]) async throws {
        try await withArguments(baseArguments) { arguments in
            let tool = Tool(command: Self.xcodebuildPath, arguments: arguments, filters: Self.filters)
            try await tool.run()
        }
    }

    /// Calls `body` with the arguments of an xcodebuild run: `baseArguments`, then the workspace, project, scheme,
    /// destination, configuration and the xcconfig file of the build settings. `destination` replaces the destination of
    /// this value when it is set. The xcconfig file exists only while `body` runs.
    internal func withArguments<T>(
        _ baseArguments: [String],
        destination: String? = nil,
        _ body: ([String]) async throws -> T
    ) async throws -> T {
        var result = baseArguments
        if let workspace {
            result.append(contentsOf: ["-workspace", workspace.filePath])
        }
        if let project {
            result.append(contentsOf: ["-project", project.filePath])
        }
        if let scheme {
            result.append(contentsOf: ["-scheme", scheme])
        }
        if let destination = destination ?? self.destination {
            result.append(contentsOf: ["-destination", destination])
        }
        if let config {
            result.append(contentsOf: ["-configuration", config])
        }
        guard !buildSettings.isEmpty else {
            return try await body(result)
        }
        let directory = try TemporaryDirectory()
        defer { try? directory.remove() }
        let xcconfigURL = try writeXcconfig(in: directory)
        result.append(contentsOf: ["-xcconfig", xcconfigURL.filePath])
        return try await body(result)
    }

    private func writeXcconfig(in directory: TemporaryDirectory) throws -> URL {
        let url = directory.childURL(name: "build-settings.xcconfig")
        let text = buildSettings
            .sorted(by: { $0.key < $1.key })
            .map { "\($0.key) = \($0.value)" }
            .joined(separator: "\n")
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            throw BuildError(message: "Failed to write file '\(url.filePath)'. Details: \(error)")
        }
        return url
    }

    /// The name used in default step names: the scheme, else the workspace or project file name
    /// without its path and extension, else "Xcode project".
    var stepSubject: String {
        if let scheme {
            return scheme
        }
        if let url = workspace ?? project {
            return url.deletingPathExtension().lastPathComponent
        }
        return "Xcode project"
    }

    internal let workspace: URL?
    internal let project: URL?
    internal let scheme: String?
    internal let config: String?
    internal let destination: String?
    internal let buildSettings: [String: String]

    internal static let xcodebuildPath = "/usr/bin/xcodebuild"
    internal static let dittoPath = "/usr/bin/ditto"
    internal static let xcrunPath = "/usr/bin/xcrun"

    static let filters: [Filter] = [xcodebuildFilter]

    /// Shows errors, warnings and the result line on the console. The full log keeps everything.
    static let xcodebuildFilter: Filter = { line in
        // False warnings of duplicate symbols on Apple silicon Macs.
        if line.contains("both /usr/lib/libauthinstall.dylib") { return nil }

        if let result = line.firstMatch(of: #/^\*\* ([A-Z ]+) SUCCEEDED \*\*/#) {
            return "\(LogSymbol.success) \(result.1) finished"
        }
        if line.contains(#/^\*\* [A-Z ]+ FAILED \*\*/#) { return line }
        if line.contains(#/(^|: )(fatal )?error: /#) { return line }
        if line.contains(#/(^|: )warning: /#) { return line }
        return nil
    }
}
