import Foundation

/// The CI environment of the running build: which CI system runs it, and the branch, commit, tag, merge request,
/// build number, build URL and job name that it builds.
public enum CI {
    /// The CI environment of the running run, detected once when `SwiftCI { }` starts. A query: it does not open a step.
    ///
    /// A local run has ``CISystem/local`` and no build information, so ``CIEnvironment/isCI`` is `false`. Reading it
    /// outside a running `SwiftCI { }` or a `SwiftCITest` run is a programming error and stops the process with a
    /// message that says so, as with ``Artifacts/directory``.
    public static var environment: CIEnvironment {
        guard let environment = CIState.current else {
            preconditionFailure(
                "CI.environment was read outside a running SwiftCI { } or SwiftCITest run. Read it inside a command or a step."
            )
        }
        return environment
    }
}

/// What the CI system says about the build. A field is `nil` when the CI system does not set it, or sets it to an empty
/// or malformed value.
public struct CIEnvironment: Equatable, Sendable {
    /// The CI system that runs the build, or ``CISystem/local`` when no CI system is detected.
    public var system: CISystem

    /// `true` unless ``system`` is ``CISystem/local``.
    public var isCI: Bool { system != .local }

    /// The branch built. For a merge request, its source branch.
    public var branch: String?

    /// The full hash of the revision checked out. For a GitHub pull request, this is the merge commit that GitHub
    /// checks out, not the head of the pull request branch.
    public var commit: String?

    /// The tag built, if the build is for a tag.
    public var tag: String?

    /// The merge request built, if the build is for one.
    public var mergeRequest: MergeRequest?

    /// The build number of the CI system, such as the pipeline or run number.
    public var buildNumber: Int?

    /// The URL of the build's page in the CI system.
    public var buildURL: URL?

    /// The name of the job or workflow that runs the build.
    public var jobName: String?

    /// Creates a CI environment. Adapters use it to describe a CI system, and tests use it to compare results.
    public init(
        system: CISystem,
        branch: String? = nil,
        commit: String? = nil,
        tag: String? = nil,
        mergeRequest: MergeRequest? = nil,
        buildNumber: Int? = nil,
        buildURL: URL? = nil,
        jobName: String? = nil
    ) {
        self.system = system
        self.branch = branch
        self.commit = commit
        self.tag = tag
        self.mergeRequest = mergeRequest
        self.buildNumber = buildNumber
        self.buildURL = buildURL
        self.jobName = jobName
    }
}

/// A merge request, or a pull request on GitHub, that the build is for.
public struct MergeRequest: Equatable, Sendable {
    /// The number of the merge request in its project, such as the GitLab IID or the GitHub pull request number.
    public var number: Int

    /// The branch that the merge request proposes, if the CI system sets it.
    public var sourceBranch: String?

    /// The branch that the merge request targets, if the CI system sets it.
    public var targetBranch: String?

    /// The page of the merge request, if the CI system sets it.
    public var url: URL?

    /// Creates a merge request.
    public init(number: Int, sourceBranch: String? = nil, targetBranch: String? = nil, url: URL? = nil) {
        self.number = number
        self.sourceBranch = sourceBranch
        self.targetBranch = targetBranch
        self.url = url
    }
}

/// A CI system, identified by an id and shown with a name. The built-in systems are static constants, so that
/// extensions can add their own systems with ``init(id:name:)``.
public struct CISystem: Hashable, Sendable {
    /// Creates a CI system. Use a short, stable id, such as `azure-pipelines`.
    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    /// The stable identifier of the system.
    public let id: String

    /// The name shown in the log, such as `GitHub Actions`.
    public let name: String

    /// GitHub Actions (`GITHUB_ACTIONS=true`).
    public static let gitHubActions = CISystem(id: "github-actions", name: "GitHub Actions")

    /// GitLab CI (`GITLAB_CI=true`).
    public static let gitLabCI = CISystem(id: "gitlab-ci", name: "GitLab CI")

    /// Jenkins, detected by `JENKINS_URL`, or by `BUILD_URL`, `JOB_NAME` and `BUILD_NUMBER` together.
    public static let jenkins = CISystem(id: "jenkins", name: "Jenkins")

    /// bitrise.io (`BITRISE_IO=true`). The Bitrise CLI on another machine is a runner, not a CI system.
    public static let bitrise = CISystem(id: "bitrise", name: "Bitrise")

    /// Another CI system that sets `CI=true` or `CI=1`, with no build information.
    public static let genericCI = CISystem(id: "generic-ci", name: "Generic CI")

    /// A run that no CI system matches, such as on a developer's Mac.
    public static let local = CISystem(id: "local", name: "Local")
}

/// Describes one CI system to SwiftCI. Scripts pass their adapters to `SwiftCI(ciAdapters:)`, and they are asked before
/// the built-in adapters. The first adapter that returns an environment wins.
///
/// An adapter reads the variables it is given, which have no empty values, and must not read the process
/// environment or the file system except for files that a variable names, such as GitHub's event file.
public protocol CIAdapter {
    /// The environment of this CI system, or `nil` if the variables do not belong to it.
    func environment(from variables: [String: String]) -> CIEnvironment?

    /// The exporter for the runner these variables belong to, or `nil` to leave it to the next adapter.
    func exporter(from variables: [String: String]) -> (any CIExporter)?
}

extension CIAdapter {
    /// `nil`: the adapter does not export values. Override it to pass values to later steps (see ``CIExporter``).
    public func exporter(from variables: [String: String]) -> (any CIExporter)? {
        nil
    }
}

/// Passes a value to later steps of the CI job, through the mechanism of one runner. Adapters return exporters from
/// ``CIAdapter/exporter(from:)``. The built-in exporters are `envman`, `$GITHUB_ENV` and the dotenv file (see
/// ``CI/export(_:_:)``).
public protocol CIExporter {
    /// Makes `value` available as the environment variable `name` to later steps.
    func export(name: String, value: String) async throws
}

/// The CI environment and the exporter of the running run. Set by the run's start and restored when it returns (see
/// ``CI``).
enum CIState {
    static var current: CIEnvironment?

    /// The exporter that ``CI/export(_:_:)`` writes through, chosen with the environment at start. `nil` outside a run.
    static var exporter: (any CIExporter)?
}
