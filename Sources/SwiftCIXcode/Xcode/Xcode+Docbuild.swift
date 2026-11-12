import Foundation
import SwiftCI

public extension Xcode {
    /// Builds the documentation with `xcodebuild docbuild` and returns the `.doccarchive` directories in the built
    /// products directory of the scheme, sorted by name.
    ///
    /// A scheme with several modules produces one archive for each, and all of them are returned, for example to merge
    /// them with ``mergeDocumentation(_:to:step:)``. The directory is not emptied first, so it also holds the archives of
    /// earlier builds that are still in DerivedData, for example of a module that was removed from the project. Delete
    /// DerivedData before the build to avoid them, with ``deleteDerivedData(step:)``. A project without documentation
    /// returns an empty list, and that is not an error.
    ///
    /// `hostingBasePath` is passed to the documentation compiler as `--hosting-base-path`, for a site that is served from
    /// a sub-path. It is set through the build setting `OTHER_DOCC_FLAGS`, so it replaces the value that the project sets
    /// for that setting.
    ///
    /// Opens a step named "Build documentation for MyApp" when called at the top level of a command. `step` renames it.
    ///
    /// - Parameters:
    ///   - hostingBasePath: The path under which the site is served, such as `docs`. Defaults to `nil`: no base path.
    ///   - name: The name of the step, if it is not the default.
    /// - Returns: The archives, sorted by file name.
    func docbuild(hostingBasePath: String? = nil, step name: String? = nil) async throws -> [URL] {
        try await step(default: "Build documentation for \(stepSubject)", name: name) {
            // Find the location of the produced documentation.
            let buildSettings = try await getBuildSettings()
            let outputURL = URL(filePath: try buildSettings.builtProductsDir)
            log.completion("Documentation output path: \(outputURL.filePath)")

            var arguments = ["docbuild"]
            if let hostingBasePath {
                arguments.append("OTHER_DOCC_FLAGS=--hosting-base-path \(hostingBasePath)")
            }

            try await runXcodebuild(arguments)

            return try FileManager.default.contentsOfDirectory(at: outputURL, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "doccarchive" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        }
    }

    /// Merges documentation archives, such as the ones of ``docbuild(hostingBasePath:step:)``, into one archive at
    /// `outputURL` with `xcrun docc merge`. The merged archive has one search index and a landing page that lists every
    /// module. The input archives are logged.
    ///
    /// Opens a step named "Merge documentation archives" when called at the top level of a command. `step` renames it.
    ///
    /// - Parameters:
    ///   - archives: The `.doccarchive` directories to merge.
    ///   - outputURL: The merged `.doccarchive` to write.
    ///   - name: The name of the step, if it is not the default.
    static func mergeDocumentation(_ archives: [URL], to outputURL: URL, step name: String? = nil) async throws {
        @Use var log: Log

        try await step(default: "Merge documentation archives", name: name) {
            for archive in archives {
                log.completion(archive.filePath)
            }
            let arguments = ["docc", "merge"] + archives.map(\.filePath) + ["--output-path", outputURL.filePath]
            try await Tool(command: xcrunPath, arguments: arguments).run()
        }
    }
}
