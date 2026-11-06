import Foundation
import SwiftCI

/// The keychain of a match install, found by its name or by its path.
enum MatchKeychainPath {
    /// The file of the keychain `name`. A `name` with a `/` is a path, and it is used as it is. Otherwise the keychain is
    /// `<keychainsDirectory>/<name>-db` if that file exists, or else `<keychainsDirectory>/<name>`. Throws a ``BuildError``
    /// if no such file exists.
    static func resolve(name: String, keychainsDirectory: URL) throws -> URL {
        let candidates = name.contains("/")
            ? [URL(fileURLWithPath: name)]
            : [keychainsDirectory.appending(path: "\(name)-db"), keychainsDirectory.appending(path: name)]
        if let existing = candidates.first(where: { FileManager.default.fileExists(atPath: $0.filePath) }) {
            return existing
        }
        if name.contains("/") {
            throw BuildError(message: "Keychain \(name) not found. Create it, or pass the path of an existing keychain.")
        }
        throw BuildError(
            message: "Keychain \(name) not found in \(keychainsDirectory.filePath). Create it, or pass the name of an existing keychain, such as login.keychain."
        )
    }
}

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
        try FullLog.write("Setting the key partition list of keychain \(keychain.filePath) with security set-key-partition-list. The command is sent to security -i on standard input.")
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
        "\(profile.name), \(profile.uuid), expires \(MatchSelection.isoDate(profile.expirationDate)), \(profile.certificateName)"
    }

    /// Writes the files of the certificates into a new import directory, and imports each certificate, then its key. The
    /// directory is deleted afterwards, on success and on failure.
    private static func importCertificates(_ certificates: [MatchCertificate], keychain: URL) async throws {
        try await withImportDirectory { directory in
            var files: [(certificate: URL, key: URL)] = []
            for certificate in certificates {
                let name = URL(filePath: certificate.file).deletingPathExtension().lastPathComponent
                let certificateURL = directory.appending(path: "\(name).cer")
                let keyURL = directory.appending(path: "\(name).p12")
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

    /// Runs `body` with a new directory for the import files. The directory has mode 0700, and it is deleted afterwards,
    /// also when `body` throws. After a failed `body`, its error is thrown. A failure to delete the directory after a
    /// successful `body` throws a ``BuildError`` that names the directory.
    private static func withImportDirectory(_ body: (URL) async throws -> Void) async throws {
        let directory = try TemporaryDirectory(name: "match-import-$UUID")
        do {
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.url.filePath)
            try await body(directory.url)
        } catch {
            // The error that ends the step is the one to report, so a failed removal does not replace it.
            try? FileManager.default.removeItem(at: directory.url)
            throw error
        }
        do {
            try FileManager.default.removeItem(at: directory.url)
        } catch {
            throw BuildError(
                message: "Couldn't remove the temporary directory \(directory.url.filePath), which holds decrypted keys of the match repository. Remove it by hand."
            )
        }
    }

    /// Writes `data` to `url` with mode 0600. The file is created with that mode, so it is never readable by others.
    private static func writeOwnerOnly(_ data: Data, to url: URL) throws {
        guard FileManager.default.createFile(atPath: url.filePath, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw BuildError(message: "Couldn't write \(url.lastPathComponent) to the temporary import directory.")
        }
    }

    /// Writes each profile as `<UUID>.mobileprovision` into `profilesDirectory`, replacing a file with the same UUID.
    /// Other files of the directory are not touched. Returns the profiles in the order of the selection.
    private static func writeProfiles(_ assets: MatchAssets, teamId: String, profilesDirectory: URL) throws -> [InstalledProfile] {
        try FileManager.default.createDirectory(at: profilesDirectory, withIntermediateDirectories: true)
        return try assets.profiles.map { profile in
            let uuid = profile.profile.uuid
            guard !uuid.isEmpty, !uuid.contains("/") else {
                throw BuildError(message: "The provisioning profile \(profile.file) has a UUID that can't be used as a file name.")
            }
            guard let certificate = assets.certificates.first(where: { $0.file == profile.certificateFile }) else {
                throw BuildError(message: "The certificate \(profile.certificateFile) of \(profile.bundleIdentifier) is not in the selection.")
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
                message: "The signing identity \(certificate.info.commonName) (\(certificate.info.sha1)) was imported into \(keychain.filePath), but codesign can't use it. Check that the keychain is unlocked and in the search list (security list-keychains -d user), and that Apple's intermediate certificates are installed."
            )
        }
    }
}

extension MatchInstallation {
    /// The message `security import` prints when the item is already in the keychain. Re-running an install is
    /// expected, so this is success. The line is hidden on the console, and it stays in the full log.
    static let duplicateItemMessage = "The specified item already exists in the keychain."

    /// Imports `item` into the keychain. Exit code 1 with the duplicate-item message is success, without a warning.
    /// Any other non-zero exit code throws a ``BuildError`` that names the file and the keychain and shows the stderr of
    /// `security`. A program that cannot be started also throws.
    static func runImport(item: URL, keychainURL: URL, itemPassword: String) async throws {
        let args = ["import", item.filePath, "-k", keychainURL.filePath, "-P", itemPassword,
                    "-T", "/usr/bin/codesign", "-T", "/usr/bin/security", "-T", "/usr/bin/productbuild", "-T", "/usr/bin/productsign"]
        let tool = Tool(command: "/usr/bin/security", arguments: args, filters: [filter(duplicateItemMessage)])
        let result = try await tool.result()
        guard result.exitCode != 0 else { return }

        let isDuplicate = result.exitCode == 1
            && result.stderr.components(separatedBy: "\n").contains { $0.hasSuffix(duplicateItemMessage) }
        if isDuplicate {
            return
        }
        let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        var message = "security couldn't import \(item.lastPathComponent) into \(keychainURL.filePath) (exit code \(result.exitCode))."
        if !detail.isEmpty {
            message += " \(detail)"
        }
        throw BuildError(message: message)
    }

    /// Runs a tool whose failure the install tolerates. A non-zero exit code is logged as a warning that names the tool
    /// and the code, and the caller continues. Other failures, such as a program that cannot be started, still throw.
    static func runTolerated(_ tool: Tool, what: String) async throws {
        @Use var log: Log

        let result = try await tool.result()
        if result.exitCode != 0 {
            log.warning("\(tool.displayName) exited with code \(result.exitCode) while \(what). The install continues.")
        }
    }

    /// The `set-key-partition-list` call of the install, as a `security -i` tool. The password is revealed here and sent
    /// on standard input only. Tests build the tool and check it without running it.
    static func partitionListTool(keychainURL: URL, password: Secret) throws -> Tool {
        try SecurityInteractive.tool(for: [
            SecurityArgument(kind: "command", value: "set-key-partition-list"),
            SecurityArgument(kind: "option", value: "-S"),
            SecurityArgument(kind: "option", value: "apple-tool:,apple:,codesign:"),
            SecurityArgument(kind: "option", value: "-s"),
            SecurityArgument(kind: "option", value: "-k"),
            SecurityArgument(kind: "keychain password", value: try password.revealedValue()),
            SecurityArgument(kind: "keychain path", value: keychainURL.filePath),
        ])
    }
}
