import Foundation
import SwiftCI

/// The URL and the environment for a git command that may need credentials. The URL never contains credentials. The environment carries the HTTP header as a secret.
struct GitCredentials {
    /// The URL without any user information. Safe to pass as an argument.
    let url: String
    /// Variables to add to the environment of the git process.
    let environment: [String: ToolEnvironmentValue]
}

enum GitCredentialHelper {
    static let urlVariable = "MATCH_GIT_URL"
    static let basicVariable = "MATCH_GIT_BASIC_AUTHORIZATION"
    static let bearerVariable = "MATCH_GIT_BEARER_AUTHORIZATION"

    /// Resolves the credentials of `url`. Credentials come from the user information of an http or https URL, or from
    /// `basicAuthorization` (base64 of `user:token`) or `bearerAuthorization`. Only one source may be given.
    ///
    /// - The user information is percent-decoded. With a password, the password is registered as a secret and the header
    ///   is `Authorization: Basic base64(user:password)`. Without one, the user is the token: the header is
    ///   `Authorization: Basic base64(user:)`, and the user is registered.
    /// - `MATCH_GIT_BASIC_AUTHORIZATION` gives `Authorization: Basic <value>`, and `MATCH_GIT_BEARER_AUTHORIZATION`
    ///   gives `Authorization: Bearer <value>`. Git sends the stored line as it is, so the header name is part of it.
    /// - The header is sent as `http.<url>.extraHeader` through `GIT_CONFIG_COUNT`, `GIT_CONFIG_KEY_<n>` and
    ///   `GIT_CONFIG_VALUE_<n>`. If the inherited environment already has `GIT_CONFIG_COUNT`, the new entry is appended.
    /// - A URL with a password for a scheme other than http or https (for example `ssh://user:password@host/repo`, or
    ///   `user:password@host:path`) is refused. Git would take the password from the arguments. An SSH user name without
    ///   a password (`ssh://git@host/repo`, `git@host:org/repo.git`) passes through unchanged, with no header.
    /// - A URL that starts with `http://` or `https://` but cannot be parsed, or has no host, is refused too. It is not
    ///   sent unchecked.
    ///
    /// Errors name the variables, never the URL or a value, because the URL may hold a password. Throws a usage error if
    /// credentials come from more than one source, or if a credential source is given for a URL that is not http or
    /// https. It also throws if `GIT_CONFIG_COUNT` is not a non-negative number that leaves room for one more entry.
    static func resolve(
        url: String,
        basicAuthorization: Secret?,
        bearerAuthorization: Secret?,
        inheritedEnvironment: [String: String]
    ) throws -> GitCredentials {
        let components = URLComponents(string: url)
        let scheme = components?.scheme?.lowercased() ?? ""
        let isWebURL = scheme == "http" || scheme == "https"
        let looksWeb = url.lowercased().hasPrefix("http://") || url.lowercased().hasPrefix("https://")

        // A raw space or other whitespace is not allowed in a URL (RFC 3986). URLComponents would percent-encode it and
        // accept the URL, so it is refused here.
        let hasWhitespace = url.contains { $0.isWhitespace || $0.isNewline }
        if looksWeb && (!isWebURL || components?.host?.isEmpty != false || hasWhitespace) {
            throw BuildError(
                message: "\(urlVariable) starts with http:// or https://, but it cannot be parsed safely. Check it for typos and stray characters. Its value is not shown, because it may hold a password.",
                code: .usage
            )
        }
        if !isWebURL && hasPassword(url, components: components) {
            throw BuildError(
                message: "\(urlVariable) has a password, and it is not an http or https URL. Git would receive the password as an argument. Use an SSH key, or remove the password from the URL. Its value is not shown.",
                code: .usage
            )
        }

        let user = isWebURL ? try decoded(components?.percentEncodedUser) : ""
        let password = isWebURL ? try decoded(components?.percentEncodedPassword) : ""
        let urlHasCredentials = !user.isEmpty || !password.isEmpty

        var sources: [String] = []
        if urlHasCredentials { sources.append(urlVariable) }
        if basicAuthorization != nil { sources.append(basicVariable) }
        if bearerAuthorization != nil { sources.append(bearerVariable) }
        guard sources.count <= 1 else {
            throw BuildError(
                message: "Git credentials are given more than once: \(sources.joined(separator: ", ")). Give one source only.",
                code: .usage
            )
        }
        if !isWebURL, let name = basicAuthorization != nil ? basicVariable : (bearerAuthorization != nil ? bearerVariable : nil) {
            throw BuildError(
                message: "\(name) needs an http or https \(urlVariable). Git sends the credential header only over HTTP(S).",
                code: .usage
            )
        }

        let header: Secret
        var cleanURL = url
        if urlHasCredentials, var stripped = components {
            // A password is the secret. Without one, the user is the token, and it is the secret.
            _ = Secret(value: password.isEmpty ? user : password)
            header = Secret(value: "Authorization: Basic " + Data("\(user):\(password)".utf8).base64EncodedString())
            stripped.percentEncodedUser = nil
            stripped.percentEncodedPassword = nil
            guard let text = stripped.string else {
                throw BuildError(message: "Failed to remove the credentials from \(urlVariable).", code: .usage)
            }
            cleanURL = text
        } else if let basicAuthorization {
            header = Secret(value: "Authorization: Basic " + (try basicAuthorization.revealedValue()))
        } else if let bearerAuthorization {
            header = Secret(value: "Authorization: Bearer " + (try bearerAuthorization.revealedValue()))
        } else {
            return GitCredentials(url: url, environment: [:])
        }

        var index = 0
        if let existing = inheritedEnvironment["GIT_CONFIG_COUNT"] {
            guard let count = Int(existing), count >= 0, count < Int.max else {
                throw BuildError(
                    message: "GIT_CONFIG_COUNT is not a number that leaves room for one more entry, so SwiftCI cannot add the credential header. Set it to a non-negative number, or unset it.",
                    code: .usage
                )
            }
            index = count
        }
        return GitCredentials(url: cleanURL, environment: [
            "GIT_CONFIG_COUNT": .text("\(index + 1)"),
            "GIT_CONFIG_KEY_\(index)": .text("http.\(cleanURL).extraHeader"),
            "GIT_CONFIG_VALUE_\(index)": .secret(header),
        ])
    }

    /// Whether a URL that is not http or https carries a password. A URL parsed by `URLComponents` has one if it has a
    /// colon in its user information. An scp-style address (`user:password@host:path`) has no scheme, so its user part
    /// before the `@` is checked for a colon.
    static func hasPassword(_ url: String, components: URLComponents?) -> Bool {
        if url.contains("://") {
            return components?.percentEncodedPassword != nil
        }
        guard let at = url.firstIndex(of: "@") else { return false }
        return url[..<at].contains(":")
    }

    /// Percent-decodes one part of the user information. An invalid encoding is a usage error, so that no credential
    /// is dropped without notice.
    private static func decoded(_ encoded: String?) throws -> String {
        guard let encoded else { return "" }
        guard let text = encoded.removingPercentEncoding else {
            throw BuildError(message: "\(urlVariable) has an invalid percent-encoding in its user information.", code: .usage)
        }
        return text
    }
}
