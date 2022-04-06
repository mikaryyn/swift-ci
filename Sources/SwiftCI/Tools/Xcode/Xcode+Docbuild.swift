import Foundation

public extension Xcode {
    func docbuild(hostingBasePath: String? = nil) async throws -> [URL] {
        // Find the location of the produced documentation.
        let buildSettings = try await getBuildSettings()
        let outputURL = URL(filePath: try buildSettings.builtProductsDir)
        logCompletion("Documentation output path: \(outputURL)")

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
