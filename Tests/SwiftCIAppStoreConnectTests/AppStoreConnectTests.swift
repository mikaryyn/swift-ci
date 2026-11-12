#if os(macOS)
@testable import SwiftCI
@testable import SwiftCIAppStoreConnect
@testable import SwiftCITestSupport
import CryptoKit
import Foundation
import SwiftCITesting
import Testing

extension GlobalStateTests {
    /// The client: the bearer token, the retries and their waits, the error messages, decoding and pagination. The HTTP
    /// client is a mock and the waits are recorded, so no request leaves the test and nothing waits.
    @Suite(.serialized) struct AppStoreConnectTests {
        static let keyID = "TESTKEY123"

        /// The URL of `path` under the App Store Connect base URL, written out in full.
        static func url(_ path: String) -> URL {
            URL(string: "https://api.appstoreconnect.apple.com" + path)!
        }

        /// An API key with a new P-256 key, as the PEM text of a `.p8` file.
        static func apiKey() -> AppStoreConnectAPIKey {
            AppStoreConnectAPIKey(
                keyID: keyID,
                issuerID: Secret(value: "issuer-test-1234"),
                privateKey: Secret(value: P256.Signing.PrivateKey().pemRepresentation)
            )
        }

        /// Records the waits of a client, in order.
        final class SleepRecorder {
            var durations: [Duration] = []
        }

        /// A client whose waits are recorded in `sleeps` instead of taken.
        static func client(sleeps: SleepRecorder) -> AppStoreConnect {
            var appStoreConnect = AppStoreConnect(apiKey: apiKey())
            appStoreConnect.sleep = { sleeps.durations.append($0) }
            return appStoreConnect
        }

        /// The token of a recorded request, without the `Bearer ` prefix. It fails if the request has no bearer token.
        static func token(of request: HTTPClientMock.RecordedRequest) throws -> String {
            let authorization = try #require(request.secretHeaders["Authorization"])
            let value = try authorization.revealedValue()
            #expect(value.hasPrefix("Bearer "))
            return String(value.dropFirst("Bearer ".count))
        }

        /// The error body that Apple sends for request errors, with one entry per tuple.
        static func appleErrors(_ entries: [(code: String, title: String, detail: String)]) throws -> Data {
            let errors = entries.map { entry in
                ["status": "422", "code": entry.code, "title": entry.title, "detail": entry.detail]
            }
            return try JSONSerialization.data(withJSONObject: ["errors": errors])
        }

        /// The token is sent as a secret header with a `Bearer ` JWT. The request has no plain `Authorization` header.
        @Test func authorizationIsASecretBearerToken() async throws {
            let restore = isolatedGlobalState()
            defer { restore() }
            let client = HTTPClientMock()
            client.respond("GET", Self.url("/v1/apps/1"), body: Data("{}".utf8))
            let sleeps = SleepRecorder()

            _ = try await SwiftCITest.withMocks(httpClient: client) {
                try await Self.client(sleeps: sleeps).send("GET", "/v1/apps/1")
            }

            let request = try #require(client.requests.first)
            #expect(request.headers["Authorization"] == nil)
            #expect(request.headers["Accept"] == "application/json")
            #expect(request.headers["Content-Type"] == nil)
            let token = try Self.token(of: request)
            #expect(token.split(separator: ".").count == 3)
        }

        /// A 401 says the key was rejected and names the three things to check, and it does not show the token.
        @Test func unauthorizedSaysTheKeyWasRejected() async throws {
            let restore = isolatedGlobalState()
            defer { restore() }
            let client = HTTPClientMock()
            client.respond("GET", Self.url("/v1/apps/1"), status: 401, body: Data(#"{"errors":[{"status":"401","code":"NOT_AUTHORIZED","title":"Authentication failed"}]}"#.utf8))
            let sleeps = SleepRecorder()

            let error = await SwiftCITest.withMocks(httpClient: client) {
                await thrownError {
                    _ = try await Self.client(sleeps: sleeps).send("GET", "/v1/apps/1")
                }
            }

            let message = try #require(error?.message)
            #expect(message.contains("rejected the API key for GET /v1/apps/1 (401)"))
            #expect(message.contains("key ID"))
            #expect(message.contains("issuer ID"))
            #expect(message.contains("key file"))
            #expect(message.contains("NOT_AUTHORIZED: Authentication failed"))
            let token = try Self.token(of: client.requests[0])
            #expect(!message.contains(token))
            #expect(sleeps.durations.isEmpty)
        }

        /// A 403 names the request and the roles that the key needs.
        @Test func forbiddenNamesTheRequestAndTheRole() async {
            let client = HTTPClientMock()
            client.respond("GET", Self.url("/v1/apps/1"), status: 403, body: Data())

            let error = await SwiftCITest.withMocks(httpClient: client) {
                await thrownError {
                    _ = try await Self.client(sleeps: SleepRecorder()).send("GET", "/v1/apps/1")
                }
            }

            #expect(error?.message == "The API key lacks the role for GET /v1/apps/1 (403). The key needs one of the roles Account Holder, Admin, App Manager or Developer.")
        }

        /// A 422 with two Apple errors shows both, each with its code, title and detail.
        @Test func unprocessableEntityShowsEveryAppleError() async throws {
            let client = HTTPClientMock()
            client.respond(
                "POST",
                Self.url("/v1/buildUploads"),
                status: 422,
                body: try Self.appleErrors([
                    (code: "ENTITY_ERROR.ATTRIBUTE.INVALID", title: "An attribute value is invalid", detail: "The version is not valid."),
                    (code: "PARAMETER_ERROR", title: "Parameter error", detail: "The build number is missing"),
                ])
            )

            let error = await SwiftCITest.withMocks(httpClient: client) {
                await thrownError {
                    _ = try await Self.client(sleeps: SleepRecorder()).send("POST", "/v1/buildUploads", body: Data("{}".utf8))
                }
            }

            #expect(error?.message == "App Store Connect request POST /v1/buildUploads failed with status 422. Apple says: ENTITY_ERROR.ATTRIBUTE.INVALID: An attribute value is invalid — The version is not valid.; PARAMETER_ERROR: Parameter error — The build number is missing.")
        }

        /// A 429 is retried once after one second, and the second attempt succeeds.
        @Test func rateLimitIsRetriedAfterOneSecond() async throws {
            let restore = isolatedGlobalState()
            defer { restore() }
            let client = HTTPClientMock()
            client.respond("GET", Self.url("/v1/apps/1"), status: 429)
            client.respond("GET", Self.url("/v1/apps/1"), body: Data("{}".utf8))
            let sleeps = SleepRecorder()
            let log = LogMock()

            _ = try await SwiftCITest.withMocks(httpClient: client, log: log) {
                try await Self.client(sleeps: sleeps).send("GET", "/v1/apps/1")
            }

            #expect(client.requests.count == 2)
            #expect(sleeps.durations == [.seconds(1)])
            #expect(log.loggedLines.contains("App Store Connect: GET /v1/apps/1 retry 1 of 5 in 1 s after status 429."))
        }

        /// Six 429 responses in a row fail after five retries, which wait 1, 2, 4, 8 and 16 seconds. The sixth attempt is
        /// not retried.
        @Test func rateLimitFailsAfterFiveRetries() async {
            let client = HTTPClientMock()
            for _ in 0..<6 {
                client.respond("GET", Self.url("/v1/apps/1"), status: 429)
            }
            let sleeps = SleepRecorder()

            let error = await SwiftCITest.withMocks(httpClient: client) {
                await thrownError {
                    _ = try await Self.client(sleeps: sleeps).send("GET", "/v1/apps/1")
                }
            }

            #expect(error?.message.hasPrefix("App Store Connect rate limit reached for GET /v1/apps/1") == true)
            #expect(client.requests.count == 6)
            #expect(sleeps.durations == [.seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(16)])
        }

        /// Two 503 responses are retried after 2 and 4 seconds, and the third attempt succeeds.
        @Test func serviceUnavailableIsRetriedThenSucceeds() async throws {
            let restore = isolatedGlobalState()
            defer { restore() }
            let client = HTTPClientMock()
            client.respond("GET", Self.url("/v1/apps/1"), status: 503)
            client.respond("GET", Self.url("/v1/apps/1"), status: 503)
            client.respond("GET", Self.url("/v1/apps/1"), body: Data("{}".utf8))
            let sleeps = SleepRecorder()

            let response = try await SwiftCITest.withMocks(httpClient: client) {
                try await Self.client(sleeps: sleeps).send("GET", "/v1/apps/1")
            }

            #expect(response.statusCode == 200)
            #expect(client.requests.count == 3)
            #expect(sleeps.durations == [.seconds(2), .seconds(4)])
        }

        /// A 500 that repeats fails after three retries, which wait 2, 4 and 8 seconds, and the message shows the status.
        @Test func internalServerErrorFailsAfterThreeRetries() async {
            let client = HTTPClientMock()
            for _ in 0..<4 {
                client.respond("GET", Self.url("/v1/apps/1"), status: 500)
            }
            let sleeps = SleepRecorder()

            let error = await SwiftCITest.withMocks(httpClient: client) {
                await thrownError {
                    _ = try await Self.client(sleeps: sleeps).send("GET", "/v1/apps/1")
                }
            }

            #expect(error?.message == "App Store Connect request GET /v1/apps/1 failed with status 500.")
            #expect(client.requests.count == 4)
            #expect(sleeps.durations == [.seconds(2), .seconds(4), .seconds(8)])
        }

        /// A transport error is retried like a 5xx: after 2 seconds the next attempt succeeds.
        @Test func transportErrorIsRetriedThenSucceeds() async throws {
            let restore = isolatedGlobalState()
            defer { restore() }
            let client = HTTPClientMock()
            client.respond("GET", Self.url("/v1/apps/1"), error: BuildError(message: "The network connection was lost."))
            client.respond("GET", Self.url("/v1/apps/1"), body: Data("{}".utf8))
            let sleeps = SleepRecorder()

            let response = try await SwiftCITest.withMocks(httpClient: client) {
                try await Self.client(sleeps: sleeps).send("GET", "/v1/apps/1")
            }

            #expect(response.statusCode == 200)
            #expect(sleeps.durations == [.seconds(2)])
        }

        /// A `POST` is not retried after a 5xx, because the server may have created the resource: one request, no wait.
        @Test func postIsNotRetriedAfterAServerError() async {
            let client = HTTPClientMock()
            client.respond("POST", Self.url("/v1/buildUploads"), status: 503)
            let sleeps = SleepRecorder()

            let error = await SwiftCITest.withMocks(httpClient: client) {
                await thrownError {
                    _ = try await Self.client(sleeps: sleeps).send("POST", "/v1/buildUploads", body: Data("{}".utf8))
                }
            }

            #expect(error?.message == "App Store Connect request POST /v1/buildUploads failed with status 503.")
            #expect(client.requests.count == 1)
            #expect(sleeps.durations.isEmpty)
        }

        /// A `POST` is not retried after a transport error either, and the error is thrown as it is.
        @Test func postIsNotRetriedAfterATransportError() async {
            let client = HTTPClientMock()
            client.respond(
                "POST", Self.url("/v1/buildUploads"), error: BuildError(message: "The network connection was lost.")
            )
            let sleeps = SleepRecorder()

            let error = await SwiftCITest.withMocks(httpClient: client) {
                await thrownError {
                    _ = try await Self.client(sleeps: sleeps).send("POST", "/v1/buildUploads", body: Data("{}".utf8))
                }
            }

            #expect(error?.message == "The network connection was lost.")
            #expect(client.requests.count == 1)
            #expect(sleeps.durations.isEmpty)
        }

        /// A 429 means the request was not processed, so a `POST` is retried after it.
        @Test func postIsRetriedAfterARateLimit() async throws {
            let restore = isolatedGlobalState()
            defer { restore() }
            let client = HTTPClientMock()
            client.respond("POST", Self.url("/v1/buildUploads"), status: 429)
            client.respond("POST", Self.url("/v1/buildUploads"), body: Data("{}".utf8))
            let sleeps = SleepRecorder()

            let response = try await SwiftCITest.withMocks(httpClient: client) {
                try await Self.client(sleeps: sleeps).send("POST", "/v1/buildUploads", body: Data("{}".utf8))
            }

            #expect(response.statusCode == 200)
            #expect(sleeps.durations == [.seconds(1)])
        }

        /// A cancelled request is thrown as a `CancellationError` at once: no retry, no wait.
        @Test func cancellationIsNotRetried() async {
            let restore = isolatedGlobalState()
            defer { restore() }
            let client = HTTPClientMock()
            client.respond("GET", Self.url("/v1/apps/1"), error: CancellationError())
            let sleeps = SleepRecorder()

            var cancelled = false
            do {
                _ = try await SwiftCITest.withMocks(httpClient: client) {
                    try await Self.client(sleeps: sleeps).send("GET", "/v1/apps/1")
                }
            } catch is CancellationError {
                cancelled = true
            } catch {}

            #expect(cancelled)
            #expect(client.requests.count == 1)
            #expect(sleeps.durations.isEmpty)
        }

        /// A 404 names the request and shows Apple's details when the body has them.
        @Test func notFoundNamesTheRequestAndShowsAppleDetails() async throws {
            let client = HTTPClientMock()
            client.respond(
                "GET", Self.url("/v1/apps/1"), status: 404,
                body: try Self.appleErrors([(code: "NOT_FOUND", title: "The specified resource does not exist", detail: "There is no resource of type 'apps' with id '1'")])
            )

            let error = await SwiftCITest.withMocks(httpClient: client) {
                await thrownError {
                    _ = try await Self.client(sleeps: SleepRecorder()).send("GET", "/v1/apps/1")
                }
            }

            #expect(error?.message == "App Store Connect request GET /v1/apps/1 was not found (404). Apple says: NOT_FOUND: The specified resource does not exist — There is no resource of type 'apps' with id '1'.")
        }

        /// A 400 fails at once, without a retry or a wait.
        @Test func badRequestFailsWithoutRetry() async {
            let client = HTTPClientMock()
            client.respond("PATCH", Self.url("/v1/buildUploadFiles/9"), status: 400, body: Data())
            let sleeps = SleepRecorder()

            let error = await SwiftCITest.withMocks(httpClient: client) {
                await thrownError {
                    _ = try await Self.client(sleeps: sleeps).send("PATCH", "/v1/buildUploadFiles/9")
                }
            }

            #expect(error?.message == "App Store Connect request PATCH /v1/buildUploadFiles/9 failed with status 400.")
            #expect(client.requests.count == 1)
            #expect(sleeps.durations.isEmpty)
        }

        /// A decoding error names the field that does not match, and does not show the value in the body.
        @Test func decodingErrorNamesTheFieldNotTheBody() async {
            struct Resource: Decodable {
                let data: Item
                struct Item: Decodable {
                    let id: Int
                }
            }
            let client = HTTPClientMock()
            client.respond("GET", Self.url("/v1/apps/1"), body: Data(#"{"data":{"id":"secret-value-1234"}}"#.utf8))

            let error = await SwiftCITest.withMocks(httpClient: client) {
                await thrownError {
                    _ = try await Self.client(sleeps: SleepRecorder()).get("/v1/apps/1", as: Resource.self)
                }
            }

            #expect(error?.message == "The App Store Connect response to GET /v1/apps/1 is not the expected JSON (unexpected value at data.id). The API may have changed; report this with the log.")
            #expect(error?.message.contains("secret-value-1234") == false)
        }

        /// Two pages are read in order: the first with `limit=200`, the second from the `links.next` URL of the first.
        @Test func paginationFollowsLinksNext() async throws {
            struct Item: Decodable, Equatable {
                let id: String
            }
            let next = "https://api.appstoreconnect.apple.com/v1/apps/1/builds?cursor=abc&limit=200"
            let client = HTTPClientMock()
            client.respond(
                "GET",
                Self.url("/v1/apps/1/builds?filter%5BcfBundleVersion%5D=42&limit=200"),
                body: Data(#"{"data":[{"id":"a"}],"links":{"next":"\#(next)"}}"#.utf8)
            )
            client.respond("GET", URL(string: next)!, body: Data(#"{"data":[{"id":"b"}],"links":{}}"#.utf8))

            let items: [Item] = try await SwiftCITest.withMocks(httpClient: client) {
                try await Self.client(sleeps: SleepRecorder()).getAll(
                    "/v1/apps/1/builds", query: [URLQueryItem(name: "filter[cfBundleVersion]", value: "42")]
                )
            }

            #expect(items == [Item(id: "a"), Item(id: "b")])
            #expect(client.requests.map(\.url) == [
                Self.url("/v1/apps/1/builds?filter%5BcfBundleVersion%5D=42&limit=200"),
                URL(string: next)!,
            ])
        }

        /// A `links.next` URL on another host is not requested, so the token is not sent there.
        @Test func nextLinkOnAnotherHostIsRejected() async {
            struct Item: Decodable {
                let id: String
            }
            let client = HTTPClientMock()
            client.respond(
                "GET",
                Self.url("/v1/apps/1/builds?limit=200"),
                body: Data(#"{"data":[{"id":"a"}],"links":{"next":"https://evil.example.com/steal?x=1"}}"#.utf8)
            )

            let error = await SwiftCITest.withMocks(httpClient: client) {
                await thrownError {
                    let _: [Item] = try await Self.client(sleeps: SleepRecorder()).getAll("/v1/apps/1/builds", query: [])
                }
            }

            #expect(error?.message == "The App Store Connect link of GET /v1/apps/1/builds points to another server, so the request was not sent. Check that the response came from App Store Connect.")
            #expect(client.requests.count == 1)
            #expect(client.requests.allSatisfy { $0.url.host == "api.appstoreconnect.apple.com" })
        }

        /// Each request is logged once with its method, path and status, and never with its query. No log line or error
        /// message contains the token.
        @Test func logsOneLinePerRequestAndNeverTheToken() async throws {
            let restore = isolatedGlobalState()
            defer { restore() }
            let client = HTTPClientMock()
            client.respond("GET", Self.url("/v1/apps/1?fields%5Bapps%5D=bundleId"), body: Data("{}".utf8))
            client.respond("POST", Self.url("/v1/buildUploads"), status: 422, body: try Self.appleErrors([
                (code: "CODE", title: "Title", detail: "Detail"),
            ]))
            let log = LogMock()
            let sleeps = SleepRecorder()

            let error = try await SwiftCITest.withMocks(httpClient: client, log: log) {
                let appStoreConnect = Self.client(sleeps: sleeps)
                _ = try await appStoreConnect.send("GET", "/v1/apps/1", query: [URLQueryItem(name: "fields[apps]", value: "bundleId")])
                return await thrownError {
                    _ = try await appStoreConnect.send("POST", "/v1/buildUploads", body: Data("{}".utf8))
                }
            }

            let token = try Self.token(of: client.requests[0])
            #expect(log.loggedLines == [
                "App Store Connect: GET /v1/apps/1 -> 200",
                "App Store Connect: POST /v1/buildUploads -> 422",
            ])
            #expect(error?.message.contains(token) == false)
            #expect(!log.loggedLines.joined().contains(token))
            #expect(!log.loggedLines.joined().contains("fields"))
        }
    }
}
#endif
