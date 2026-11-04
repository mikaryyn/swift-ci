import Foundation
import SwiftCI

/// The native install of the signing assets of a fastlane match repository. The keychain is resolved before the clone.
/// The assets are decrypted from the clone, and the clone is deleted before anything is installed. No step is opened
/// here.
enum MatchNativeInstall {
    /// Installs the profile of each bundle identifier, and the certificate of each profile, from the match repository at
    /// `repositoryURL`. See ``MatchSelection/select(type:bundleIdentifiers:teamId:checkout:password:now:)`` for the rules
    /// that pick the profiles and certificates. See ``MatchInstallation/install(_:teamId:keychain:keychainPassword:profilesDirectory:)``
    /// for the install.
    static func install(
        type: MatchType,
        bundleIdentifiers: [String],
        teamId: String,
        repositoryURL: String,
        branch: String,
        basicAuthorization: Secret?,
        bearerAuthorization: Secret?,
        password: Secret,
        keychainName: String,
        keychainPassword: Secret,
        keychainsDirectory: URL = MatchInstallation.defaultKeychainsDirectory,
        profilesDirectory: URL = MatchInstallation.defaultProfilesDirectory,
        now: Date = Date()
    ) async throws -> [InstalledProfile] {
        @Use var log: Log

        let keychain = try MatchKeychainPath.resolve(name: keychainName, keychainsDirectory: keychainsDirectory)
        let matchPassword = try password.revealedValue()
        let credentials = try GitCredentialHelper.resolve(
            url: repositoryURL,
            basicAuthorization: basicAuthorization,
            bearerAuthorization: bearerAuthorization,
            inheritedEnvironment: ProcessInfo.processInfo.environment
        )

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
            keychainPassword: keychainPassword,
            profilesDirectory: profilesDirectory
        )
    }
}
