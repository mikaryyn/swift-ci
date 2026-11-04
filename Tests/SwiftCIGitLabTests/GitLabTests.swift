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
    }
}
