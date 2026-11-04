import Foundation
import SwiftCI

/// The native install of the signing assets of a fastlane match repository. The caller resolves the keychain and the Git
/// credentials, and builds the partition list, before any process runs. The assets are decrypted from a clone, and the
/// clone is deleted before anything is installed. No step is opened here.
enum MatchNativeInstall {
    /// Installs the profile of each bundle identifier, and the certificate of each profile, from the match repository
    /// cloned with `credentials` at `branch`. See ``MatchSelection/select(type:bundleIdentifiers:teamId:checkout:password:now:)``
    /// for the rules that pick the profiles and certificates. See ``MatchInstallation/install(_:teamId:keychain:partitionTool:profilesDirectory:)``
    /// for the install.
    static func install(
        type: MatchType,
        bundleIdentifiers: [String],
        teamId: String,
        branch: String,
        credentials: GitCredentials,
        password: Secret,
        keychain: URL,
        partitionTool: Tool,
        profilesDirectory: URL,
        now: Date
    ) async throws -> [InstalledProfile] {
        @Use var log: Log

        let matchPassword = try password.revealedValue()
        log("Cloning \(credentials.url) (\(branch))")
        let assets = try await MatchSelection.withCheckout(branch: branch, credentials: credentials) { checkout in
            try MatchSelection.select(
                type: type,
                bundleIdentifiers: bundleIdentifiers,
                teamId: teamId,
                checkout: checkout,
                password: matchPassword,
                now: now
            )
        }
        log("Selected \(assets.profiles.count) profiles, \(assets.certificates.count) certificates")

        return try await MatchInstallation.install(
            assets,
            teamId: teamId,
            keychain: keychain,
            partitionTool: partitionTool,
            profilesDirectory: profilesDirectory
        )
    }
}
