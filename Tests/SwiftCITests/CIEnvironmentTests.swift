@_spi(Testing) import SwiftCI
@testable import SwiftCI
@testable import SwiftCITestSupport
import Foundation
import SwiftCITesting
import Testing

/// Detection of the CI environment from variables. Pure: no global state, so the suite runs without `GlobalStateTests`.
@Suite struct CIDetectionTests {
    private let githubBase = [
        "GITHUB_ACTIONS": "true",
        "GITHUB_SERVER_URL": "https://github.com",
        "GITHUB_REPOSITORY": "example/myapp",
        "GITHUB_SHA": "3f2a9c1d0e4b5a6f7c8d9e0f1a2b3c4d5e6f7a8b",
        "GITHUB_RUN_ID": "42",
        "GITHUB_RUN_NUMBER": "7",
        "GITHUB_WORKFLOW": "CI",
        "GITHUB_JOB": "build",
    ]

    @Test func gitHubBranchBuild() {
        let variables = githubBase.merging([
            "GITHUB_REF": "refs/heads/main",
            "GITHUB_REF_TYPE": "branch",
            "GITHUB_REF_NAME": "main",
        ]) { $1 }

        #expect(detect(variables) == CIEnvironment(
            system: .gitHubActions,
            branch: "main",
            commit: "3f2a9c1d0e4b5a6f7c8d9e0f1a2b3c4d5e6f7a8b",
            buildNumber: 7,
            buildURL: URL(string: "https://github.com/example/myapp/actions/runs/42"),
            jobName: "CI"
        ))
    }

    @Test func gitHubPullRequestBuild() {
        let variables = githubBase.merging([
            "GITHUB_REF": "refs/pull/12/merge",
            "GITHUB_REF_TYPE": "branch",
            "GITHUB_REF_NAME": "12/merge",
            "GITHUB_HEAD_REF": "feature/x",
            "GITHUB_BASE_REF": "main",
        ]) { $1 }

        #expect(detect(variables) == CIEnvironment(
            system: .gitHubActions,
            branch: "feature/x",
            commit: "3f2a9c1d0e4b5a6f7c8d9e0f1a2b3c4d5e6f7a8b",
            mergeRequest: MergeRequest(
                number: 12,
                sourceBranch: "feature/x",
                targetBranch: "main",
                url: URL(string: "https://github.com/example/myapp/pull/12")
            ),
            buildNumber: 7,
            buildURL: URL(string: "https://github.com/example/myapp/actions/runs/42"),
            jobName: "CI"
        ))
    }

    @Test func gitHubTagBuild() {
        let variables = githubBase.merging([
            "GITHUB_REF": "refs/tags/v1.2.0",
            "GITHUB_REF_TYPE": "tag",
            "GITHUB_REF_NAME": "v1.2.0",
        ]) { $1 }

        let environment = detect(variables)
        #expect(environment.tag == "v1.2.0")
        #expect(environment.branch == nil)
        #expect(environment.mergeRequest == nil)
    }

    @Test func gitHubPullRequestTargetReadsTheEventFile() throws {
        let eventPath = try writeFixture(#"{"action": "opened", "pull_request": {"number": 34}}"#)
        defer { removeFixture(eventPath) }
        let variables = githubBase.merging([
            "GITHUB_REF": "refs/heads/main",
            "GITHUB_REF_TYPE": "branch",
            "GITHUB_REF_NAME": "main",
            "GITHUB_HEAD_REF": "feature/x",
            "GITHUB_BASE_REF": "main",
            "GITHUB_EVENT_PATH": eventPath,
        ]) { $1 }

        let environment = detect(variables)
        #expect(environment.mergeRequest == MergeRequest(
            number: 34,
            sourceBranch: "feature/x",
            targetBranch: "main",
            url: URL(string: "https://github.com/example/myapp/pull/34")
        ))
        #expect(environment.branch == "feature/x")
    }

    @Test func gitLabBranchBuild() {
        let environment = detect([
            "GITLAB_CI": "true",
            "CI_COMMIT_BRANCH": "develop",
            "CI_COMMIT_SHA": "9c8b7a6f5e4d3c2b1a09f8e7d6c5b4a3f2e1d0c9",
            "CI_PIPELINE_IID": "88",
            "CI_JOB_URL": "https://gitlab.example.com/group/project/-/jobs/9",
            "CI_JOB_NAME": "build-ios",
        ])

        #expect(environment == CIEnvironment(
            system: .gitLabCI,
            branch: "develop",
            commit: "9c8b7a6f5e4d3c2b1a09f8e7d6c5b4a3f2e1d0c9",
            buildNumber: 88,
            buildURL: URL(string: "https://gitlab.example.com/group/project/-/jobs/9"),
            jobName: "build-ios"
        ))
    }

    @Test func gitLabMergeRequestBuild() {
        let environment = detect([
            "GITLAB_CI": "true",
            "CI_MERGE_REQUEST_IID": "5",
            "CI_MERGE_REQUEST_SOURCE_BRANCH_NAME": "feature/y",
            "CI_MERGE_REQUEST_TARGET_BRANCH_NAME": "main",
            "CI_MERGE_REQUEST_PROJECT_URL": "https://gitlab.example.com/group/project",
            "CI_COMMIT_BRANCH": "ignored-for-merge-requests",
            "CI_COMMIT_SHA": "9c8b7a6f5e4d3c2b1a09f8e7d6c5b4a3f2e1d0c9",
        ])

        #expect(environment.branch == "feature/y")
        #expect(environment.mergeRequest == MergeRequest(
            number: 5,
            sourceBranch: "feature/y",
            targetBranch: "main",
            url: URL(string: "https://gitlab.example.com/group/project/-/merge_requests/5")
        ))
    }

    @Test func gitLabTagBuild() {
        let environment = detect(["GITLAB_CI": "true", "CI_COMMIT_TAG": "v2.0.0"])

        #expect(environment.system == .gitLabCI)
        #expect(environment.tag == "v2.0.0")
        #expect(environment.branch == nil)
    }

    @Test func bitriseBranchBuild() {
        let environment = detect([
            "BITRISE_IO": "true",
            "BITRISE_GIT_BRANCH": "main",
            "BITRISE_GIT_COMMIT": "1a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d",
            "BITRISE_BUILD_NUMBER": "15",
            "BITRISE_BUILD_URL": "https://app.bitrise.io/build/abc",
            "BITRISE_TRIGGERED_WORKFLOW_ID": "release",
        ])

        #expect(environment == CIEnvironment(
            system: .bitrise,
            branch: "main",
            commit: "1a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d",
            buildNumber: 15,
            buildURL: URL(string: "https://app.bitrise.io/build/abc"),
            jobName: "release"
        ))
    }

    @Test func bitriseMergeRequestAndTagBuilds() {
        let merge = detect([
            "BITRISE_IO": "true",
            "BITRISE_GIT_BRANCH": "feature/b",
            "BITRISEIO_GIT_BRANCH_DEST": "main",
            "BITRISE_PULL_REQUEST": "3",
        ])
        #expect(merge.mergeRequest == MergeRequest(number: 3, sourceBranch: "feature/b", targetBranch: "main"))

        let tag = detect(["BITRISE_IO": "true", "BITRISE_GIT_TAG": "v3.0.0"])
        #expect(tag.tag == "v3.0.0")
        #expect(tag.mergeRequest == nil)
    }

    @Test func jenkinsBranchBuild() {
        let environment = detect([
            "JENKINS_URL": "https://jenkins.example.com/",
            "BUILD_URL": "https://jenkins.example.com/job/MyApp/job/main/123/",
            "JOB_NAME": "MyApp/main",
            "BUILD_NUMBER": "123",
            "GIT_BRANCH": "origin/main",
            "GIT_COMMIT": "7d6c5b4a39281706f5e4d3c2b1a0f9e8d7c6b5a4",
        ])

        #expect(environment == CIEnvironment(
            system: .jenkins,
            branch: "main",
            commit: "7d6c5b4a39281706f5e4d3c2b1a0f9e8d7c6b5a4",
            buildNumber: 123,
            buildURL: URL(string: "https://jenkins.example.com/job/MyApp/job/main/123/"),
            jobName: "MyApp/main"
        ))
    }

    @Test func jenkinsMultibranchChangeRequest() {
        let environment = detect([
            "JENKINS_URL": "https://jenkins.example.com/",
            "BUILD_NUMBER": "124",
            "JOB_NAME": "MyApp/PR-45",
            "CHANGE_ID": "45",
            "CHANGE_BRANCH": "feature/z",
            "CHANGE_TARGET": "main",
            "CHANGE_URL": "https://github.com/example/myapp/pull/45",
            "BRANCH_NAME": "PR-45",
            "GIT_BRANCH": "origin/pr/45/head",
            "GIT_COMMIT": "7d6c5b4a39281706f5e4d3c2b1a0f9e8d7c6b5a4",
        ])

        #expect(environment.branch == "feature/z")
        #expect(environment.mergeRequest == MergeRequest(
            number: 45,
            sourceBranch: "feature/z",
            targetBranch: "main",
            url: URL(string: "https://github.com/example/myapp/pull/45")
        ))
    }

    @Test func jenkinsChangeRequestIgnoresBranchNameAndStripsOrigin() {
        let environment = detect([
            "JENKINS_URL": "https://jenkins.example.com/",
            "BUILD_NUMBER": "124",
            "CHANGE_ID": "45",
            "BRANCH_NAME": "PR-45",
            "GIT_BRANCH": "origin/pr/45/head",
        ])

        #expect(environment.branch == "pr/45/head")
    }

    @Test func jenkinsGitLabPluginMergeRequest() {
        let environment = detect([
            "JENKINS_URL": "https://jenkins.example.com/",
            "BUILD_NUMBER": "125",
            "gitlabActionType": "MERGE",
            "gitlabMergeRequestIid": "9",
            "gitlabSourceBranch": "feature/g",
            "gitlabTargetBranch": "main",
            "gitlabMergeRequestLastCommit": "aa11bb22cc33dd44ee55ff66aa77bb88cc99dd00",
            "gitlabAfter": "0011223344556677889900aabbccddeeff112233",
        ])

        #expect(environment.branch == "feature/g")
        #expect(environment.commit == "aa11bb22cc33dd44ee55ff66aa77bb88cc99dd00")
        #expect(environment.mergeRequest == MergeRequest(number: 9, sourceBranch: "feature/g", targetBranch: "main"))
    }

    @Test func jenkinsGitLabPluginPushIsNotAMergeRequest() {
        let environment = detect([
            "JENKINS_URL": "https://jenkins.example.com/",
            "BUILD_NUMBER": "126",
            "gitlabActionType": "PUSH",
            "gitlabMergeRequestIid": "9",
            "gitlabSourceBranch": "main",
            "gitlabAfter": "0011223344556677889900aabbccddeeff112233",
        ])

        #expect(environment.branch == "main")
        #expect(environment.commit == "0011223344556677889900aabbccddeeff112233")
        #expect(environment.mergeRequest == nil)
    }

    @Test func jenkinsTagBuild() {
        let environment = detect(["JENKINS_URL": "https://jenkins.example.com/", "TAG_NAME": "v1.0.0"])

        #expect(environment.system == .jenkins)
        #expect(environment.tag == "v1.0.0")
    }

    @Test func jenkinsWithoutJenkinsURLIsDetectedFromBuildVariables() {
        let environment = detect([
            "BUILD_URL": "https://jenkins.example.com/job/MyApp/main/123/",
            "JOB_NAME": "MyApp/main",
            "BUILD_NUMBER": "123",
        ])

        #expect(environment.system == .jenkins)
        #expect(environment.buildNumber == 123)
        #expect(environment.jobName == "MyApp/main")
    }

    @Test func jenkinsNeedsAllOfTheBuildVariablesWithoutJenkinsURL() {
        let environment = detect([
            "BUILD_URL": "https://jenkins.example.com/job/MyApp/main/123/",
            "BUILD_NUMBER": "123",
        ])

        #expect(environment.system == .local)
    }

    @Test func bitriseCLIVariablesInsideJenkinsAreJenkins() {
        let environment = detect([
            "JENKINS_URL": "https://jenkins.example.com/",
            "BUILD_URL": "https://jenkins.example.com/job/MyApp/main/4/",
            "JOB_NAME": "MyApp/main",
            "BUILD_NUMBER": "4",
            "ENVMAN_ENVSTORE_PATH": "/tmp/envman/envstore.yml",
            "BITRISE_DEPLOY_DIR": "/tmp/deploy",
        ])

        #expect(environment.system == .jenkins)
        #expect(environment.buildNumber == 4)
    }

    @Test func bitriseCLIOnADeveloperMacIsLocal() {
        let environment = detect([
            "ENVMAN_ENVSTORE_PATH": "/tmp/envman/envstore.yml",
            "BITRISE_DEPLOY_DIR": "/tmp/deploy",
        ])

        #expect(environment == CIEnvironment(system: .local))
    }

    @Test func genericCIWithCIVariable() {
        for value in ["true", "1"] {
            let environment = detect(["CI": value])

            #expect(environment == CIEnvironment(system: .genericCI))
            #expect(environment.isCI)
        }
    }

    @Test func localRunHasNoBuildInformation() {
        let environment = detect(["CI": "false", "HOME": "/Users/example"])

        #expect(environment == CIEnvironment(system: .local))
        #expect(!environment.isCI)
    }

    @Test func emptyVariablesAreUnset() {
        let environment = detect([
            "GITHUB_ACTIONS": "",
            "CI": "",
            "JENKINS_URL": "",
        ])

        #expect(environment == CIEnvironment(system: .local))
    }

    @Test func emptyBranchFallsBackToTheNextVariable() {
        let environment = detect([
            "JENKINS_URL": "https://jenkins.example.com/",
            "BUILD_NUMBER": "127",
            "CHANGE_BRANCH": "",
            "gitlabSourceBranch": "",
            "GIT_BRANCH": "origin/main",
            "TAG_NAME": "",
        ])

        #expect(environment.branch == "main")
        #expect(environment.tag == nil)
    }

    @Test func gitBranchThatIsOnlyTheOriginPrefixIsNil() {
        let environment = detect(["JENKINS_URL": "https://jenkins.example.com/", "GIT_BRANCH": "origin/"])

        #expect(environment.branch == nil)
    }

    @Test func malformedNumbersAreNil() {
        let jenkins = detect([
            "JENKINS_URL": "https://jenkins.example.com/",
            "BUILD_NUMBER": "12x",
            "CHANGE_ID": "pr-45",
        ])
        #expect(jenkins.buildNumber == nil)
        #expect(jenkins.mergeRequest == nil)

        let gitLab = detect(["GITLAB_CI": "true", "CI_PIPELINE_IID": "", "CI_MERGE_REQUEST_IID": "five"])
        #expect(gitLab.buildNumber == nil)
        #expect(gitLab.mergeRequest == nil)

        let github = detect(githubBase.merging(["GITHUB_RUN_NUMBER": "seven"]) { $1 })
        #expect(github.buildNumber == nil)
    }

    @Test func emptyURLsAreNil() {
        let environment = detect(["GITLAB_CI": "true", "CI_JOB_URL": "", "CI_MERGE_REQUEST_IID": "5"])

        #expect(environment.buildURL == nil)
        #expect(environment.mergeRequest?.url == nil)
    }

    @Test func malformedOrMissingEventFileGivesNoPullRequest() throws {
        let malformed = try writeFixture("{ not json")
        defer { removeFixture(malformed) }
        let withoutNumber = try writeFixture(#"{"pull_request": {"title": "x"}}"#)
        defer { removeFixture(withoutNumber) }
        let base = githubBase.merging(["GITHUB_REF": "refs/heads/main", "GITHUB_REF_TYPE": "branch"]) { $1 }

        #expect(detect(base.merging(["GITHUB_EVENT_PATH": malformed]) { $1 }).mergeRequest == nil)
        #expect(detect(base.merging(["GITHUB_EVENT_PATH": withoutNumber]) { $1 }).mergeRequest == nil)
        #expect(detect(base.merging(["GITHUB_EVENT_PATH": "/no/such/event.json"]) { $1 }).mergeRequest == nil)
        #expect(detect(base).mergeRequest == nil)
    }

    @Test func registeredAdapterWinsOverBuiltIns() {
        let azure = VariableAdapter(variable: "AZURE_PIPELINES", system: CISystem(id: "azure-pipelines", name: "Azure Pipelines"))
        let environment = detect(
            ["AZURE_PIPELINES": "True", "GITHUB_ACTIONS": "true", "CI": "true"],
            adapters: [azure]
        )

        #expect(environment.system == CISystem(id: "azure-pipelines", name: "Azure Pipelines"))
    }

    @Test func adapterThatDoesNotMatchLeavesDetectionToBuiltIns() {
        let azure = VariableAdapter(variable: "AZURE_PIPELINES", system: CISystem(id: "azure-pipelines", name: "Azure Pipelines"))
        let environment = detect(["GITHUB_ACTIONS": "true"], adapters: [azure])

        #expect(environment.system == .gitHubActions)
    }

    @Test func firstRegisteredAdapterThatAnswersWins() {
        let first = VariableAdapter(variable: "BUILD_FARM", system: CISystem(id: "first", name: "First"))
        let second = VariableAdapter(variable: "BUILD_FARM", system: CISystem(id: "second", name: "Second"))

        #expect(detect(["BUILD_FARM": "1"], adapters: [first, second]).system.id == "first")
    }

    @Test func summaryNamesOnlyTheFieldsThatAreSet() {
        let environment = CIEnvironment(system: .jenkins, branch: "main", buildNumber: 123)
        #expect(CIDetection.summary(environment) == "CI: Jenkins, build 123, branch main")

        let merge = CIEnvironment(
            system: .gitHubActions,
            branch: "feature/x",
            mergeRequest: MergeRequest(number: 12),
            buildNumber: 7
        )
        #expect(CIDetection.summary(merge) == "CI: GitHub Actions, build 7, branch feature/x, merge request !12")

        #expect(CIDetection.summary(CIEnvironment(system: .local)) == "CI: Local")
    }

    private func detect(_ variables: [String: String], adapters: [any CIAdapter] = []) -> CIEnvironment {
        CIDetection.detect(variables: variables, adapters: adapters)
    }

    private func writeFixture(_ contents: String) throws -> String {
        let folder = FileManager.default.temporaryDirectory.appending(path: "swift-ci-tests", directoryHint: .isDirectory)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: "event.json")
        try contents.write(to: file, atomically: true, encoding: .utf8)
        return file.filePath
    }

    private func removeFixture(_ path: String) {
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: path).deletingLastPathComponent())
    }
}

/// An adapter for a test CI system that sets one variable.
private struct VariableAdapter: CIAdapter {
    let variable: String
    let system: CISystem

    func environment(from variables: [String: String]) -> CIEnvironment? {
        variables[variable] == nil ? nil : CIEnvironment(system: system)
    }
}

extension GlobalStateTests {
    /// The CI environment inside a run: `CI.environment`, the full log line and the restore of the state.
    @Suite(.serialized) struct CIEnvironmentRunTests {
        @Test func commandReadsTheDetectedEnvironment() async {
            var seen: CIEnvironment?
            let result = await SwiftCITest.run(
                ["build"],
                environment: ["GITHUB_ACTIONS": "true", "GITHUB_REF_TYPE": "branch", "GITHUB_REF_NAME": "main"],
                artifactsDirectory: temporaryArtifactsDirectory()
            ) {
                command(Command("build") {
                    seen = CI.environment
                    try await step("Work") { }
                })
            }

            #expect(result.exitCode == 0)
            #expect(seen?.system == .gitHubActions)
            #expect(seen?.branch == "main")
            #expect(CIState.current == nil)
        }

        @Test func registeredAdapterWinsInTheRun() async {
            var seen: CIEnvironment?
            let azure = VariableAdapter(variable: "AZURE_PIPELINES", system: CISystem(id: "azure-pipelines", name: "Azure Pipelines"))
            _ = await SwiftCITest.run(
                ["build"],
                environment: ["AZURE_PIPELINES": "True", "CI": "true"],
                artifactsDirectory: temporaryArtifactsDirectory(),
                ciAdapters: [azure]
            ) {
                command(Command("build") {
                    seen = CI.environment
                })
            }

            #expect(seen?.system.id == "azure-pipelines")
        }

        @Test func fullLogRecordsTheCISummary() async throws {
            let root = FileManager.default.temporaryDirectory.appending(path: "swift-ci-tests", directoryHint: .isDirectory)
                .appending(path: UUID().uuidString, directoryHint: .isDirectory)
            defer { try? FileManager.default.removeItem(at: root) }
            let artifacts = root.appending(path: "artifacts", directoryHint: .isDirectory)

            let result = await SwiftCITest.run(
                ["build"],
                environment: [
                    "JENKINS_URL": "https://jenkins.example.com/",
                    "BUILD_NUMBER": "123",
                    "GIT_BRANCH": "origin/main",
                ],
                artifactsDirectory: artifacts
            ) {
                command(Command("build") {
                    try await step("Work") { }
                })
            }

            let log = try String(contentsOf: artifacts.appending(path: "logs/build.log"), encoding: .utf8)
            #expect(result.exitCode == 0)
            #expect(log.components(separatedBy: "\n").contains("CI: Jenkins, build 123, branch main"))
        }

        @Test func withMocksDetectsWithItsAdapters() async {
            let azure = VariableAdapter(variable: "AZURE_PIPELINES", system: CISystem(id: "azure-pipelines", name: "Azure Pipelines"))
            let seen = await SwiftCITest.withMocks(["AZURE_PIPELINES": "True"], ciAdapters: [azure]) {
                CI.environment.system
            }

            #expect(seen.id == "azure-pipelines")
            #expect(CIState.current == nil)
        }
    }
}
