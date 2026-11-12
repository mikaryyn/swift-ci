import Foundation
import SwiftCI
import Security
import CryptoKit

/// The facts of a certificate that match selection needs.
struct CertificateInfo: Equatable, Sendable {
    /// The subject summary of the certificate, which is its common name.
    var commonName: String
    /// The SHA-1 of the DER certificate, in uppercase hex, as `security find-identity` prints it.
    var sha1: String
    var expirationDate: Date

    /// Reads the facts of the DER certificate `der`. `file` names the file in errors.
    ///
    /// Throws a ``BuildError`` that names `file` when the data is not a certificate, or when its expiry date or common
    /// name cannot be read.
    init(der: Data, file: String) throws {
        guard let certificate = SecCertificateCreateWithData(nil, der as CFData) else {
            throw BuildError(
                message: "The file \(file) is not a certificate. Check that it is a DER certificate (.cer) of the match "
                    + "repository, and that the match password is right."
            )
        }
        guard let commonName = SecCertificateCopySubjectSummary(certificate) as String? else {
            throw BuildError(
                message: "The certificate \(file) has no common name. Check that it is a certificate for signing an app."
            )
        }
        // SecCertificateCopyValues works on macOS 13. SecCertificateCopyNotValidAfterDate needs macOS 15.
        let keys = [kSecOIDX509V1ValidityNotAfter] as CFArray
        guard let values = SecCertificateCopyValues(certificate, keys, nil) as? [String: [String: Any]],
              let notAfter = values[kSecOIDX509V1ValidityNotAfter as String]?[kSecPropertyKeyValue as String] as? NSNumber
        else {
            throw BuildError(
                message: "The expiry date of the certificate \(file) can't be read. Check that it is a valid certificate."
            )
        }
        self.commonName = commonName
        sha1 = Insecure.SHA1.hash(data: der).map { String(format: "%02X", $0) }.joined()
        expirationDate = Date(timeIntervalSinceReferenceDate: notAfter.doubleValue)
    }
}
