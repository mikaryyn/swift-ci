import Foundation
import SwiftCI

/// A connection to the API of a GitLab server. Requests send the token in the `PRIVATE-TOKEN` header as a secret header,
/// so the token is never written to the log or to an error message.
///
/// The connection itself opens no step and logs nothing. A method that does work for a script says in its doc comment
/// whether it opens a step.
public struct GitLab {
    /// Creates a connection to a GitLab server.
    ///
    /// - Parameters:
    ///   - apiURL: The API base, such as `https://gitlab.example.com/api/v4`.
    ///   - token: An access token with the `api` scope. It is revealed only to make a request.
    public init(apiURL: URL, token: Secret) {
        self.apiURL = apiURL
        self.token = token
    }

    @Use private var client: HTTPClient
    private let apiURL: URL
    private let token: Secret

    /// Sends a request to `path` under the API base and returns the response. A status outside 2xx throws a
    /// ``BuildError`` with the method, the path, the status and GitLab's message. The token is not in the error.
    ///
    /// - Parameters:
    ///   - method: The HTTP method, such as `GET` or `POST`.
    ///   - path: The path under the API base, such as `/projects/group%2Fproject`. It is appended as text, so the
    ///     percent-encoding of a project path is kept.
    ///   - query: The query items of the request.
    ///   - body: The JSON body, or `nil` for a request without one.
    func send(_ method: String, _ path: String, query: [URLQueryItem] = [], body: Data? = nil) async throws -> HTTPResponse {
        var headers = ["Accept": "application/json"]
        if body != nil {
            headers["Content-Type"] = "application/json"
        }
        let request = HTTPRequest(
            method: method,
            url: try url(for: path, query: query),
            headers: headers,
            secretHeaders: ["PRIVATE-TOKEN": token],
            body: body
        )
        let response = try await client.send(request)
        guard (200..<300).contains(response.statusCode) else {
            throw Self.statusError(method, path, response)
        }
        return response
    }

    /// The URL of `path` under the API base, with the query. The API base is a string here, because `URL.appending(path:)`
    /// would encode the `%` of a project path a second time.
    func url(for path: String, query: [URLQueryItem]) throws -> URL {
        var base = apiURL.absoluteString
        while base.hasSuffix("/") {
            base.removeLast()
        }
        let separator = path.hasPrefix("/") ? "" : "/"
        guard var components = URLComponents(string: base + separator + path) else {
            throw BuildError(message: "The GitLab API path \(path) cannot be added to the API URL. Check the API URL, such as https://gitlab.example.com/api/v4.")
        }
        if !query.isEmpty {
            components.queryItems = query
        }
        guard let url = components.url else {
            throw BuildError(message: "The GitLab API path \(path) makes an invalid URL. Check the API URL, such as https://gitlab.example.com/api/v4.")
        }
        return url
    }

    /// Decodes the JSON body of `response`, the response to `method` `path`. A body that does not match `type` throws a
    /// ``BuildError`` with the place of the problem. The body itself is not in the error.
    func decode<Value: Decodable>(_ type: Value.Type, from response: HTTPResponse, _ method: String, _ path: String) throws -> Value {
        do {
            return try JSONDecoder().decode(type, from: response.body)
        } catch {
            throw BuildError(
                message: "The GitLab API response to \(method) \(path) is not the expected JSON (\(Self.decodingProblem(error))). Check the API URL and the GitLab version."
            )
        }
    }

    /// Returns the items of every page of a list, such as the discussions of a merge request. It asks for 100 items per
    /// page and follows the `X-Next-Page` header until that is empty. A page that does not match `Item` throws as
    /// ``decode(_:from:_:_:)`` does.
    func paginated<Item: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> [Item] {
        var items: [Item] = []
        var page = 1
        while true {
            var pageQuery = query + [URLQueryItem(name: "per_page", value: "100")]
            if page > 1 {
                pageQuery.append(URLQueryItem(name: "page", value: String(page)))
            }
            let response = try await send("GET", path, query: pageQuery)
            items += try decode([Item].self, from: response, "GET", path)
            // A next page that is not after the current one would repeat forever, so it ends the list.
            guard let next = response.headerValue("X-Next-Page").flatMap(Int.init), next > page else {
                return items
            }
            page = next
        }
    }

    /// The error of a response whose status is outside 2xx. It names the method, the path and the status, adds GitLab's
    /// message when the body has one, and says what to check for the common statuses.
    static func statusError(_ method: String, _ path: String, _ response: HTTPResponse) -> BuildError {
        var sentences = ["GitLab API request \(method) \(path) failed with status \(response.statusCode)"]
        if let detail = errorDetail(in: response.body) {
            sentences.append("GitLab says: \(detail)")
        }
        switch response.statusCode {
        case 401, 403:
            sentences.append("Check that the token is valid and has the api scope")
        case 404:
            sentences.append("Check the API URL and the project and merge request IDs")
        default:
            break
        }
        let sentence = sentences.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".")) }.joined(separator: ". ")
        return BuildError(message: sentence + ".")
    }

    /// GitLab's message, from the `message` field of a JSON error body, or else its `error` field. `nil` when there is
    /// neither, or the body is not a JSON object.
    static func errorDetail(in body: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return nil }
        return text(of: object["message"]) ?? text(of: object["error"])
    }

    /// The text of a JSON value. GitLab sends a message as a string, as a list of strings, or as an object of lists of
    /// strings for validation errors. A string is used as it is, a list is joined, and an object gives `key: text` for
    /// each key in order. Other values give `nil`.
    static func text(of value: Any?) -> String? {
        let texts: [String]
        switch value {
        case let string as String:
            texts = [string]
        case let list as [Any]:
            texts = list.compactMap { text(of: $0) }
        case let object as [String: Any]:
            texts = object.keys.sorted().compactMap { key in text(of: object[key]).map { "\(key): \($0)" } }
        default:
            return nil
        }
        let joined = texts.filter { !$0.isEmpty }.joined(separator: "; ")
        return joined.isEmpty ? nil : joined
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

extension HTTPResponse {
    /// The value of the header field `name`. HTTP header names are not case-sensitive, but the response keeps the case
    /// that the server sent, so the lookup ignores case.
    func headerValue(_ name: String) -> String? {
        headers.first { $0.key.lowercased() == name.lowercased() }?.value
    }
}
