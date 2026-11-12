import Foundation
import SwiftCI

/// The fastlane install of the signing assets: `fastlane match --readonly`, run once, and then the profiles that it
/// installed are read back from the Xcode profiles folder. The caller resolves the keychain and the Git credentials
/// before any process runs. No step is opened here.
enum MatchFastlaneInstall {
    /// Logs the implementation and the fastlane version, runs fastlane match, and returns the profile of each bundle
    /// identifier that it installed. See ``installedProfiles(type:bundleIdentifiers:teamId:profilesDirectory:)``.
    static func install(
        type: MatchType,
        bundleIdentifiers: [String],
        teamId: String,
        branch: String,
        credentials: GitCredentials,
        password: Secret,
        keychainName: String,
        keychainPassword: Secret,
        invocation: FastlaneInvocation,
        environment: [String: ToolEnvironmentValue],
        verbose: Bool,
        profilesDirectory: URL
    ) async throws -> [InstalledProfile] {
        @Use var log: Log

        let version = await fastlaneVersion(invocation: invocation, environment: environment)
        log("Implementation: \(version.map { "fastlane \($0)" } ?? "fastlane") (\(invocation.commandName))")

        // The secrets are set after the caller's variables, so they win. The header of the credentials is a secret too.
        var matchEnvironment = environment
        matchEnvironment["MATCH_PASSWORD"] = .secret(password)
        matchEnvironment["MATCH_KEYCHAIN_PASSWORD"] = .secret(keychainPassword)
        matchEnvironment.merge(credentials.environment) { _, new in new }
        let arguments = ["match", type.rawValue, "--readonly"] + (verbose ? ["--verbose"] : [])
            + [
                "--app_identifier", bundleIdentifiers.joined(separator: ","),
                "--team_id", teamId,
                "--git_url", credentials.url,
                "--git_branch", branch,
                "--keychain_name", keychainName,
            ]
        try await Fastlane.fastlaneTool(
            invocation: invocation,
            arguments: arguments,
            environment: matchEnvironment,
            console: Fastlane.consoleFilter()
        ).run()

        let profiles = try installedProfiles(
            type: type,
            bundleIdentifiers: bundleIdentifiers,
            teamId: teamId,
            profilesDirectory: profilesDirectory
        )
        for profile in profiles {
            log(MatchInstallation.profileLine(profile))
        }
        return profiles
    }

    /// The version of fastlane that `invocation` runs, or `nil` if it can't be read. The run is quiet on the console:
    /// its output goes to the full log only. A fastlane that cannot start is not an error here, because the match call
    /// that follows fails with the same problem.
    private static func fastlaneVersion(
        invocation: FastlaneInvocation,
        environment: [String: ToolEnvironmentValue]
    ) async -> String? {
        @Use var log: Log

        let tool = Fastlane.fastlaneTool(
            invocation: invocation,
            arguments: ["--version"],
            environment: environment,
            console: hideAllLines
        )
        let reason: String
        do {
            let result = try await tool.result()
            if result.exitCode != 0 {
                reason = "fastlane --version exited with code \(result.exitCode)"
            } else if let match = (result.stdout + "\n" + result.stderr).firstMatch(of: #/fastlane (\d+\.\d+\.\d+)/#) {
                return String(match.1)
            } else {
                reason = "its output names no version"
            }
        } catch {
            reason = "fastlane --version could not start. Details: \(error)"
        }
        log.warning(
            "Couldn't read the fastlane version (\(reason)). The install continues. If fastlane can't run, the match call fails."
        )
        return nil
    }

    /// The newest profile of each bundle identifier in `profilesDirectory`. A profile is named as fastlane names it,
    /// `match <Type> <identifier>`, and its team must be `teamId`. Of the candidates, the newest is taken: the latest
    /// creation date, and on a tie the latest expiry date. Files that cannot be decoded are skipped, and their number is
    /// given in the error when a profile is missing.
    ///
    /// Throws a ``BuildError`` that names the identifier, the expected name and the folder when a profile is missing.
    static func installedProfiles(
        type: MatchType,
        bundleIdentifiers: [String],
        teamId: String,
        profilesDirectory: URL
    ) throws -> [InstalledProfile] {
        var profiles: [(url: URL, profile: ProvisioningProfile)] = []
        var unreadable = 0
        for url in try mobileprovisionFiles(in: profilesDirectory) {
            if let data = try? Data(contentsOf: url),
               let profile = try? ProvisioningProfile(data: data, file: url.lastPathComponent) {
                profiles.append((url, profile))
            } else {
                unreadable += 1
            }
        }

        return try bundleIdentifiers.map { identifier in
            let name = type.profileName(for: identifier)
            let candidates = profiles.filter { $0.profile.name == name && $0.profile.teamIdentifiers.contains(teamId) }
            guard let newest = candidates.max(by: { isOlder($0.profile, $1.profile) }) else {
                var message = "fastlane match finished, but the provisioning profile for \(identifier) named \"\(name)\" "
                    + "for team \(teamId) isn't in \(profilesDirectory.filePath). A custom profile_name isn't supported, "
                    + "so the profile must have fastlane's default name."
                if unreadable > 0 {
                    message += " \(unreadable) profile file(s) in that folder couldn't be read."
                }
                throw BuildError(message: message)
            }
            return try installedProfile(newest.profile, url: newest.url, bundleIdentifier: identifier, teamId: teamId)
        }
    }

    /// Whether `a` is older than `b`: an earlier creation date, or on a tie an earlier expiry date. A profile without a
    /// creation date is older than any other.
    static func isOlder(_ a: ProvisioningProfile, _ b: ProvisioningProfile) -> Bool {
        switch (a.creationDate, b.creationDate) {
        case (nil, nil):
            break
        case (nil, _):
            return true
        case (_, nil):
            return false
        case let (created?, other?):
            if created != other {
                return created < other
            }
        }
        return a.expirationDate < b.expirationDate
    }

    /// The `InstalledProfile` of a profile that fastlane wrote. Its certificate is the first one in the profile.
    private static func installedProfile(
        _ profile: ProvisioningProfile,
        url: URL,
        bundleIdentifier: String,
        teamId: String
    ) throws -> InstalledProfile {
        guard let der = profile.developerCertificates.first else {
            throw BuildError(
                message: "The provisioning profile \(url.lastPathComponent) has no certificate. Run fastlane match again."
            )
        }
        let certificate = try CertificateInfo(der: der, file: url.lastPathComponent)
        return InstalledProfile(
            bundleIdentifier: bundleIdentifier,
            name: profile.name,
            uuid: profile.uuid,
            teamIdentifier: teamId,
            certificateName: certificate.commonName,
            expirationDate: profile.expirationDate,
            url: url
        )
    }

    /// The `.mobileprovision` files of `directory`, by name, as URLs inside `directory`. A directory that does not exist has none.
    private static func mobileprovisionFiles(in directory: URL) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: directory.filePath) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: directory.filePath)
            .filter { URL(filePath: $0).pathExtension.lowercased() == "mobileprovision" }
            .sorted()
            .map { directory.appending(path: $0) }
    }
}

/// The name of the fastlane command, as the implementation line shows it.
private extension FastlaneInvocation {
    var commandName: String {
        switch self {
        case .direct:
            return "fastlane"
        case .bundler:
            return "bundle exec fastlane"
        }
    }
}
