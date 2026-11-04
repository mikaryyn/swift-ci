@testable import SwiftCI
@testable import SwiftCITestSupport
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SwiftCITesting
import Testing

extension GlobalStateTests {
    /// The HTTP types and the `URLSession` client. No test opens a connection: the client is driven with a stub transport,
    /// and the request it builds is checked before the transport is called.
    @Suite(.serialized) struct HTTPClientTests {
        private let url = URL(string: "https://example.com/api/items")!

        @Test func requestDefaultsToAGetWithoutHeadersOrBody() {
            let request = HTTPRequest(url: url)

            #expect(request.method == "GET")
            #expect(request.url == url)
            #expect(request.headers.isEmpty)
            #expect(request.secretHeaders.isEmpty)
            #expect(request.body == nil)
        }

        @Test func responseDefaultsToNoHeadersAndAnEmptyBody() {
            let response = HTTPResponse(statusCode: 204)

            #expect(response.statusCode == 204)
            #expect(response.headers.isEmpty)
            #expect(response.body.isEmpty)
        }

        @Test func urlRequestCarriesMethodPlainAndSecretHeadersAndBody() throws {
            let restore = secretsSetUp(["SWIFTCI_HTTP_TOKEN": "tok-VALUE-1"])
            defer { restore() }
            let request = HTTPRequest(
                method: "POST",
                url: url,
                headers: ["Accept": "application/json"],
                secretHeaders: ["PRIVATE-TOKEN": Secret("SWIFTCI_HTTP_TOKEN")],
                body: Data("{}".utf8)
            )

            let urlRequest = try URLSessionHTTPClient.urlRequest(for: request)

            #expect(urlRequest.url == url)
            #expect(urlRequest.httpMethod == "POST")
            #expect(urlRequest.value(forHTTPHeaderField: "Accept") == "application/json")
            #expect(urlRequest.value(forHTTPHeaderField: "PRIVATE-TOKEN") == "tok-VALUE-1")
            #expect(urlRequest.httpBody == Data("{}".utf8))
        }

        @Test func secretHeaderWinsOverPlainHeaderWithTheSameName() throws {
            let restore = secretsSetUp(["SWIFTCI_HTTP_TOKEN": "tok-VALUE-2"])
            defer { restore() }
            let request = HTTPRequest(
                url: url,
                headers: ["Authorization": "plain"],
                secretHeaders: ["Authorization": Secret("SWIFTCI_HTTP_TOKEN")]
            )

            let urlRequest = try URLSessionHTTPClient.urlRequest(for: request)

            #expect(urlRequest.value(forHTTPHeaderField: "Authorization") == "tok-VALUE-2")
        }

        @Test func missingSecretIsAUsageErrorThatNamesTheVariableOnly() async {
            let restore = secretsSetUp([:])
            defer { restore() }
            let request = HTTPRequest(url: url, secretHeaders: ["Authorization": Secret("SWIFTCI_HTTP_MISSING")])

            let error = await thrownError {
                _ = try URLSessionHTTPClient.urlRequest(for: request)
            }

            #expect(error?.code == .usage)
            #expect(error?.message.contains("SWIFTCI_HTTP_MISSING") == true)
        }

        @Test func transportFailureNamesMethodAndURLWithoutUserQueryOrFragment() async {
            let request = HTTPRequest(
                method: "DELETE",
                url: URL(string: "https://user:pw-VALUE@example.com/api/items/7?token=abc-VALUE#section")!
            )

            let error = await thrownError {
                _ = try await URLSessionHTTPClient.send(request) { _ in
                    throw URLError(.notConnectedToInternet)
                }
            }

            #expect(error?.code == .failure)
            #expect(error?.message == "HTTP DELETE https://example.com/api/items/7 failed: \(URLError(.notConnectedToInternet).localizedDescription). Check the network connection and the URL.")
        }

        @Test func responseKeepsStatusHeadersAndBodyOfAnyStatus() async throws {
            let response = try await URLSessionHTTPClient.send(HTTPRequest(url: url)) { urlRequest in
                let httpResponse = HTTPURLResponse(
                    url: urlRequest.url!,
                    statusCode: 404,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"]
                )!
                return (Data("{}".utf8), httpResponse)
            }

            #expect(response.statusCode == 404)
            #expect(response.headers["Content-Type"] == "application/json")
            #expect(response.body == Data("{}".utf8))
        }

        @Test func responseThatIsNotHTTPIsAFailure() async {
            let error = await thrownError {
                _ = try await URLSessionHTTPClient.send(HTTPRequest(url: url)) { urlRequest in
                    let response = URLResponse(url: urlRequest.url!, mimeType: nil, expectedContentLength: 0, textEncodingName: nil)
                    return (Data(), response)
                }
            }

            #expect(error?.message.hasPrefix("HTTP GET https://example.com/api/items got a response that is not HTTP.") == true)
        }

        @Test func registeredDefaultClientIsTheURLSessionClient() {
            let restore = secretsSetUp()
            defer { restore() }

            registerDependencies()
            @Use var client: HTTPClient

            #expect(client is URLSessionHTTPClient)
        }
    }
}
