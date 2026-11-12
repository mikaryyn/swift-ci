#if os(macOS)
import CryptoKit
import Foundation
import SwiftCI

/// An App Store Connect API key: the key ID, the issuer ID and the private key of the `.p8` file that Apple issues with
/// it. The issuer ID and the private key are secrets. The key ID is not secret.
///
/// Use ``p8File(_:keyID:issuerID:)`` to read the key file, or ``environment(keyID:keyFileVariable:issuerVariable:)`` to
/// read its path and the issuer from environment variables.
public struct AppStoreConnectAPIKey: Sendable {
    /// Creates a key from values that are already known.
    ///
    /// - Parameters:
    ///   - keyID: The key ID that App Store Connect shows for the key, such as `ABC123DEFG`.
    ///   - issuerID: The issuer ID of the team.
    ///   - privateKey: The PEM text of the `.p8` file, which holds a P-256 private key.
    public init(keyID: String, issuerID: Secret, privateKey: Secret) {
        self.keyID = keyID
        self.issuerID = issuerID
        self.privateKey = privateKey
    }

    /// The key ID. It is not secret.
    public let keyID: String

    /// The issuer ID of the team.
    let issuerID: Secret

    /// The PEM text of the `.p8` file.
    let privateKey: Secret

    /// Reads the private key from a `.p8` file. The content of the file is registered as a secret.
    ///
    /// Throws a ``BuildError`` that names the file when it cannot be read, is empty or does not hold a P-256 private key
    /// in PEM form. The error never shows the content.
    ///
    /// - Parameters:
    ///   - url: The file URL of the `.p8` file.
    ///   - keyID: The key ID that App Store Connect shows for the key.
    ///   - issuerID: The issuer ID of the team.
    public static func p8File(_ url: URL, keyID: String, issuerID: Secret) throws -> AppStoreConnectAPIKey {
        let pem: String
        do {
            pem = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw BuildError(
                message: "Cannot read the App Store Connect API key file \(url.filePath). "
                    + "Check that the file exists and is the .p8 file that Apple issued."
            )
        }
        guard !pem.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BuildError(
                message: "The App Store Connect API key file \(url.filePath) is empty. "
                    + "Check that it is the .p8 file that Apple issued."
            )
        }
        guard (try? P256.Signing.PrivateKey(pemRepresentation: pem)) != nil else {
            throw BuildError(
                message: "The App Store Connect API key file \(url.filePath) does not hold a P-256 private key in PEM "
                    + "form. Check that it is the .p8 file that Apple issued."
            )
        }
        return AppStoreConnectAPIKey(keyID: keyID, issuerID: issuerID, privateKey: Secret(value: pem))
    }

    /// Reads the key file path from the environment variable `keyFileVariable` and the issuer ID from the environment
    /// variable `issuerVariable`, then reads the key file with ``p8File(_:keyID:issuerID:)``.
    ///
    /// Throws a ``BuildError`` with exit code 2 that names the variable when one of them is unset or empty.
    ///
    /// - Parameters:
    ///   - keyID: The key ID that App Store Connect shows for the key.
    ///   - keyFileVariable: The name of the variable that holds the path of the `.p8` file.
    ///   - issuerVariable: The name of the variable that holds the issuer ID. The issuer ID is a secret.
    public static func environment(
        keyID: String,
        keyFileVariable: String,
        issuerVariable: String
    ) throws -> AppStoreConnectAPIKey {
        guard let keyFile = Environment.optional(keyFileVariable), !keyFile.isEmpty else {
            throw BuildError(
                message: "Environment variable \(keyFileVariable) is not set. "
                    + "Set it to the path of the App Store Connect .p8 key file.",
                code: .usage
            )
        }
        guard let issuerID = Secret.optional(issuerVariable) else {
            throw BuildError(
                message: "Environment variable \(issuerVariable) is not set. "
                    + "Set it to the issuer ID of the App Store Connect API key.",
                code: .usage
            )
        }
        return try p8File(URL(fileURLWithPath: keyFile), keyID: keyID, issuerID: issuerID)
    }
}
#endif
