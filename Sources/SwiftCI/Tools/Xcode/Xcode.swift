import Foundation
import System

public struct Xcode {
    public init(
        project: String? = nil,
        scheme: String? = nil,
        configuration: String? = nil,
        destination: String? = "generic/platform=iOS",
        config: Configuration = .standard
    ) {
        self.project = project
        self.scheme = scheme
        self.configuration = configuration
        self.destination = destination
        self.config = config
    }

    public func clean() async throws {
        let tool = Tool(
            command: Self.xcodebuildPath,
            arguments: try makeArguments(["clean"]),
            filters: Self.filters
        )
        try await tool.run()
    }

    public func build() async throws {
        let tool = Tool(
            command: Self.xcodebuildPath,
            arguments: try makeArguments(["build"]),
            filters: Self.filters
        )
        try await tool.run()
    }

    public func archiveAndExport(
        ipaFileName: String,
        outputPath: String
    ) async throws -> ArchiveInfo {
        let tempDir = try TemporaryDirectory(name: "archiveAndExport_$DATE")
        let archivePath = tempDir.childPath(name: "\(ipaFileName).xcarchive")
        let exportPath = tempDir.childPath(name: "export")
        let exportOptionsPath = tempDir.childPath(name: "export_options.plist")

        let archiveInfo = try await archive(to: archivePath)

        let buildSettings = try await getBuildSettings()

        try createExportOptions(
            file: exportOptionsPath,
            method: .adhoc,
            bundleIdentifier: archiveInfo.bundleIdentifier,
            provisioningProfile: buildSettings.provisioningProfileSpecifier,
            signingCertificate: archiveInfo.signingIdentity,
            teamIdentifier: archiveInfo.teamIdentifier
        )

        try await exportArchive(from: archivePath, to: exportPath, exportOptionsPath: exportOptionsPath)

        try copyExportedIpa(from: exportPath, to: FilePath(outputPath), ipaFileName: ipaFileName)

        return archiveInfo
    }

    public func resolvePackages() async throws {
        let tool = Tool(
            command: Self.xcodebuildPath,
            arguments: try makeArguments(["-resolvePackageDependencies"]),
            filters: Self.filters
        )
        try await tool.run()
    }

    public func getBuildSettings() async throws -> BuildSettings {
        logCompletion("Getting Xcode build settings…")
        let tool = Tool(
            command: Self.xcodebuildPath,
            arguments: try makeArguments(["-showBuildSettings", "-json"]),
            filters: [filter(#/./#)]
        )
        let output = try await tool.runAndGetOutput(includeStandardError: false)
        let data = output.data(using: .utf8) ?? Data()
        return try JSONDecoder().decode([BuildSettings].self, from: data).first ?? .empty
    }

    public struct Configuration {
        public static let standard = Configuration(
            xcconfig: ["COMPILER_INDEX_STORE_ENABLE": "NO"]
        )

        var xcconfig: [String: String]
    }

    internal func makeArguments(_ baseArguments: [String], useScheme: Bool = true) throws -> [String] {
        var result = baseArguments
        if let project = project {
            result.append(contentsOf: ["-project", project])
        }
        if useScheme, let scheme = scheme {
            result.append(contentsOf: ["-scheme", scheme])
        }
        if let destination = destination {
            result.append(contentsOf: ["-destination", destination])
        }
        if let configuration = configuration {
            result.append(contentsOf: ["-configuration", configuration])
        }
        if !config.xcconfig.isEmpty {
            let xcconfigFilePath = try createXcconfig().string
            result.append(contentsOf: ["-xcconfig", xcconfigFilePath])
        }
        return result
    }

    private func createXcconfig() throws -> FilePath {
        let path = try TemporaryDirectory().childPath(name: "$UUID.xcconfig")
        let text = config.xcconfig
            .sorted(by: { $0.key < $1.key })
            .map { "\($0.key) = \($0.value)" }
            .joined(separator: "\n")
        do {
            try text.write(toFile: path.string, atomically: true, encoding: .utf8)
        } catch {
            throw BuildError(message: "Failed to write file '\(path)'. Details: \(error)")
        }
        return path
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

    private func archive(to targetPath: FilePath) async throws -> ArchiveInfo {
        let archiveArguments = try makeArguments([
            "archive",
            "-archivePath", targetPath.string
        ])
        let archiveTool = Tool(
            command: Self.xcodebuildPath,
            arguments: archiveArguments,
            filters: Self.filters
        )
        try await archiveTool.run()

        let archiveInfoPlist = try Plist.read(file: targetPath.appending("Info.plist").string)
        let archiveInfo = try ArchiveInfo(plist: archiveInfoPlist)
        logCompletion("Archive information:")
        log("    Bundle identifier: \(archiveInfo.bundleIdentifier)")
        log("    Signing identity : \(archiveInfo.signingIdentity)")
        log("    Team identifier  : \(archiveInfo.teamIdentifier)")
        return archiveInfo
    }

    private func exportArchive(from archivePath: FilePath, to exportPath: FilePath, exportOptionsPath: FilePath) async throws {
        let exportArguments = try makeArguments([
            "-exportArchive",
            "-archivePath", archivePath.string,
            "-exportPath", exportPath.string,
            "-exportOptionsPlist", exportOptionsPath.string
        ], useScheme: false)
        let exportTool = Tool(
            command: Self.xcodebuildPath,
            arguments: exportArguments,
            filters: Self.filters
        )
        try await exportTool.run()
    }

    private func copyExportedIpa(from sourcePath: FilePath, to targetPath: FilePath, ipaFileName: String) throws {
        try FileManager.default.createDirectory(atPath: targetPath.string, withIntermediateDirectories: true)
        let sourceIpaFileName = try FileManager.default.contentsOfDirectory(atPath: sourcePath.string).first { $0.hasSuffix(".ipa") }
        guard let sourceIpaFileName = sourceIpaFileName else {
            throw BuildError(message: "Failed to find IPA file in '\(sourcePath)'")
        }
        let copyFrom = sourcePath.appending(sourceIpaFileName).string
        let copyTo = targetPath.appending("\(ipaFileName).ipa").string
        logCompletion("Copying IPA File")
        log("    From: \(copyFrom)")
        log("    To:   \(copyTo)")
        try FileManager.default.copyItem(atPath: copyFrom, toPath: copyTo)
    }

    private func createExportOptions(
        file: FilePath,
        method: ExportMethod,
        bundleIdentifier: String,
        provisioningProfile: String,
        signingCertificate: String,
        teamIdentifier: String
    ) throws {
        let lines = try Plist.save(
            toFile: file.string,
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

        logLines(title: "Contents of generated '\(file)' file:", lines: lines)
    }

    private let project: String?
    private let scheme: String?
    private let configuration: String?
    private let destination: String?
    private let config: Configuration

    internal static let xcodebuildPath = "/usr/bin/xcodebuild"

    // TODO
    static let filters = [
        // False warnings of duplicate symbols on M1 macs.
        filter("both /usr/lib/libauthinstall.dylib"),

        // Empty lines
        filter(#/^ */#),

        filter("Requested but did not find extension point with identifier"),
        filter("detected encoding of input file as Unicode (UTF-8)"),

        // Build phases
        filter(#/^Resolve Package Graph$/#),
        filter(#/^Analyze workspace$/#),
        filter(#/^Create build description$/#),
        filter(#/^Build description signature:/#),
        filter(#/^Build description path/#),
        filter(#/^$/#),
        filter(#/^$/#),

        // Package resolution
        filter(#/^Resolved source packages:$/#),
        filter(#/  ([\w\-]+): (https|git|/)/#),
        filter(#/^resolved source packages: .+$/#, "PACKAGE RESOLUTION finished".success),

        // Command line tools
        filter(#/^ *(cd|/bin/chmod|/bin/ln|/bin/mkdir|/usr/bin/touch|/usr/bin/codesign|/bin/sh|/usr/sbin/chown|export) /#),
        filter(#/\/bin/(actool|ibtool|strip|dsymutil|clang|swiftc|swift-frontend|lipo) /#),

        // Actool/ibtool
        filter("/* com.apple.actool.compilation-results */"),
        filter("/* com.apple.actool.document.notices */"),
        filter("/* com.apple.ibtool.document.notices */"),
        filter(#/\.build/assetcatalog_generated_info\.plist$/#),
        filter(#/\.bundle/Assets\.car$/#),

        // Entitlements
        filter(#/^ *Entitlements:$/#),
        filter(#/^ *\{$/#),
        filter(#/^ *"[^"]+" = .+?;/#),
        filter(#/^\}$/#),

        // IBAgent (may be useful?)
        filter(" IBAgent-iOS["),

        // Signing
        filter(#/^ *Signing Identity: *"([^"]+)"/#),
        filter(#/^ *Provisioning Profile: *"([^"]+)"/#),
        filter(#/^ *\([0-9a-f-]+\)$/#),

        // Something
        filter("DEBUG: Added to environment"),
        filter(#/^ *TMPDIR = "//#),

        filter(#/^ *builtin-create-build-directory /#),
        filter(#/^ *builtin-process-xcframework /#),
        filter(#/^ *builtin-process-xcframework /#),
        filter(#/^ *builtin-copy /#),
        filter(#/^ *write-file /#),
        filter(#/^ *builtin-swiftStdLibTool /#),
        filter(#/^ *builtin-infoPlistUtility /#),
        filter(#/^ *builtin-copyStrings /#),
        filter(#/^ *builtin-productPackagingUtility /#),
        filter(#/^ *builtin-RegisterExecutionPolicyException /#),
        filter(#/^ *builtin-swiftHeaderTool /#),
        filter(#/^ *builtin-validationUtility /#),

        filter(#/^remark: /#),
        filter(#/^note: /#),
        filter(#/^Probing signature of /#),

        // Build actions
        filter(#/^SymLink /#),
        filter(#/^CreateBuildDirectory /#),
        filter(#/^CodeSign /#),
        filter(#/^SetMode /#),
        filter(#/^CompileXIB /#),
        filter(#/^MkDir /#),
        filter(#/^ProcessXCFramework /#),
        filter(#/^WriteAuxiliaryFile /#),
        filter(#/^CompileAssetCatalog /#),
        filter(#/^Copying /#),
        filter(#/^Codesigning /#),
        filter(#/^CopySwiftLibs /#),
        filter(#/^GenerateDSYMFile /#),
        filter(#/^CompileStoryboard /#),
        filter(#/^LinkStoryboards /#),
        filter(#/^Touch /#),
        filter(#/^Copy /#),
        filter(#/^CopyStringsFile /#),
        filter(#/^SwiftCodeGeneration /#),
        filter(#/^Ld /#),
        filter(#/^CompileSwift /#),
        filter(#/^CompileSwiftSources /#),
        filter(#/^RegisterExecutionPolicyException /#),
        filter(#/^PhaseScriptExecution /#),
        filter(#/^ProcessProductPackaging /#),
        filter(#/^ProcessInfoPlistFile /#),
        filter(#/^CpResource /#),
        filter(#/^SetOwnerAndGroup /#),
        filter(#/^SwiftMergeGeneratedHeaders /#),
        filter(#/^Validate /#),
        filter(#/^CompileC /#),
        filter(#/^CreateUniversalBinary /#),
        filter(#/^Strip /#),

        // WARNINGS

        // Compiler warning
        filter(#/^(/.+?:\d+:\d+): warning: (.*)/#),
        // Linker warning
        filter(#/^(ld: )warning: (.*)/#),

        // ERRORS

        // RESULTS

        // Operation was successfully finished.
        filter(#/^\*\* ([A-Z]*) SUCCEEDED \*\*/#, { "\($0.1) finished".success })

    ]
}
