#if os(macOS)
@testable import SwiftCI
@testable import SwiftCIAppStoreConnect
@testable import SwiftCITestSupport
import CryptoKit
import Foundation
import SwiftCITesting
import Testing

extension GlobalStateTests {
    /// The ES256 token: its header and payload, its signature, its lifetime and its cache. The clock is a test value,
    /// and the keys are generated in each test.
    @Suite(.serialized) struct AppStoreConnectTokenTests {
        static let keyID = "TESTKEY123"
        static let issuer = "issuer-test-1234"
        static let start = Date(timeIntervalSince1970: 1_800_000_000)

        /// A clock that the test moves by hand.
        final class TestClock {
            var now: Date

            init(_ now: Date) {
                self.now = now
            }
        }

        /// An API key with a new P-256 key, as the PEM text of a `.p8` file.
        static func apiKey(privateKey: P256.Signing.PrivateKey) -> AppStoreConnectAPIKey {
            AppStoreConnectAPIKey(
                keyID: keyID,
                issuerID: Secret(value: issuer),
                privateKey: Secret(value: privateKey.pemRepresentation)
            )
        }

        /// Splits a token into its header, payload and signature segments. Fails if it does not have three.
        static func segments(of token: String) throws -> (signingInput: String, header: Data, payload: Data, signature: Data) {
            let parts = token.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            try #require(parts.count == 3)
            return (
                signingInput: parts[0] + "." + parts[1],
                header: try decodeBase64URL(parts[0]),
                payload: try decodeBase64URL(parts[1]),
                signature: try decodeBase64URL(parts[2])
            )
        }

        static func decodeBase64URL(_ text: String) throws -> Data {
            var base64 = text
                .replacingOccurrences(of: "-", with: "+")
                .replacingOccurrences(of: "_", with: "/")
            while base64.count % 4 != 0 {
                base64 += "="
            }
            return try #require(Data(base64Encoded: base64))
        }

        static func json(_ data: Data) throws -> [String: Any] {
            try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }

        /// The header has exactly the three fields App Store Connect expects.
        @Test func headerNamesTheAlgorithmKeyAndType() throws {
            let restore = secretsSetUp()
            defer { restore() }
            let privateKey = P256.Signing.PrivateKey()
            let clock = TestClock(Self.start)
            let token = try AppStoreConnectToken(apiKey: Self.apiKey(privateKey: privateKey), now: { clock.now }).token()

            let parts = try Self.segments(of: token.revealedValue())
            let header = try Self.json(parts.header)
            #expect(header.count == 3)
            #expect(header["alg"] as? String == "ES256")
            #expect(header["kid"] as? String == Self.keyID)
            #expect(header["typ"] as? String == "JWT")
        }

        /// The payload has the issuer, the audience, `iat` 60 seconds before the time the token was made, and `exp`
        /// 1140 seconds after `iat`. The lifetime stays within the 1200 seconds that Apple allows.
        @Test func payloadHasIssuerAudienceAndTimes() throws {
            let restore = secretsSetUp()
            defer { restore() }
            let privateKey = P256.Signing.PrivateKey()
            let clock = TestClock(Self.start)
            let token = try AppStoreConnectToken(apiKey: Self.apiKey(privateKey: privateKey), now: { clock.now }).token()

            let payload = try Self.json(Self.segments(of: token.revealedValue()).payload)
            let issuedAt = try #require(payload["iat"] as? Int)
            let expiresAt = try #require(payload["exp"] as? Int)
            #expect(payload["iss"] as? String == Self.issuer)
            #expect(payload["aud"] as? String == "appstoreconnect-v1")
            #expect(issuedAt == Int(Self.start.timeIntervalSince1970) - 60)
            #expect(expiresAt - issuedAt == 1140)
            #expect(expiresAt - issuedAt <= 1200)
            #expect(Set(payload.keys) == ["iss", "iat", "exp", "aud"])
        }

        /// The signature is the raw 64-byte `r || s` form, and it verifies with the public key of the `.p8` key over the
        /// signing input.
        @Test func signatureVerifiesWithThePublicKey() throws {
            let restore = secretsSetUp()
            defer { restore() }
            let privateKey = P256.Signing.PrivateKey()
            let clock = TestClock(Self.start)
            let token = try AppStoreConnectToken(apiKey: Self.apiKey(privateKey: privateKey), now: { clock.now }).token()

            let parts = try Self.segments(of: token.revealedValue())
            #expect(parts.signature.count == 64)
            let signature = try P256.Signing.ECDSASignature(rawRepresentation: parts.signature)
            #expect(privateKey.publicKey.isValidSignature(signature, for: Data(parts.signingInput.utf8)))
            #expect(!privateKey.publicKey.isValidSignature(signature, for: Data((parts.signingInput + "x").utf8)))
        }

        /// Within the lifetime the same token is returned. Once less than 60 seconds remain before `exp`, a new token is
        /// made with the new time.
        @Test func cachesTheTokenAndRenewsItNearExpiry() throws {
            let restore = secretsSetUp()
            defer { restore() }
            let privateKey = P256.Signing.PrivateKey()
            let clock = TestClock(Self.start)
            let token = AppStoreConnectToken(apiKey: Self.apiKey(privateKey: privateKey), now: { clock.now })

            let first = try token.token()
            // `exp` is start + 1080 (iat is start - 60, plus 1140), so 1000 seconds later 80 seconds remain.
            clock.now = Self.start.addingTimeInterval(1000)
            #expect(try token.token() == first)

            // 1021 seconds later 59 seconds remain, so the token is renewed.
            clock.now = Self.start.addingTimeInterval(1021)
            let renewed = try token.token()
            #expect(renewed != first)
            let payload = try Self.json(Self.segments(of: renewed.revealedValue()).payload)
            #expect(payload["iat"] as? Int == Int(Self.start.timeIntervalSince1970) + 1021 - 60)
        }

        /// A key that does not parse fails with the documented error, and the error shows no key material.
        @Test func badPEMFailsWithoutShowingTheKey() async throws {
            let restore = secretsSetUp()
            defer { restore() }
            let apiKey = AppStoreConnectAPIKey(
                keyID: Self.keyID,
                issuerID: Secret(value: Self.issuer),
                privateKey: Secret(value: "-----BEGIN PRIVATE KEY-----\nNOTAKEYMATERIAL\n-----END PRIVATE KEY-----")
            )
            let token = AppStoreConnectToken(apiKey: apiKey)

            let error = await thrownError { _ = try token.token() }
            let message = try #require(error?.message)
            #expect(message.contains("not a valid App Store Connect API key"))
            #expect(message.contains("P-256"))
            #expect(!message.contains("NOTAKEYMATERIAL"))
            #expect(!message.contains("BEGIN PRIVATE KEY"))
        }
    }
}
#endif
