import Foundation
import SwiftCI

/// A merge request on a GitLab server, identified as the GitLab API identifies it.
public struct GitLabMergeRequest: Equatable, Sendable {
    /// The project: its numeric ID, or its URL-encoded path such as `group%2Fproject`.
    public var project: String

    /// The IID of the merge request: its number in the project, as the GitLab UI shows it.
    public var iid: Int

    /// Creates a reference to a merge request.
    ///
    /// - Parameters:
    ///   - project: The numeric ID of the project, or its URL-encoded path such as `group%2Fproject`.
    ///   - iid: The IID of the merge request in the project.
    public init(project: String, iid: Int) {
        self.project = project
        self.iid = iid
    }
}

extension GitLabMergeRequest {
    /// The merge request that the CI variables in `environment` name, or `nil` if there is none. The IID is the first of
    /// `CI_MERGE_REQUEST_IID` (GitLab CI) and `gitlabMergeRequestIid` (Jenkins GitLab plugin) that is set. The project is
    /// described under ``mergeRequest()``. Empty values count as unset. This is a query: it does not open a step.
    ///
    /// It does not check whether the build is for a merge request. A Jenkins push build can still have
    /// `gitlabMergeRequestIid` set, so use ``mergeRequest()`` for the merge request of the running build.
    ///
    /// - Parameter environment: The variables to read, by name.
    /// - Returns: The merge request, or `nil` if the IID or the project is missing or the IID is not a number.
    public static func mergeRequest(from environment: [String: String]) -> GitLabMergeRequest? {
        guard let iid = environment.firstValue(iidVariables).flatMap(Int.init),
              let project = project(in: environment)
        else { return nil }
        return GitLabMergeRequest(project: project, iid: iid)
    }

    /// The merge request of the running build, or `nil` if the build is not for a merge request or no project is known.
    /// The IID is the merge request number of ``CI/environment``. The project comes from the first of
    /// `CI_PROJECT_ID` (GitLab CI) and `gitlabMergeRequestTargetProjectId` (Jenkins GitLab plugin) that is set. Otherwise
    /// it is the path of the first of `gitlabTargetRepoHttpUrl`, `gitlabTargetRepoSshUrl` and `GIT_URL` that has one. The
    /// path has no host, `.git` suffix or slashes at the ends, and its `/` is written as `%2F`. This is a query: it does
    /// not open a step, and it reads ``CI/environment``, so it runs inside a command or a step.
    public static func mergeRequest() -> GitLabMergeRequest? {
        var variables: [String: String] = [:]
        for name in projectIDVariables + repositoryURLVariables {
            variables[name] = Environment.optional(name)
        }
        guard let iid = CI.environment.mergeRequest?.number,
              let project = project(in: variables)
        else { return nil }
        return GitLabMergeRequest(project: project, iid: iid)
    }

    /// The variables that hold the IID of the merge request, in order of preference.
    private static let iidVariables = ["CI_MERGE_REQUEST_IID", "gitlabMergeRequestIid"]

    /// The project variables that hold a numeric ID, in order of preference.
    private static let projectIDVariables = ["CI_PROJECT_ID", "gitlabMergeRequestTargetProjectId"]

    /// The variables that hold a repository URL, in order of preference.
    private static let repositoryURLVariables = ["gitlabTargetRepoHttpUrl", "gitlabTargetRepoSshUrl", "GIT_URL"]

    /// The project of `environment`, URL-encoded if it is a path. `nil` when none of the variables is set and usable.
    static func project(in environment: [String: String]) -> String? {
        if let id = environment.firstValue(projectIDVariables) {
            return id
        }
        for name in repositoryURLVariables {
            if let path = projectPath(ofRepositoryURL: environment[name] ?? ""), let encoded = encodedProjectPath(path) {
                return encoded
            }
        }
        return nil
    }

    /// The project path of a repository URL. It handles `https://host/group/project.git`,
    /// `ssh://git@host:2222/group/project.git` and the scp form `git@host:group/project.git`. The host, the user, the
    /// port, the `.git` suffix and the slashes at the ends are removed. `nil` when no path is left.
    static func projectPath(ofRepositoryURL url: String) -> String? {
        let rawPath: Substring
        if let scheme = url.range(of: "://") {
            let rest = url[scheme.upperBound...]
            guard let slash = rest.firstIndex(of: "/") else { return nil }
            rawPath = rest[slash...]
        } else if let colon = url.firstIndex(of: ":") {
            rawPath = url[url.index(after: colon)...]
        } else {
            return nil
        }
        var path = String(rawPath)
        while path.hasPrefix("/") {
            path.removeFirst()
        }
        while path.hasSuffix("/") {
            path.removeLast()
        }
        if path.hasSuffix(".git") {
            path.removeLast(".git".count)
        }
        return path.isEmpty ? nil : path
    }

    /// `path` with every character except letters, digits and `-._~` percent-encoded, so `/` becomes `%2F`. `nil` if the
    /// text cannot be encoded.
    static func encodedProjectPath(_ path: String) -> String? {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return path.addingPercentEncoding(withAllowedCharacters: allowed)
    }
}

private extension Dictionary where Key == String, Value == String {
    /// The first of `names` whose value is set and not empty.
    func firstValue(_ names: [String]) -> String? {
        names.lazy.compactMap { self[$0] }.first { !$0.isEmpty }
    }
}
