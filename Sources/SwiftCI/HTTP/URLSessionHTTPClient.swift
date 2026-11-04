import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The real HTTP client, built on `URLSession`. Registered in `registerDependencies()`.
///
/// Secret header values are revealed only while the `URLRequest` is built, so they are never held in a log or an error.
/// The `send(_:perform:)` overload takes the transport as a parameter, so tests can check the mapping of errors and
/// responses without opening a connection.
struct URLSessionHTTPClient: HTTPClient {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        try await Self.send(request) { try await URLSession.shared.data(for: $0) }
    }

    /// Builds the `URLRequest`, runs `perform` with it, and maps the result. A transport failure is thrown as a
    /// ``BuildError`` that names the method and the URL. A response that is not HTTP is also an error.
    ///
    /// - Parameters:
    ///   - request: The request to send.
    ///   - perform: The transport. `URLSession.data(for:)` in production.
    /// - Returns: The response with its status code, header fields and body.
    static func send(
        _ request: HTTPRequest,
        perform: (URLRequest) async throws -> (Data, URLResponse)
    ) async throws -> HTTPResponse {
        let urlRequest = try urlRequest(for: request)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await perform(urlRequest)
        } catch {
            throw transportError(request, error)
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw BuildError(message: "\(requestLabel(request)) got a response that is not HTTP. Check the URL of the server.")
        }
        return HTTPResponse(
            statusCode: httpResponse.statusCode,
            headers: headerFields(httpResponse),
            body: data
        )
    }

    /// Builds the `URLRequest` for `request`. Secret headers are revealed here, and set after the plain headers, so a
    /// secret wins if both give the same name. A secret that cannot be revealed throws its usage error, which names the
    /// environment variable and not the value.
    static func urlRequest(for request: HTTPRequest) throws -> URLRequest {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        for (name, secret) in request.secretHeaders {
            urlRequest.setValue(try secret.revealedValue(), forHTTPHeaderField: name)
        }
        urlRequest.httpBody = request.body
        return urlRequest
    }

    /// The error of a failed transport. It names the method and the URL without the query, and says what failed.
    static func transportError(_ request: HTTPRequest, _ error: Error) -> BuildError {
        BuildError(
            message: "\(requestLabel(request)) failed: \(error.localizedDescription). Check the network connection and the URL."
        )
    }

    /// The method and the URL of a request, as shown in messages.
    static func requestLabel(_ request: HTTPRequest) -> String {
        "HTTP \(request.method) \(loggableURL(request.url))"
    }

    /// The URL as text, without its user, password, query and fragment. Those parts can hold credentials or tokens.
    static func loggableURL(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return "(unparseable URL)"
        }
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        return components.string ?? "(unparseable URL)"
    }

    private static func headerFields(_ response: HTTPURLResponse) -> [String: String] {
        var headers: [String: String] = [:]
        for (name, value) in response.allHeaderFields {
            if let name = name as? String, let value = value as? String {
                headers[name] = value
            }
        }
        return headers
    }
}
