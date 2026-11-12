#if os(macOS)
@testable import SwiftCI
@testable import SwiftCIAppStoreConnect
@testable import SwiftCITestSupport
import CryptoKit
import Foundation
import SwiftCITesting
import Testing

extension GlobalStateTests {
    /// Reading the key from a `.p8` file and from the environment. Files are written to a temporary directory.
    @Suite(.serialized) struct AppStoreConnectAPIKeyTests {
        static let keyFileVariable = "ASC_TEST_KEY_FILE"
        static let issuerVariable = "ASC_TEST_ISSUER"
        static let pem = P256.Signing.PrivateKey().pemRepresentation

        /// Writes `content` to the child `name` of `directory` and returns the file URL. The caller removes the directory.
        static func writeFile(_ content: String, named name: String, in directory: TemporaryDirectory) throws -> URL {
            let url = directory.childURL(name: name)
            try content.write(to: url, atomically: true, encoding: .utf8)
            return url
        }

        /// The key from a file that holds the PEM text is the same text, registered as a secret.
        @Test func p8FileReadsThePrivateKey() throws {
            let restore = isolatedGlobalState()
            defer { restore() }
            let directory = try TemporaryDirectory(name: "appstoreconnect-tests-$UUID")
            defer { try? FileManager.default.removeItem(at: directory.url) }
            let url = try Self.writeFile(Self.pem, named: "AuthKey_TESTKEY123.p8", in: directory)

            let key = try AppStoreConnectAPIKey.p8File(url, keyID: "TESTKEY123", issuerID: Secret(value: "issuer-test-1234"))

            #expect(key.keyID == "TESTKEY123")
            #expect(try key.privateKey.revealedValue() == Self.pem)
            #expect(try key.issuerID.revealedValue() == "issuer-test-1234")
            #expect(!Secret.redact(Self.pem).contains("BEGIN PRIVATE KEY"))
        }

        /// A file that does not exist fails with an error that names the file.
        @Test func p8FileThatCannotBeReadFailsNamingTheFile() async throws {
            let restore = isolatedGlobalState()
            defer { restore() }
            let directory = try TemporaryDirectory(name: "appstoreconnect-tests-$UUID")
            defer { try? FileManager.default.removeItem(at: directory.url) }
            let url = directory.childURL(name: "missing.p8")

            let error = await thrownError {
                _ = try AppStoreConnectAPIKey.p8File(url, keyID: "TESTKEY123", issuerID: Secret(value: "issuer-test-1234"))
            }

            let message = try #require(error?.message)
            #expect(message.contains(url.filePath))
            #expect(message.contains("Cannot read"))
        }

        /// An empty file fails with an error that names the file.
        @Test func emptyP8FileFailsNamingTheFile() async throws {
            let restore = isolatedGlobalState()
            defer { restore() }
            let directory = try TemporaryDirectory(name: "appstoreconnect-tests-$UUID")
            defer { try? FileManager.default.removeItem(at: directory.url) }
            let url = try Self.writeFile("  \n", named: "AuthKey_TESTKEY123.p8", in: directory)

            let error = await thrownError {
                _ = try AppStoreConnectAPIKey.p8File(url, keyID: "TESTKEY123", issuerID: Secret(value: "issuer-test-1234"))
            }

            let message = try #require(error?.message)
            #expect(message.contains(url.filePath))
            #expect(message.contains("is empty"))
        }

        /// A file that holds something else than a P-256 key fails at the read, names the file and shows no content.
        @Test func p8FileWithoutAKeyFailsNamingTheFileWithoutShowingItsContent() async throws {
            let restore = isolatedGlobalState()
            defer { restore() }
            let directory = try TemporaryDirectory(name: "appstoreconnect-tests-$UUID")
            defer { try? FileManager.default.removeItem(at: directory.url) }
            let url = try Self.writeFile(
                "-----BEGIN CERTIFICATE-----\nNOTAKEYMATERIAL\n-----END CERTIFICATE-----\n",
                named: "AuthKey_TESTKEY123.p8",
                in: directory
            )

            let error = await thrownError {
                _ = try AppStoreConnectAPIKey.p8File(url, keyID: "TESTKEY123", issuerID: Secret(value: "issuer-test-1234"))
            }

            let message = try #require(error?.message)
            #expect(message.contains(url.filePath))
            #expect(message.contains("P-256 private key"))
            #expect(!message.contains("NOTAKEYMATERIAL"))
        }

        /// Without the key file variable the error names it, and no file is read.
        @Test func environmentWithoutKeyFileVariableFailsNamingIt() async throws {
            let restore = isolatedGlobalState([Self.issuerVariable: "issuer-test-1234"])
            defer { restore() }

            let error = await thrownError {
                _ = try AppStoreConnectAPIKey.environment(
                    keyID: "TESTKEY123", keyFileVariable: Self.keyFileVariable, issuerVariable: Self.issuerVariable
                )
            }

            #expect(error?.message.contains(Self.keyFileVariable) == true)
            #expect(error?.code == .usage)
        }

        /// Without the issuer variable the error names it.
        @Test func environmentWithoutIssuerVariableFailsNamingIt() async throws {
            let directory = try TemporaryDirectory(name: "appstoreconnect-tests-$UUID")
            defer { try? FileManager.default.removeItem(at: directory.url) }
            let url = try Self.writeFile(Self.pem, named: "AuthKey_TESTKEY123.p8", in: directory)
            let restore = isolatedGlobalState([Self.keyFileVariable: url.filePath])
            defer { restore() }

            let error = await thrownError {
                _ = try AppStoreConnectAPIKey.environment(
                    keyID: "TESTKEY123", keyFileVariable: Self.keyFileVariable, issuerVariable: Self.issuerVariable
                )
            }

            #expect(error?.message.contains(Self.issuerVariable) == true)
            #expect(error?.code == .usage)
        }

        /// With both variables set, the path is read from the first and the issuer taken from the second.
        @Test func environmentReadsKeyFileAndIssuer() throws {
            let directory = try TemporaryDirectory(name: "appstoreconnect-tests-$UUID")
            defer { try? FileManager.default.removeItem(at: directory.url) }
            let url = try Self.writeFile(Self.pem, named: "AuthKey_TESTKEY123.p8", in: directory)
            let restore = isolatedGlobalState([Self.keyFileVariable: url.filePath, Self.issuerVariable: "issuer-test-1234"])
            defer { restore() }

            let key = try AppStoreConnectAPIKey.environment(
                keyID: "TESTKEY123", keyFileVariable: Self.keyFileVariable, issuerVariable: Self.issuerVariable
            )

            #expect(key.keyID == "TESTKEY123")
            #expect(try key.issuerID.revealedValue() == "issuer-test-1234")
            #expect(try key.privateKey.revealedValue() == Self.pem)
        }
    }
}
#endif
