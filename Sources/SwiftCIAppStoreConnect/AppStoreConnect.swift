#if os(macOS)
import Foundation
import SwiftCI

/// A client of the App Store Connect API. Every request carries the bearer token of the API key as a secret header, so
/// the token is never written to the log or to an error message.
///
/// The client opens no step and logs one line per request, without its query. A method that does work for a script says
/// in its doc comment whether it opens a step.
public struct AppStoreConnect {
    /// Creates a client for an API key.
    ///
    /// - Parameters:
    ///   - apiKey: The API key that signs the requests.
    ///   - baseURL: The base of the API. Requests go to paths under it.
    public init(apiKey: AppStoreConnectAPIKey, baseURL: URL = URL(string: "https://api.appstoreconnect.apple.com")!) {
        self.baseURL = baseURL
        token = AppStoreConnectToken(apiKey: apiKey)
    }

    @Use private var client: HTTPClient
    @Use private var log: Log
    private let baseURL: URL
    private let token: AppStoreConnectToken

    /// Waits between retries. Tests replace it, so that they never wait.
    var sleep: (Duration) async throws -> Void = { try await Task.sleep(for: $0) }

    /// The clock that deadlines and expiry times are compared with. Tests replace it, so that they can move time.
    var now: () -> Date = Date.init

    /// Retries of a 429 response: waits 1, 2, 4, 8 and 16 seconds.
    static let rateLimitRetries = 5
    /// Retries of a 500, 502, 503 or 504 response, or of a transport error: waits 2, 4 and 8 seconds.
    static let serverRetries = 3

    /// Sends a request to `path` under the base URL and returns the response. A status outside 2xx throws a
    /// ``BuildError`` that names the method and the path. The query is not in the error.
    ///
    /// - Parameters:
    ///   - method: The HTTP method, such as `GET` or `POST`.
    ///   - path: The path under the base URL, such as `/v1/apps/1234567890`.
    ///   - query: The query items of the request.
    ///   - body: The JSON body, or `nil` for a request without one.
    ///   - accepting: A status that is returned as a response instead of thrown, so that the caller can read its body.
    func send(
        _ method: String, _ path: String, query: [URLQueryItem] = [], body: Data? = nil, accepting: Int? = nil
    ) async throws -> HTTPResponse {
        try await send(method, path, url: try url(for: path, query: query), body: body, accepting: accepting)
    }

    /// Sends a request to the absolute `url`, such as the `links.next` URL of a list. The URL must be on the host of the
    /// base URL, because the request carries the token. `path` names the request in messages.
    ///
    /// - Parameters:
    ///   - method: The HTTP method.
    ///   - path: The path of the request, as it names the request in messages.
    ///   - url: The full URL, including the query.
    ///   - body: The JSON body, or `nil` for a request without one.
    ///   - accepting: A status that is returned as a response instead of thrown.
    func send(_ method: String, _ path: String, url: URL, body: Data?, accepting: Int? = nil) async throws -> HTTPResponse {
        guard url.scheme == baseURL.scheme, url.host == baseURL.host, url.port == baseURL.port else {
            throw BuildError(
                message: "The App Store Connect link of \(method) \(path) points to another server, so the request was not sent. Check that the response came from App Store Connect."
            )
        }
        var headers = ["Accept": "application/json"]
        if body != nil {
            headers["Content-Type"] = "application/json"
        }
        let bearer = try Secret(value: "Bearer " + token.token().revealedValue())
        let request = HTTPRequest(
            method: method,
            url: url,
            headers: headers,
            secretHeaders: ["Authorization": bearer],
            body: body
        )
        return try await perform(request, method, path, accepting: accepting)
    }

    /// Reads a JSON response of `path`.
    ///
    /// - Parameters:
    ///   - path: The path under the base URL.
    ///   - query: The query items of the request.
    ///   - type: The type that the response decodes to.
    func get<T: Decodable>(_ path: String, query: [URLQueryItem] = [], as type: T.Type) async throws -> T {
        try decode(type, from: try await send("GET", path, query: query), "GET", path)
    }

    /// Sends a JSON body to `path` with `POST` and decodes the response.
    ///
    /// - Parameters:
    ///   - path: The path under the base URL.
    ///   - body: The value that is encoded as the JSON body.
    ///   - type: The type that the response decodes to.
    func post<T: Decodable>(_ path: String, body: some Encodable, as type: T.Type) async throws -> T {
        try await write("POST", path, body: body, as: type)
    }

    /// Sends a JSON body to `path` with `PATCH` and decodes the response.
    ///
    /// - Parameters:
    ///   - path: The path under the base URL.
    ///   - body: The value that is encoded as the JSON body.
    ///   - type: The type that the response decodes to.
    func patch<T: Decodable>(_ path: String, body: some Encodable, as type: T.Type) async throws -> T {
        try await write("PATCH", path, body: body, as: type)
    }

    /// Returns the items of every page of a JSON:API list. The first page is requested with `limit=200`, and each next
    /// page is the `links.next` URL of the page before, until a page has no next link.
    ///
    /// - Parameters:
    ///   - path: The path under the base URL.
    ///   - query: The query items of the first page.
    func getAll<Item: Decodable>(_ path: String, query: [URLQueryItem]) async throws -> [Item] {
        var page = try await get(path, query: query + [URLQueryItem(name: "limit", value: "200")], as: ListPage<Item>.self)
        var items: [Item] = []
        var requested: Set<String> = []
        while true {
            items += page.data
            guard let next = page.links?.next else { return items }
            guard requested.insert(next).inserted else {
                throw BuildError(message: "App Store Connect returned the same next page of \(path) twice. Run the step again; if it repeats, report it with the log.")
            }
            guard let url = URL(string: next) else {
                throw BuildError(message: "App Store Connect returned a next page of \(path) that is not a valid URL. Run the step again; if it repeats, report it with the log.")
            }
            let response = try await send("GET", path, url: url, body: nil)
            page = try decode(ListPage<Item>.self, from: response, "GET", path)
        }
    }

    /// The URL of `path` under the base URL, with the query. The base is a string here, because `URL.appending(path:)`
    /// would encode a `%` in the path a second time.
    private func url(for path: String, query: [URLQueryItem]) throws -> URL {
        var base = baseURL.absoluteString
        while base.hasSuffix("/") {
            base.removeLast()
        }
        let separator = path.hasPrefix("/") ? "" : "/"
        guard var components = URLComponents(string: base + separator + path) else {
            throw BuildError(message: "The App Store Connect path \(path) cannot be added to the base URL. Check the base URL of the API.")
        }
        if !query.isEmpty {
            components.queryItems = query
        }
        guard let url = components.url else {
            throw BuildError(message: "The App Store Connect path \(path) makes an invalid URL. Check the base URL of the API.")
        }
        return url
    }

    private func write<T: Decodable>(_ method: String, _ path: String, body: some Encodable, as type: T.Type) async throws -> T {
        let data = try Self.encode(body, method, path)
        return try decode(type, from: try await send(method, path, body: data), method, path)
    }

    /// The JSON body of a request to `method` `path`. Throws a ``BuildError`` that names the request if the value cannot be encoded.
    static func encode(_ value: some Encodable, _ method: String, _ path: String) throws -> Data {
        do {
            return try JSONEncoder().encode(value)
        } catch {
            throw BuildError(message: "The request body of \(method) \(path) cannot be encoded as JSON. Report this with the log.")
        }
    }

    /// Sends `request` and retries as the policy says. A 429 response is retried up to ``rateLimitRetries`` times, and a
    /// 500, 502, 503 or 504 response, or a transport error, up to ``serverRetries`` times. Any other status outside 2xx
    /// fails at once, unless it is `accepting`, which is returned as a response. Each attempt is logged with its status,
    /// never with the query.
    private func perform(_ request: HTTPRequest, _ method: String, _ path: String, accepting: Int?) async throws -> HTTPResponse {
        var rateLimitAttempts = 0
        var serverAttempts = 0
        while true {
            let response: HTTPResponse
            do {
                response = try await client.send(request)
            } catch {
                log.recorded("App Store Connect: \(method) \(path) -> no response")
                guard serverAttempts < Self.serverRetries else { throw error }
                try await self.sleep(.seconds(2 << serverAttempts))
                serverAttempts += 1
                continue
            }
            log.recorded("App Store Connect: \(method) \(path) -> \(response.statusCode)")
            if response.statusCode == accepting {
                return response
            }
            switch response.statusCode {
            case 200..<300:
                return response
            case 429:
                guard rateLimitAttempts < Self.rateLimitRetries else {
                    throw BuildError(
                        message: "App Store Connect rate limit reached for \(method) \(path), and it still applied after \(Self.rateLimitRetries) retries. App Store Connect limits the requests of each API key per hour, so run the step again later."
                    )
                }
                try await self.sleep(.seconds(1 << rateLimitAttempts))
                rateLimitAttempts += 1
            case 500, 502, 503, 504:
                guard serverAttempts < Self.serverRetries else {
                    throw Self.statusError(method, path, response)
                }
                try await self.sleep(.seconds(2 << serverAttempts))
                serverAttempts += 1
            default:
                throw Self.statusError(method, path, response)
            }
        }
    }

    /// The error of a response whose status is outside 2xx. It names the method and the path, and says what to check for
    /// the statuses that have a known cause. Apple's details are added where the response has them.
    static func statusError(_ method: String, _ path: String, _ response: HTTPResponse) -> BuildError {
        let request = "\(method) \(path)"
        let details = appleSays(in: response.body)
        switch response.statusCode {
        case 401:
            return BuildError(
                message: "App Store Connect rejected the API key for \(request) (401). Check the key ID, the issuer ID and the key file.\(details)"
            )
        case 403:
            return BuildError(
                message: "The API key lacks the role for \(request) (403). The key needs one of the roles Account Holder, Admin, App Manager or Developer.\(details)"
            )
        case 404:
            return BuildError(message: "App Store Connect request \(request) was not found (404).")
        default:
            return BuildError(
                message: "App Store Connect request \(request) failed with status \(response.statusCode).\(details)"
            )
        }
    }

    /// Apple's details of `body` as the end of an error message: ` Apple says: <details>.`, or an empty string when the body
    /// has none.
    static func appleSays(in body: Data) -> String {
        guard let details = appleDetails(in: body) else { return "" }
        return " Apple says: \(details)" + (details.hasSuffix(".") ? "" : ".")
    }

    /// Apple's error entries of `body` as `code: title — detail`, with each part only when it is present. `nil` when the
    /// body has no entries. The entries are joined with `; `.
    static func appleDetails(in body: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let errors = object["errors"] as? [[String: Any]]
        else { return nil }
        let texts = errors.compactMap { entry -> String? in
            var text = nonEmpty(entry["code"]) ?? ""
            if let title = nonEmpty(entry["title"]) {
                text = text.isEmpty ? title : "\(text): \(title)"
            }
            if let detail = nonEmpty(entry["detail"]) {
                text = text.isEmpty ? detail : "\(text) — \(detail)"
            }
            return text.isEmpty ? nil : text
        }
        return texts.isEmpty ? nil : texts.joined(separator: "; ")
    }

    /// The string `value`, or `nil` when it is not a string or is empty.
    private static func nonEmpty(_ value: Any?) -> String? {
        guard let string = value as? String, !string.isEmpty else { return nil }
        return string
    }

    /// Decodes the JSON body of `response`, the response to `method` `path`. A body that does not match `type` throws a
    /// ``BuildError`` that names the field. The body itself is not in the error.
    func decode<T: Decodable>(_ type: T.Type, from response: HTTPResponse, _ method: String, _ path: String) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: response.body)
        } catch {
            throw BuildError(
                message: "The App Store Connect response to \(method) \(path) is not the expected JSON (\(Self.decodingProblem(error))). The API may have changed; report this with the log."
            )
        }
    }

    /// Where a JSON value does not match the expected type. It names the field, and never shows the value.
    static func decodingProblem(_ error: Error) -> String {
        guard let error = error as? DecodingError else { return "unexpected JSON" }
        switch error {
        case .keyNotFound(let key, _):
            return "missing field \(key.stringValue)"
        case .valueNotFound(_, let context), .typeMismatch(_, let context), .dataCorrupted(let context):
            let field = context.codingPath.map(\.stringValue).joined(separator: ".")
            return field.isEmpty ? "unexpected JSON" : "unexpected value at \(field)"
        @unknown default:
            return "unexpected JSON"
        }
    }
}

/// One page of a JSON:API list: its items, and the link to the next page when there is one.
private struct ListPage<Item: Decodable>: Decodable {
    struct Links: Decodable {
        let next: String?
    }

    let data: [Item]
    let links: Links?
}
#endif
