@testable import SwiftCIGitLab
@testable import SwiftCITestSupport
import Foundation
@testable import SwiftCI
import SwiftCITesting
import Testing

extension GlobalStateTests {
    /// The comment of a report ID: which requests each combination of run and comment makes, the decisions of the dry run,
    /// the footer and the errors. The HTTP client is a mock, so no request leaves the test.
    @Suite(.serialized) struct MergeRequestCommentTests {
        static let apiURL = URL(string: "https://gitlab.example.com/api/v4")!
        static let token = "glpat-comment-token-5678"
        static let mergeRequest = GitLabMergeRequest(project: "group%2Fproject", iid: 5)
        nonisolated static let base = "/projects/group%2Fproject/merge_requests/5"

        /// The state of the comment on the merge request before the run.
        enum ExistingKind: Sendable {
            /// No note with the marker.
            case absent
            /// A plain note, which cannot be resolved.
            case plainNote
            /// A resolvable thread that is not resolved.
            case thread
            /// A resolvable thread that is resolved.
            case resolvedThread
        }

        /// One combination of run and comment, and the writes it makes. The reads come first in every row.
        struct Row: Sendable {
            let clean: Bool
            let behavior: CleanRunBehavior
            let existing: ExistingKind
            let writes: [String]
        }

        /// Every combination of clean or not, the three behaviours and the states of the comment. The writes are the
        /// requests in order, written as `METHOD path`.
        nonisolated static let rows: [Row] = [
            Row(clean: true, behavior: .deleteComment, existing: .absent, writes: []),
            Row(clean: true, behavior: .deleteComment, existing: .thread, writes: ["DELETE \(base)/notes/10"]),
            Row(clean: false, behavior: .deleteComment, existing: .absent, writes: ["POST \(base)/notes"]),
            Row(clean: false, behavior: .deleteComment, existing: .thread, writes: ["PUT \(base)/notes/10"]),
            Row(clean: true, behavior: .updateComment, existing: .absent, writes: []),
            Row(clean: true, behavior: .updateComment, existing: .thread, writes: ["PUT \(base)/notes/10"]),
            Row(clean: false, behavior: .updateComment, existing: .absent, writes: ["POST \(base)/notes"]),
            Row(clean: false, behavior: .updateComment, existing: .thread, writes: ["PUT \(base)/notes/10"]),
            Row(clean: true, behavior: .resolveThread, existing: .absent, writes: []),
            Row(clean: true, behavior: .resolveThread, existing: .thread, writes: [
                "PUT \(base)/notes/10",
                "PUT \(base)/discussions/d-thread",
            ]),
            Row(clean: true, behavior: .resolveThread, existing: .resolvedThread, writes: ["PUT \(base)/notes/10"]),
            Row(clean: false, behavior: .resolveThread, existing: .absent, writes: ["POST \(base)/discussions"]),
            Row(clean: false, behavior: .resolveThread, existing: .thread, writes: ["PUT \(base)/notes/10"]),
            Row(clean: false, behavior: .resolveThread, existing: .resolvedThread, writes: [
                "PUT \(base)/notes/10",
                "PUT \(base)/discussions/d-thread",
            ]),
            Row(clean: true, behavior: .resolveThread, existing: .plainNote, writes: ["DELETE \(base)/notes/10"]),
            Row(clean: false, behavior: .resolveThread, existing: .plainNote, writes: [
                "DELETE \(base)/notes/10",
                "POST \(base)/discussions",
            ]),
            Row(clean: true, behavior: .updateComment, existing: .plainNote, writes: ["PUT \(base)/notes/10"]),
            Row(clean: false, behavior: .deleteComment, existing: .plainNote, writes: ["PUT \(base)/notes/10"]),
        ]

        /// The requests of one call and the console of the call.
        struct Outcome {
            let requests: [HTTPClientMock.RecordedRequest]
            let log: LogMock
        }

        /// The URL of `path` under the test API base, written out in full.
        static func url(_ path: String) -> URL {
            URL(string: "https://gitlab.example.com/api/v4" + path)!
        }

        /// The marker line of the comment of `id`.
        static func marker(_ id: String = "tests") -> String {
            "<!-- swiftci-report-id: \(id) -->"
        }

        /// JSON data of a value that is made of dictionaries, arrays, strings, numbers and booleans.
        static func json(_ value: Any) -> Data {
            (try? JSONSerialization.data(withJSONObject: value)) ?? Data()
        }

        /// A note as the API returns it, with the fields the comment uses.
        static func note(_ id: Int, body: String, author: Int = 7, resolvable: Bool = true, resolved: Bool = false) -> [String: Any] {
            [
                "id": id,
                "body": body,
                "author": ["id": author, "username": "ci-bot"],
                "resolvable": resolvable,
                "resolved": resolved,
            ]
        }

        /// A discussion as the API returns it. A plain note is a discussion with `individual_note` set.
        static func discussion(_ id: String, _ notes: [[String: Any]], individual: Bool = false) -> [String: Any] {
            ["id": id, "individual_note": individual, "notes": notes]
        }

        /// The discussions that hold the comment of `id` in the given state, written by `author`.
        static func discussions(for existing: ExistingKind, id: String = "tests", author: Int = 7) -> [[String: Any]] {
            let text = "Old report\n\n\(marker(id))"
            switch existing {
            case .absent:
                return []
            case .plainNote:
                return [discussion("d-plain", [note(10, body: text, author: author, resolvable: false)], individual: true)]
            case .thread:
                return [discussion("d-thread", [note(10, body: text, author: author)])]
            case .resolvedThread:
                return [discussion("d-thread", [note(10, body: text, author: author, resolved: true)])]
            }
        }

        /// A report that is clean (no findings) or has one warning, which makes it not clean.
        static func report(clean: Bool) -> RunReport {
            RunReport(
                commandName: "tests",
                findings: clean ? [] : [ReportFinding(severity: .warning, text: "Slow test.")],
                outcome: .succeeded
            )
        }

        /// The mock client for a run: the user, one response per page of discussions, and the expected writes. A page
        /// names the next page in `X-Next-Page` unless it is the last. A write is `METHOD path`.
        static func client(base: String = Self.base, discussionPages: [[[String: Any]]], writes: [String]) -> HTTPClientMock {
            let client = HTTPClientMock()
            client.respond("GET", url("/user"), body: json(["id": 7, "username": "ci-bot"]))
            for (index, items) in discussionPages.enumerated() {
                let number = index + 1
                let next = number < discussionPages.count ? ["X-Next-Page": String(number + 1)] : [:]
                let pageQuery = number == 1 ? "" : "&page=\(number)"
                client.respond("GET", url("\(base)/discussions?per_page=100\(pageQuery)"), headers: next, body: json(items))
            }
            for write in writes {
                let parts = write.split(separator: " ", maxSplits: 1)
                client.respond(String(parts[0]), url(String(parts[1])), body: json([:]))
            }
            return client
        }

        /// Runs `updateComment` on the test merge request with the mock client, and returns the requests and the console.
        static func update(
            _ report: RunReport,
            on mergeRequest: GitLabMergeRequest = Self.mergeRequest,
            id: String = "tests",
            whenClean: CleanRunBehavior = .deleteComment,
            mode: CommentMode = .post,
            discussionPages: [[[String: Any]]] = [[]],
            writes: [String] = [],
            environment: [String: String] = [:]
        ) async throws -> Outcome {
            let base = "/projects/\(mergeRequest.project)/merge_requests/\(mergeRequest.iid)"
            let client = client(base: base, discussionPages: discussionPages, writes: writes)
            let log = LogMock()
            try await SwiftCITest.withMocks(environment, httpClient: client, log: log) {
                let gitLab = GitLab(apiURL: apiURL, token: Secret(value: token))
                try await gitLab.updateComment(
                    for: report,
                    id: id,
                    title: "Unit tests",
                    on: mergeRequest,
                    whenClean: whenClean,
                    mode: mode
                )
            }
            return Outcome(requests: client.requests, log: log)
        }

        /// The requests as `METHOD path`, with the query, without the API base.
        static func describe(_ requests: [HTTPClientMock.RecordedRequest]) -> [String] {
            requests.map { "\($0.method) \($0.url.absoluteString.replacingOccurrences(of: apiURL.absoluteString, with: ""))" }
        }

        /// The `body` text of a request that sends a JSON object.
        static func body(of request: HTTPClientMock.RecordedRequest) throws -> String {
            let data = try #require(request.body)
            let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            return try #require(object["body"] as? String)
        }

        /// The read requests that every call makes, before its writes.
        static let reads = ["GET /user", "GET \(base)/discussions?per_page=100"]

        /// The table: each combination makes the reads and then exactly the writes of the table.
        @Test(arguments: Self.rows) func commentFollowsTheRunAndTheComment(row: Row) async throws {
            let outcome = try await Self.update(
                Self.report(clean: row.clean),
                whenClean: row.behavior,
                discussionPages: [Self.discussions(for: row.existing)],
                writes: row.writes
            )

            #expect(Self.describe(outcome.requests) == Self.reads + row.writes)
        }

        /// The changes of a run are reported one completion line each, and a clean run without a comment says so.
        @Test func logsOneCompletionLinePerChange() async throws {
            let reopened = try await Self.update(
                Self.report(clean: false),
                whenClean: .resolveThread,
                discussionPages: [Self.discussions(for: .resolvedThread)],
                writes: ["PUT \(Self.base)/notes/10", "PUT \(Self.base)/discussions/d-thread"]
            )
            let nothing = try await Self.update(Self.report(clean: true))

            #expect(reopened.log.completions == [
                "Updated merge request comment tests",
                "Reopened merge request comment tests",
            ])
            #expect(nothing.log.completions == ["Nothing to do for merge request comment tests"])
        }

        /// The log names the merge request and the user of the token before the comment text, and a numeric project ID is
        /// shown as it is. A clean run without a comment logs the same line.
        @Test func logsTheMergeRequestAndUserForNumericProjectID() async throws {
            let outcome = try await Self.update(
                Self.report(clean: true),
                on: GitLabMergeRequest(project: "42", iid: 123),
                mode: .log
            )

            let line = "Merge request !123 of project 42, as @ci-bot"
            let lineIndex = try #require(outcome.log.loggedLines.firstIndex(of: line))
            let bodyIndex = try #require(outcome.log.loggedLines.firstIndex { $0.contains("## Unit tests") })
            #expect(lineIndex < bodyIndex)
            #expect(outcome.log.completions == ["Nothing to do for merge request comment tests"])
        }

        /// A project given as a URL-encoded path is shown decoded, in both modes.
        @Test(arguments: [CommentMode.post, .log]) func logsTheMergeRequestAndUserForPathProject(mode: CommentMode) async throws {
            let writes = mode == .post ? ["POST \(Self.base)/notes"] : []
            let outcome = try await Self.update(Self.report(clean: false), mode: mode, writes: writes)

            #expect(outcome.log.loggedLines.contains("Merge request !5 of project group/project, as @ci-bot"))
            #expect(Self.describe(outcome.requests) == Self.reads + writes)
        }

        /// The pages of the discussions are read in order until the comment is found on the second page.
        @Test func commentOnTheSecondPageIsFound() async throws {
            let otherThread = [Self.discussion("d-other", [Self.note(3, body: "Unrelated")])]
            let outcome = try await Self.update(
                Self.report(clean: true),
                whenClean: .updateComment,
                discussionPages: [otherThread, Self.discussions(for: .thread)],
                writes: ["PUT \(Self.base)/notes/10"]
            )

            #expect(Self.describe(outcome.requests) == [
                "GET /user",
                "GET \(Self.base)/discussions?per_page=100",
                "GET \(Self.base)/discussions?per_page=100&page=2",
                "PUT \(Self.base)/notes/10",
            ])
        }

        /// A note of another user that contains the marker is not the comment, so a new one is posted and the other is
        /// left as it is.
        @Test func notesOfOtherUsersAreNeverChanged() async throws {
            let outcome = try await Self.update(
                Self.report(clean: false),
                discussionPages: [Self.discussions(for: .thread, author: 8)],
                writes: ["POST \(Self.base)/notes"]
            )

            #expect(Self.describe(outcome.requests) == Self.reads + ["POST \(Self.base)/notes"])
        }

        /// The marker must be the whole line. The marker of `ab` does not match the report ID `a`.
        @Test func markerOfAnotherIDIsIgnored() async throws {
            let outcome = try await Self.update(
                Self.report(clean: false),
                id: "a",
                discussionPages: [Self.discussions(for: .thread, id: "ab")],
                writes: ["POST \(Self.base)/notes"]
            )

            #expect(Self.describe(outcome.requests) == Self.reads + ["POST \(Self.base)/notes"])
        }

        /// Each ID without the marker is rejected before any request, and the message says which characters are allowed.
        @Test(arguments: ["", "bad id", "a/b", "tests!", "ünï"]) func invalidIDThrowsBeforeAnyRequest(id: String) async throws {
            let client = HTTPClientMock()
            let log = LogMock()
            let error = await SwiftCITest.withMocks(httpClient: client, log: log) {
                await thrownError {
                    let gitLab = GitLab(apiURL: Self.apiURL, token: Secret(value: Self.token))
                    try await gitLab.updateComment(for: Self.report(clean: true), id: id, title: "Unit tests", on: Self.mergeRequest)
                }
            }

            #expect(error?.message.contains("is not valid") == true)
            #expect(error?.message.contains("letters, digits") == true)
            #expect(client.requests.isEmpty)
        }

        /// A rejected token gives a readable error. The error and the console never show the token.
        @Test func unauthorizedUserLookupNamesTheRequestWithoutTheToken() async {
            let client = HTTPClientMock()
            client.respond("GET", Self.url("/user"), status: 401, body: Self.json(["message": "401 Unauthorized"]))
            let log = LogMock()
            let error = await SwiftCITest.withMocks(httpClient: client, log: log) {
                await thrownError {
                    let gitLab = GitLab(apiURL: Self.apiURL, token: Secret(value: Self.token))
                    try await gitLab.updateComment(for: Self.report(clean: false), id: "tests", title: "Unit tests", on: Self.mergeRequest)
                }
            }

            #expect(error?.message == "GitLab API request GET /user failed with status 401. GitLab says: 401 Unauthorized. Check that the token is valid and has the api scope.")
            #expect(error?.message.contains(Self.token) == false)
            #expect(log.completions.joined().contains(Self.token) == false)
            #expect(client.requests.map(\.method) == ["GET"])
        }

        /// The token is sent as a secret header, and it is not in the recorded requests or the console of a run.
        @Test func tokenIsNotInTheRequestsOrTheLog() async throws {
            let outcome = try await Self.update(
                Self.report(clean: false),
                writes: ["POST \(Self.base)/notes"]
            )

            #expect(!String(reflecting: outcome.requests).contains(Self.token))
            #expect(!outcome.log.completions.joined().contains(Self.token))
            #expect(!outcome.log.titledLines.map(\.lines).joined().joined().contains(Self.token))
        }

        /// The dry run sends only the reads. It logs the rendered text, and the change it would make.
        @Test func dryRunSendsOnlyReadsAndLogsTheBodyAndTheChange() async throws {
            let outcome = try await Self.update(
                Self.report(clean: false),
                whenClean: .resolveThread,
                mode: .log,
                discussionPages: [Self.discussions(for: .resolvedThread)]
            )

            #expect(Self.describe(outcome.requests) == Self.reads)
            let logged = try #require(outcome.log.titledLines.first)
            #expect(logged.title == "Merge request comment tests")
            #expect(logged.lines.contains("## Unit tests passed"))
            #expect(logged.lines.contains("**Warnings**"))
            #expect(logged.lines.last(where: { !$0.isEmpty }) == Self.marker())
            #expect(outcome.log.completions == [
                "Would update comment for merge request comment tests",
                "Would reopen thread for merge request comment tests",
            ])
        }

        /// The dry run logs the same decision as a real run, without writes, for a clean run with nothing to change.
        @Test func dryRunOfCleanRunWithoutCommentLogsNothingToDo() async throws {
            let outcome = try await Self.update(Self.report(clean: true), mode: .log)

            #expect(Self.describe(outcome.requests) == Self.reads)
            #expect(outcome.log.completions == ["Nothing to do for merge request comment tests"])
        }

        /// The footer links the CI build and names the commit, and the marker is the last line of the posted text.
        @Test func footerLinksTheBuildAndEndsWithTheMarker() async throws {
            let outcome = try await Self.update(
                Self.report(clean: false),
                writes: ["POST \(Self.base)/notes"],
                environment: [
                    "GITLAB_CI": "true",
                    "CI_JOB_URL": "https://gitlab.example.com/group/project/-/jobs/12",
                    "CI_COMMIT_SHA": "0123456789abcdef0123456789abcdef01234567",
                ]
            )

            let text = try Self.body(of: try #require(outcome.requests.last))
            let lastLine = text.split(whereSeparator: \.isNewline).last.map(String.init)
            #expect(lastLine == Self.marker())
            #expect(text.contains("[CI build](https://gitlab.example.com/group/project/-/jobs/12), commit `0123456789abcdef0123456789abcdef01234567`"))
        }

        /// A footer without a known build or commit has only the marker.
        @Test func footerWithoutKnownBuildOrCommitHasOnlyTheMarker() async throws {
            let outcome = try await Self.update(Self.report(clean: false), writes: ["POST \(Self.base)/notes"])

            let text = try Self.body(of: try #require(outcome.requests.last))
            #expect(text.split(whereSeparator: \.isNewline).last.map(String.init) == Self.marker())
            #expect(!text.contains("CI build"))
            #expect(!text.contains("commit"))
        }

        /// Reopening and resolving send the thread state as a JSON body.
        @Test func threadStateIsSentAsJSON() async throws {
            let reopened = try await Self.update(
                Self.report(clean: false),
                whenClean: .resolveThread,
                discussionPages: [Self.discussions(for: .resolvedThread)],
                writes: ["PUT \(Self.base)/notes/10", "PUT \(Self.base)/discussions/d-thread"]
            )
            let resolved = try await Self.update(
                Self.report(clean: true),
                whenClean: .resolveThread,
                discussionPages: [Self.discussions(for: .thread)],
                writes: ["PUT \(Self.base)/notes/10", "PUT \(Self.base)/discussions/d-thread"]
            )

            let reopen = try #require(reopened.requests.last)
            let resolve = try #require(resolved.requests.last)
            #expect(reopen.method == "PUT")
            #expect(resolve.method == "PUT")
            #expect(try JSONSerialization.jsonObject(with: try #require(reopen.body)) as? [String: Bool] == ["resolved": false])
            #expect(try JSONSerialization.jsonObject(with: try #require(resolve.body)) as? [String: Bool] == ["resolved": true])
        }

        /// A plain note moves to a new thread, and the thread holds the whole report.
        @Test func plainNoteIsReplacedByAThreadWithTheReport() async throws {
            let outcome = try await Self.update(
                Self.report(clean: false),
                whenClean: .resolveThread,
                discussionPages: [Self.discussions(for: .plainNote)],
                writes: ["DELETE \(Self.base)/notes/10", "POST \(Self.base)/discussions"]
            )

            let post = try #require(outcome.requests.last)
            #expect(try Self.body(of: post).hasPrefix("## Unit tests passed"))
            #expect(try Self.body(of: post).split(whereSeparator: \.isNewline).last.map(String.init) == Self.marker())
        }

        /// The text posted for a sample report, exactly: the heading, the warnings table, and the footer with the build and
        /// the commit. The marker is its last line, and the text ends with one newline.
        @Test func postedBodyOfASampleReportIsExact() async throws {
            let report = RunReport(
                commandName: "tests",
                findings: [ReportFinding(severity: .warning, text: "Slow test.", file: "Tests/LoginTests.swift", line: 12)],
                outcome: .succeeded
            )
            let outcome = try await Self.update(
                report,
                writes: ["POST \(Self.base)/notes"],
                environment: [
                    "GITLAB_CI": "true",
                    "CI_JOB_URL": "https://gitlab.example.com/group/project/-/jobs/12",
                    "CI_COMMIT_SHA": "0123456789abcdef0123456789abcdef01234567",
                ]
            )

            #expect(try Self.body(of: try #require(outcome.requests.last)) == """
            ## Unit tests passed

            **Warnings**

            | Location | Message |
            | --- | --- |
            | `Tests/LoginTests.swift:12` | Slow test. |

            [CI build](https://gitlab.example.com/group/project/-/jobs/12), commit `0123456789abcdef0123456789abcdef01234567`
            <!-- swiftci-report-id: tests -->

            """)
        }
    }
}
