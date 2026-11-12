#if os(macOS)
import Foundation
import SwiftCI

/// The error messages of the client: the status of a response, Apple's details and the problem of a decoding error.
extension AppStoreConnect {
    /// The error of a response whose status is outside 2xx. It names the method and the path, and says what to check for
    /// the statuses that have a known cause. Apple's details are added where the response has them.
    static func statusError(_ method: String, _ path: String, _ response: HTTPResponse) -> BuildError {
        let request = "\(method) \(path)"
        let details = appleSays(in: response.body)
        switch response.statusCode {
        case 401:
            return BuildError(
                message: "App Store Connect rejected the API key for \(request) (401). "
                    + "Check the key ID, the issuer ID and the key file.\(details)"
            )
        case 403:
            return BuildError(
                message: "The API key lacks the role for \(request) (403). "
                    + "The key needs one of the roles Account Holder, Admin, App Manager or Developer.\(details)"
            )
        case 404:
            return BuildError(message: "App Store Connect request \(request) was not found (404).\(details)")
        default:
            return BuildError(
                message: "App Store Connect request \(request) failed with status \(response.statusCode).\(details)"
            )
        }
    }

    /// Apple's details of `body` as the end of an error message: ` Apple says: <details>.`, or an empty string when the
    /// body has none.
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
#endif
