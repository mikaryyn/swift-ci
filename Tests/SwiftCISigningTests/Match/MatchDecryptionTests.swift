@testable import SwiftCI
@testable import SwiftCISigning
import Foundation
import Testing

/// Decryption of fastlane match files, against the fixtures in `Fixtures/Match`. The fixtures are written by fastlane
/// 2.232.2's own encryption code, as `Fixtures/Match/make-fixtures.sh` does.
@Suite struct MatchDecryptionTests {
    static let password = "fixture-password"
    static let certificatePath = "certs/distribution/CERTID1234.cer"
    static let privateKeyPath = "certs/distribution/CERTID1234.p12"
    static let profilePath = "profiles/adhoc/AdHoc_com.example.app1.mobileprovision"

    /// A wrong password whose MD5 decrypt of the app1 profile unpads, so the padding check alone accepts it. Found with
    /// fastlane's EncryptionV1 (MD5) on `v1/profiles/adhoc/AdHoc_com.example.app1.mobileprovision`: `wrong-0` to
    /// `wrong-215` fail the padding, and `wrong-216` is the first that unpads (217 tries, about 0.4%).
    static let unpaddingPassword = "wrong-216"

    @Test func encryptedFilesDecryptToTheirPlainFiles() throws {
        for (directory, format) in [("v1", MatchFileFormat.v1), ("v2", .v2)] {
            let encryptedFiles = try relativeFiles(in: matchFixtureURL(directory)).filter(isEncryptedFile)
            #expect(encryptedFiles.count == 13, "\(directory): \(encryptedFiles)")

            var contents: [MatchFileContent] = []
            for relative in encryptedFiles {
                let decrypted = try MatchDecryption.decrypt(
                    Data(contentsOf: matchFixtureURL("\(directory)/\(relative)")),
                    file: relative,
                    password: Self.password
                )
                let plain = try matchPlainData(relative)
                #expect(decrypted.data == plain, "\(directory)/\(relative)")
                #expect(decrypted.format == format, "\(directory)/\(relative)")
                #expect(decrypted.content == expectedContent(relative), "\(directory)/\(relative)")
                contents.append(decrypted.content)
            }
            #expect(contents.filter { $0 == .certificate }.count == 3)
            #expect(contents.filter { $0 == .pemPrivateKey }.count == 3)
            #expect(contents.filter { $0 == .profile }.count == 7)
        }
    }

    @Test func encryptedFixturesHaveLineBreaksAndStillDecryptWhenTheyChange() throws {
        let relative = Self.profilePath
        let text = try String(contentsOf: matchFixtureURL("v2/\(relative)"), encoding: .utf8)
        #expect(text.contains("\n"))

        let plain = try matchPlainData(relative)
        let crlf = Data(text.replacingOccurrences(of: "\n", with: "\r\n").utf8)
        let noWhitespace = Data(text.filter { !$0.isWhitespace }.utf8)
        for variant in [crlf, noWhitespace] {
            let decrypted = try MatchDecryption.decrypt(variant, file: relative, password: Self.password)
            #expect(decrypted.data == plain)
            #expect(decrypted.format == .v2)
            #expect(decrypted.content == .profile)
        }
    }

    @Test func v1FileWithSHA256FallbackDecrypts() throws {
        let decrypted = try MatchDecryption.decrypt(
            Data(contentsOf: matchFixtureURL("extra/v1-sha256/\(Self.certificatePath)")),
            file: Self.certificatePath,
            password: Self.password
        )
        #expect(decrypted.format == .v1)
        #expect(decrypted.content == .certificate)
        let plain = try matchPlainData(Self.certificatePath)
        #expect(decrypted.data == plain)
    }

    @Test func pkcs12EncryptedWithV2DecryptsToThePKCS12File() throws {
        let decrypted = try MatchDecryption.decrypt(
            Data(contentsOf: matchFixtureURL("extra/pkcs12/v2/\(Self.privateKeyPath)")),
            file: Self.privateKeyPath,
            password: Self.password
        )
        let expected = try Data(contentsOf: matchFixtureURL("extra/pkcs12/plain/\(Self.privateKeyPath)"))
        #expect(decrypted.format == .v2)
        #expect(decrypted.content == .pkcs12)
        #expect(decrypted.data == expected)
    }

    @Test func extensionIsCaseInsensitive() throws {
        let decrypted = try MatchDecryption.decrypt(
            Data(contentsOf: matchFixtureURL("v2/\(Self.certificatePath)")),
            file: "certs/distribution/CERTID1234.CER",
            password: Self.password
        )
        #expect(decrypted.content == .certificate)
    }

    @Test func wrongPasswordV2IsAPasswordError() throws {
        let encrypted = try Data(contentsOf: matchFixtureURL("v2/\(Self.certificatePath)"))
        let message = buildErrorMessage {
            _ = try MatchDecryption.decrypt(encrypted, file: Self.certificatePath, password: "wrong-password")
        }
        #expect(message == "Couldn't decrypt certs/distribution/CERTID1234.cer. Check the match password.")
        #expect(message?.contains("wrong-password") == false)
    }

    @Test func wrongPasswordV1IsAPasswordError() throws {
        let encrypted = try Data(contentsOf: matchFixtureURL("v1/\(Self.privateKeyPath)"))
        let message = buildErrorMessage {
            _ = try MatchDecryption.decrypt(encrypted, file: Self.privateKeyPath, password: "wrong-password")
        }
        #expect(message == "Couldn't decrypt certs/distribution/CERTID1234.p12. Check the match password.")
        #expect(message?.contains("wrong-password") == false)
    }

    @Test func wrongPasswordThatUnpadsByChanceIsStillAPasswordError() throws {
        let encrypted = try Data(contentsOf: matchFixtureURL("v1/\(Self.profilePath)"))
        let bytes = try [UInt8](fixtureBytes("v1/\(Self.profilePath)"))
        let salt = Data(bytes[8..<16])
        let ciphertext = Data(bytes[16...])

        // The low-level MD5 decrypt succeeds, so the padding check passes, and only the content check rejects it.
        _ = try MatchDecryption.decryptV1(
            ciphertext: ciphertext,
            salt: salt,
            password: Data(Self.unpaddingPassword.utf8),
            hash: .md5
        )

        let message = buildErrorMessage {
            _ = try MatchDecryption.decrypt(encrypted, file: Self.profilePath, password: Self.unpaddingPassword)
        }
        #expect(message == "Couldn't decrypt \(Self.profilePath). Check the match password.")
    }

    @Test func contentCheckRejectsAFileWithTheWrongExtension() throws {
        let encrypted = try Data(contentsOf: matchFixtureURL("v2/\(Self.profilePath)"))
        let message = buildErrorMessage {
            _ = try MatchDecryption.decrypt(encrypted, file: "certs/distribution/X.cer", password: Self.password)
        }
        #expect(message == "Couldn't decrypt certs/distribution/X.cer. Check the match password.")
    }

    @Test func emptyDataIsNotBase64Text() {
        #expect(formatMessage(Data(), file: Self.certificatePath) == formatError(Self.certificatePath, "it is not base64 text"))
    }

    @Test func plainFilesAreNotBase64Text() throws {
        let plainCertificate = try Data(contentsOf: matchFixtureURL("plain/\(Self.certificatePath)"))
        let plainKey = try Data(contentsOf: matchFixtureURL("plain/\(Self.privateKeyPath)"))
        let notBase64 = formatError(Self.certificatePath, "it is not base64 text")
        #expect(formatMessage(plainCertificate, file: Self.certificatePath) == notBase64)
        #expect(formatMessage(plainKey, file: Self.certificatePath) == notBase64)
        #expect(formatMessage(Data("hello, world!".utf8), file: Self.certificatePath) == notBase64)
    }

    @Test func base64WithoutAMatchPrefixIsAFormatError() {
        let encoded = Data("just some text".utf8).base64EncodedData()
        #expect(formatMessage(encoded, file: Self.certificatePath) == formatError(
            Self.certificatePath,
            "it has neither the match_encrypted_v2__ nor the Salted__ prefix"
        ))
    }

    @Test func truncatedEnvelopesAreFormatErrors() {
        let tooShort = formatError(Self.certificatePath, "it is too short")
        let v2Prefix = Data("match_encrypted_v2__".utf8)
        let v1Prefix = Data("Salted__".utf8)
        #expect(formatMessage(encoded(v2Prefix + Data(repeating: 1, count: 10)), file: Self.certificatePath) == tooShort)
        #expect(formatMessage(encoded(v1Prefix + Data(repeating: 1, count: 4)), file: Self.certificatePath) == tooShort)
        #expect(formatMessage(encoded(v1Prefix + Data(repeating: 1, count: 8)), file: Self.certificatePath) == tooShort)
    }

    @Test func v1CiphertextLengthMustBeABlockMultiple() {
        let encoded = encoded(Data("Salted__".utf8) + Data(repeating: 1, count: 8 + 17))
        #expect(formatMessage(encoded, file: Self.certificatePath) == formatError(
            Self.certificatePath,
            "its length is not a multiple of the AES block size"
        ))
    }

    @Test func truncatedV2FixtureThrowsABuildErrorNamingTheFile() throws {
        let text = try String(contentsOf: matchFixtureURL("v2/\(Self.certificatePath)"), encoding: .utf8)
        let truncated = Data(text.components(separatedBy: "\n").prefix(3).joined(separator: "\n").utf8)
        let message = buildErrorMessage {
            _ = try MatchDecryption.decrypt(truncated, file: Self.certificatePath, password: Self.password)
        }
        #expect(message?.hasPrefix("Couldn't decrypt certs/") == true)
    }

    @Test func v2EnvelopeWithEmptyCiphertextIsAPasswordError() {
        let envelope = Data("match_encrypted_v2__".utf8) + Data(repeating: 1, count: 8) + Data(repeating: 2, count: 16)
        let message = buildErrorMessage {
            _ = try MatchDecryption.decrypt(encoded(envelope), file: Self.certificatePath, password: Self.password)
        }
        #expect(message == "Couldn't decrypt \(Self.certificatePath). Check the match password.")
    }

    @Test func unknownExtensionIsAnError() {
        let message = buildErrorMessage {
            _ = try MatchDecryption.decrypt(Data("anything".utf8), file: "README.md", password: Self.password)
        }
        #expect(message == "Couldn't decrypt README.md: match encrypts only .cer, .p12, .mobileprovision and .provisionprofile files.")
    }

    @Test func encryptedExtensionsAreTheFourMatchTypes() {
        #expect(MatchDecryption.encryptedExtensions == ["cer", "p12", "mobileprovision", "provisionprofile"])
    }
}

// MARK: - Helpers

/// The decoded bytes of a base64 fixture, with the line breaks removed.
private func fixtureBytes(_ path: String) throws -> Data {
    let text = try String(contentsOf: matchFixtureURL(path), encoding: .utf8)
    return try #require(Data(base64Encoded: text.filter { !$0.isWhitespace }))
}

/// The paths of the regular files below `directory`, relative to it, sorted.
private func relativeFiles(in directory: URL) throws -> [String] {
    let fileManager = FileManager.default
    let enumerator = try #require(fileManager.enumerator(atPath: directory.path))
    var files: [String] = []
    while let path = enumerator.nextObject() as? String {
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: directory.appending(path: path).path, isDirectory: &isDirectory), !isDirectory.boolValue {
            files.append(path)
        }
    }
    return files.sorted()
}

/// Whether `relative` has an extension that fastlane match encrypts.
private func isEncryptedFile(_ relative: String) -> Bool {
    MatchDecryption.encryptedExtensions.contains(URL(filePath: relative).pathExtension.lowercased())
}

/// The content that a fixture holds, from its extension.
private func expectedContent(_ relative: String) -> MatchFileContent {
    switch URL(filePath: relative).pathExtension.lowercased() {
    case "cer": return .certificate
    case "p12": return .pemPrivateKey
    default: return .profile
    }
}

/// The message of the ``BuildError`` that `body` throws. Records an issue and returns nil when `body` throws another
/// error or nothing.
private func buildErrorMessage(_ body: () throws -> Void, sourceLocation: SourceLocation = #_sourceLocation) -> String? {
    matchBuildError(body, sourceLocation: sourceLocation)?.message
}

/// The message of the error that decrypting `data` as `file` throws. It is an error by the format check.
private func formatMessage(_ data: Data, file: String) -> String? {
    buildErrorMessage {
        _ = try MatchDecryption.decrypt(data, file: file, password: "fixture-password")
    }
}

/// The text of a format error for `file` with `reason`.
private func formatError(_ file: String, _ reason: String) -> String {
    "Couldn't decrypt \(file): \(reason). Check that it is a file of a fastlane match repository."
}

/// The base64 text of `data`, as a file of a match repository holds it.
private func encoded(_ data: Data) -> Data {
    data.base64EncodedData()
}
