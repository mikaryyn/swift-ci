import Foundation
import SwiftCI

/// How fastlane is started by the fastlane fallback.
public enum FastlaneInvocation: Equatable, Sendable {
    /// Runs `fastlane` from `PATH`.
    case direct
    /// Runs `bundle exec fastlane`, for a project that pins fastlane in its Gemfile. With `gemfile`, `BUNDLE_GEMFILE` is
    /// set to its path in the environment of the tool, which overrides the same variable in `environment`. Without it,
    /// Bundler finds the Gemfile as usual. SwiftCI never looks for a Gemfile and never installs gems.
    case bundler(gemfile: URL? = nil)
}

/// The fastlane fallback of the signing install: `fastlane match` run from Swift.
///
/// The repository, its branch and the passwords are not arguments of these methods. `fastlane match` reads the
/// repository and the branch from the `Matchfile` of the project, and the passwords from its environment, such as
/// `MATCH_PASSWORD` as a ``Secret`` in `environment`. See ``Signing/installMatchAssets(type:bundleIdentifiers:teamId:repository:matchPassword:keychain:using:step:)``
/// to pass them from Swift.
///
/// The console of `match` shows the errors, the warnings, the installed certificate and the final result, and hides the
/// rest. The full log keeps all output.
public enum Fastlane {
    /// Runs `fastlane match` in readonly mode to install signing assets. Nothing is written to the match repository.
    ///
    /// Opens a step named "Install signing assets with fastlane match (appstore, com.example.myapp)" when called
    /// at the top level of a command. With several identifiers the name gives their count instead, for example
    /// "(appstore, 2 bundle identifiers)". `step` renames it.
    ///
    /// - Parameters:
    ///   - type: The distribution type.
    ///   - bundleIdentifiers: The bundle identifiers to install the profiles of. Must not be empty.
    ///   - teamId: The Apple Developer Team ID.
    ///   - invocation: How fastlane is started. See ``FastlaneInvocation``.
    ///   - environment: Variables for the tool, such as `PATH`, `LC_ALL` or a match password as a ``Secret``.
    ///   - verbose: Passes `--verbose`, so fastlane logs in detail. The full log keeps that output.
    ///   - name: The name of the step, if it is not the default.
    ///
    /// Throws a usage error, before any process runs, if `bundleIdentifiers` is empty.
    public static func match(
        type: MatchType,
        bundleIdentifiers: [String],
        teamId: String,
        invocation: FastlaneInvocation = .direct,
        environment: [String: ToolEnvironmentValue] = [:],
        verbose: Bool = false,
        step name: String? = nil
    ) async throws {
        try await runMatch(
            title: "Install", mode: "--readonly", type: type, bundleIdentifiers: bundleIdentifiers, teamId: teamId,
            invocation: invocation, environment: environment, verbose: verbose, step: name
        )
    }

    /// Runs `fastlane match` with `--force`, which renews the provisioning profiles on every run.
    ///
    /// This writes to the match repository: fastlane can create certificates and profiles and push them to the
    /// repository, so it needs write access to it, and every other user of the repository gets the change. Use
    /// ``match(type:bundleIdentifiers:teamId:invocation:environment:verbose:step:)`` to install without writing.
    ///
    /// Opens a step named "Update signing assets with fastlane match (appstore, com.example.myapp)" when called
    /// at the top level of a command. With several identifiers the name gives their count instead. `step` renames it.
    ///
    /// - Parameters:
    ///   - type: The distribution type.
    ///   - bundleIdentifiers: The bundle identifiers to renew the profiles of. Must not be empty.
    ///   - teamId: The Apple Developer Team ID.
    ///   - invocation: How fastlane is started. See ``FastlaneInvocation``.
    ///   - environment: Variables for the tool. See
    ///     ``match(type:bundleIdentifiers:teamId:invocation:environment:verbose:step:)``.
    ///   - verbose: Passes `--verbose`, so fastlane logs in detail. The full log keeps that output.
    ///   - name: The name of the step, if it is not the default.
    ///
    /// Throws a usage error, before any process runs, if `bundleIdentifiers` is empty.
    public static func matchUpdate(
        type: MatchType,
        bundleIdentifiers: [String],
        teamId: String,
        invocation: FastlaneInvocation = .direct,
        environment: [String: ToolEnvironmentValue] = [:],
        verbose: Bool = false,
        step name: String? = nil
    ) async throws {
        try await runMatch(
            title: "Update", mode: "--force", type: type, bundleIdentifiers: bundleIdentifiers, teamId: teamId,
            invocation: invocation, environment: environment, verbose: verbose, step: name
        )
    }

    /// Runs `fastlane match <type> <mode>` for the identifiers in a step named "<title> signing assets with fastlane
    /// match (<type>, <identifiers>)".
    private static func runMatch(
        title: String,
        mode: String,
        type: MatchType,
        bundleIdentifiers: [String],
        teamId: String,
        invocation: FastlaneInvocation,
        environment: [String: ToolEnvironmentValue],
        verbose: Bool,
        step name: String?
    ) async throws {
        let identifiers = try appIdentifierArgument(bundleIdentifiers)
        let description = "\(type.rawValue), \(identifierDescription(bundleIdentifiers))"
        try await step(default: "\(title) signing assets with fastlane match (\(description))", name: name) {
            try await fastlaneTool(
                invocation: invocation,
                arguments: ["match", type.rawValue, mode] + (verbose ? ["--verbose"] : [])
                    + ["--app_identifier", identifiers, "--team_id", teamId],
                environment: environment,
                console: consoleFilter()
            ).run()
        }
    }

    /// The value of `--app_identifier`: the identifiers joined with commas. Throws a usage error if there are none.
    private static func appIdentifierArgument(_ bundleIdentifiers: [String]) throws -> String {
        guard !bundleIdentifiers.isEmpty else {
            throw BuildError(
                message: "fastlane match needs at least one bundle identifier. "
                    + "Pass the bundle identifiers of the apps whose signing assets to install.",
                code: .usage
            )
        }
        return bundleIdentifiers.joined(separator: ",")
    }

    /// The identifier in a step name: the identifier itself, or the count when there is more than one.
    private static func identifierDescription(_ bundleIdentifiers: [String]) -> String {
        bundleIdentifiers.count == 1 ? bundleIdentifiers[0] : "\(bundleIdentifiers.count) bundle identifiers"
    }

    /// The tool that runs fastlane with `arguments`, started as `invocation` says. `console` decides which of its lines
    /// reach the console. The full log keeps all of them.
    static func fastlaneTool(
        invocation: FastlaneInvocation,
        arguments: [String],
        environment: [String: ToolEnvironmentValue],
        console: @escaping Filter
    ) -> Tool {
        switch invocation {
        case .direct:
            return Tool(command: "fastlane", arguments: arguments, environment: environment, filters: [console])
        case .bundler(let gemfile):
            var environment = environment
            if let gemfile {
                environment["BUNDLE_GEMFILE"] = .text(gemfile.filePath)
            }
            return Tool(
                command: "bundle",
                arguments: ["exec", "fastlane"] + arguments,
                environment: environment,
                filters: [console]
            )
        }
    }

    /// The console filter of a `match` run. It is made for each tool, because the table filter keeps state for its tool.
    static func consoleFilter() -> Filter {
        tableFilter(keeping: { $0 == "Installed Certificate" }, otherLines: consoleLineFilter)
    }

    /// Keeps the errors, the warnings except the per-profile "Setting environment variable" ones, the lines with `[!]`,
    /// the bundler failure and the final result. Other lines are hidden.
    private static let consoleLineFilter: Filter = { line in
        let plain = line.withoutTerminalCodes
        if plain.hasPrefix("WARN ") && !plain.contains("Setting environment variable '") {
            return line
        }
        let isKept = plain.contains("[!]")
            || plain.hasPrefix("ERROR ")
            || plain.hasPrefix("bundler: failed to load command")
            || plain.contains("All required keys, certificates and provisioning profiles are installed")
        return isKept ? line : nil
    }
}
