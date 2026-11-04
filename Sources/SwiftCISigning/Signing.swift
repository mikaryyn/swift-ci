import Foundation
import SwiftCI

/// A fastlane match Git repository.
public struct MatchRepository: Sendable {
    /// The URL of the repository, such as `git@git.example.com:ios/certificates.git` or `https://git.example.com/certificates.git`.
    /// The user information of an http or https URL is taken as the credentials, and it is never passed as an argument.
    public var url: String
    /// The branch to clone. The default is `master`.
    public var branch: String
    /// The base64 of `user:token`, sent as `Authorization: Basic …` to an http or https repository.
    public var basicAuthorization: Secret?
    /// The token, sent as `Authorization: Bearer …` to an http or https repository.
    public var bearerAuthorization: Secret?

    /// Creates a repository. Give at most one source of credentials: the user information of `url`, `basicAuthorization`
    /// or `bearerAuthorization`.
    public init(url: String, branch: String = "master", basicAuthorization: Secret? = nil, bearerAuthorization: Secret? = nil) {
        self.url = url
        self.branch = branch
        self.basicAuthorization = basicAuthorization
        self.bearerAuthorization = bearerAuthorization
    }
}

/// The keychain that receives the certificates and keys.
public enum MatchKeychain: Sendable {
    /// An existing keychain, which the caller unlocks, for example with ``Keychain/unlock(name:password:step:)``.
    ///
    /// `name` is a keychain in `~/Library/Keychains`, or a path. A name resolves to `<name>-db` first, then to `<name>`.
    /// `password` is the keychain password. It is used for the key partition list, so that codesign can use the imported
    /// key without a prompt. It is sent to `security` on standard input only.
    case existing(name: String, password: Secret)
}

/// The implementation that installs the signing assets. The caller chooses one. SwiftCI never falls back to the other.
public enum MatchImplementation: Sendable {
    /// The Swift implementation. It clones the repository, decrypts the files it needs, imports the certificates and
    /// keys, writes the profiles to the Xcode 16+ profiles folder, and checks that codesign can use each certificate.
    case native
    /// fastlane match in readonly mode, run once, and then the profiles that it installed are read back.
    ///
    /// The non-secret values are passed as arguments, which override a `Matchfile` in the project. The secrets go in the
    /// environment: `MATCH_PASSWORD`, and `MATCH_KEYCHAIN_PASSWORD` for the keychain. A `Matchfile` that sets
    /// `keychain_password` takes precedence over `MATCH_KEYCHAIN_PASSWORD`, so the project should not set it there, or
    /// should set the same value. The profiles are found only under fastlane's default names, `match <Type> <identifier>`.
    /// A custom `profile_name` is not supported.
    ///
    /// - Parameters:
    ///   - invocation: How fastlane is started. See ``FastlaneInvocation``.
    ///   - environment: Variables for the tool. The match password and the keychain password are set after these, so
    ///     they win over the same names here.
    ///   - verbose: Passes `--verbose`, so fastlane logs in detail. The full log keeps that output.
    case fastlane(invocation: FastlaneInvocation = .direct, environment: [String: ToolEnvironmentValue] = [:], verbose: Bool = false)
}

/// One profile that an install wrote into the Xcode profiles folder.
public struct InstalledProfile: Equatable, Sendable {
    /// The bundle identifier that the profile was installed for.
    public var bundleIdentifier: String
    /// The name of the profile, such as `match AdHoc com.example.myapp`.
    public var name: String
    /// The UUID of the profile. The file is named by it.
    public var uuid: String
    /// The team ID that was asked for. It is also in the profile's `TeamIdentifier`.
    public var teamIdentifier: String
    /// The common name of the profile's certificate.
    public var certificateName: String
    /// When the profile expires.
    public var expirationDate: Date
    /// Where the profile was written.
    public var url: URL
}

/// Signing assets for the apps of a fastlane match repository.
public enum Signing {
    /// Installs the signing assets of `type` for each bundle identifier. The certificate and key of each profile go into
    /// the keychain, and the profile goes into the Xcode profiles folder.
    ///
    /// The keychain must exist and be unlocked before this call, for example with ``Keychain/unlock(name:password:step:)``.
    /// `password` decrypts the files of the repository. The Git credentials of `repository` are sent to git, never as
    /// arguments. No password or credential appears in the console, the full log or an error.
    ///
    /// Each identifier gets one profile, in the order of the identifiers without repeats. With ``MatchImplementation/native``,
    /// the profile must be for `teamId`, and it must not have expired. With ``MatchImplementation/fastlane(invocation:environment:verbose:)``,
    /// fastlane decides which profile it writes, and the newest one of the team with the default name is read back.
    ///
    /// - Parameters:
    ///   - type: The distribution type. It selects the folders in the repository, and the names of the profiles.
    ///   - bundleIdentifiers: The apps to install the profiles of. Must not be empty.
    ///   - teamId: The Apple Developer Team ID.
    ///   - repository: The match repository and its credentials. See ``MatchRepository``.
    ///   - password: The password of the match repository.
    ///   - keychain: The keychain that receives the certificates and keys. See ``MatchKeychain``.
    ///   - implementation: The implementation that runs. See ``MatchImplementation``.
    ///   - name: The step name, or `nil` for the default.
    /// - Returns: One ``InstalledProfile`` for each bundle identifier, in the same order.
    ///
    /// Throws a usage error, before any process runs, if `bundleIdentifiers` is empty. The keychain path is resolved
    /// before any process runs too. The native implementation also checks the keychain password before the clone.
    ///
    /// Opens a step named "Install match adhoc signing assets" when called at the top level of a command. The name
    /// follows `type`. `step` renames it.
    public static func installMatchAssets(
        type: MatchType,
        bundleIdentifiers: [String],
        teamId: String,
        repository: MatchRepository,
        password: Secret,
        keychain: MatchKeychain,
        using implementation: MatchImplementation,
        step name: String? = nil
    ) async throws -> [InstalledProfile] {
        try await installMatchAssets(
            type: type,
            bundleIdentifiers: bundleIdentifiers,
            teamId: teamId,
            repository: repository,
            password: password,
            keychain: keychain,
            using: implementation,
            step: name,
            keychainsDirectory: MatchInstallation.defaultKeychainsDirectory,
            profilesDirectory: MatchInstallation.defaultProfilesDirectory,
            now: Date()
        )
    }

    /// The install with its test seams: the folder of the keychains, the folder of the profiles, and the date that the
    /// native selection checks expiry against. Tests use the temporary directories through it.
    static func installMatchAssets(
        type: MatchType,
        bundleIdentifiers: [String],
        teamId: String,
        repository: MatchRepository,
        password: Secret,
        keychain: MatchKeychain,
        using implementation: MatchImplementation,
        step name: String?,
        keychainsDirectory: URL,
        profilesDirectory: URL,
        now: Date
    ) async throws -> [InstalledProfile] {
        try await step(default: "Install match \(type.rawValue) signing assets", name: name) {
            @Use var log: Log

            // Everything that can fail without a process runs first, so that an error stops the install before any tool.
            let identifiers = try MatchSelection.uniqueBundleIdentifiers(bundleIdentifiers)
            let (keychainName, keychainPassword) = switch keychain {
            case .existing(let existingName, let existingPassword): (existingName, existingPassword)
            }
            let keychainURL = try MatchKeychainPath.resolve(name: keychainName, keychainsDirectory: keychainsDirectory)
            let credentials = try GitCredentialHelper.resolve(
                url: repository.url,
                basicAuthorization: repository.basicAuthorization,
                bearerAuthorization: repository.bearerAuthorization,
                inheritedEnvironment: ProcessInfo.processInfo.environment
            )
            // Checked here. The value is revealed only where it is used.
            _ = try password.revealedValue()

            switch implementation {
            case .native:
                // Built before the clone, so that an invalid keychain password stops the install first.
                let partitionTool = try MatchInstallation.partitionListTool(keychainURL: keychainURL, password: keychainPassword)
                log("Implementation: native")
                return try await MatchNativeInstall.install(
                    type: type,
                    bundleIdentifiers: identifiers,
                    teamId: teamId,
                    branch: repository.branch,
                    credentials: credentials,
                    password: password,
                    keychain: keychainURL,
                    partitionTool: partitionTool,
                    profilesDirectory: profilesDirectory,
                    now: now
                )
            case .fastlane(let invocation, let environment, let verbose):
                return try await MatchFastlaneInstall.install(
                    type: type,
                    bundleIdentifiers: identifiers,
                    teamId: teamId,
                    branch: repository.branch,
                    credentials: credentials,
                    password: password,
                    keychainName: keychainName,
                    keychainPassword: keychainPassword,
                    invocation: invocation,
                    environment: environment,
                    verbose: verbose,
                    profilesDirectory: profilesDirectory
                )
            }
        }
    }
}
