import Foundation
import SwiftCI

/// An HTTP client for tests. It sends no request. It returns the responses queued for each method and URL, and it records
/// every request it receives, with secret header values masked.
///
/// Queue responses with ``respond(_:_:status:headers:body:)`` or ``respond(_:_:error:)``. The responses for one method
/// and URL are used in the order they were queued, each once. A request with no queued response left is unexpected:
/// it is recorded, and ``send(_:)`` throws a ``BuildError`` that names the method and the URL without the query.
///
/// ```swift
/// let client = HTTPClientMock()
/// client.respond("GET", url, status: 200, body: Data("{}".utf8))
/// ```
///
/// Register it with ``SwiftCITest/run(_:environment:artifactsDirectory:ciAdapters:runner:httpClient:log:script:)`` or
/// ``SwiftCITest/withMocks(_:runner:httpClient:log:artifactsDirectory:ciAdapters:_:)``, and the code under test gets it
/// with `@Use var client: HTTPClient`.
public final class HTTPClientMock: HTTPClient {
    /// Every request received, in order, including the unexpected ones.
    public private(set) var requests: [RecordedRequest] = []

    private var queues: [Key: [Outcome]] = [:]

    /// Creates a client with no queued responses and no recorded requests.
    public init() {}

    /// Queues a response for the next request with `method` and `url`. The URL must match exactly, including the query.
    ///
    /// - Parameters:
    ///   - method: The HTTP method of the request, for example `"GET"`. The match is exact.
    ///   - url: The full URL of the request.
    ///   - status: The status code of the response.
    ///   - headers: The header fields of the response.
    ///   - body: The body of the response.
    public func respond(
        _ method: String,
        _ url: URL,
        status: Int = 200,
        headers: [String: String] = [:],
        body: Data = Data()
    ) {
        enqueue(method, url, .response(HTTPResponse(statusCode: status, headers: headers, body: body)))
    }

    /// Queues an error for the next request with `method` and `url`. ``send(_:)`` throws `error` as it is. To simulate a
    /// transport failure as the real client reports it, pass a ``BuildError`` that names the method and the URL.
    ///
    /// - Parameters:
    ///   - method: The HTTP method of the request. The match is exact.
    ///   - url: The full URL of the request.
    ///   - error: The error to throw.
    public func respond(_ method: String, _ url: URL, error: Error) {
        enqueue(method, url, .failure(error))
    }

    /// Records the request, then returns the next queued response for its method and URL, or throws the queued error.
    /// Throws a ``BuildError`` if none is left. Called by the SwiftCI code under test. Tests do not call it.
    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requests.append(RecordedRequest(request))
        let key = Key(method: request.method, url: request.url)
        guard let next = queues[key]?.first else {
            throw BuildError(
                message: "Unexpected HTTP request \(Self.label(request)): no response is queued for it. Queue one with HTTPClientMock.respond in the test."
            )
        }
        queues[key]?.removeFirst()
        switch next {
        case .response(let response):
            return response
        case .failure(let error):
            throw error
        }
    }

    private func enqueue(_ method: String, _ url: URL, _ outcome: Outcome) {
        queues[Key(method: method, url: url), default: []].append(outcome)
    }

    /// The method and the URL without the user, password, query and fragment, as the real client shows them.
    private static func label(_ request: HTTPRequest) -> String {
        guard var components = URLComponents(url: request.url, resolvingAgainstBaseURL: false) else {
            return "\(request.method) (unparseable URL)"
        }
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        return "\(request.method) \(components.string ?? "(unparseable URL)")"
    }

    /// A request that the mock received. Its secret header values are ``Secret`` values, which print as `••••••`, so
    /// the recorded request does not show them in the console or in a failure message.
    public struct RecordedRequest: Equatable, Sendable {
        /// The HTTP method.
        public let method: String
        /// The full URL, including the query.
        public let url: URL
        /// The header fields that are not secret.
        public let headers: [String: String]
        /// The header fields whose values are secret. Each value is a ``Secret``, which masks itself when printed.
        public let secretHeaders: [String: Secret]
        /// The body, or `nil` if the request had none.
        public let body: Data?

        init(_ request: HTTPRequest) {
            method = request.method
            url = request.url
            headers = request.headers
            secretHeaders = request.secretHeaders
            body = request.body
        }
    }

    private struct Key: Hashable {
        let method: String
        let url: URL
    }

    private enum Outcome {
        case response(HTTPResponse)
        case failure(Error)
    }
}
