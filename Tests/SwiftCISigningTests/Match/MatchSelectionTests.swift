@testable import SwiftCISigning
@testable import SwiftCITestSupport
@testable import SwiftCI
import CryptoKit
import Foundation
import SwiftCITesting
import Testing

/// Selection of the signing assets from a match repository, against the fixtures in `Fixtures/Match`. The checkout is
/// the fixture itself, so no clone runs.
@Suite struct MatchSelectionTests {
    static let password = "fixture-password"
    static let teamId = "TEAMID1234"
    /// 2030-01-01. The fixtures expire in 2046, and the expired ones expired before this date.
    static let now = Date(timeIntervalSince1970: 1_893_456_000)
    static let mainCertificate = "certs/distribution/CERTID1234.cer"
    static let mainKey = "certs/distribution/CERTID1234.p12"
    static let app1Profile = "profiles/adhoc/AdHoc_com.example.app1.mobileprovision"
    static let app2Profile = "profiles/adhoc/AdHoc_com.example.app2.mobileprovision"

    /// Selects from `checkout` (a fixture name, or a URL of a copy), with the fixture password unless `password` is given.
    func select(
        _ type: MatchType = .adhoc,
        _ identifiers: [String],
        checkout: String = "v2",
        url: URL? = nil,
        teamId: String = Self.teamId,
        password: String = Self.password,
        now: Date = Self.now
    ) throws -> MatchAssets {
        try MatchSelection.select(
            type: type,
            bundleIdentifiers: identifiers,
            teamId: teamId,
            checkout: url ?? matchFixtureURL(checkout),
            password: password,
            now: now
        )
    }

    // MARK: - Selection

    @Test func adhocProfilesOfTwoIdentifiersShareOneCertificate() throws {
        let assets = try select(.adhoc, ["com.example.app1", "com.example.app2"])

        #expect(assets.profiles.map(\.bundleIdentifier) == ["com.example.app1", "com.example.app2"])
        #expect(assets.profiles.map(\.file) == [Self.app1Profile, Self.app2Profile])
        #expect(assets.profiles.map(\.certificateFile) == [Self.mainCertificate, Self.mainCertificate])
        #expect(assets.profiles.map(\.profile.uuid) == ["11111111-1111-4111-8111-111111111111", "22222222-2222-4222-8222-222222222222"])
        #expect(assets.profiles.map(\.profile.name) == ["match AdHoc com.example.app1", "match AdHoc com.example.app2"])
        #expect(assets.profiles.allSatisfy { $0.profile.teamIdentifiers == [Self.teamId] })
        let app1 = try matchPlainData(Self.app1Profile)
        let app2 = try matchPlainData(Self.app2Profile)
        #expect(assets.profiles[0].data == app1)
        #expect(assets.profiles[1].data == app2)

        #expect(assets.certificates.count == 1)
        let certificate = try #require(assets.certificates.first)
        let der = try matchPlainData(Self.mainCertificate)
        let key = try matchPlainData(Self.mainKey)
        #expect(certificate.file == Self.mainCertificate)
        #expect(certificate.certificateData == der)
        #expect(certificate.privateKeyData == key)
        #expect(certificate.info.commonName == "SwiftCI Test Distribution (TEAMID1234)")
        #expect(certificate.info.sha1 == Insecure.SHA1.hash(data: der).map { String(format: "%02X", $0) }.joined())
    }

    /// CERTID9999 is in the repository, and it sorts after CERTID1234. A rule that takes the last certificate by name
    /// would pick it. No profile was made for it, so selection must neither choose it nor decrypt it.
    @Test func theCertificateIsTheOneOfTheProfileNotTheLastByName() throws {
        let assets = try select(.adhoc, ["com.example.app1"])

        #expect(assets.profiles[0].certificateFile == Self.mainCertificate)
        #expect(!assets.certificates.contains { $0.file == "certs/distribution/CERTID9999.cer" })
    }

    @Test func appstoreProfileIsReadFromItsOwnFolder() throws {
        let assets = try select(.appstore, ["com.example.app1"])

        #expect(assets.profiles.map(\.file) == ["profiles/appstore/AppStore_com.example.app1.mobileprovision"])
        #expect(assets.profiles[0].profile.name == "match AppStore com.example.app1")
        #expect(assets.profiles[0].certificateFile == Self.mainCertificate)
    }

    @Test func duplicateIdentifiersAreReadOnceInTheOrderOfTheirFirstAppearance() throws {
        let assets = try select(.adhoc, ["com.example.app2", "com.example.app1", "com.example.app2"])

        #expect(assets.profiles.map(\.bundleIdentifier) == ["com.example.app2", "com.example.app1"])
    }

    @Test func noIdentifierIsAUsageError() throws {
        let error = matchBuildError { _ = try select(.adhoc, []) }

        #expect(error?.code == .usage)
    }

    @Test func aMissingProfileNamesTheIdentifierAndThePath() throws {
        let message = matchBuildError { _ = try select(.adhoc, ["com.example.missing"]) }?.message

        #expect(message?.contains("com.example.missing") == true)
        #expect(message?.contains("profiles/adhoc/AdHoc_com.example.missing.mobileprovision") == true)
    }

    /// The folder and the file name of the development type are the ones that fastlane match writes.
    @Test func aMissingDevelopmentProfileIsLookedUpInTheDevelopmentFolder() throws {
        let message = matchBuildError { _ = try select(.development, ["com.example.app1"]) }?.message

        #expect(message?.contains("profiles/development/Development_com.example.app1.mobileprovision") == true)
    }

    @Test func aProfileOfAnotherTeamNamesBothTeams() throws {
        let message = matchBuildError { _ = try select(.adhoc, ["com.example.otherteam"]) }?.message

        #expect(message?.contains("OTHERTEAM1") == true)
        #expect(message?.contains(Self.teamId) == true)
        #expect(message?.contains("profiles/adhoc/AdHoc_com.example.otherteam.mobileprovision") == true)
    }

    @Test func anExpiredProfileNamesTheFileAndTheDate() throws {
        let message = matchBuildError { _ = try select(.adhoc, ["com.example.expired"]) }?.message

        #expect(message?.contains("profiles/adhoc/AdHoc_com.example.expired.mobileprovision") == true)
        #expect(message?.contains("expired on 2020-01-01") == true)
    }

    /// The profile lists a certificate that the repository does not hold, so none of its certificates is the one.
    @Test func aProfileWhoseCertificateIsNotInTheRepositoryIsAnError() throws {
        let message = matchBuildError { _ = try select(.adhoc, ["com.example.nocert"]) }?.message

        #expect(message?.contains("None of the certificates in certs/distribution/") == true)
        #expect(message?.contains("profiles/adhoc/AdHoc_com.example.nocert.mobileprovision") == true)
    }

    @Test func anExpiredCertificateNamesItsFile() throws {
        let message = matchBuildError { _ = try select(.adhoc, ["com.example.expiredcert"]) }?.message

        #expect(message?.contains("certs/distribution/CERTIDEXPD.cer") == true)
        #expect(message?.contains("expired on 2020-01-01") == true)
    }

    @Test func aMissingPrivateKeyNamesItsPath() throws {
        let copy = try fixtureCopy("v2") { root in
            try FileManager.default.removeItem(at: root.appending(path: Self.mainKey))
        }
        let message = matchBuildError {
            _ = try select(.adhoc, ["com.example.app1"], url: copy.url)
        }?.message

        #expect(message?.contains("certs/distribution/CERTID1234.p12") == true)
    }

    @Test func aWrongPasswordFailsOnTheFirstFileDecrypted() throws {
        let message = matchBuildError {
            _ = try select(.adhoc, ["com.example.app1"], password: "wrong-password")
        }?.message

        #expect(message == "Couldn't decrypt \(Self.app1Profile). Check the match password.")
        #expect(message?.contains("wrong-password") == false)
    }

    @Test func aMissingCertificateFolderIsTheNoCertificateError() throws {
        let copy = try fixtureCopy("v2") { root in
            try FileManager.default.removeItem(at: root.appending(path: "certs/distribution"))
        }
        let message = matchBuildError {
            _ = try select(.adhoc, ["com.example.app1"], url: copy.url)
        }?.message

        #expect(message?.contains("None of the certificates in certs/distribution/") == true)
    }

    /// The same selection on the v1 format, which is decrypted with its own code path.
    @Test func v1RepositoryIsSelectedToo() throws {
        let assets = try select(.adhoc, ["com.example.app1"], checkout: "v1")
        let app1 = try matchPlainData(Self.app1Profile)
        let key = try matchPlainData(Self.mainKey)

        #expect(assets.profiles[0].data == app1)
        #expect(assets.certificates.map(\.file) == [Self.mainCertificate])
        #expect(assets.certificates[0].privateKeyData == key)
    }

    @Test func defaultNowSelectsTheValidFixtures() throws {
        let assets = try MatchSelection.select(
            type: .adhoc,
            bundleIdentifiers: ["com.example.app1"],
            teamId: Self.teamId,
            checkout: matchFixtureURL("v2"),
            password: Self.password
        )

        #expect(assets.profiles.map(\.file) == [Self.app1Profile])
    }

    // MARK: - Copies of a fixture

    /// A copy of the fixture `name` in a new temporary directory, which `modify` changes before the copy is used. The
    /// directory is removed when the copy is released, with ``FixtureCopy/deinit``.
    func fixtureCopy(_ name: String, modify: (URL) throws -> Void) throws -> FixtureCopy {
        let copy = try FixtureCopy(source: matchFixtureURL(name))
        try modify(copy.url)
        return copy
    }
}

/// A copy of a fixture in a temporary directory. The directory is removed when the value goes away.
final class FixtureCopy {
    let url: URL
    private let root: URL

    init(source: URL) throws {
        root = FileManager.default.temporaryDirectory.appending(
            path: "swiftci-match-copy-\(UUID().uuidString)", directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        url = root.appending(path: "repository", directoryHint: .isDirectory)
        try FileManager.default.copyItem(at: source, to: url)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }
}
