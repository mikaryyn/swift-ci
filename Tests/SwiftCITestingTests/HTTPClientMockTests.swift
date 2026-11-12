import Foundation
import SwiftCI
import SwiftCITesting
import Testing

/// The HTTP client mock as an extension author uses it, through the public API of `SwiftCI` and `SwiftCITesting`.
@Suite(.serialized) struct HTTPClientMockTests {
    private let items = URL(string: "https://api.example.com/items")!

    @Test func queuedResponsesForOneKeyAreServedInOrder() async throws {
        let client = HTTPClientMock()
        client.respond("GET", items, status: 200, body: Data("first".utf8))
        client.respond("GET", items, status: 201, body: Data("second".utf8))

        let first = try await client.send(HTTPRequest(url: items))
        let second = try await client.send(HTTPRequest(url: items))

        #expect(first.statusCode == 200)
        #expect(first.body == Data("first".utf8))
        #expect(second.statusCode == 201)
        #expect(second.body == Data("second".utf8))
    }

    @Test func responsesAreKeyedByMethodAndURL() async throws {
        let other = URL(string: "https://api.example.com/users")!
        let client = HTTPClientMock()
        client.respond("GET", items, body: Data("get-items".utf8))
        client.respond("POST", items, status: 201, body: Data("post-items".utf8))
        client.respond("GET", other, body: Data("get-users".utf8))

        let users = try await client.send(HTTPRequest(url: other))
        let post = try await client.send(HTTPRequest(method: "POST", url: items))
        let get = try await client.send(HTTPRequest(url: items))

        #expect(users.body == Data("get-users".utf8))
        #expect(post.statusCode == 201)
        #expect(get.body == Data("get-items".utf8))
    }

    @Test func aQueryIsPartOfTheKey() async throws {
        let paged = URL(string: "https://api.example.com/items?page=2")!
        let client = HTTPClientMock()
        client.respond("GET", paged, status: 200)

        await #expect(throws: BuildError.self) {
            _ = try await client.send(HTTPRequest(url: items))
        }
        let paginated = try await client.send(HTTPRequest(url: paged))
        #expect(paginated.statusCode == 200)
    }

    @Test func queuedErrorIsThrownOnceAndTheNextResponseFollows() async throws {
        let client = HTTPClientMock()
        client.respond("GET", items, error: BuildError(message: "offline"))
        client.respond("GET", items, status: 200)

        await #expect(throws: BuildError.self) {
            _ = try await client.send(HTTPRequest(url: items))
        }
        let next = try await client.send(HTTPRequest(url: items))
        #expect(next.statusCode == 200)
    }

    @Test func unexpectedRequestIsRecordedAndFailsNamingMethodAndURL() async throws {
        let client = HTTPClientMock()

        do {
            _ = try await client.send(HTTPRequest(method: "DELETE", url: URL(string: "https://api.example.com/items/7?token=abc")!))
            Issue.record("An unexpected request must throw.")
        } catch let error as BuildError {
            #expect(error.message.contains("DELETE https://api.example.com/items/7:"))
            #expect(!error.message.contains("token=abc"))
        }
        #expect(client.requests.map(\.method) == ["DELETE"])
    }

    @Test func unexpectedRequestMessageNamesMethodAndURLWithoutQuery() async {
        let client = HTTPClientMock()

        let result = await SwiftCITest.run(["delete"], httpClient: client) {
            command(Command("delete") {
                try await step("Delete") {
                    @Use var httpClient: HTTPClient
                    _ = try await httpClient.send(HTTPRequest(method: "DELETE", url: URL(string: "https://api.example.com/items/7?token=abc")!))
                }
            })
        }

        #expect(result.exitCode == 1)
        #expect(result.plainLog.contains("<Error> Unexpected HTTP request DELETE https://api.example.com/items/7: no response is queued for it. Queue one with HTTPClientMock.respond in the test."))
        #expect(!result.plainLog.contains { $0.contains("token=abc") })
    }

    @Test func recordedRequestsMaskSecretHeaders() async throws {
        let client = HTTPClientMock()
        client.respond("POST", items, status: 204)

        try await SwiftCITest.withMocks(["MYAPP_TOKEN": "s3cret-VALUE"], httpClient: client) {
            @Use var httpClient: HTTPClient
            _ = try await httpClient.send(HTTPRequest(
                method: "POST",
                url: items,
                headers: ["Accept": "application/json"],
                secretHeaders: ["PRIVATE-TOKEN": Secret("MYAPP_TOKEN")],
                body: Data("{}".utf8)
            ))
        }

        let recorded = try #require(client.requests.first)
        #expect(client.requests.count == 1)
        #expect(recorded.method == "POST")
        #expect(recorded.url == items)
        #expect(recorded.headers == ["Accept": "application/json"])
        #expect(recorded.body == Data("{}".utf8))
        let secret = try #require(recorded.secretHeaders["PRIVATE-TOKEN"])
        #expect("\(secret)" == "••••••")
        #expect(!String(describing: client.requests).contains("s3cret-VALUE"))
    }

    @Test func clientIsUsedByTheCommandAndSendingLogsNothing() async {
        let client = HTTPClientMock()
        client.respond("GET", items, body: Data("pong-BODY".utf8))

        let result = await SwiftCITest.run(["ping"], httpClient: client) {
            command(Command("ping") {
                try await step("Ping") {
                    @Use var httpClient: HTTPClient
                    let response = try await httpClient.send(HTTPRequest(url: items))
                    #expect(response.body == Data("pong-BODY".utf8))
                }
            })
        }

        #expect(result.exitCode == 0)
        #expect(client.requests.map(\.url) == [items])
        #expect(result.plainLog.filter { $0.contains("Entering step [") }.count == 1)
        #expect(!result.plainLog.contains { $0.contains("pong-BODY") })
    }

    @Test func transportErrorFailsTheCommandWithItsMessage() async {
        let client = HTTPClientMock()
        client.respond("GET", items, error: BuildError(message: "HTTP GET https://api.example.com/items failed: offline."))

        let result = await SwiftCITest.run(["fetch"], httpClient: client) {
            command(Command("fetch") {
                try await step("Fetch") {
                    @Use var httpClient: HTTPClient
                    _ = try await httpClient.send(HTTPRequest(url: items))
                }
            })
        }

        #expect(result.exitCode == 1)
        #expect(result.plainLog.contains("<Error> HTTP GET https://api.example.com/items failed: offline."))
    }
}
