import Foundation
import SwiftCI

public extension Xcode {
    /// Archives the project, exports it as an IPA and copies the IPA to `outputURL` as `<ipaFileName>.ipa`.
    ///
    /// `method` is the export method. The default, ``ExportMethod/adhoc``, exports for ad-hoc distribution.
    /// ``ExportMethod/appstore`` exports for App Store Connect. An App Store export only writes the IPA: it is not
    /// uploaded, so uploading it is the caller's job, for example with `AppStoreConnect.uploadBuild` from `SwiftCIAppStoreConnect`.
    ///
    /// `provisioningProfile` names the provisioning profile of the export. It is called with the bundle identifier of
    /// the archive, and its result is the profile name. Use it when the profile is not the one of the build settings, for
    /// example when the archive is signed with an ad-hoc profile but the export needs the App Store profile of the same
    /// app. Without it, the export uses `PROVISIONING_PROFILE_SPECIFIER` of the build settings, and reads them.
    ///
    /// Unless `includeDSYMZip` is `false`, it also zips the dSYMs of the archive to `outputURL` as
    /// `<ipaFileName>.dSYM.zip`, with the `.dSYM` bundles at the root of the zip. If the archive has no dSYMs, a warning
    /// is logged and no zip is written; the step still succeeds.
    ///
    /// `outputURL` defaults to the artifacts directory (``Artifacts/directory``), read when the call is made, so it must
    /// be called inside a command. The directory is created if it is missing, and an IPA or dSYM zip of the same name in
    /// it is replaced. The archive and the export are intermediate files in a temporary directory, and the step removes
    /// the directory when it ends, also when it fails.
    ///
    /// To keep the archive for a later step, pass `archiveURL`. The `.xcarchive` is then written there, and
    /// ``ExportedApp/archiveURL`` returns it. An archive that already exists at `archiveURL` is removed first, and the
    /// parent directory is created if it is missing. The caller owns the kept archive and removes it.
    ///
    /// Opens a step named "Archive and export MyApp" when called at the top level of a command. `step` renames it.
    ///
    /// - Parameters:
    ///   - ipaFileName: The name of the IPA without the `.ipa` extension, for example `MyApp`.
    ///   - method: The export method. Defaults to ad-hoc.
    ///   - provisioningProfile: Returns the provisioning profile name for the bundle identifier of the archive. Defaults
    ///     to the `PROVISIONING_PROFILE_SPECIFIER` build setting.
    ///   - outputURL: The directory that receives the IPA and the dSYM zip. Defaults to the artifacts directory.
    ///   - archiveURL: Where to write the `.xcarchive`, such as `Artifacts.url("MyApp.xcarchive")`. Defaults to `nil`: the
    ///     archive is written to a temporary directory and removed.
    ///   - includeDSYMZip: Whether to write the dSYM zip. Pass `false` to write only the IPA.
    ///   - name: The name of the step, if it is not the default.
    /// - Returns: The IPA and the dSYM zip that were written, the archive if `archiveURL` was passed, and the bundle
    ///   identifier, signing identity and team identifier of the archive. ``ExportedApp/dSYMZipURL`` is `nil` if no zip
    ///   was written.
    @discardableResult
    func archiveAndExport(
        ipaFileName: String,
        method: ExportMethod = .adhoc,
        provisioningProfile: ((_ bundleIdentifier: String) -> String)? = nil,
        outputURL: URL = Artifacts.directory,
        archiveURL keptArchiveURL: URL? = nil,
        includeDSYMZip: Bool = true,
        step name: String? = nil
    ) async throws -> ExportedApp {
        try await step(default: "Archive and export \(stepSubject)", name: name) {
            // A unique name: the dSYMs are zipped from the archive, so an archive from another call must not be reused.
            let tempDir = try TemporaryDirectory(name: "archiveAndExport_$UUID")
            defer { try? tempDir.remove() }
            let archiveURL = keptArchiveURL ?? tempDir.childURL(name: "\(ipaFileName).xcarchive")
            if keptArchiveURL != nil {
                try prepareKeptArchive(at: archiveURL)
            }
            let exportURL = tempDir.childURL(name: "export")
            let exportOptionsURL = tempDir.childURL(name: "export_options.plist")

            let archiveInfo = try await archive(to: archiveURL)

            let profileName: String
            if let provisioningProfile {
                profileName = provisioningProfile(archiveInfo.bundleIdentifier)
            } else {
                profileName = try await getBuildSettings().provisioningProfileSpecifier
            }

            try createExportOptions(
                file: exportOptionsURL,
                method: method,
                bundleIdentifier: archiveInfo.bundleIdentifier,
                provisioningProfile: profileName,
                signingCertificate: archiveInfo.signingIdentity,
                teamIdentifier: archiveInfo.teamIdentifier
            )

            try await exportArchive(from: archiveURL, to: exportURL, exportOptionsURL: exportOptionsURL)

            let ipaURL = try copyExportedIpa(from: exportURL, to: outputURL, ipaFileName: ipaFileName)

            var dSYMZipURL: URL?
            if includeDSYMZip {
                dSYMZipURL = try await writeDSYMZip(from: archiveURL, to: outputURL, ipaFileName: ipaFileName)
            }

            return ExportedApp(
                ipaURL: ipaURL,
                dSYMZipURL: dSYMZipURL,
                archiveURL: keptArchiveURL,
                bundleIdentifier: archiveInfo.bundleIdentifier,
                signingIdentity: archiveInfo.signingIdentity,
                teamIdentifier: archiveInfo.teamIdentifier
            )
        }
    }

    /// The result of ``Xcode/archiveAndExport(ipaFileName:method:provisioningProfile:outputURL:archiveURL:includeDSYMZip:step:)``.
    struct ExportedApp {
        /// The IPA in the output directory, named `<ipaFileName>.ipa`.
        public let ipaURL: URL
        /// The dSYM zip in the output directory, named `<ipaFileName>.dSYM.zip`. `nil` if `includeDSYMZip` is `false`, or
        /// if the archive has no dSYMs.
        public let dSYMZipURL: URL?
        /// The archive that was kept, the `archiveURL` that the call was given. `nil` if the archive was removed.
        public let archiveURL: URL?
        /// The bundle identifier of the archive.
        public let bundleIdentifier: String
        /// The signing identity of the archive.
        public let signingIdentity: String
        /// The team identifier of the archive.
        public let teamIdentifier: String
    }

    /// The export method of ``archiveAndExport(ipaFileName:method:provisioningProfile:outputURL:archiveURL:includeDSYMZip:step:)``. It
    /// is written to the export options as `method`.
    enum ExportMethod: String {
        /// Exports for App Store Connect. The IPA is written, not uploaded.
        case appstore = "app-store-connect"
        /// Exports for ad-hoc distribution to the devices of the provisioning profile.
        case adhoc = "ad-hoc"
        /// Exports for the devices of a development provisioning profile.
        case development
        /// Exports for in-house distribution with an enterprise account.
        case enterprise
    }
}

extension Xcode {
    /// The facts of the archive that the export needs, read from the `Info.plist` of the archive.
    struct ArchiveInfo {
        init(plist: [String: Any]) throws {
            guard
                let properties = plist["ApplicationProperties"] as? [String: Any],
                let bundleIdentifier = properties["CFBundleIdentifier"] as? String,
                let signingIdentity = properties["SigningIdentity"] as? String,
                let teamIdentifier = properties["Team"] as? String
            else {
                throw BuildError(
                    message: "Failed to read the archive information from the Info.plist of the archive. It needs ApplicationProperties "
                        + "with CFBundleIdentifier, SigningIdentity and Team. A scheme that archives a framework or a library has none."
                )
            }
            self.bundleIdentifier = bundleIdentifier
            self.signingIdentity = signingIdentity
            self.teamIdentifier = teamIdentifier
        }

        let bundleIdentifier: String
        let signingIdentity: String
        let teamIdentifier: String
    }

    /// Removes an archive of an earlier run at `url`, and creates its parent directory.
    private func prepareKeptArchive(at url: URL) throws {
        if FileManager.default.fileExists(atPath: url.filePath) {
            log("Removing existing archive \(url.filePath)")
            try FileManager.default.removeItem(at: url)
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    private func archive(to targetURL: URL) async throws -> ArchiveInfo {
        try await runXcodebuild(["archive", "-archivePath", targetURL.filePath])

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

    private func copyExportedIpa(from sourceURL: URL, to targetURL: URL, ipaFileName: String) throws -> URL {
        try FileManager.default.createDirectory(at: targetURL, withIntermediateDirectories: true)
        let exported = try FileManager.default.contentsOfDirectory(atPath: sourceURL.filePath)
        guard let sourceIpaFileName = exported.first(where: { $0.hasSuffix(".ipa") }) else {
            throw BuildError(message: "Failed to find IPA file in '\(sourceURL.filePath)'")
        }
        let copyFrom = sourceURL.appending(path: sourceIpaFileName)
        let copyTo = targetURL.appending(path: "\(ipaFileName).ipa")
        log.completion("Copying IPA File")
        log("    From: \(copyFrom.filePath)")
        log("    To:   \(copyTo.filePath)")
        // An IPA of the same name is from an earlier run into the same directory. It is replaced, as the full log is.
        if FileManager.default.fileExists(atPath: copyTo.filePath) {
            log("    Removing existing \(copyTo.filePath)")
            try FileManager.default.removeItem(at: copyTo)
        }
        try FileManager.default.copyItem(at: copyFrom, to: copyTo)
        return copyTo
    }

    /// Zips the `dSYMs` folder of the archive with `ditto`, so the zip holds the `.dSYM` bundles at its root.
    ///
    /// An archive without dSYMs, such as one built without the debug information format `DWARF with dSYM File`, logs
    /// a warning and writes no zip. An existing zip of the same name is removed then, so it does not sit next to the new IPA.
    ///
    /// Returns the URL of the zip, or `nil` if no zip was written.
    private func writeDSYMZip(from archiveURL: URL, to outputURL: URL, ipaFileName: String) async throws -> URL? {
        let dSYMsURL = archiveURL.appending(path: "dSYMs")
        let zipURL = outputURL.appending(path: "\(ipaFileName).dSYM.zip")
        // A zip of the same name is from an earlier run into the same directory. It is removed also when this archive
        // has no dSYMs, so an old zip never sits next to a new IPA it does not belong to.
        if FileManager.default.fileExists(atPath: zipURL.filePath) {
            log("Removing existing \(zipURL.filePath)")
            try FileManager.default.removeItem(at: zipURL)
        }

        let dSYMs = (try? FileManager.default.contentsOfDirectory(atPath: dSYMsURL.filePath)) ?? []
        guard !dSYMs.isEmpty else {
            log.warning("No dSYMs in '\(dSYMsURL.filePath)', so no dSYM zip is written. Build with the debug information "
                + "format 'DWARF with dSYM File' to get dSYMs.")
            return nil
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
        return zipURL
    }

    private func createExportOptions(
        file: URL,
        method: ExportMethod,
        bundleIdentifier: String,
        provisioningProfile: String,
        signingCertificate: String,
        teamIdentifier: String
    ) throws {
        var contents: [String: Any] = [
            "distributionBundleIdentifier": bundleIdentifier,
            "method": method.rawValue,
            "provisioningProfiles": [
                bundleIdentifier: provisioningProfile
            ],
            "signingCertificate": signingCertificate,
            "teamID": teamIdentifier
        ]
        if method == .appstore {
            // The IPA is written, not uploaded. Xcode does not set the version and build numbers.
            contents["destination"] = "export"
            contents["manageAppVersionAndBuildNumber"] = false
        }
        let lines = try Plist.save(to: file, contents: contents)

        log.lines(title: "Contents of generated '\(file.filePath)' file:", lines: lines)
    }
}
