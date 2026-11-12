import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The real HTTP client, built on `URLSession`. Registered in `registerDependencies()`.
///
/// It uses its own session, not `URLSession.shared`, so that responses are not cached and cookies are not kept between
/// requests. Redirects are followed, but a redirect to another origin (scheme, host or port) loses the secret headers
/// of the request, so a token is never sent to a host that the caller did not name. The other headers are kept.
/// Secret header values are revealed only while the `URLRequest` is built, so they are never held in a log or an error.
/// The `send(_:perform:)` overload takes the transport as a parameter, so tests can check the mapping of errors and
/// responses without opening a connection.
struct URLSessionHTTPClient: HTTPClient {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let redirects = RedirectPolicy(secretHeaderNames: Set(request.secretHeaders.keys))
        return try await Self.send(request) { try await Self.session.data(for: $0, delegate: redirects) }
    }

    /// The session of all requests: no cache, no cookies, no stored credentials.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration)
    }()

    /// Builds the `URLRequest`, runs `perform` with it, and maps the result. A transport failure is thrown as a
    /// ``BuildError`` that names the method and the URL, unless the task was cancelled: then it is a
    /// `CancellationError`. A response that is not HTTP is also an error.
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
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                throw CancellationError()
            }
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

/// Decides what a redirect keeps of the request. A redirect to another origin loses the secret headers of the request,
/// because the new server did not get them from the caller. An origin is the scheme, the host and the port, so a
/// redirect from https to http loses them too.
nonisolated final class RedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
    private let secretHeaderNames: Set<String>

    /// - Parameter secretHeaderNames: The names of the secret headers of the request, in any case.
    init(secretHeaderNames: Set<String>) {
        self.secretHeaderNames = Set(secretHeaderNames.map { $0.lowercased() })
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(redirectedRequest(request, from: response.url))
    }

    /// The request to send after a redirect from `source`: `redirect` without the secret headers if its URL has another
    /// origin than `source`. A URL whose origin cannot be read counts as another origin.
    func redirectedRequest(_ redirect: URLRequest, from source: URL?) -> URLRequest {
        guard let target = redirect.url, let source,
              let sourceOrigin = Self.origin(of: source), sourceOrigin == Self.origin(of: target) else {
            return strippingSecretHeaders(from: redirect)
        }
        return redirect
    }

    private func strippingSecretHeaders(from request: URLRequest) -> URLRequest {
        var stripped = request
        for name in request.allHTTPHeaderFields?.keys ?? [:].keys where secretHeaderNames.contains(name.lowercased()) {
            stripped.setValue(nil, forHTTPHeaderField: name)
        }
        return stripped
    }

    /// The scheme, host and port of `url`, in lower case, with the default port of the scheme filled in. `nil` if the
    /// URL has no scheme or host.
    static func origin(of url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased() else { return nil }
        let defaultPorts = ["http": 80, "https": 443]
        guard let port = url.port ?? defaultPorts[scheme] else { return nil }
        return "\(scheme)://\(host):\(port)"
    }
}
