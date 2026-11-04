import Foundation
import SwiftCI

/// A certificate of the repository with its key, decrypted.
struct MatchCertificate: Equatable, Sendable {
    /// The path of the `.cer` relative to the repository, such as `certs/distribution/ABC123.cer`.
    var file: String
    /// The DER certificate.
    var certificateData: Data
    /// The decrypted `.p12`: a PEM key or a PKCS#12.
    var privateKeyData: Data
    var info: CertificateInfo
}

/// A profile for one bundle identifier, decrypted.
struct MatchProfile: Equatable, Sendable {
    var bundleIdentifier: String
    /// The path of the profile relative to the repository, such as `profiles/adhoc/AdHoc_com.example.app.mobileprovision`.
    var file: String
    /// The decrypted CMS data of the profile, as it is written to the Xcode profiles folder.
    var data: Data
    var profile: ProvisioningProfile
    /// The `file` of the ``MatchCertificate`` that the profile was made for.
    var certificateFile: String
}

/// The signing assets that a selection reads from a match repository.
struct MatchAssets: Equatable, Sendable {
    /// Each certificate once, in the order of first use.
    var certificates: [MatchCertificate]
    /// One profile for each bundle identifier, in the order of the identifiers.
    var profiles: [MatchProfile]
}

/// Selection of the signing assets of a fastlane match repository. It reads files only. The checkout is made by
/// ``withCheckout(branch:credentials:_:)``.
enum MatchSelection {
    /// Selects and decrypts, from a checkout of a match repository, the profile of each bundle identifier and the
    /// certificate each profile was made for. Only the needed files are decrypted. Reads files only.
    ///
    /// The profile of an identifier is `profiles/<type>/<Name>_<identifier>.mobileprovision`. Its team must contain
    /// `teamId`, and it must not have expired at `now`. Its certificate is the first `.cer` of `certs/<folder>/` by name
    /// whose DER equals one of the profile's `DeveloperCertificates`. That certificate must not have expired at `now`,
    /// and its `.p12` must be next to it.
    ///
    /// Duplicate identifiers are read once, in the order of their first appearance.
    ///
    /// Throws a ``BuildError`` at the first problem. Each message names the bundle identifier or the file, and never the
    /// password. A wrong password fails as ``MatchDecryption`` reports it.
    static func select(
        type: MatchType,
        bundleIdentifiers: [String],
        teamId: String,
        checkout: URL,
        password: String,
        now: Date = Date()
    ) throws -> MatchAssets {
        let identifiers = try uniqueBundleIdentifiers(bundleIdentifiers)
        var selection = Selection(type: type, teamId: teamId, checkout: checkout, password: password, now: now)
        var profiles: [MatchProfile] = []
        for identifier in identifiers {
            profiles.append(try selection.profile(for: identifier))
        }
        return MatchAssets(certificates: selection.certificates, profiles: profiles)
    }

    /// Clones the repository once, shallow, into a new temporary directory with mode 0700, runs `body` with the
    /// checkout's URL, and deletes the directory afterwards, also when `body` or the clone throws.
    ///
    /// The clone uses `credentials`: its URL has no user information, and its header is in its environment. A failed clone
    /// throws, and `body` does not run. A failure to delete the directory after a successful `body` throws a
    /// ``BuildError`` that names the directory. After a failed `body`, the error of `body` is thrown.
    static func withCheckout<T>(
        branch: String,
        credentials: GitCredentials,
        _ body: (URL) async throws -> T
    ) async throws -> T {
        let directory = try TemporaryDirectory(name: "match-$UUID")
        let checkout = directory.childURL(name: "repository")
        let value: T
        do {
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.url.filePath)
            try await Tool(
                command: "/usr/bin/git",
                arguments: ["clone", "--depth", "1", "--branch", branch, credentials.url, checkout.filePath],
                environment: credentials.environment
            ).run()
            value = try await body(checkout)
        } catch {
            // The error that ends the step is the one to report, so a failed removal does not replace it.
            try? FileManager.default.removeItem(at: directory.url)
            throw error
        }
        do {
            try FileManager.default.removeItem(at: directory.url)
        } catch {
            throw BuildError(
                message: "Couldn't remove the temporary directory \(directory.url.filePath), which holds the match repository. Remove it by hand."
            )
        }
        return value
    }

    /// The identifiers without repeats, in the order of their first appearance. Throws a usage error if there are none.
    private static func uniqueBundleIdentifiers(_ identifiers: [String]) throws -> [String] {
        guard !identifiers.isEmpty else {
            throw BuildError(
                message: "Pass at least one bundle identifier. Its provisioning profile is read from the match repository.",
                code: .usage
            )
        }
        var seen = Set<String>()
        return identifiers.filter { seen.insert($0).inserted }
    }

    /// The date as ISO 8601 in UTC, without the time.
    static func isoDate(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        formatter.timeZone = TimeZone(identifier: "UTC") ?? .current
        return formatter.string(from: date)
    }
}

/// The state of one selection. Each file is decrypted once, and each certificate is added once.
private struct Selection {
    let type: MatchType
    let teamId: String
    let checkout: URL
    let password: String
    let now: Date
    /// The certificates in the order of first use.
    private(set) var certificates: [MatchCertificate] = []
    /// The decrypted data of each file that was read, by its path relative to the repository.
    private var decrypted: [String: Data] = [:]

    init(type: MatchType, teamId: String, checkout: URL, password: String, now: Date) {
        self.type = type
        self.teamId = teamId
        self.checkout = checkout
        self.password = password
        self.now = now
    }

    /// The profile of `identifier`, with the certificate it was made for.
    mutating func profile(for identifier: String) throws -> MatchProfile {
        let profileFile = "profiles/\(type.rawValue)/\(type.profileTypeName)_\(identifier).mobileprovision"
        guard FileManager.default.fileExists(atPath: checkout.appending(path: profileFile).filePath) else {
            throw BuildError(
                message: "No \(type.rawValue) provisioning profile for \(identifier) in the match repository: "
                    + "\(profileFile) is missing. Run fastlane match for this identifier (not read-only) to create it."
            )
        }
        let data = try decrypt(profileFile)
        let profile = try ProvisioningProfile(data: data, file: profileFile)
        guard profile.teamIdentifiers.contains(teamId) else {
            throw BuildError(
                message: "The provisioning profile \"\(profile.name)\" (\(profileFile)) is for the team "
                    + "\(profile.teamIdentifiers.joined(separator: ", ")), not for \(teamId). "
                    + "Check the team ID of the app, and the team of the match repository."
            )
        }
        guard profile.expirationDate > now else {
            throw BuildError(
                message: "The provisioning profile \"\(profile.name)\" (\(profileFile)) expired on "
                    + "\(MatchSelection.isoDate(profile.expirationDate)). "
                    + "Renew it with fastlane match for \(identifier) (not read-only), then run this again."
            )
        }
        let certificate = try certificate(for: profile, bundleIdentifier: identifier, profileFile: profileFile)
        return MatchProfile(
            bundleIdentifier: identifier,
            file: profileFile,
            data: data,
            profile: profile,
            certificateFile: certificate.file
        )
    }

    /// The first certificate of the profile's folder, by name, whose DER is one of the profile's certificates. Each
    /// candidate is decrypted in name order until one matches.
    private mutating func certificate(
        for profile: ProvisioningProfile,
        bundleIdentifier: String,
        profileFile: String
    ) throws -> MatchCertificate {
        let folder = "certs/\(type.certificatesFolder)"
        for file in try cerFiles(in: folder) {
            let der = try decrypt(file)
            guard profile.developerCertificates.contains(der) else { continue }
            if let chosen = certificates.first(where: { $0.file == file }) {
                return chosen
            }
            let chosen = try repositoryCertificate(file: file, der: der)
            certificates.append(chosen)
            return chosen
        }
        throw BuildError(
            message: "None of the certificates in \(folder)/ is the one that the provisioning profile "
                + "\"\(profile.name)\" (\(profileFile)) was made for. Check that the match repository has that certificate, "
                + "or run fastlane match for \(bundleIdentifier) (not read-only) to create a profile with a certificate "
                + "of the repository."
        )
    }

    /// The certificate `file`, with its key, after its expiry and the presence of its `.p12` are checked.
    private mutating func repositoryCertificate(file: String, der: Data) throws -> MatchCertificate {
        let info = try CertificateInfo(der: der, file: file)
        guard info.expirationDate > now else {
            throw BuildError(
                message: "The certificate \(file) (\(info.commonName)) expired on \(MatchSelection.isoDate(info.expirationDate)). Renew it with fastlane match (not read-only), then run this again."
            )
        }
        // The extension is replaced, and the path stays relative to the repository.
        let keyFile = (file as NSString).deletingPathExtension + ".p12"
        guard FileManager.default.fileExists(atPath: checkout.appending(path: keyFile).filePath) else {
            throw BuildError(
                message: "The private key of the certificate \(file) is missing: \(keyFile) is not in the match repository. "
                    + "Run fastlane match (not read-only) to create the certificate and its key again."
            )
        }
        return MatchCertificate(
            file: file,
            certificateData: der,
            privateKeyData: try decrypt(keyFile),
            info: info
        )
    }

    /// The `.cer` files of `folder`, by name. A folder that does not exist has none.
    private func cerFiles(in folder: String) throws -> [String] {
        let url = checkout.appending(path: folder)
        guard FileManager.default.fileExists(atPath: url.filePath) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: url.filePath)
            .filter { URL(filePath: $0).pathExtension.lowercased() == "cer" }
            .sorted()
            .map { "\(folder)/\($0)" }
    }

    /// The decrypted data of `file`, a path relative to the repository. It is decrypted once.
    private mutating func decrypt(_ file: String) throws -> Data {
        if let data = decrypted[file] {
            return data
        }
        let encrypted = try Data(contentsOf: checkout.appending(path: file))
        let data = try MatchDecryption.decrypt(encrypted, file: file, password: password).data
        decrypted[file] = data
        return data
    }
}

/// The folders and names of a match type in the repository.
private extension MatchType {
    /// The folder of the certificates, under `certs/`.
    var certificatesFolder: String {
        switch self {
        case .appstore, .adhoc: return "distribution"
        case .enterprise: return "enterprise"
        case .development: return "development"
        }
    }

    /// The name of the type in the file name of a profile, such as `AdHoc` in `AdHoc_com.example.app.mobileprovision`.
    var profileTypeName: String {
        switch self {
        case .appstore: return "AppStore"
        case .adhoc: return "AdHoc"
        case .enterprise: return "InHouse"
        case .development: return "Development"
        }
    }
}
