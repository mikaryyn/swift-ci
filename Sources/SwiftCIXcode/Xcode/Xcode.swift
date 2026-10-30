import Foundation
import SwiftCI

public struct Xcode {
    @Use internal var log: Log

    public init(
        workspace: URL? = nil,
        project: URL? = nil,
        scheme: String? = nil,
        configuration: String? = nil,
        destination: String? = "generic/platform=iOS",
        config: Configuration = .standard
    ) {
        self.workspace = workspace
        self.project = project
        self.scheme = scheme
        self.configuration = configuration
        self.destination = destination
        self.config = config
    }

    /// Runs `xcodebuild clean`.
    ///
    /// Opens a step named "Clean MyApp" when called at the top level of a command. `step` renames it.
    public func clean(step name: String? = nil) async throws {
        try await step(default: "Clean \(stepSubject)", name: name) {
            let tool = Tool(
                command: Self.xcodebuildPath,
                arguments: try makeArguments(["clean"]),
                filters: Self.filters
            )
            try await tool.run()
        }
    }

    /// Runs `xcodebuild build`.
    ///
    /// Opens a step named "Build MyApp" when called at the top level of a command. `step` renames it.
    public func build(step name: String? = nil) async throws {
        try await step(default: "Build \(stepSubject)", name: name) {
            let tool = Tool(
                command: Self.xcodebuildPath,
                arguments: try makeArguments(["build"]),
                filters: Self.filters
            )
            try await tool.run()
        }
    }

    /// Runs `xcodebuild test` and writes the result bundle to `resultBundleURL`.
    ///
    /// `destination` is passed as `-destination`. Without it, the destination of this `Xcode` value is used. A test run
    /// needs a concrete destination, such as `platform=iOS Simulator,name=iPhone 17,OS=latest`. The default destination,
    /// `generic/platform=iOS`, fails in `xcodebuild` for tests.
    ///
    /// An existing bundle at `resultBundleURL` is removed first, because `xcodebuild` refuses to write over it. Its parent
    /// directory is created if it is missing. `enableCodeCoverage` sets `-enableCodeCoverage` to `YES` or `NO`.
    ///
    /// The console shows the failing and skipped tests with their issues, and the summary lines. Passing tests are
    /// hidden.
    /// If `rawLogURL` is set, every line of the output goes to that file unfiltered (see ``Tool/outputFile``).
    ///
    /// If `xcodebuild` exits with a non-zero code, the error names the scheme and the exit code, and gives the path of the
    /// result bundle if the bundle exists. The bundle and the raw log are complete then, so a caller can catch the error,
    /// read them, and rethrow.
    ///
    /// Opens a step named "Test MyApp" when called at the top level of a command. `step` renames it.
    public func test(
        destination: String? = nil,
        resultBundleURL: URL,
        rawLogURL: URL? = nil,
        enableCodeCoverage: Bool = true,
        step name: String? = nil
    ) async throws {
        try await step(default: "Test \(stepSubject)", name: name) {
            try prepareResultBundle(at: resultBundleURL)
            let arguments = try makeArguments(
                [
                    "test",
                    "-resultBundlePath", resultBundleURL.filePath,
                    "-enableCodeCoverage", enableCodeCoverage ? "YES" : "NO"
                ],
                destination: destination
            )
            let tool = Tool(
                command: Self.xcodebuildPath,
                arguments: arguments,
                blockFilter: Self.testOutputFilter(),
                outputFile: rawLogURL
            )
            let result = try await tool.result()
            guard result.exitCode == 0 else {
                throw BuildError(message: testFailureMessage(exitCode: result.exitCode, resultBundleURL: resultBundleURL))
            }
        }
    }

    /// Removes an existing result bundle at `url`, and creates its parent directory.
    private func prepareResultBundle(at url: URL) throws {
        if FileManager.default.fileExists(atPath: url.filePath) {
            try FileManager.default.removeItem(at: url)
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    private func testFailureMessage(exitCode: Int32, resultBundleURL: URL) -> String {
        let subject = scheme.map { "scheme '\($0)'" } ?? "the Xcode project"
        var message = "xcodebuild test of \(subject) exited with code \(exitCode)."
        if FileManager.default.fileExists(atPath: resultBundleURL.filePath) {
            message += " The result bundle is at '\(resultBundleURL.filePath)'."
        }
        return message
    }

    /// Archives the project, exports it as an IPA and copies the IPA to `outputURL` as `<ipaFileName>.ipa`.
    ///
    /// Unless `includeDSYMZip` is `false`, it also zips the dSYMs of the archive to `outputURL` as
    /// `<ipaFileName>.dSYM.zip`, with the `.dSYM` bundles at the root of the zip. If the archive has no dSYMs, a warning
    /// is logged and no zip is written; the step still succeeds.
    ///
    /// `outputURL` defaults to the artifacts directory (``Artifacts/directory``), read when the call is made, so it must
    /// be called inside a command. The directory is created if it is missing, and an IPA or dSYM zip of the same name in
    /// it is replaced. The archive and the export are intermediate files in a temporary directory and are not kept.
    ///
    /// Opens a step named "Archive and export MyApp" when called at the top level of a command. `step` renames it.
    ///
    /// - Parameters:
    ///   - ipaFileName: The name of the IPA without the `.ipa` extension, for example `MyApp`.
    ///   - outputURL: The directory that receives the IPA and the dSYM zip. Defaults to the artifacts directory.
    ///   - includeDSYMZip: Whether to write the dSYM zip. Pass `false` to write only the IPA.
    ///   - name: The name of the step, if it is not the default.
    /// - Returns: The bundle identifier, signing identity and team identifier of the archive.
    public func archiveAndExport(
        ipaFileName: String,
        outputURL: URL = Artifacts.directory,
        includeDSYMZip: Bool = true,
        step name: String? = nil
    ) async throws -> ArchiveInfo {
        try await step(default: "Archive and export \(stepSubject)", name: name) {
            // A unique name: the dSYMs are zipped from the archive, so an archive from another call must not be reused.
            let tempDir = try TemporaryDirectory(name: "archiveAndExport_$UUID")
            let archiveURL = tempDir.childURL(name: "\(ipaFileName).xcarchive")
            let exportURL = tempDir.childURL(name: "export")
            let exportOptionsURL = tempDir.childURL(name: "export_options.plist")

            let archiveInfo = try await archive(to: archiveURL)

            let buildSettings = try await getBuildSettings()

            try createExportOptions(
                file: exportOptionsURL,
                method: .adhoc,
                bundleIdentifier: archiveInfo.bundleIdentifier,
                provisioningProfile: buildSettings.provisioningProfileSpecifier,
                signingCertificate: archiveInfo.signingIdentity,
                teamIdentifier: archiveInfo.teamIdentifier
            )

            try await exportArchive(from: archiveURL, to: exportURL, exportOptionsURL: exportOptionsURL)

            try copyExportedIpa(from: exportURL, to: outputURL, ipaFileName: ipaFileName)

            if includeDSYMZip {
                try await writeDSYMZip(from: archiveURL, to: outputURL, ipaFileName: ipaFileName)
            }

            return archiveInfo
        }
    }

    /// Resolves the Swift package dependencies with `xcodebuild -resolvePackageDependencies`.
    ///
    /// Opens a step named "Resolve packages for MyApp" when called at the top level of a command. `step` renames it.
    public func resolvePackages(step name: String? = nil) async throws {
        try await step(default: "Resolve packages for \(stepSubject)", name: name) {
            let tool = Tool(
                command: Self.xcodebuildPath,
                arguments: try makeArguments(["-resolvePackageDependencies"]),
                filters: Self.filters
            )
            try await tool.run()
        }
    }

    /// Reads the build settings of the scheme, or of the project if no scheme is set.
    ///
    /// The scheme has one entry per target. Without `target`, the first entry is used. With `target`, the entry of that
    /// target is used, and a target that the entries do not list is a ``BuildError`` that lists the available targets.
    ///
    /// A query: does not open a step.
    public func getBuildSettings(target: String? = nil) async throws -> BuildSettings {
        log.completion("Getting Xcode build settings…")
        let tool = Tool(
            command: Self.xcodebuildPath,
            arguments: try makeArguments(["-showBuildSettings", "-json"]),
            filters: [filter(#/./#)]
        )
        let output = try await tool.output()
        let data = output.data(using: .utf8) ?? Data()
        let entries = try JSONDecoder().decode([BuildSettings].self, from: data)
        guard let target else {
            return entries.first ?? .empty
        }
        if let entry = entries.first(where: { $0.target == target }) {
            return entry
        }
        let available = entries.compactMap(\.target)
        let list = available.isEmpty ? "none" : available.joined(separator: ", ")
        throw BuildError(message: "Failed to find target '\(target)' in the build settings. Available targets: \(list).")
    }

    public struct Configuration {
        public static let standard = Configuration(
            xcconfig: ["COMPILER_INDEX_STORE_ENABLE": "NO"]
        )

        var xcconfig: [String: String]
    }

    /// The arguments of an xcodebuild run. `destination` replaces the destination of this value when it is set.
    internal func makeArguments(_ baseArguments: [String], destination: String? = nil) throws -> [String] {
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
        if let configuration {
            result.append(contentsOf: ["-configuration", configuration])
        }
        if !config.xcconfig.isEmpty {
            let xcconfigPath = try createXcconfig().filePath
            result.append(contentsOf: ["-xcconfig", xcconfigPath])
        }
        return result
    }

    private func createXcconfig() throws -> URL {
        let url = try TemporaryDirectory().childURL(name: "$UUID.xcconfig")
        let text = config.xcconfig
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

    public enum ExportMethod: String {
        case appstore
        case adhoc = "ad-hoc"
        case development
        case enterprise
    }

    public struct ArchiveInfo {
        init(plist: [String: Any]) throws {
            guard
                let properties = plist["ApplicationProperties"] as? [String: Any],
                let bundleIdentifier = properties["CFBundleIdentifier"] as? String,
                let signingIdentity = properties["SigningIdentity"] as? String,
                let teamIdentifier = properties["Team"] as? String
            else {
                throw BuildError(message: "Failed to read archive information")
            }
            self.bundleIdentifier = bundleIdentifier
            self.signingIdentity = signingIdentity
            self.teamIdentifier = teamIdentifier
        }

        public let bundleIdentifier: String
        public let signingIdentity: String
        public let teamIdentifier: String
    }

    private func archive(to targetURL: URL) async throws -> ArchiveInfo {
        let archiveArguments = try makeArguments([
            "archive",
            "-archivePath", targetURL.filePath
        ])
        let archiveTool = Tool(
            command: Self.xcodebuildPath,
            arguments: archiveArguments,
            filters: Self.filters
        )
        try await archiveTool.run()

        let archiveInfoPlist = try Plist.read(url: targetURL.appending(path: "Info.plist"))
        let archiveInfo = try ArchiveInfo(plist: archiveInfoPlist)
        log.completion("Archive information:")
        log("    Bundle identifier: \(archiveInfo.bundleIdentifier)")
        log("    Signing identity : \(archiveInfo.signingIdentity)")
        log("    Team identifier  : \(archiveInfo.teamIdentifier)")
        return archiveInfo
    }

    /// Exports the archive. xcodebuild takes no workspace, project, scheme, destination or configuration here: it fails
    /// with a workspace but no scheme, and the archive already holds what the export needs.
    private func exportArchive(from archiveURL: URL, to exportURL: URL, exportOptionsURL: URL) async throws {
        let exportArguments = [
            "-exportArchive",
            "-archivePath", archiveURL.filePath,
            "-exportPath", exportURL.filePath,
            "-exportOptionsPlist", exportOptionsURL.filePath
        ]
        let exportTool = Tool(
            command: Self.xcodebuildPath,
            arguments: exportArguments,
            filters: Self.filters
        )
        try await exportTool.run()
    }

    private func copyExportedIpa(from sourceURL: URL, to targetURL: URL, ipaFileName: String) throws {
        try FileManager.default.createDirectory(at: targetURL, withIntermediateDirectories: true)
        let sourceIpaFileName = try FileManager.default.contentsOfDirectory(atPath: sourceURL.filePath).first { $0.hasSuffix(".ipa") }
        guard let sourceIpaFileName = sourceIpaFileName else {
            throw BuildError(message: "Failed to find IPA file in '\(sourceURL.filePath)'")
        }
        let copyFrom = sourceURL.appending(path: sourceIpaFileName)
        let copyTo = targetURL.appending(path: "\(ipaFileName).ipa")
        log.completion("Copying IPA File")
        log("    From: \(copyFrom.filePath)")
        log("    To:   \(copyTo.filePath)")
        // An IPA of the same name is from an earlier run into the same directory. It is replaced, as the full log is.
        if FileManager.default.fileExists(atPath: copyTo.filePath) {
            try FileManager.default.removeItem(at: copyTo)
        }
        try FileManager.default.copyItem(at: copyFrom, to: copyTo)
    }

    /// Zips the `dSYMs` folder of the archive with `ditto`, so the zip holds the `.dSYM` bundles at its root.
    ///
    /// An archive without dSYMs, such as one built without the debug information format `DWARF with dSYM File`, logs
    /// a warning and writes no zip. An existing zip of the same name is left alone then, and the warning says so.
    private func writeDSYMZip(from archiveURL: URL, to outputURL: URL, ipaFileName: String) async throws {
        let dSYMsURL = archiveURL.appending(path: "dSYMs")
        let zipURL = outputURL.appending(path: "\(ipaFileName).dSYM.zip")
        // A zip of the same name is from an earlier run into the same directory. It is removed also when this archive
        // has no dSYMs, so an old zip never sits next to a new IPA it does not belong to.
        if FileManager.default.fileExists(atPath: zipURL.filePath) {
            try FileManager.default.removeItem(at: zipURL)
        }

        let dSYMs = (try? FileManager.default.contentsOfDirectory(atPath: dSYMsURL.filePath)) ?? []
        guard !dSYMs.isEmpty else {
            log.warning("No dSYMs in '\(dSYMsURL.filePath)', so no dSYM zip is written. Build with the debug information "
                + "format 'DWARF with dSYM File' to get dSYMs.")
            return
        }

        try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)
        log.completion("Zipping dSYMs")
        log("    From: \(dSYMsURL.filePath)")
        log("    To:   \(zipURL.filePath)")
        // ditto prints nothing when it succeeds. A failure throws with its stderr, so the console filter hides all lines.
        let tool = Tool(
            command: Self.dittoPath,
            arguments: ["-c", "-k", "--sequesterRsrc", dSYMsURL.filePath, zipURL.filePath],
            filters: [filter(#/./#)]
        )
        try await tool.run()
    }

    private func createExportOptions(
        file: URL,
        method: ExportMethod,
        bundleIdentifier: String,
        provisioningProfile: String,
        signingCertificate: String,
        teamIdentifier: String
    ) throws {
        let lines = try Plist.save(
            to: file,
            contents: [
                "compileBitcode": false,
                "distributionBundleIdentifier": bundleIdentifier,
                "method": method.rawValue,
                "provisioningProfiles": [
                    bundleIdentifier: provisioningProfile
                ],
                "signingCertificate": signingCertificate,
                "teamID": teamIdentifier
            ]
        )

        log.lines(title: "Contents of generated '\(file.filePath)' file:", lines: lines)
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

    private let workspace: URL?
    private let project: URL?
    private let scheme: String?
    private let configuration: String?
    private let destination: String?
    private let config: Configuration

    internal static let xcodebuildPath = "/usr/bin/xcodebuild"
    internal static let dittoPath = "/usr/bin/ditto"

    static let filters: [Filter] = [xcodebuildFilter]

    /// Shows errors, warnings and the result line on the console. The full log keeps everything.
    static let xcodebuildFilter: Filter = { line in
        // False warnings of duplicate symbols on Apple silicon Macs.
        if line.contains("both /usr/lib/libauthinstall.dylib") { return nil }

        if let result = line.firstMatch(of: #/^\*\* ([A-Z ]+) SUCCEEDED \*\*/#) {
            return "\(result.1) finished".success
        }
        if line.contains(#/^\*\* [A-Z ]+ FAILED \*\*/#) { return line }
        if line.contains(#/(^|: )(fatal )?error: /#) { return line }
        if line.contains(#/(^|: )warning: /#) { return line }
        return nil
    }
}
