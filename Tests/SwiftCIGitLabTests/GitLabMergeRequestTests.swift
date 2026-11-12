@testable import SwiftCIGitLab
@testable import SwiftCITestSupport
import Foundation
import SwiftCI
import SwiftCITesting
import Testing

extension GlobalStateTests {
    /// The merge request of a run: the variables that name the project and the IID, and the repository URL forms.
    @Suite(.serialized) struct GitLabMergeRequestTests {
        /// GitLab CI names the project by ID and the merge request by IID.
        @Test func gitLabCIVariables() {
            let mergeRequest = GitLabMergeRequest.mergeRequest(from: [
                "CI_PROJECT_ID": "42",
                "CI_MERGE_REQUEST_IID": "5",
            ])

            #expect(mergeRequest == GitLabMergeRequest(project: "42", iid: 5))
        }

        /// A merge request pipeline names the project of the merge request, which is not the project of the pipeline when
        /// the merge request comes from a fork.
        @Test func mergeRequestProjectIDIsPreferredOverTheProjectOfThePipeline() {
            let mergeRequest = GitLabMergeRequest.mergeRequest(from: [
                "CI_MERGE_REQUEST_PROJECT_ID": "7",
                "CI_PROJECT_ID": "42",
                "CI_MERGE_REQUEST_IID": "5",
            ])

            #expect(mergeRequest == GitLabMergeRequest(project: "7", iid: 5))
        }

        /// The Jenkins GitLab plugin names the project by target project ID and the merge request by IID.
        @Test func jenkinsGitLabPluginVariables() {
            let mergeRequest = GitLabMergeRequest.mergeRequest(from: [
                "gitlabMergeRequestTargetProjectId": "77",
                "gitlabMergeRequestIid": "9",
            ])

            #expect(mergeRequest == GitLabMergeRequest(project: "77", iid: 9))
        }

        /// The project ID is preferred over the repository URL, and the GitLab CI IID over the Jenkins IID.
        @Test func projectIDAndIIDPreferTheirFirstSource() {
            let mergeRequest = GitLabMergeRequest.mergeRequest(from: [
                "CI_PROJECT_ID": "42",
                "gitlabMergeRequestTargetProjectId": "77",
                "gitlabTargetRepoHttpUrl": "https://gitlab.example.com/group/project.git",
                "CI_MERGE_REQUEST_IID": "5",
                "gitlabMergeRequestIid": "9",
            ])

            #expect(mergeRequest == GitLabMergeRequest(project: "42", iid: 5))
        }

        /// The project path from a repository URL, URL-encoded with `%2F`. The forms are HTTPS with and without `.git`,
        /// SSH with a port, and the scp form, which has no scheme.
        @Test(arguments: [
            ("https://gitlab.example.com/group/project.git", "group%2Fproject"),
            ("https://gitlab.example.com/group/project", "group%2Fproject"),
            ("https://gitlab.example.com/group/sub/project.git", "group%2Fsub%2Fproject"),
            ("https://user@gitlab.example.com/group/project.git/", "group%2Fproject"),
            ("ssh://git@gitlab.example.com:2222/group/project.git", "group%2Fproject"),
            ("git@gitlab.example.com:group/sub/project.git", "group%2Fsub%2Fproject"),
        ])
        func projectPathFromRepositoryURL(url: String, project: String) {
            #expect(GitLabMergeRequest.mergeRequest(from: ["gitlabTargetRepoHttpUrl": url, "CI_MERGE_REQUEST_IID": "5"])
                == GitLabMergeRequest(project: project, iid: 5))
            #expect(GitLabMergeRequest.mergeRequest(from: ["GIT_URL": url, "CI_MERGE_REQUEST_IID": "5"])
                == GitLabMergeRequest(project: project, iid: 5))
        }

        /// The SSH and the GIT_URL sources are used when the HTTP URL is not set. The first source with a path wins.
        @Test func repositoryURLSourcesAreTriedInOrder() {
            #expect(GitLabMergeRequest.mergeRequest(from: [
                "gitlabTargetRepoSshUrl": "git@gitlab.example.com:group/ssh.git",
                "GIT_URL": "https://gitlab.example.com/group/git.git",
                "CI_MERGE_REQUEST_IID": "5",
            ]) == GitLabMergeRequest(project: "group%2Fssh", iid: 5))
            #expect(GitLabMergeRequest.mergeRequest(from: [
                "gitlabTargetRepoHttpUrl": "https://gitlab.example.com",
                "GIT_URL": "https://gitlab.example.com/group/git.git",
                "CI_MERGE_REQUEST_IID": "5",
            ]) == GitLabMergeRequest(project: "group%2Fgit", iid: 5))
        }

        /// Empty values count as unset, so an empty project ID falls back to the next source.
        @Test func emptyValuesAreUnset() {
            let mergeRequest = GitLabMergeRequest.mergeRequest(from: [
                "CI_PROJECT_ID": "",
                "GIT_URL": "https://gitlab.example.com/group/project.git",
                "CI_MERGE_REQUEST_IID": "",
                "gitlabMergeRequestIid": "9",
            ])

            #expect(mergeRequest == GitLabMergeRequest(project: "group%2Fproject", iid: 9))
        }

        /// No merge request: no IID, an IID that is not a number, or no project.
        @Test func nilWithoutIIDOrProject() {
            #expect(GitLabMergeRequest.mergeRequest(from: ["CI_PROJECT_ID": "42"]) == nil)
            #expect(GitLabMergeRequest.mergeRequest(from: ["CI_PROJECT_ID": "42", "CI_MERGE_REQUEST_IID": "five"]) == nil)
            #expect(GitLabMergeRequest.mergeRequest(from: ["CI_MERGE_REQUEST_IID": "5"]) == nil)
            #expect(GitLabMergeRequest.mergeRequest(from: [
                "gitlabTargetRepoHttpUrl": "https://gitlab.example.com/",
                "CI_MERGE_REQUEST_IID": "5",
            ]) == nil)
            #expect(GitLabMergeRequest.mergeRequest(from: [:]) == nil)
        }

        /// The convenience reads the IID from the CI environment and the project from the variables of the run.
        @Test func convenienceUsesTheCIEnvironmentAndTheProjectVariables() async {
            let mergeRequest = await SwiftCITest.withMocks([
                "GITLAB_CI": "true",
                "CI_PROJECT_ID": "42",
                "CI_MERGE_REQUEST_IID": "5",
            ]) {
                GitLabMergeRequest.mergeRequest()
            }

            #expect(mergeRequest == GitLabMergeRequest(project: "42", iid: 5))
        }

        /// A Jenkins GitLab plugin build with a merge request comment (the NOTE action) is a merge request.
        @Test func convenienceFindsAJenkinsNoteBuild() async {
            let mergeRequest = await SwiftCITest.withMocks([
                "JENKINS_URL": "https://jenkins.example.com/",
                "BUILD_NUMBER": "127",
                "gitlabActionType": "NOTE",
                "gitlabMergeRequestIid": "9",
                "gitlabMergeRequestTargetProjectId": "77",
            ]) {
                GitLabMergeRequest.mergeRequest()
            }

            #expect(mergeRequest == GitLabMergeRequest(project: "77", iid: 9))
        }

        /// The convenience is nil for a build that is not a merge request, and for a merge request without a project.
        @Test func convenienceIsNilOutsideAMergeRequestOrWithoutAProject() async {
            let pushBuild = await SwiftCITest.withMocks([
                "GITLAB_CI": "true",
                "CI_PROJECT_ID": "42",
            ]) {
                GitLabMergeRequest.mergeRequest()
            }
            let noProject = await SwiftCITest.withMocks([
                "GITLAB_CI": "true",
                "CI_MERGE_REQUEST_IID": "5",
            ]) {
                GitLabMergeRequest.mergeRequest()
            }
            let local = await SwiftCITest.withMocks([:]) {
                GitLabMergeRequest.mergeRequest()
            }

            #expect(pushBuild == nil)
            #expect(noProject == nil)
            #expect(local == nil)
        }
    }
}
