import Foundation
import SwiftCI

public extension Xcode {
    /// Builds the documentation with `xcodebuild docbuild` and returns the produced `.doccarchive` URLs.
    ///
    /// Opens a step named "Build documentation for MyApp" when called at the top level of a command. `step` renames it.
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

            let docbuildTool = Tool(
                command: Self.xcodebuildPath,
                arguments: try makeArguments(arguments),
                filters: Self.filters
            )
            try await docbuildTool.run()

            return try FileManager.default.contentsOfDirectory(at: outputURL, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "doccarchive" }
                .filter { try $0.checkResourceIsReachable() }
        }
    }
}
