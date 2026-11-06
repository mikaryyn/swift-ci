#if os(macOS)
import CryptoKit
import Foundation
import SwiftCI

/// The ES256 JSON Web Token that authenticates App Store Connect requests, made from an ``AppStoreConnectAPIKey``.
///
/// A token starts 60 seconds before the time it is made, which tolerates a clock that is slightly behind Apple's, and
/// expires 1140 seconds after that. The token is cached and reused until less than 60 seconds remain before it expires,
/// so a long upload never sends an expired token. The clock is injected so that tests can move it.
final class AppStoreConnectToken {
    /// The `aud` claim that App Store Connect requires.
    static let audience = "appstoreconnect-v1"

    /// Seconds from `iat` to `exp`.
    static let lifetime = 1140

    /// Seconds by which `iat` lies before the time the token is made.
    static let clockSkew = 60

    /// A cached token is renewed when no more than this many seconds remain before it expires.
    static let renewalMargin: TimeInterval = 60

    init(apiKey: AppStoreConnectAPIKey, now: @escaping () -> Date = Date.init) {
        self.apiKey = apiKey
        self.now = now
    }

    /// Returns the cached token while more than 60 seconds remain before it expires, and makes a new one otherwise.
    /// Throws a ``BuildError`` if the private key of the API key is not a valid P-256 key in PEM form.
    func token() throws -> Secret {
        let date = now()
        if let cached, cached.expiration.timeIntervalSince(date) > Self.renewalMargin {
            return cached.token
        }
        let issuedAt = Int(date.timeIntervalSince1970) - Self.clockSkew
        let expiresAt = issuedAt + Self.lifetime
        let token = Secret(value: try makeToken(issuedAt: issuedAt, expiresAt: expiresAt))
        cached = (token, Date(timeIntervalSince1970: TimeInterval(expiresAt)))
        return token
    }

    private let apiKey: AppStoreConnectAPIKey
    private let now: () -> Date
    private var cached: (token: Secret, expiration: Date)?

    private struct Header: Encodable {
        let alg = "ES256"
        let kid: String
        let typ = "JWT"
    }

    private struct Payload: Encodable {
        let iss: String
        let iat: Int
        let exp: Int
        let aud: String
    }

    /// The signed token: the header and the payload, base64url-encoded and joined with dots, then the ES256 signature.
    private func makeToken(issuedAt: Int, expiresAt: Int) throws -> String {
        let key = try privateKey()
        let header = try Self.segment(Header(kid: apiKey.keyID))
        let payload = try Self.segment(
            Payload(
                iss: try apiKey.issuerID.revealedValue(),
                iat: issuedAt,
                exp: expiresAt,
                aud: Self.audience
            )
        )
        let signingInput = "\(header).\(payload)"
        let signature = try key.signature(for: Data(signingInput.utf8))
        return "\(signingInput).\(Self.base64URL(signature.rawRepresentation))"
    }

    /// The P-256 key of the API key. The error does not show the key, because a key file that does not parse is the
    /// most likely mistake, and its content must not reach a log.
    private func privateKey() throws -> P256.Signing.PrivateKey {
        let pem = try apiKey.privateKey.revealedValue()
        do {
            return try P256.Signing.PrivateKey(pemRepresentation: pem)
        } catch {
            throw BuildError(
                message: "The App Store Connect API key file is not a valid App Store Connect API key. It must be a P-256 private key in PEM form, as in the .p8 file that Apple issued."
            )
        }
    }

    /// A JSON segment of the token: the value with sorted keys, base64url-encoded.
    private static func segment<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return base64URL(try encoder.encode(value))
    }

    /// Base64url without padding, as JWT requires (RFC 7515).
    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
#endif
