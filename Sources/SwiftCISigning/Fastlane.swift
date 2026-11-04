import Foundation
import SwiftCI

/// Distribution types of fastlane match. The raw value is the type argument of `fastlane match`. The folders of the
/// certificates and profiles in the match repository are derived from the type.
public enum MatchType: String {
    case appstore, adhoc, enterprise, development
}

/// How fastlane is started by the fastlane fallback.
public enum FastlaneInvocation: Equatable, Sendable {
    /// Runs `fastlane` from `PATH`.
    case direct
    /// Runs `bundle exec fastlane`, for a project that pins fastlane in its Gemfile. With `gemfile`, `BUNDLE_GEMFILE` is
    /// set to its path in the environment of the tool, which overrides the same variable in `environment`. Without it,
    /// Bundler finds the Gemfile as usual. SwiftCI never looks for a Gemfile and never installs gems.
    case bundler(gemfile: URL? = nil)
}

/// Swift helpers for invoking fastlane match.
///
/// The console of `match` shows the errors, the warnings, the installed certificate and the final result, and hides the
/// rest. The full log keeps all output.
public struct Fastlane {
    /// Run `fastlane match` (Ruby) in readonly mode to install signing assets.
    /// - Parameters:
    ///   - type: Distribution type (appstore/adhoc/enterprise).
    ///   - appIdentifiers: Bundle identifiers to install the profiles of. Must not be empty.
    ///   - teamId: Apple Developer Team ID.
    ///   - invocation: How fastlane is started. See ``FastlaneInvocation``.
    ///   - environment: Variables for the tool, such as `PATH`, `LC_ALL` or a match password as a ``Secret``.
    ///   - verbose: Passes `--verbose`, so fastlane logs in detail. The full log keeps that output.
    ///
    /// Throws a usage error, before any process runs, if `appIdentifiers` is empty.
    ///
    /// Opens a step named "Install signing assets with fastlane match (appstore, com.example.myapp)" when called
    /// at the top level of a command. With several identifiers the name gives their count instead, for example
    /// "(appstore, 2 app identifiers)". `step` renames it.
    public static func match(
        type: MatchType,
        appIdentifiers: [String],
        teamId: String,
        invocation: FastlaneInvocation = .direct,
        environment: [String: ToolEnvironmentValue] = [:],
        verbose: Bool = false,
        step name: String? = nil
    ) async throws {
        let identifiers = try appIdentifierArgument(appIdentifiers)
        try await step(
            default: "Install signing assets with fastlane match (\(type.rawValue), \(appIdentifierDescription(appIdentifiers)))",
            name: name
        ) {
            try await fastlaneTool(
                invocation: invocation,
                arguments: ["match", type.rawValue, "--readonly"] + verboseArgument(verbose)
                    + ["--app_identifier", identifiers, "--team_id", teamId],
                environment: environment,
                console: consoleFilter()
            ).run()
        }
    }

    /// Run `fastlane match` (Ruby) with `--force` to refresh profiles if needed.
    /// - Parameters:
    ///   - type: Distribution type (appstore/adhoc/enterprise).
    ///   - appIdentifiers: Bundle identifiers. Must not be empty.
    ///   - teamId: Apple Developer Team ID.
    ///   - invocation: How fastlane is started. See ``FastlaneInvocation``.
    ///   - environment: Variables for the tool. See
    ///     ``match(type:appIdentifiers:teamId:invocation:environment:verbose:step:)``.
    ///   - verbose: Passes `--verbose`, so fastlane logs in detail. The full log keeps that output.
    ///
    /// Throws a usage error, before any process runs, if `appIdentifiers` is empty.
    ///
    /// Opens a step named "Update signing assets with fastlane match (appstore, com.example.myapp)" when called
    /// at the top level of a command. With several identifiers the name gives their count instead. `step` renames it.
    public static func matchUpdate(
        type: MatchType,
        appIdentifiers: [String],
        teamId: String,
        invocation: FastlaneInvocation = .direct,
        environment: [String: ToolEnvironmentValue] = [:],
        verbose: Bool = false,
        step name: String? = nil
    ) async throws {
        let identifiers = try appIdentifierArgument(appIdentifiers)
        try await step(
            default: "Update signing assets with fastlane match (\(type.rawValue), \(appIdentifierDescription(appIdentifiers)))",
            name: name
        ) {
            try await fastlaneTool(
                invocation: invocation,
                arguments: ["match", type.rawValue, "--force"] + verboseArgument(verbose)
                    + ["--app_identifier", identifiers, "--team_id", teamId],
                environment: environment,
                console: consoleFilter()
            ).run()
        }
    }

    /// The value of `--app_identifier`: the identifiers joined with commas. Throws a usage error if there are none.
    private static func appIdentifierArgument(_ appIdentifiers: [String]) throws -> String {
        guard !appIdentifiers.isEmpty else {
            throw BuildError(
                message: "fastlane match needs at least one app identifier. Pass the bundle identifiers of the apps whose signing assets to install.",
                code: .usage
            )
        }
        return appIdentifiers.joined(separator: ",")
    }

    /// `--verbose` when `verbose` is true, otherwise nothing.
    private static func verboseArgument(_ verbose: Bool) -> [String] {
        verbose ? ["--verbose"] : []
    }

    /// The identifier in a step name: the identifier itself, or the count when there is more than one.
    private static func appIdentifierDescription(_ appIdentifiers: [String]) -> String {
        appIdentifiers.count == 1 ? appIdentifiers[0] : "\(appIdentifiers.count) app identifiers"
    }

    /// The tool that runs fastlane with `arguments`, started as `invocation` says. `console` decides which of its lines
    /// reach the console. The full log keeps all of them.
    static func fastlaneTool(
        invocation: FastlaneInvocation,
        arguments: [String],
        environment: [String: ToolEnvironmentValue],
        console: @escaping BlockFilter
    ) -> Tool {
        switch invocation {
        case .direct:
            return Tool(command: "fastlane", arguments: arguments, environment: environment, blockFilter: console)
        case .bundler(let gemfile):
            var environment = environment
            if let gemfile {
                environment["BUNDLE_GEMFILE"] = .text(gemfile.filePath)
            }
            return Tool(
                command: "bundle",
                arguments: ["exec", "fastlane"] + arguments,
                environment: environment,
                blockFilter: console
            )
        }
    }

    /// The console filter of a `match` run. It is made for each tool, because a block filter keeps state for its tool.
    static func consoleFilter() -> BlockFilter {
        tableFilter(keeping: { $0 == "Installed Certificate" }, otherLines: consoleLineFilter)
    }

    /// Keeps the errors, the warnings except the per-profile "Setting environment variable" ones, the lines with `[!]`,
    /// the bundler failure and the final result. Other lines are hidden.
    private static let consoleLineFilter: Filter = { line in
        let plain = line.replacingOccurrences(of: "\u{1B}\\[[0-9;]*[A-Za-z]", with: "", options: .regularExpression)
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
