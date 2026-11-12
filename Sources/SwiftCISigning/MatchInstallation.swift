import Foundation
import SwiftCI

/// Installs the signing assets of a selection: the certificates and keys into a keychain, and the profiles into the
/// Xcode profiles folder. The install checks that codesign can use each certificate.
enum MatchInstallation {
    /// `~/Library/Developer/Xcode/UserData/Provisioning Profiles`, where Xcode 16 and later read profiles.
    static var defaultProfilesDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(
            path: "Library/Developer/Xcode/UserData/Provisioning Profiles", directoryHint: .isDirectory
        )
    }

    /// `~/Library/Keychains`, where the keychains of the user are.
    static var defaultKeychainsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Keychains", directoryHint: .isDirectory)
    }

    /// Imports the certificates and keys of `assets` into `keychain`, sets the key partition list once, writes the
    /// profiles, checks that codesign can use every certificate, and logs one line per profile.
    ///
    /// `partitionTool` is the `set-key-partition-list` call from ``partitionListTool(keychainURL:password:)``. The caller
    /// builds it before any process runs, so an invalid keychain password stops the install before the clone.
    ///
    /// The keychain password is sent to `security -i` on standard input only. Throws a ``BuildError`` at the first failed
    /// import or check. A failed partition list is a warning, and the check decides.
    static func install(
        _ assets: MatchAssets,
        teamId: String,
        keychain: URL,
        partitionTool: Tool,
        profilesDirectory: URL
    ) async throws -> [InstalledProfile] {
        @Use var log: Log

        try await importCertificates(assets.certificates, keychain: keychain)
        // The full log header of the partition list shows only `security -i`, so this line names the operation.
        try FullLog.write(
            "Setting the key partition list of keychain \(keychain.filePath) with security set-key-partition-list. "
                + "The command is sent to security -i on standard input."
        )
        try await runTolerated(partitionTool, what: "setting the key partition list")
        let installed = try writeProfiles(assets, teamId: teamId, profilesDirectory: profilesDirectory)
        try await checkIdentities(assets.certificates, keychain: keychain)
        for profile in installed {
            log(profileLine(profile))
        }
        return installed
    }

    /// The line that logs an installed profile: its name, UUID, expiry date and certificate.
    static func profileLine(_ profile: InstalledProfile) -> String {
        let expiry = MatchSelection.isoDate(profile.expirationDate)
        return "\(profile.name), \(profile.uuid), expires \(expiry), \(profile.certificateName)"
    }

    /// Writes the files of the certificates into a new import directory, and imports each certificate, then its key. The
    /// directory is deleted afterwards, on success and on failure.
    private static func importCertificates(_ certificates: [MatchCertificate], keychain: URL) async throws {
        try await TemporaryDirectory.withDirectory(
            name: "match-import-$UUID",
            holding: "decrypted keys of the match repository"
        ) { directory in
            var files: [(certificate: URL, key: URL)] = []
            for certificate in certificates {
                let name = URL(filePath: certificate.file).deletingPathExtension().lastPathComponent
                let certificateURL = directory.childURL(name: "\(name).cer")
                let keyURL = directory.childURL(name: "\(name).p12")
                try writeOwnerOnly(certificate.certificateData, to: certificateURL)
                try writeOwnerOnly(certificate.privateKeyData, to: keyURL)
                files.append((certificateURL, keyURL))
            }
            for file in files {
                try await runImport(item: file.certificate, keychainURL: keychain, itemPassword: "")
                try await runImport(item: file.key, keychainURL: keychain, itemPassword: "")
            }
        }
    }

    /// Writes `data` to `url` with mode 0600. The file is created with that mode, so it is never readable by others.
    private static func writeOwnerOnly(_ data: Data, to url: URL) throws {
        let created = FileManager.default.createFile(
            atPath: url.filePath, contents: data, attributes: [.posixPermissions: 0o600]
        )
        guard created else {
            throw BuildError(message: "Couldn't write \(url.lastPathComponent) to the temporary import directory.")
        }
    }

    /// Writes each profile as `<UUID>.mobileprovision` into `profilesDirectory`, replacing a file with the same UUID.
    /// Other files of the directory are not touched. Returns the profiles in the order of the selection.
    private static func writeProfiles(
        _ assets: MatchAssets,
        teamId: String,
        profilesDirectory: URL
    ) throws -> [InstalledProfile] {
        try FileManager.default.createDirectory(at: profilesDirectory, withIntermediateDirectories: true)
        return try assets.profiles.map { profile in
            let uuid = profile.profile.uuid
            guard !uuid.isEmpty, !uuid.contains("/") else {
                throw BuildError(
                    message: "The provisioning profile \(profile.file) has a UUID that can't be used as a file name."
                )
            }
            guard let certificate = assets.certificates.first(where: { $0.file == profile.certificateFile }) else {
                throw BuildError(
                    message: "The certificate \(profile.certificateFile) of \(profile.bundleIdentifier) is not in "
                        + "the selection."
                )
            }
            let url = profilesDirectory.appending(path: "\(uuid).mobileprovision")
            try profile.data.write(to: url, options: .atomic)
            return InstalledProfile(
                bundleIdentifier: profile.bundleIdentifier,
                name: profile.profile.name,
                uuid: uuid,
                teamIdentifier: teamId,
                certificateName: certificate.info.commonName,
                expirationDate: profile.profile.expirationDate,
                url: url
            )
        }
    }

    /// Checks that codesign can use each certificate: `security find-identity -v -p codesigning`, which is run with the
    /// user's search list, lists the SHA-1 of each. Throws for the first certificate that is not listed.
    private static func checkIdentities(_ certificates: [MatchCertificate], keychain: URL) async throws {
        let identities = try await Tool(
            command: "/usr/bin/security",
            arguments: ["find-identity", "-v", "-p", "codesigning"],
            filters: [filter(#/./#)]
        ).output().lowercased()
        for certificate in certificates where !identities.contains(certificate.info.sha1.lowercased()) {
            throw BuildError(
                message: "The signing identity \(certificate.info.commonName) (\(certificate.info.sha1)) was imported "
                    + "into \(keychain.filePath), but codesign can't use it. Check that the keychain is unlocked and in "
                    + "the search list (security list-keychains -d user), and that Apple's intermediate certificates "
                    + "are installed."
            )
        }
    }

    /// The message `security import` prints when the item is already in the keychain. Re-running an install is
    /// expected, so this is success. The line is hidden on the console, and it stays in the full log.
    static let duplicateItemMessage = "The specified item already exists in the keychain."

    /// Imports `item` into the keychain. Exit code 1 with the duplicate-item message is success, without a warning.
    /// Any other non-zero exit code throws a ``BuildError`` that names the file and the keychain and shows the stderr of
    /// `security`. A program that cannot be started also throws.
    static func runImport(item: URL, keychainURL: URL, itemPassword: String) async throws {
        let trusted = ["codesign", "security", "productbuild", "productsign"].flatMap { ["-T", "/usr/bin/\($0)"] }
        let args = ["import", item.filePath, "-k", keychainURL.filePath, "-P", itemPassword] + trusted
        let tool = Tool(command: "/usr/bin/security", arguments: args, filters: [filter(duplicateItemMessage)])
        let result = try await tool.result()
        guard result.exitCode != 0 else { return }

        let isDuplicate = result.exitCode == 1
            && result.stderr.components(separatedBy: "\n").contains { $0.hasSuffix(duplicateItemMessage) }
        if isDuplicate {
            return
        }
        let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        var message = "security couldn't import \(item.lastPathComponent) into \(keychainURL.filePath) "
            + "(exit code \(result.exitCode))."
        if !detail.isEmpty {
            message += " \(detail)"
        }
        throw BuildError(message: message)
    }

    /// Runs a tool whose failure the install tolerates. A non-zero exit code is logged as a warning that names the tool
    /// and the code, then the last lines of stderr, because the console filter of the tool may hide them. The caller
    /// continues. Other failures, such as a program that cannot be started, still throw.
    static func runTolerated(_ tool: Tool, what: String) async throws {
        @Use var log: Log

        let result = try await tool.result()
        if result.exitCode != 0 {
            var message = "\(tool.displayName) exited with code \(result.exitCode) while \(what). The install continues."
            let stderr = result.stderr.trimmingCharacters(in: .newlines)
            if !stderr.isEmpty {
                message += "\n" + stderr.components(separatedBy: "\n").suffix(10).joined(separator: "\n")
            }
            log.warning(message)
        }
    }

    /// The `set-key-partition-list` call of the install, as a `security -i` tool. The password is revealed here and sent
    /// on standard input only. The console hides all of its output: on success `security` prints a dump of the key
    /// attributes, whose format varies, and a failure's reason reaches the console through the warning of
    /// ``runTolerated(_:what:)``. The full log keeps the output. Tests build the tool and check it without running it.
    static func partitionListTool(keychainURL: URL, password: Secret) throws -> Tool {
        try SecurityInteractive.tool(for: [
            SecurityArgument(kind: "command", value: "set-key-partition-list"),
            SecurityArgument(kind: "option", value: "-S"),
            SecurityArgument(kind: "option", value: "apple-tool:,apple:,codesign:"),
            SecurityArgument(kind: "option", value: "-s"),
            SecurityArgument(kind: "option", value: "-k"),
            SecurityArgument(kind: "keychain password", value: try password.revealedValue()),
            SecurityArgument(kind: "keychain path", value: keychainURL.filePath),
        ], filters: [hideAllLines])
    }
}
