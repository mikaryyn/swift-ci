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
        var settings = [String: String]()
        let tool = Tool(
            command: Self.xcodebuildPath,
            arguments: try makeArguments(["-showBuildSettings"]),
            filters: [reFilter(".", nil)]
        )
        let output = try await tool.runAndGetOutput()
        for line in output.split(whereSeparator: \.isNewline) {
            let result = String(line).matches(of: #"^ +([A-Za-z0-9_]+) = (.*)$"#)
            if result.count == 2 {
                settings[result[0]] = result[1]
            }
        }
        return BuildSettings(all: settings)
    }

    public struct Configuration {
        public static let standard = Configuration(
            xcconfig: ["COMPILER_INDEX_STORE_ENABLE": "NO"]
        )

        var xcconfig: [String: String]
    }

    private func makeArguments(_ baseArguments: [String], useScheme: Bool = true) throws -> [String] {
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

/*non appstore
	if options.CompileBitcode != CompileBitcodeDefault {
		hash[CompileBitcodeKey] = options.CompileBitcode
	}
	if options.EmbedOnDemandResourcesAssetPacksInBundle != EmbedOnDemandResourcesAssetPacksInBundleDefault {
		hash[EmbedOnDemandResourcesAssetPacksInBundleKey] = options.EmbedOnDemandResourcesAssetPacksInBundle
	}
	if !options.Manifest.IsEmpty() {
		hash[ManifestKey] = options.Manifest.ToHash()
	}
	if len(options.BundleIDProvisioningProfileMapping) > 0 {
		hash[ProvisioningProfilesKey] = options.BundleIDProvisioningProfileMapping
	}
	if options.SigningCertificate != "" {
		hash[SigningCertificateKey] = options.SigningCertificate
	}
	if options.SigningStyle != "" {
		hash[SigningStyleKey] = options.SigningStyle
	}


    appstore
	if options.UploadBitcode != UploadBitcodeDefault {
		hash[UploadBitcodeKey] = options.UploadBitcode
	}
	if options.UploadSymbols != UploadSymbolsDefault {
		hash[UploadSymbolsKey] = options.UploadSymbols
	}
	if options.ManageAppVersion != manageAppVersionDefault {
		hash[manageAppVersionKey] = options.ManageAppVersion
	}
	if options.ICloudContainerEnvironment != "" {
		hash[ICloudContainerEnvironmentKey] = options.ICloudContainerEnvironment
	}
	if options.DistributionBundleIdentifier != "" {
		hash[DistributionBundleIdentifier] = options.DistributionBundleIdentifier
	}
	if len(options.BundleIDProvisioningProfileMapping) > 0 {
		hash[ProvisioningProfilesKey] = options.BundleIDProvisioningProfileMapping
	}
	if options.SigningCertificate != "" {
		hash[SigningCertificateKey] = options.SigningCertificate
	}
	if options.InstallerSigningCertificate != "" {
		hash[InstallerSigningCertificateKey] = options.InstallerSigningCertificate
	}
	if options.SigningStyle != "" {
		hash[SigningStyleKey] = options.SigningStyle
	}

*/

    private let project: String?
    private let scheme: String?
    private let configuration: String?
    private let destination: String?
    private let config: Configuration

    private static let xcodebuildPath = "/usr/bin/xcodebuild"

    // TODO
    static let filters = [
        // False warnings of duplicate symbols on M1 macs.
        textFilter("both /usr/lib/libauthinstall.dylib", nil),

        // Empty lines
        reFilter("^ *$", nil),

        textFilter("Requested but did not find extension point with identifier", nil),
        textFilter("detected encoding of input file as Unicode (UTF-8)", nil),

        // Build phases
        reFilter("^Resolve Package Graph$", nil),
        reFilter("^Analyze workspace$", nil),
        reFilter("^Create build description$", nil),
        reFilter("^Build description signature:", nil),
        reFilter("^Build description path", nil),
        reFilter("^$", nil),
        reFilter("^$", nil),

        // Package resolution
        reFilter(#"^Resolved source packages:$"#, nil),
        reFilter(#"  ([\w\-]+): (https|git|/)"#, nil),
        reFilter(#"^resolved source packages: .+$"#, "PACKAGE RESOLUTION finished".success),

        // Command line tools
        reFilter("^ *(cd|/bin/chmod|/bin/ln|/bin/mkdir|/usr/bin/touch|/usr/bin/codesign|/bin/sh|/usr/sbin/chown|export) ", nil),
        reFilter("/bin/(actool|ibtool|strip|dsymutil|clang|swiftc|swift-frontend|lipo) ", nil),

        // Actool/ibtool
        textFilter("/* com.apple.actool.compilation-results */", nil),
        textFilter("/* com.apple.actool.document.notices */", nil),
        textFilter("/* com.apple.ibtool.document.notices */", nil),
        reFilter(#"\.build/assetcatalog_generated_info\.plist$"#, nil),
        reFilter(#"\.bundle/Assets\.car$"#, nil),

        // Entitlements
        reFilter("^ *Entitlements:$", nil),
        reFilter(#"^ *\{$"#, nil),
        reFilter(#"^ *"[^"]+" = .+?;"#, nil),
        reFilter(#"^\}$"#, nil),

        // IBAgent (may be useful?)
        textFilter(" IBAgent-iOS[", nil),

        // Signing
        reFilter(#"^ *Signing Identity: *"([^"]+)""#, nil),
        reFilter(#"^ *Provisioning Profile: *"([^"]+)""#, nil),
        reFilter(#"^ *\([0-9a-f-]+\)$"#, nil),

        // Something
        textFilter("DEBUG: Added to environment", nil),
        reFilter(#"^ *TMPDIR = "/"#, nil),

        reFilter("^ *builtin-create-build-directory ", nil),
        reFilter("^ *builtin-process-xcframework ", nil),
        reFilter("^ *builtin-process-xcframework ", nil),
        reFilter("^ *builtin-copy ", nil),
        reFilter("^ *write-file ", nil),
        reFilter("^ *builtin-swiftStdLibTool ", nil),
        reFilter("^ *builtin-infoPlistUtility ", nil),
        reFilter("^ *builtin-copyStrings ", nil),
        reFilter("^ *builtin-productPackagingUtility ", nil),
        reFilter("^ *builtin-RegisterExecutionPolicyException ", nil),
        reFilter("^ *builtin-swiftHeaderTool ", nil),
        reFilter("^ *builtin-validationUtility ", nil),

        reFilter("^remark: ", nil),
        reFilter("^note: ", nil),
        reFilter("^Probing signature of ", nil),

        // Build actions
        reFilter("^SymLink ", nil),
        reFilter("^CreateBuildDirectory ", nil),
        reFilter("^CodeSign ", nil),
        reFilter("^SetMode ", nil),
        reFilter("^CompileXIB ", nil),
        reFilter("^MkDir ", nil),
        reFilter("^ProcessXCFramework ", nil),
        reFilter("^WriteAuxiliaryFile ", nil),
        reFilter("^CompileAssetCatalog ", nil),
        reFilter("^Copying ", nil),
        reFilter("^Codesigning ", nil),
        reFilter("^CopySwiftLibs ", nil),
        reFilter("^GenerateDSYMFile ", nil),
        reFilter("^CompileStoryboard ", nil),
        reFilter("^LinkStoryboards ", nil),
        reFilter("^Touch ", nil),
        reFilter("^Copy ", nil),
        reFilter("^CopyStringsFile ", nil),
        reFilter("^SwiftCodeGeneration ", nil),
        reFilter("^Ld ", nil),
        reFilter("^CompileSwift ", nil),
        reFilter("^CompileSwiftSources ", nil),
        reFilter("^RegisterExecutionPolicyException ", nil),
        reFilter("^PhaseScriptExecution ", nil),
        reFilter("^ProcessProductPackaging ", nil),
        reFilter("^ProcessInfoPlistFile ", nil),
        reFilter("^CpResource ", nil),
        reFilter("^SetOwnerAndGroup ", nil),
        reFilter("^SwiftMergeGeneratedHeaders ", nil),
        reFilter("^Validate ", nil),
        reFilter("^CompileC ", nil),
        reFilter("^CreateUniversalBinary ", nil),
        reFilter("^Strip ", nil),

        // WARNINGS

        // Compiler warning
        reFilter(#"^(/.+?:\d+:\d+): warning: (.*)"#, nil),
        // Linker warning
        reFilter(#"^(ld: )warning: (.*)"#, nil),

        // ERRORS

        // RESULTS

        // Operation was successfully finished.
        reFilter(#"^\*\* ([A-Z]*) SUCCEEDED \*\*"#, "$1 finished".success)

    ]
}
