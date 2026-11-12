@testable import SwiftCI
@testable import SwiftCIGitLab
@testable import SwiftCITestSupport
import Foundation
import SwiftCITesting
import Testing

extension GlobalStateTests {
    /// The connection: requests, the token as a secret header, errors and pagination. The HTTP client is a mock, so no
    /// request leaves the test.
    @Suite(.serialized) struct GitLabTests {
        static let apiURL = URL(string: "https://gitlab.example.com/api/v4")!
        static let token = "glpat-test-token-1234"

        /// The URL of `path` under the test API base, written out in full.
        static func url(_ path: String) -> URL {
            URL(string: "https://gitlab.example.com/api/v4" + path)!
        }

        /// The token is sent as a secret header: it is revealed only in the request, and it is not in the recorded
        /// request or its description.
        @Test func tokenIsSentAsASecretHeader() async throws {
            let client = HTTPClientMock()
            client.respond("GET", Self.url("/user"), body: Data("{}".utf8))

            try await SwiftCITest.withMocks(httpClient: client) {
                let gitLab = GitLab(apiURL: Self.apiURL, token: Secret(value: Self.token))
                _ = try await gitLab.send("GET", "/user")
            }

            let request = try #require(client.requests.first)
            #expect(request.headers["PRIVATE-TOKEN"] == nil)
            #expect(try request.secretHeaders["PRIVATE-TOKEN"]?.revealedValue() == Self.token)
            #expect(!"\(client.requests)".contains(Self.token))
            #expect(!String(reflecting: client.requests).contains(Self.token))
        }

        /// The request URL is the API base, the path and the query. A base with a trailing slash gives the same URL, and
        /// a project path keeps its `%2F`.
        @Test func urlIsBuiltFromTheAPIBaseWithPathAndQuery() async throws {
            let client = HTTPClientMock()
            let mergeRequests = "/projects/group%2Fproject/merge_requests"
            client.respond("GET", Self.url(mergeRequests + "?state=opened"), body: Data("[]".utf8))
            client.respond("GET", Self.url(mergeRequests + "?state=opened"), body: Data("[]".utf8))

            try await SwiftCITest.withMocks(httpClient: client) {
                let gitLab = GitLab(apiURL: Self.apiURL, token: Secret(value: Self.token))
                _ = try await gitLab.send("GET", mergeRequests, query: [URLQueryItem(name: "state", value: "opened")])
                let withSlash = GitLab(apiURL: URL(string: "https://gitlab.example.com/api/v4/")!, token: Secret(value: Self.token))
                _ = try await withSlash.send("GET", mergeRequests, query: [URLQueryItem(name: "state", value: "opened")])
            }

            #expect(client.requests.map(\.url) == [
                Self.url(mergeRequests + "?state=opened"),
                Self.url(mergeRequests + "?state=opened"),
            ])
            #expect(client.requests.map(\.method) == ["GET", "GET"])
        }

        /// A 401 with GitLab's string message: the error names the method, the path and the status, and shows the
        /// message. It has no query and no token.
        @Test func unauthorizedWithStringMessageNamesTheRequestAndNotTheToken() async {
            let client = HTTPClientMock()
            client.respond("GET", Self.url("/user?private=1"), status: 401, body: Data(#"{"message":"401 Unauthorized"}"#.utf8))

            let error = await SwiftCITest.withMocks(httpClient: client) {
                await thrownError {
                    let gitLab = GitLab(apiURL: Self.apiURL, token: Secret(value: Self.token))
                    _ = try await gitLab.send("GET", "/user", query: [URLQueryItem(name: "private", value: "1")])
                }
            }

            #expect(error?.message == "GitLab API request GET /user failed with status 401. GitLab says: 401 Unauthorized. Check that the token is valid and has the api scope.")
            #expect(error?.code == .failure)
            #expect(error?.message.contains(Self.token) == false)
        }

        /// A 404 with GitLab's object message (validation errors) shows the keys with their messages.
        @Test func notFoundWithObjectMessageShowsTheMessages() async {
            let client = HTTPClientMock()
            client.respond(
                "GET",
                Self.url("/projects/group%2Fproject/merge_requests/5"),
                status: 404,
                body: Data(#"{"message":{"base":["Merge request not found"],"title":["can't be blank"]}}"#.utf8)
            )

            let error = await SwiftCITest.withMocks(httpClient: client) {
                await thrownError {
                    let gitLab = GitLab(apiURL: Self.apiURL, token: Secret(value: Self.token))
                    _ = try await gitLab.send("GET", "/projects/group%2Fproject/merge_requests/5")
                }
            }

            #expect(error?.message == "GitLab API request GET /projects/group%2Fproject/merge_requests/5 failed with status 404. GitLab says: base: Merge request not found; title: can't be blank. Check the API URL and the project and merge request IDs.")
        }

        /// A 404 with a body that is not JSON has no GitLab message, so the error says only the request and the status.
        @Test func notFoundWithoutJSONBodyOmitsTheMessage() async {
            let client = HTTPClientMock()
            client.respond("GET", Self.url("/projects/42"), status: 404, body: Data("<html>Not Found</html>".utf8))

            let error = await SwiftCITest.withMocks(httpClient: client) {
                await thrownError {
                    let gitLab = GitLab(apiURL: Self.apiURL, token: Secret(value: Self.token))
                    _ = try await gitLab.send("GET", "/projects/42")
                }
            }

            #expect(error?.message == "GitLab API request GET /projects/42 failed with status 404. Check the API URL and the project and merge request IDs.")
        }

        /// A JSON body with an `error` field (no `message`) shows that field.
        @Test func errorFieldIsShownWhenThereIsNoMessage() async {
            let client = HTTPClientMock()
            client.respond("GET", Self.url("/user"), status: 403, body: Data(#"{"error":"insufficient_scope"}"#.utf8))

            let error = await SwiftCITest.withMocks(httpClient: client) {
                await thrownError {
                    let gitLab = GitLab(apiURL: Self.apiURL, token: Secret(value: Self.token))
                    _ = try await gitLab.send("GET", "/user")
                }
            }

            #expect(error?.message == "GitLab API request GET /user failed with status 403. GitLab says: insufficient_scope. Check that the token is valid and has the api scope.")
        }

        /// A decode failure names the request and the field, and does not show the value of the field.
        @Test func decodeFailureNamesTheFieldWithoutTheValue() async {
            struct Item: Decodable {
                let id: Int
            }
            let gitLab = GitLab(apiURL: Self.apiURL, token: Secret(value: Self.token))
            let wrongType = HTTPResponse(statusCode: 200, body: Data(#"{"id":"not a number"}"#.utf8))
            let notJSON = HTTPResponse(statusCode: 200, body: Data("not json".utf8))
            let missing = HTTPResponse(statusCode: 200, body: Data("{}".utf8))

            let typeError = await thrownError { _ = try gitLab.decode(Item.self, from: wrongType, "GET", "/user") }
            let jsonError = await thrownError { _ = try gitLab.decode(Item.self, from: notJSON, "GET", "/user") }
            let missingError = await thrownError { _ = try gitLab.decode(Item.self, from: missing, "GET", "/user") }

            #expect(typeError?.message.contains("GET /user is not the expected JSON (unexpected value at id)") == true)
            #expect(typeError?.message.contains("not a number") == false)
            #expect(jsonError?.message.contains("(unexpected JSON)") == true)
            #expect(missingError?.message.contains("(missing field id)") == true)
        }

        /// Pages are followed through `X-Next-Page`, whatever the case of the header name, and the items of all pages
        /// are returned in order. The second page asks for `page=2` with the same `per_page`.
        @Test func paginatedFollowsXNextPageInAnyCase() async throws {
            struct Item: Decodable, Equatable {
                let id: Int
            }
            let client = HTTPClientMock()
            let path = "/projects/group%2Fproject/merge_requests/5/discussions"
            client.respond("GET", Self.url(path + "?per_page=100"), headers: ["x-Next-Page": "2"], body: Data(#"[{"id":1},{"id":2}]"#.utf8))
            client.respond("GET", Self.url(path + "?per_page=100&page=2"), headers: ["X-NEXT-PAGE": ""], body: Data(#"[{"id":3}]"#.utf8))

            let items: [Item] = try await SwiftCITest.withMocks(httpClient: client) {
                let gitLab = GitLab(apiURL: Self.apiURL, token: Secret(value: Self.token))
                return try await gitLab.paginated(path)
            }

            #expect(items == [Item(id: 1), Item(id: 2), Item(id: 3)])
            #expect(client.requests.map(\.url) == [
                Self.url(path + "?per_page=100"),
                Self.url(path + "?per_page=100&page=2"),
            ])
        }

        /// A next page that is not after the current one ends the list, so a server that repeats a page cannot loop.
        @Test func paginatedStopsWhenTheNextPageIsNotAfterTheCurrentOne() async throws {
            struct Item: Decodable, Equatable {
                let id: Int
            }
            let client = HTTPClientMock()
            client.respond("GET", Self.url("/projects?per_page=100"), headers: ["X-Next-Page": "1"], body: Data(#"[{"id":1}]"#.utf8))

            let items: [Item] = try await SwiftCITest.withMocks(httpClient: client) {
                let gitLab = GitLab(apiURL: Self.apiURL, token: Secret(value: Self.token))
                return try await gitLab.paginated("/projects")
            }

            #expect(items == [Item(id: 1)])
            #expect(client.requests.count == 1)
        }

        /// Each request is logged with its method, its path and its status. The query and the token are not logged.
        @Test func requestIsLoggedWithMethodPathAndStatus() async throws {
            let client = HTTPClientMock()
            let log = LogMock()
            client.respond("GET", Self.url("/projects/group%2Fproject/merge_requests?state=opened"), body: Data("[]".utf8))
            client.respond("POST", Self.url("/projects/group%2Fproject/merge_requests/1/notes"), status: 201, body: Data("{}".utf8))

            try await SwiftCITest.withMocks(httpClient: client, log: log) {
                let gitLab = GitLab(apiURL: Self.apiURL, token: Secret(value: Self.token))
                _ = try await gitLab.send("GET", "/projects/group%2Fproject/merge_requests", query: [URLQueryItem(name: "state", value: "opened")])
                _ = try await gitLab.send("POST", "/projects/group%2Fproject/merge_requests/1/notes", body: Data("{}".utf8))
            }

            #expect(log.loggedLines == [
                "GitLab: GET /projects/group%2Fproject/merge_requests -> 200",
                "GitLab: POST /projects/group%2Fproject/merge_requests/1/notes -> 201",
            ])
            #expect(!log.loggedLines.contains { $0.contains(Self.token) || $0.contains("state=opened") })
        }

        /// A failed status is logged with its status, and the error still names it.
        @Test func failedStatusIsLoggedAndThrown() async throws {
            let client = HTTPClientMock()
            let log = LogMock()
            client.respond("GET", Self.url("/user"), status: 401, body: Data(#"{"message":"401 Unauthorized"}"#.utf8))

            let error = await SwiftCITest.withMocks(httpClient: client, log: log) {
                await thrownError {
                    let gitLab = GitLab(apiURL: Self.apiURL, token: Secret(value: Self.token))
                    _ = try await gitLab.send("GET", "/user")
                }
            }

            #expect(error?.message.contains("status 401") == true)
            #expect(log.loggedLines == ["GitLab: GET /user -> 401"])
        }

        /// A request with no response is logged as `no response`, and the transport error is thrown. A `POST` is not retried,
        /// so the first error is the last.
        @Test func requestWithNoResponseIsLogged() async throws {
            let client = HTTPClientMock()
            let log = LogMock()
            client.respond("POST", Self.url("/user"), error: BuildError(message: "SWIFTCI_TEST_TRANSPORT"))

            let error = await SwiftCITest.withMocks(httpClient: client, log: log) {
                await thrownError {
                    let gitLab = GitLab(apiURL: Self.apiURL, token: Secret(value: Self.token))
                    _ = try await gitLab.send("POST", "/user", body: Data("{}".utf8))
                }
            }

            #expect(error?.message == "SWIFTCI_TEST_TRANSPORT")
            #expect(log.loggedLines == ["GitLab: POST /user -> no response"])
        }

        /// Records the waits of a connection, in order.
        final class SleepRecorder {
            var durations: [Duration] = []
        }

        /// A connection whose waits are recorded in `sleeps` instead of taken.
        static func gitLab(sleeps: SleepRecorder) -> GitLab {
            var gitLab = GitLab(apiURL: apiURL, token: Secret(value: token))
            gitLab.sleep = { sleeps.durations.append($0) }
            return gitLab
        }

        /// Two 503 responses are retried after 2 and 4 seconds, and the third attempt succeeds. Each retry is logged
        /// before its wait.
        @Test func serviceUnavailableIsRetriedThenSucceeds() async throws {
            let client = HTTPClientMock()
            let log = LogMock()
            client.respond("GET", Self.url("/user"), status: 503)
            client.respond("GET", Self.url("/user"), status: 503)
            client.respond("GET", Self.url("/user"), body: Data("{}".utf8))
            let sleeps = SleepRecorder()

            let response = try await SwiftCITest.withMocks(httpClient: client, log: log) {
                try await Self.gitLab(sleeps: sleeps).send("GET", "/user")
            }

            #expect(response.statusCode == 200)
            #expect(client.requests.count == 3)
            #expect(sleeps.durations == [.seconds(2), .seconds(4)])
            #expect(log.loggedLines == [
                "GitLab: GET /user -> 503",
                "GitLab: GET /user retry 1 of 3 in 2 s after status 503.",
                "GitLab: GET /user -> 503",
                "GitLab: GET /user retry 2 of 3 in 4 s after status 503.",
                "GitLab: GET /user -> 200",
            ])
        }

        /// A 502 that repeats fails after three retries, which wait 2, 4 and 8 seconds, and the error shows the status.
        @Test func badGatewayFailsAfterThreeRetries() async {
            let client = HTTPClientMock()
            for _ in 0..<4 {
                client.respond("GET", Self.url("/user"), status: 502)
            }
            let sleeps = SleepRecorder()

            let error = await SwiftCITest.withMocks(httpClient: client) {
                await thrownError { _ = try await Self.gitLab(sleeps: sleeps).send("GET", "/user") }
            }

            #expect(error?.message.hasPrefix("GitLab API request GET /user failed with status 502") == true)
            #expect(client.requests.count == 4)
            #expect(sleeps.durations == [.seconds(2), .seconds(4), .seconds(8)])
        }

        /// A transport error is retried like a 5xx: after 2 seconds the next attempt succeeds.
        @Test func transportErrorIsRetriedThenSucceeds() async throws {
            let client = HTTPClientMock()
            client.respond("GET", Self.url("/user"), error: BuildError(message: "The network connection was lost."))
            client.respond("GET", Self.url("/user"), body: Data("{}".utf8))
            let sleeps = SleepRecorder()

            let response = try await SwiftCITest.withMocks(httpClient: client) {
                try await Self.gitLab(sleeps: sleeps).send("GET", "/user")
            }

            #expect(response.statusCode == 200)
            #expect(sleeps.durations == [.seconds(2)])
        }

        /// A 429 is retried for every method, a `POST` included, because the request was not processed.
        @Test func postIsRetriedAfterARateLimit() async throws {
            let client = HTTPClientMock()
            let path = "/projects/42/merge_requests/5/notes"
            client.respond("POST", Self.url(path), status: 429)
            client.respond("POST", Self.url(path), status: 201, body: Data("{}".utf8))
            let sleeps = SleepRecorder()

            let response = try await SwiftCITest.withMocks(httpClient: client) {
                try await Self.gitLab(sleeps: sleeps).send("POST", path, body: Data("{}".utf8))
            }

            #expect(response.statusCode == 201)
            #expect(sleeps.durations == [.seconds(2)])
        }

        /// A `POST` is not retried after a 5xx or a transport error, because the server may have created the note.
        @Test func postIsNotRetriedAfterAServerErrorOrATransportError() async {
            let client = HTTPClientMock()
            let path = "/projects/42/merge_requests/5/notes"
            client.respond("POST", Self.url(path), status: 503)
            client.respond("POST", Self.url(path), error: BuildError(message: "The network connection was lost."))
            let sleeps = SleepRecorder()

            let (statusError, transportError) = await SwiftCITest.withMocks(httpClient: client) {
                let statusError = await thrownError {
                    _ = try await Self.gitLab(sleeps: sleeps).send("POST", path, body: Data("{}".utf8))
                }
                let transportError = await thrownError {
                    _ = try await Self.gitLab(sleeps: sleeps).send("POST", path, body: Data("{}".utf8))
                }
                return (statusError, transportError)
            }

            #expect(statusError?.message.hasPrefix("GitLab API request POST \(path) failed with status 503") == true)
            #expect(transportError?.message == "The network connection was lost.")
            #expect(client.requests.count == 2)
            #expect(sleeps.durations.isEmpty)
        }

        /// A 404 fails at once, without a retry or a wait.
        @Test func notFoundIsNotRetried() async {
            let client = HTTPClientMock()
            client.respond("GET", Self.url("/user"), status: 404)
            let sleeps = SleepRecorder()

            let error = await SwiftCITest.withMocks(httpClient: client) {
                await thrownError { _ = try await Self.gitLab(sleeps: sleeps).send("GET", "/user") }
            }

            #expect(error?.message.hasPrefix("GitLab API request GET /user failed with status 404") == true)
            #expect(client.requests.count == 1)
            #expect(sleeps.durations.isEmpty)
        }

        /// A cancelled request is thrown as a `CancellationError`, and it is not logged as `no response`.
        @Test func cancelledRequestIsNotLoggedAsNoResponse() async {
            let client = HTTPClientMock()
            let log = LogMock()
            client.respond("GET", Self.url("/user"), error: CancellationError())

            var cancelled = false
            do {
                try await SwiftCITest.withMocks(httpClient: client, log: log) {
                    let gitLab = GitLab(apiURL: Self.apiURL, token: Secret(value: Self.token))
                    _ = try await gitLab.send("GET", "/user")
                }
            } catch is CancellationError {
                cancelled = true
            } catch {}

            #expect(cancelled)
            #expect(log.loggedLines.isEmpty)
        }
    }
}
