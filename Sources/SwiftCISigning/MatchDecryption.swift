import Foundation
import SwiftCI
import Security
import CryptoKit
import CommonCrypto

/// The format of a file that fastlane match encrypted.
enum MatchFileFormat: String, Equatable, Sendable {
    /// `Salted__` prefix, OpenSSL-compatible AES-256-CBC with EVP_BytesToKey.
    case v1
    /// `match_encrypted_v2__` prefix, AES-256-GCM with a PBKDF2-derived key.
    case v2
}

/// What a decrypted match file holds, as checked by its content.
enum MatchFileContent: String, Equatable, Sendable {
    /// A DER certificate (.cer).
    case certificate
    /// A PEM private key in a .p12, as fastlane match writes it.
    case pemPrivateKey
    /// A PKCS#12 in a .p12, as `match import` can store it.
    case pkcs12
    /// A CMS-signed provisioning profile (.mobileprovision, .provisionprofile).
    case profile
}

/// A decrypted match file: its bytes, the format it was encrypted in and what the bytes hold.
struct DecryptedMatchFile: Equatable, Sendable {
    var data: Data
    var format: MatchFileFormat
    var content: MatchFileContent
}

/// Decryption of the files of a fastlane match repository, in memory. Reads the v1 and v2 formats that fastlane 2.232
/// writes, and checks the content of each decrypted file.
enum MatchDecryption {
    /// The file extensions that fastlane match encrypts.
    static let encryptedExtensions: Set<String> = ["cer", "p12", "mobileprovision", "provisionprofile"]

    /// Decrypts one file of a match repository, in memory. `file` is the path relative to the repository root, such as
    /// `certs/distribution/ABC123.cer`. It names the file in errors and decides the content check by its extension
    /// (case-insensitive). The password is never part of an error.
    ///
    /// Throws a ``BuildError`` with a format error when the data is not a match file, and a password error when the
    /// data does not decrypt to the content its extension names. A v1 file is tried with MD5, then with SHA-256.
    static func decrypt(_ encrypted: Data, file: String, password: String) throws -> DecryptedMatchFile {
        let expected = try expectedContent(file: file)
        let bytes = try decodedBytes(encrypted, file: file)
        let envelope = try parseEnvelope(bytes, file: file)
        let passwordData = Data(password.utf8)

        switch envelope.format {
        case .v2:
            if let plain = try decryptV2(envelope, password: passwordData),
               let content = matchContent(of: plain, expected: expected) {
                return DecryptedMatchFile(data: plain, format: .v2, content: content)
            }
        case .v1:
            for hash in [HashAlgorithm.md5, .sha256] {
                if let plain = try? decryptV1(
                    ciphertext: envelope.ciphertext, salt: envelope.salt, password: passwordData, hash: hash
                ), let content = matchContent(of: plain, expected: expected) {
                    return DecryptedMatchFile(data: plain, format: .v1, content: content)
                }
            }
        }
        throw passwordError(file: file)
    }

    // MARK: - Hash and cipher helpers

    /// Hash algorithms of the OpenSSL-compatible key derivation.
    enum HashAlgorithm { case md5, sha256 }

    /// Decrypts a v1 payload with AES-256-CBC and PKCS#7 padding. The key and IV come from EVP_BytesToKey with one
    /// iteration over `hash`. Throws when the padding is wrong, which a wrong password or hash usually causes.
    static func decryptV1(ciphertext: Data, salt: Data, password: Data, hash: HashAlgorithm) throws -> Data {
        let keyAndIV = evpBytesToKey(password: password, salt: salt, keyLength: 32, ivLength: 16, hash: hash)
        let bytes = [UInt8](keyAndIV)
        return try aes256cbcDecrypt(data: ciphertext, key: Data(bytes[0..<32]), iv: Data(bytes[32..<48]))
    }

    /// Decrypts a v2 payload with AES-256-GCM. The key, nonce and additional data come from PBKDF2-HMAC-SHA256 with
    /// 10,000 rounds. Returns nil when the authentication tag does not match, which a wrong password causes.
    private static func decryptV2(_ envelope: Envelope, password: Data) throws -> Data? {
        let derived = [UInt8](try pbkdf2sha256(password: password, salt: envelope.salt, rounds: 10_000, length: 68))
        guard let box = try? AES.GCM.SealedBox(
            nonce: AES.GCM.Nonce(data: Data(derived[32..<44])),
            ciphertext: envelope.ciphertext,
            tag: envelope.tag
        ) else { return nil }
        let key = SymmetricKey(data: Data(derived[0..<32]))
        return try? AES.GCM.open(box, using: key, authenticating: Data(derived[44..<68]))
    }

    /// PBKDF2 (HMAC-SHA256) derivation.
    private static func pbkdf2sha256(password: Data, salt: Data, rounds: Int, length: Int) throws -> Data {
        var out = Data(count: length)
        let result = out.withUnsafeMutableBytes { outPtr in
            salt.withUnsafeBytes { saltPtr in
                password.withUnsafeBytes { pwdPtr in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                         pwdPtr.bindMemory(to: Int8.self).baseAddress, password.count,
                                         saltPtr.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                         CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                                         UInt32(rounds),
                                         outPtr.bindMemory(to: UInt8.self).baseAddress, length)
                }
            }
        }
        guard result == kCCSuccess else { throw BuildError(message: "PBKDF2 failed: \(result)") }
        return out
    }

    /// OpenSSL EVP_BytesToKey-compatible derivation producing key||iv.
    private static func evpBytesToKey(
        password: Data,
        salt: Data,
        keyLength: Int,
        ivLength: Int,
        hash: HashAlgorithm
    ) -> Data {
        var derived = Data()
        var previous = Data()
        while derived.count < keyLength + ivLength {
            previous = digest(data: previous + password + salt, hash: hash)
            derived.append(previous)
        }
        return derived.prefix(keyLength + ivLength)
    }

    /// Computes an MD5 or SHA-256 digest.
    private static func digest(data: Data, hash: HashAlgorithm) -> Data {
        switch hash {
        case .md5: Data(Insecure.MD5.hash(data: data))
        case .sha256: Data(SHA256.hash(data: data))
        }
    }

    /// AES-256-CBC decrypt with PKCS#7 padding using CommonCrypto.
    private static func aes256cbcDecrypt(data: Data, key: Data, iv: Data) throws -> Data {
        var outLength: size_t = 0
        var outData = Data(count: data.count + kCCBlockSizeAES128)
        let outCapacity = outData.count
        let status: CCCryptorStatus = outData.withUnsafeMutableBytes { outPtr in
            guard let outBase = outPtr.baseAddress else { return CCCryptorStatus(kCCMemoryFailure) }
            return data.withUnsafeBytes { dataPtr in
                key.withUnsafeBytes { keyPtr in
                    iv.withUnsafeBytes { ivPtr in
                        CCCrypt(CCOperation(kCCDecrypt),
                                CCAlgorithm(kCCAlgorithmAES128),
                                CCOptions(kCCOptionPKCS7Padding),
                                keyPtr.baseAddress, key.count,
                                ivPtr.baseAddress,
                                dataPtr.baseAddress, data.count,
                                outBase, outCapacity,
                                &outLength)
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw BuildError(message: "AES-CBC decryption failed: \(status)") }
        outData.removeSubrange(outLength..<outData.count)
        return outData
    }

    // MARK: - Envelope

    /// The parts of an encrypted file, in the order they come in the file.
    private struct Envelope {
        var format: MatchFileFormat
        var salt: Data
        /// The authentication tag of v2. Empty for v1.
        var tag: Data
        var ciphertext: Data
    }

    private static let v1Prefix = Array("Salted__".utf8)
    private static let v2Prefix = Array("match_encrypted_v2__".utf8)
    private static let aesBlockSize = 16
    private static let base64Alphabet = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=".unicodeScalars)
    private static let base64Whitespace = Set("\n\r \t".unicodeScalars)

    /// The content kind that the extension of `file` names.
    private static func expectedContent(file: String) throws -> ExpectedContent {
        switch URL(filePath: file).pathExtension.lowercased() {
        case "cer": return .certificate
        case "p12": return .privateKeyOrPKCS12
        case "mobileprovision", "provisionprofile": return .profile
        default:
            throw BuildError(
                message: "Couldn't decrypt \(file): match encrypts only .cer, .p12, .mobileprovision and "
                    + ".provisionprofile files."
            )
        }
    }

    /// The content kinds that a file's extension can name.
    private enum ExpectedContent { case certificate, privateKeyOrPKCS12, profile }

    /// The base64 text of the file as bytes. Whitespace is removed first, and any other character outside the base64
    /// alphabet is a format error.
    private static func decodedBytes(_ encrypted: Data, file: String) throws -> Data {
        let notBase64 = formatError(file: file, reason: "it is not base64 text")
        guard let text = String(data: encrypted, encoding: .utf8) else { throw notBase64 }
        var cleaned = ""
        for scalar in text.unicodeScalars where !base64Whitespace.contains(scalar) {
            guard base64Alphabet.contains(scalar) else { throw notBase64 }
            cleaned.unicodeScalars.append(scalar)
        }
        guard let bytes = Data(base64Encoded: cleaned), !bytes.isEmpty else { throw notBase64 }
        return bytes
    }

    /// Splits the decoded bytes by their prefix. Every length is checked before a slice is taken.
    private static func parseEnvelope(_ bytes: Data, file: String) throws -> Envelope {
        let all = [UInt8](bytes)
        if bytes.starts(with: v2Prefix) {
            // [20:prefix][8:salt][16:tag][rest:ciphertext]. The ciphertext may be empty.
            guard all.count >= 44 else { throw formatError(file: file, reason: "it is too short") }
            return Envelope(format: .v2, salt: Data(all[20..<28]), tag: Data(all[28..<44]), ciphertext: Data(all[44...]))
        }
        if bytes.starts(with: v1Prefix) {
            // [8:prefix][8:salt][rest:ciphertext]
            guard all.count > 16 else { throw formatError(file: file, reason: "it is too short") }
            guard (all.count - 16) % aesBlockSize == 0 else {
                throw formatError(file: file, reason: "its length is not a multiple of the AES block size")
            }
            return Envelope(format: .v1, salt: Data(all[8..<16]), tag: Data(), ciphertext: Data(all[16...]))
        }
        throw formatError(file: file, reason: "it has neither the match_encrypted_v2__ nor the Salted__ prefix")
    }

    // MARK: - Content checks

    /// The content of the decrypted data when it has the kind that `expected` names, otherwise nil.
    private static func matchContent(of data: Data, expected: ExpectedContent) -> MatchFileContent? {
        switch expected {
        case .certificate:
            return isCertificate(data) ? .certificate : nil
        case .privateKeyOrPKCS12:
            if isPEMPrivateKey(data) { return .pemPrivateKey }
            if isDERSequence(data) { return .pkcs12 }
            return nil
        case .profile:
            return isSignedPropertyList(data) ? .profile : nil
        }
    }

    private static func isCertificate(_ data: Data) -> Bool {
        SecCertificateCreateWithData(nil, data as CFData) != nil
    }

    /// Whether the data is PEM text whose first block is a private key, with its END line, and whose base64 body is a
    /// DER sequence that spans the body.
    private static func isPEMPrivateKey(_ data: Data) -> Bool {
        guard let text = String(data: data, encoding: .utf8) else { return false }
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let begin = lines.first, begin.hasPrefix("-----BEGIN "), begin.hasSuffix("-----") else { return false }
        let label = String(begin.dropFirst("-----BEGIN ".count).dropLast("-----".count))
        guard label.hasSuffix("PRIVATE KEY"), lines.count >= 3, lines.last == "-----END \(label)-----" else { return false }
        guard let der = Data(base64Encoded: lines.dropFirst().dropLast().joined()) else { return false }
        return isDERSequence(der)
    }

    /// Whether the data is a DER SEQUENCE (tag 0x30) whose length, in short or long form, spans the whole data.
    private static func isDERSequence(_ data: Data) -> Bool {
        let bytes = [UInt8](data)
        guard bytes.count >= 2, bytes[0] == 0x30 else { return false }
        let headerLength: Int
        let contentLength: Int
        if bytes[1] < 0x80 {
            headerLength = 2
            contentLength = Int(bytes[1])
        } else {
            // Long form with 1 to 4 length bytes. The indefinite form (0x80) is not DER.
            let lengthBytes = Int(bytes[1] & 0x7F)
            guard (1...4).contains(lengthBytes), bytes.count >= 2 + lengthBytes else { return false }
            headerLength = 2 + lengthBytes
            contentLength = bytes[2..<headerLength].reduce(0) { $0 << 8 | Int($1) }
        }
        return headerLength + contentLength == bytes.count
    }

    /// Whether the data is a CMS message whose content is a property list dictionary. The CMS decoder needs no keychain,
    /// unlike `security cms -D`, which imports the signer's certificate.
    private static func isSignedPropertyList(_ data: Data) -> Bool {
        guard let content = ProvisioningProfile.cmsContent(data) else { return false }
        let plist = try? PropertyListSerialization.propertyList(from: content, options: [], format: nil)
        return plist is [String: Any]
    }

    // MARK: - Errors

    /// The error for data that does not decrypt, or that decrypts to something other than the expected content. Both
    /// mean a wrong password. It never contains the password.
    private static func passwordError(file: String) -> BuildError {
        BuildError(message: "Couldn't decrypt \(file). Check the match password.")
    }

    /// The error for data that is not a match file, with the reason.
    private static func formatError(file: String, reason: String) -> BuildError {
        BuildError(message: "Couldn't decrypt \(file): \(reason). Check that it is a file of a fastlane match repository.")
    }
}
