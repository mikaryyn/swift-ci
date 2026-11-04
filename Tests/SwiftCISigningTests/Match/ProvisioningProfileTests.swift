@testable import SwiftCI
@testable import SwiftCISigning
import CryptoKit
import Foundation
import Testing

/// The fields of a provisioning profile and of a certificate, read from the plain fixtures. The missing and mistyped keys
/// are checked on property list dictionaries, because a CMS message without a signer cannot be made in a test.
@Suite struct ProvisioningProfileTests {
    static let profilePath = "profiles/adhoc/AdHoc_com.example.app1.mobileprovision"
    static let certificatePath = "certs/distribution/CERTID1234.cer"

    @Test func readsEveryFieldOfThePlainProfile() throws {
        let profile = try ProvisioningProfile(data: matchPlainData(Self.profilePath), file: Self.profilePath)

        #expect(profile.uuid == "11111111-1111-4111-8111-111111111111")
        #expect(profile.name == "match AdHoc com.example.app1")
        #expect(profile.teamIdentifiers == ["TEAMID1234"])
        #expect(profile.teamName == "SwiftCI Test")
        #expect(profile.applicationIdentifier == "TEAMID1234.com.example.app1")
        // 2026-11-04T00:00:00Z, the date the fixture was generated.
        #expect(profile.creationDate == Date(timeIntervalSince1970: 1_793_750_400))
        // The fixture expires 7300 days after it was generated, in 2046. The bounds keep the test independent of that day.
        #expect(profile.expirationDate > Date(timeIntervalSince1970: 2_208_988_800))
        #expect(profile.expirationDate < Date(timeIntervalSince1970: 2_524_608_000))
        let certificate = try matchPlainData(Self.certificatePath)
        #expect(profile.developerCertificates == [certificate])
    }

    @Test func aDERCertificateIsNotAProfile() throws {
        let error = matchBuildError {
            _ = try ProvisioningProfile(data: matchPlainData(Self.certificatePath), file: Self.certificatePath)
        }
        #expect(error?.message.hasPrefix("The provisioning profile \(Self.certificatePath) can't be read.") == true)
    }

    @Test func readsTheFieldsOfAPropertyListDictionary() throws {
        let profile = try ProvisioningProfile(propertyList: profileDictionary(), file: "test.mobileprovision")

        #expect(profile.uuid == "11111111-1111-4111-8111-111111111111")
        #expect(profile.applicationIdentifier == nil)
        #expect(profile.teamName == nil)
        #expect(profile.creationDate == nil)
        #expect(profile.developerCertificates == [Data([0x30, 0x00])])
    }

    @Test func aMissingUUIDIsNamed() throws {
        let error = matchBuildError {
            _ = try ProvisioningProfile(propertyList: profileDictionary(removing: "UUID"), file: "test.mobileprovision")
        }
        #expect(error?.message.hasPrefix("The provisioning profile test.mobileprovision has no valid UUID.") == true)
    }

    @Test func aTeamIdentifierThatIsNotAnArrayOfStringsIsNamed() throws {
        var dictionary = profileDictionary()
        dictionary["TeamIdentifier"] = "TEAMID1234"
        let error = matchBuildError {
            _ = try ProvisioningProfile(propertyList: dictionary, file: "test.mobileprovision")
        }
        #expect(error?.message.hasPrefix("The provisioning profile test.mobileprovision has no valid TeamIdentifier.") == true)
    }

    @Test func anEmptyTeamIdentifierListIsNamed() throws {
        var dictionary = profileDictionary()
        dictionary["TeamIdentifier"] = [String]()
        let error = matchBuildError {
            _ = try ProvisioningProfile(propertyList: dictionary, file: "test.mobileprovision")
        }
        #expect(error?.message.hasPrefix("The provisioning profile test.mobileprovision has no valid TeamIdentifier.") == true)
    }

    @Test func aWronglyTypedExpirationDateIsNamed() throws {
        var dictionary = profileDictionary()
        dictionary["ExpirationDate"] = "2046-10-30"
        let error = matchBuildError {
            _ = try ProvisioningProfile(propertyList: dictionary, file: "test.mobileprovision")
        }
        #expect(error?.message.hasPrefix("The provisioning profile test.mobileprovision has no valid ExpirationDate.") == true)
    }

    @Test func aCertificateThatIsNotDataIsNamed() throws {
        var dictionary = profileDictionary()
        dictionary["DeveloperCertificates"] = ["not data"]
        let error = matchBuildError {
            _ = try ProvisioningProfile(propertyList: dictionary, file: "test.mobileprovision")
        }
        #expect(error?.message.hasPrefix("The provisioning profile test.mobileprovision has no valid DeveloperCertificates.") == true)
    }

    @Test func certificateInfoReadsTheCommonNameHashAndExpiry() throws {
        let der = try matchPlainData(Self.certificatePath)
        let info = try CertificateInfo(der: der, file: Self.certificatePath)

        #expect(info.commonName == "SwiftCI Test Distribution (TEAMID1234)")
        #expect(info.sha1 == Insecure.SHA1.hash(data: der).map { String(format: "%02X", $0) }.joined())
        // Valid until 2046, see the README of the fixtures.
        #expect(info.expirationDate > Date(timeIntervalSince1970: 2_208_988_800))
        #expect(info.expirationDate < Date(timeIntervalSince1970: 2_524_608_000))
    }

    @Test func certificateInfoReadsTheExpiryOfAnExpiredCertificate() throws {
        let path = "certs/distribution/CERTIDEXPD.cer"
        let info = try CertificateInfo(der: matchPlainData(path), file: path)

        // 2020-01-01T00:00:00Z
        #expect(info.expirationDate == Date(timeIntervalSince1970: 1_577_836_800))
        #expect(info.commonName == "SwiftCI Test Distribution Expired (TEAMID1234)")
    }

    @Test func certificateInfoOfAFileThatIsNotACertificateNamesTheFile() throws {
        let error = matchBuildError {
            _ = try CertificateInfo(der: Data("not a certificate".utf8), file: "certs/distribution/X.cer")
        }
        #expect(error?.message.hasPrefix("The file certs/distribution/X.cer is not a certificate.") == true)
    }

    // MARK: - Helpers

    /// The dictionary of a profile with every key that the decoder reads, without `removed`.
    private func profileDictionary(removing removed: String? = nil) -> [String: Any] {
        var dictionary: [String: Any] = [
            "UUID": "11111111-1111-4111-8111-111111111111",
            "Name": "match AdHoc com.example.app1",
            "TeamIdentifier": ["TEAMID1234"],
            "ExpirationDate": Date(timeIntervalSince1970: 2_208_988_800),
            "DeveloperCertificates": [Data([0x30, 0x00])],
        ]
        if let removed {
            dictionary[removed] = nil
        }
        return dictionary
    }
}
