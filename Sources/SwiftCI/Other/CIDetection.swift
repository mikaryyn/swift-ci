import Foundation

/// Detects the CI environment of a run, once, when the run starts. Script adapters are asked first, then the built-in
/// adapters in the order of the CI environment plan (D3). The first adapter that answers wins. The local adapter always
/// answers.
enum CIDetection {
    /// The built-in adapters, in order.
    private static let builtIn: [any CIAdapter] = [
        GitHubActionsAdapter(),
        GitLabCIAdapter(),
        BitriseAdapter(),
        JenkinsAdapter(),
        GenericCIAdapter(),
        LocalAdapter(),
    ]

    /// The CI environment of a run with `variables` as the environment. Empty values count as unset.
    static func detect(variables: [String: String], adapters: [any CIAdapter]) -> CIEnvironment {
        let set = variables.filter { !$0.value.isEmpty }
        let answers = (adapters + builtIn).lazy.compactMap { $0.environment(from: set) }
        return answers.first ?? CIEnvironment(system: .local)
    }

    /// The exporter of a run with `variables` as the environment: the first adapter whose exporter answers, or the dotenv
    /// file when none does. It is chosen separately from the environment (D2). The Bitrise CLI is asked before the other
    /// built-in adapters, because it is the innermost runner when another CI system runs it (D3). Empty values count as
    /// unset.
    static func exporter(variables: [String: String], adapters: [any CIAdapter]) -> any CIExporter {
        let set = variables.filter { !$0.value.isEmpty }
        let builtInExporters = [BitriseAdapter()] + builtIn.filter { !($0 is BitriseAdapter) }
        let answers = (adapters + builtInExporters).lazy.compactMap { $0.exporter(from: set) }
        return answers.first ?? DotenvExporter()
    }

    /// The line that the full log of each command records, for example `CI: Jenkins, build 123, branch main`. Only the
    /// fields that are set appear.
    static func summary(_ environment: CIEnvironment) -> String {
        var parts = [environment.system.name]
        if let buildNumber = environment.buildNumber {
            parts.append("build \(buildNumber)")
        }
        if let branch = environment.branch {
            parts.append("branch \(branch)")
        }
        if let tag = environment.tag {
            parts.append("tag \(tag)")
        }
        if let mergeRequest = environment.mergeRequest {
            parts.append("merge request !\(mergeRequest.number)")
        }
        return "CI: " + parts.joined(separator: ", ")
    }
}

extension Dictionary where Key == String, Value == String {
    /// The first of `names` that is set, in order of preference.
    fileprivate func value(_ names: String...) -> String? {
        names.lazy.compactMap { self[$0] }.first
    }

    /// The value of `name` as an integer, or `nil` if it is not set or does not parse.
    fileprivate func int(_ name: String) -> Int? {
        self[name].flatMap(Int.init)
    }

    /// The value of `name` as a URL, or `nil` if it is not set or is not a valid URL.
    fileprivate func url(_ name: String) -> URL? {
        self[name].flatMap(URL.init(string:))
    }
}

/// GitHub Actions: `GITHUB_ACTIONS=true`. The pull request number comes from `GITHUB_REF`, or from the event file for
/// `pull_request_target` runs, whose `GITHUB_REF` is the base branch.
struct GitHubActionsAdapter: CIAdapter {
    /// The exporter writes to `$GITHUB_ENV`, and to `$GITHUB_OUTPUT` when that is set too. It does not need
    /// `GITHUB_ACTIONS`, as the Bitrise exporter does not need `BITRISE_IO`: the file is the mechanism.
    func exporter(from variables: [String: String]) -> (any CIExporter)? {
        guard let environmentFile = variables["GITHUB_ENV"] else { return nil }
        return GitHubExporter(
            environmentFile: URL(fileURLWithPath: environmentFile),
            outputFile: variables["GITHUB_OUTPUT"].map { URL(fileURLWithPath: $0) }
        )
    }

    func environment(from variables: [String: String]) -> CIEnvironment? {
        guard variables["GITHUB_ACTIONS"] == "true" else { return nil }

        let repository = variables["GITHUB_SERVER_URL"].flatMap { server in
            variables["GITHUB_REPOSITORY"].map { "\(server)/\($0)" }
        }
        let number = pullRequestNumber(variables)
        let mergeRequest = number.map { number in
            MergeRequest(
                number: number,
                sourceBranch: variables["GITHUB_HEAD_REF"],
                targetBranch: variables["GITHUB_BASE_REF"],
                url: repository.flatMap { URL(string: "\($0)/pull/\(number)") }
            )
        }
        let runURL = repository.flatMap { base in
            variables["GITHUB_RUN_ID"].flatMap { URL(string: "\(base)/actions/runs/\($0)") }
        }

        return CIEnvironment(
            system: .gitHubActions,
            branch: variables["GITHUB_HEAD_REF"] ?? refName(variables, type: "branch"),
            commit: variables["GITHUB_SHA"],
            tag: refName(variables, type: "tag"),
            mergeRequest: mergeRequest,
            buildNumber: variables.int("GITHUB_RUN_NUMBER"),
            buildURL: runURL,
            jobName: variables.value("GITHUB_WORKFLOW", "GITHUB_JOB")
        )
    }

    /// `GITHUB_REF_NAME` when `GITHUB_REF_TYPE` is `type`.
    private func refName(_ variables: [String: String], type: String) -> String? {
        variables["GITHUB_REF_TYPE"] == type ? variables["GITHUB_REF_NAME"] : nil
    }

    /// The number from `refs/pull/<n>/merge`, else `pull_request.number` in the event file.
    private func pullRequestNumber(_ variables: [String: String]) -> Int? {
        if let ref = variables["GITHUB_REF"], ref.hasPrefix("refs/pull/"), ref.hasSuffix("/merge") {
            if let number = Int(ref.dropFirst("refs/pull/".count).dropLast("/merge".count)) {
                return number
            }
        }
        return eventPullRequestNumber(path: variables["GITHUB_EVENT_PATH"])
    }

    /// `pull_request.number` in the JSON file at `path`, or `nil` if the file is missing or malformed.
    private func eventPullRequestNumber(path: String?) -> Int? {
        guard let path,
              let data = FileManager.default.contents(atPath: path),
              let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pullRequest = event["pull_request"] as? [String: Any]
        else { return nil }
        return pullRequest["number"] as? Int
    }
}

/// GitLab CI: `GITLAB_CI=true`.
struct GitLabCIAdapter: CIAdapter {
    func environment(from variables: [String: String]) -> CIEnvironment? {
        guard variables["GITLAB_CI"] == "true" else { return nil }

        let mergeRequest = variables.int("CI_MERGE_REQUEST_IID").map { number in
            MergeRequest(
                number: number,
                sourceBranch: variables["CI_MERGE_REQUEST_SOURCE_BRANCH_NAME"],
                targetBranch: variables["CI_MERGE_REQUEST_TARGET_BRANCH_NAME"],
                url: variables["CI_MERGE_REQUEST_PROJECT_URL"].flatMap { URL(string: "\($0)/-/merge_requests/\(number)") }
            )
        }

        return CIEnvironment(
            system: .gitLabCI,
            branch: variables.value("CI_MERGE_REQUEST_SOURCE_BRANCH_NAME", "CI_COMMIT_BRANCH"),
            commit: variables["CI_COMMIT_SHA"],
            tag: variables["CI_COMMIT_TAG"],
            mergeRequest: mergeRequest,
            buildNumber: variables.int("CI_PIPELINE_IID"),
            buildURL: variables.url("CI_JOB_URL"),
            jobName: variables["CI_JOB_NAME"]
        )
    }
}

/// bitrise.io: `BITRISE_IO=true`. The Bitrise CLI on another machine does not match, so a Jenkins job that runs it is
/// detected as Jenkins.
struct BitriseAdapter: CIAdapter {
    /// The exporter is `envman` whenever `ENVMAN_ENVSTORE_PATH` is set, so a Bitrise CLI inside another CI system exports
    /// to the Bitrise workflow. It does not need `BITRISE_IO`, which the environment does need.
    func exporter(from variables: [String: String]) -> (any CIExporter)? {
        guard let storePath = variables["ENVMAN_ENVSTORE_PATH"] else { return nil }
        return EnvmanExporter(storePath: storePath)
    }

    func environment(from variables: [String: String]) -> CIEnvironment? {
        guard variables["BITRISE_IO"] == "true" else { return nil }

        let mergeRequest = variables.int("BITRISE_PULL_REQUEST").map { number in
            MergeRequest(
                number: number,
                sourceBranch: variables["BITRISE_GIT_BRANCH"],
                targetBranch: variables["BITRISEIO_GIT_BRANCH_DEST"]
            )
        }

        return CIEnvironment(
            system: .bitrise,
            branch: variables["BITRISE_GIT_BRANCH"],
            commit: variables["BITRISE_GIT_COMMIT"],
            tag: variables["BITRISE_GIT_TAG"],
            mergeRequest: mergeRequest,
            buildNumber: variables.int("BITRISE_BUILD_NUMBER"),
            buildURL: variables.url("BITRISE_BUILD_URL"),
            jobName: variables["BITRISE_TRIGGERED_WORKFLOW_ID"]
        )
    }
}

/// Jenkins: `JENKINS_URL`, or `BUILD_URL`, `JOB_NAME` and `BUILD_NUMBER` together, since `JENKINS_URL` is set only
/// when the Jenkins URL is configured. Covers multibranch pipelines (`CHANGE_*`) and the GitLab plugin (`gitlab*`).
struct JenkinsAdapter: CIAdapter {
    func environment(from variables: [String: String]) -> CIEnvironment? {
        let isJenkins = variables["JENKINS_URL"] != nil
            || (variables["BUILD_URL"] != nil && variables["JOB_NAME"] != nil && variables["BUILD_NUMBER"] != nil)
        guard isJenkins else { return nil }

        // A multibranch change request sets CHANGE_ID. BRANCH_NAME is the branch name only for other builds.
        let isChangeRequest = variables["CHANGE_ID"] != nil
        // A GitLab plugin build is a merge request only with the MERGE action.
        let gitLabMergeRequest = variables["gitlabActionType"] == "MERGE" ? variables.int("gitlabMergeRequestIid") : nil
        let number = variables.int("CHANGE_ID") ?? gitLabMergeRequest

        let mergeRequest = number.map { number in
            MergeRequest(
                number: number,
                sourceBranch: variables.value("CHANGE_BRANCH", "gitlabSourceBranch"),
                targetBranch: variables.value("CHANGE_TARGET", "gitlabTargetBranch"),
                url: variables.url("CHANGE_URL")
            )
        }

        return CIEnvironment(
            system: .jenkins,
            branch: branch(variables, isChangeRequest: isChangeRequest),
            commit: variables.value("GIT_COMMIT", "gitlabMergeRequestLastCommit", "gitlabAfter"),
            tag: variables["TAG_NAME"],
            mergeRequest: mergeRequest,
            buildNumber: variables.int("BUILD_NUMBER"),
            buildURL: variables.url("BUILD_URL"),
            jobName: variables["JOB_NAME"]
        )
    }

    /// The branch built, from the first of these that is set: `CHANGE_BRANCH`, `gitlabSourceBranch`, `BRANCH_NAME` (not
    /// for change requests), and `GIT_BRANCH` without a leading `origin/`.
    private func branch(_ variables: [String: String], isChangeRequest: Bool) -> String? {
        if let branch = variables.value("CHANGE_BRANCH", "gitlabSourceBranch") {
            return branch
        }
        if !isChangeRequest, let branch = variables["BRANCH_NAME"] {
            return branch
        }
        guard let gitBranch = variables["GIT_BRANCH"] else { return nil }
        let prefix = "origin/"
        let branch = gitBranch.hasPrefix(prefix) ? String(gitBranch.dropFirst(prefix.count)) : gitBranch
        return branch.isEmpty ? nil : branch
    }
}

/// Another CI system that sets `CI=true` or `CI=1`, with no build information.
struct GenericCIAdapter: CIAdapter {
    func environment(from variables: [String: String]) -> CIEnvironment? {
        guard variables["CI"] == "true" || variables["CI"] == "1" else { return nil }
        return CIEnvironment(system: .genericCI)
    }
}

/// A run that no other adapter matches. It always answers.
struct LocalAdapter: CIAdapter {
    func environment(from variables: [String: String]) -> CIEnvironment? {
        CIEnvironment(system: .local)
    }
}
