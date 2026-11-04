@testable import SwiftCIGitLab
@testable import SwiftCITestSupport
import Foundation
@testable import SwiftCI
import SwiftCITesting
import Testing

extension GlobalStateTests {
    /// The convenience for scripts: a command posts its report from its `onReport` handler, in a merge request build,
    /// and skips the step outside one. The HTTP client is a mock, so no request leaves the test.
    @Suite(.serialized) struct ReportToMergeRequestTests {
        typealias Comment = MergeRequestCommentTests

        /// The project ID and IID of a GitLab CI merge request build, and the path that they make.
        static let gitLabCIEnvironment = [
            "GITLAB_CI": "true",
            "CI_PROJECT_ID": "42",
            "CI_MERGE_REQUEST_IID": "5",
        ]
        static let base = "/projects/42/merge_requests/5"

        /// A connection that uses the test token, as a script writes it.
        static func gitLab() -> GitLab {
            GitLab(apiURL: Comment.apiURL, token: Secret(value: Comment.token))
        }

        /// The script of the command: the convenience, then one step that adds a warning. A warning makes the report not
        /// clean, and the command still succeeds, so the handler posts the comment as a new note.
        static func runCommand(
            environment: [String: String],
            client: HTTPClientMock,
            mode: CommentMode = .post,
            whenClean: CleanRunBehavior = .deleteComment
        ) async -> SwiftCITestResult {
            await SwiftCITest.run(["test"], environment: environment, httpClient: client) {
                command(Command("test") {
                    postReportToMergeRequest(gitLab: gitLab(), id: "tests", title: "Unit tests", whenClean: whenClean, mode: mode)
                    try await step("Check") {
                        Report.warning("Slow test.")
                    }
                })
            }
        }

        /// In a GitLab CI merge request build, the comment is posted, and the token stays out of the console.
        @Test func postsInAGitLabCIMergeRequestBuild() async {
            let client = Comment.client(
                base: Self.base,
                discussionPages: [[]],
                writes: ["POST \(Self.base)/notes"]
            )

            let result = await Self.runCommand(environment: Self.gitLabCIEnvironment, client: client)

            #expect(result.exitCode == 0)
            #expect(Comment.describe(client.requests) == [
                "GET /user",
                "GET \(Self.base)/discussions?per_page=100",
                "POST \(Self.base)/notes",
            ])
            #expect(result.plainLog.contains { $0.contains("Created merge request comment tests") })
            #expect(!result.log.joined().contains(Comment.token))
        }

        /// A Jenkins GitLab plugin merge request build names the project and the IID with its own variables.
        @Test func postsInAJenkinsMergeRequestBuild() async {
            let client = Comment.client(
                base: Self.base,
                discussionPages: [[]],
                writes: ["POST \(Self.base)/notes"]
            )

            let result = await Self.runCommand(
                environment: [
                    "JENKINS_URL": "https://jenkins.example.com/",
                    "BUILD_NUMBER": "127",
                    "gitlabActionType": "MERGE",
                    "gitlabMergeRequestIid": "5",
                    "gitlabMergeRequestTargetProjectId": "42",
                ],
                client: client
            )

            #expect(result.exitCode == 0)
            #expect(Comment.describe(client.requests).last == "POST \(Self.base)/notes")
        }

        /// Outside a merge request build the step is skipped with the reason, and no request is made.
        @Test func skipsOutsideAMergeRequestBuild() async {
            let client = HTTPClientMock()

            let result = await Self.runCommand(environment: ["GITLAB_CI": "true", "CI_PROJECT_ID": "42"], client: client)

            #expect(result.exitCode == 0)
            #expect(client.requests.isEmpty)
            #expect(result.plainLog.contains { $0.contains("Update merge request comment tests") && $0.contains("not a merge request") })
        }

        /// A dry run sends only the reads and logs the rendered comment.
        @Test func dryRunInAMergeRequestBuildSendsOnlyReads() async {
            let client = Comment.client(base: Self.base, discussionPages: [[]], writes: [])

            let result = await Self.runCommand(environment: Self.gitLabCIEnvironment, client: client, mode: .log)

            #expect(result.exitCode == 0)
            #expect(Comment.describe(client.requests) == [
                "GET /user",
                "GET \(Self.base)/discussions?per_page=100",
            ])
            #expect(result.plainLog.contains { $0.contains("Would create comment for merge request comment tests") })
        }

        /// A rejected write fails the command, as a failing report handler does, and the error names the request.
        @Test func failedPostFailsTheCommand() async {
            let client = HTTPClientMock()
            client.respond("GET", Comment.url("/user"), body: Comment.json(["id": 7]))
            client.respond("GET", Comment.url("\(Self.base)/discussions?per_page=100"), body: Comment.json([]))
            client.respond("POST", Comment.url("\(Self.base)/notes"), status: 500, body: Comment.json(["message": "Something broke"]))

            let result = await Self.runCommand(environment: Self.gitLabCIEnvironment, client: client)

            #expect(result.exitCode == 1)
            #expect(result.plainLog.contains { $0.contains("GitLab API request POST \(Self.base)/notes failed with status 500") })
            #expect(!result.log.joined().contains(Comment.token))
        }
    }
}
