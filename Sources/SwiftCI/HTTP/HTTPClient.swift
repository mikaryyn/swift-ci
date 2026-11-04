import Foundation

/// An HTTP request. The core sends it with the registered ``HTTPClient``.
///
/// Header values in `secretHeaders` are sent but never written: the request does not log them, and error messages do
/// not show them. Give a secret as a ``Secret``, such as a token, rather than as a plain header.
public struct HTTPRequest: Sendable {
    /// The HTTP method, such as `GET` or `POST`.
    public var method: String
    /// The full URL, including the query. Errors show it without the query and fragment.
    public var url: URL
    /// The header fields, by name. Their values are not secret.
    public var headers: [String: String]
    /// Header fields whose values are secret, by name. They are sent with the request and masked everywhere else.
    public var secretHeaders: [String: Secret]
    /// The body, or `nil` for a request without one.
    public var body: Data?

    /// Creates a request. It is a `GET` without headers or a body by default.
    ///
    /// - Parameters:
    ///   - method: The HTTP method.
    ///   - url: The full URL.
    ///   - headers: The header fields that are not secret.
    ///   - secretHeaders: The header fields whose values are secret.
    ///   - body: The body, if the request has one.
    public init(
        method: String = "GET",
        url: URL,
        headers: [String: String] = [:],
        secretHeaders: [String: Secret] = [:],
        body: Data? = nil
    ) {
        self.method = method
        self.url = url
        self.headers = headers
        self.secretHeaders = secretHeaders
        self.body = body
    }
}

/// An HTTP response. Any status code is a response, so a `404` is not an error of the transport.
public struct HTTPResponse: Sendable {
    /// The HTTP status code, such as `200`.
    public var statusCode: Int
    /// The header fields of the response, by name.
    public var headers: [String: String]
    /// The body, or empty data if the response has none.
    public var body: Data

    /// Creates a response. It has no headers and an empty body by default.
    ///
    /// - Parameters:
    ///   - statusCode: The HTTP status code.
    ///   - headers: The header fields of the response.
    ///   - body: The body of the response.
    public init(statusCode: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }
}

/// Sends HTTP requests. Integrations get the registered client with `@Use var client: HTTPClient`. Tests replace it
/// with `HTTPClientMock` from `SwiftCITesting`.
///
/// Sending is a query, not a step: it opens no step and logs nothing. The caller logs what it needs. A transport failure,
/// such as no connection, is thrown as a ``BuildError`` that names the method and the URL without the query.
public protocol HTTPClient {
    /// Sends `request` and returns the response, whatever its status code.
    ///
    /// - Parameter request: The request to send.
    /// - Returns: The response of the server.
    /// - Throws: A ``BuildError`` if the request cannot be sent or no response arrives.
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
}
