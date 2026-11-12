#if os(macOS)
@testable import SwiftCI
@testable import SwiftCIAppStoreConnect
@testable import SwiftCITestSupport
import Foundation
import SwiftCITesting
import Testing

extension GlobalStateTests {
    /// Reads the facts of IPAs with the real `unzip`, on the small committed archives in `Fixtures`. The real tool is used
    /// because the behavior under test is how `unzip` matches entry names, which a mock cannot show. No network is used.
    @Suite(.serialized) struct IPAInfoTests {
        /// The archive `Fixtures/<name>.ipa`.
        static func fixture(_ name: String) throws -> URL {
            try #require(Bundle.module.resourceURL?.appending(path: "Fixtures/\(name).ipa"))
        }

        @Test func readsTheFactsOfTheAppInTheIPA() async throws {
            let restore = isolatedGlobalState()
            defer { restore() }
            let log = useRealRunner()

            let info = try await IPAInfo.read(Self.fixture("MyApp"))

            #expect(info == IPAInfo(
                bundleIdentifier: "com.example.myapp", shortVersion: "1.2.3", buildVersion: "42", platform: "IOS"
            ))
            // The listing and the extraction are hidden from the console.
            #expect(log.loggedLines.isEmpty)
        }

        /// The app name has `*`, `[` and `?`. A nested app that a wildcard would also match is in the archive, and the
        /// values come from the app itself.
        @Test func appNameWithWildcardCharactersMatchesOnlyItsOwnEntry() async throws {
            let restore = isolatedGlobalState()
            defer { restore() }
            _ = useRealRunner()

            let info = try await IPAInfo.read(Self.fixture("WildcardName"))

            #expect(info.bundleIdentifier == "com.example.wildcard")
        }

        @Test func archiveWithoutAnAppThrowsNamingTheIPA() async throws {
            let restore = isolatedGlobalState()
            defer { restore() }
            _ = useRealRunner()
            let ipa = try Self.fixture("NoApp")

            let error = await thrownError { _ = try await IPAInfo.read(ipa) }

            #expect(error?.message.contains(ipa.filePath) == true)
            #expect(error?.message.contains("no app in its Payload folder") == true)
        }

        @Test func archiveWithTwoAppsThrowsNamingBoth() async throws {
            let restore = isolatedGlobalState()
            defer { restore() }
            _ = useRealRunner()
            let ipa = try Self.fixture("TwoApps")

            let error = await thrownError { _ = try await IPAInfo.read(ipa) }

            #expect(error?.message.contains(ipa.filePath) == true)
            #expect(error?.message.contains("more than one app") == true)
            #expect(error?.message.contains("MyApp, Other") == true)
        }

        @Test func missingBuildVersionThrowsNamingTheKey() async throws {
            let restore = isolatedGlobalState()
            defer { restore() }
            _ = useRealRunner()
            let ipa = try Self.fixture("MissingBuildVersion")

            let error = await thrownError { _ = try await IPAInfo.read(ipa) }

            #expect(error?.message.contains(ipa.filePath) == true)
            #expect(error?.message.contains("has no CFBundleVersion") == true)
        }

        @Test func macOSAppThrowsThatOnlyIOSIsSupported() async throws {
            let restore = isolatedGlobalState()
            defer { restore() }
            _ = useRealRunner()
            let ipa = try Self.fixture("MacPlatform")

            let error = await thrownError { _ = try await IPAInfo.read(ipa) }

            #expect(error?.message.contains(ipa.filePath) == true)
            #expect(error?.message.contains("is for the platform macosx") == true)
            #expect(error?.message.contains("Only iOS IPAs") == true)
        }

        @Test func missingFileThrowsNamingThePath() async throws {
            let restore = isolatedGlobalState()
            defer { restore() }
            _ = useRealRunner()
            let directory = try TemporaryDirectory(name: "ipa-info-tests-$UUID")
            defer { try? FileManager.default.removeItem(at: directory.url) }
            let ipa = directory.childURL(name: "Missing.ipa")

            let error = await thrownError { _ = try await IPAInfo.read(ipa) }

            #expect(error?.message.contains(ipa.filePath) == true)
            #expect(error?.message.contains("does not exist") == true)
        }

        @Test func fileThatIsNotAZipThrowsNamingTheIPA() async throws {
            let restore = isolatedGlobalState()
            defer { restore() }
            _ = useRealRunner()
            let directory = try TemporaryDirectory(name: "ipa-info-tests-$UUID")
            defer { try? FileManager.default.removeItem(at: directory.url) }
            let ipa = directory.childURL(name: "NotAnArchive.ipa")
            try Data("not a zip archive".utf8).write(to: ipa)

            let error = await thrownError { _ = try await IPAInfo.read(ipa) }

            #expect(error?.message.contains(ipa.filePath) == true)
            #expect(error?.message.contains("is not a readable zip archive") == true)
            #expect(error?.message.contains("unzip said: [\(ipa.filePath)] End-of-central-directory signature not found.") == true)
        }

        /// The full log explains the reading before the `unzip` command, and the console gets no part of it.
        @Test func readingIsExplainedInTheFullLogBeforeUnzip() async throws {
            let restore = isolatedGlobalState()
            defer { restore() }
            var fullLog = ""
            var consoleLines: [String] = []

            try await withTemporaryArtifactsDirectory { artifacts in
                try await SwiftCITest.withMocks(artifactsDirectory: artifacts) {
                    try FullLog.open(name: "read")
                    let log = useRealRunner()
                    _ = try await IPAInfo.read(Self.fixture("MyApp"))
                    fullLog = try String(contentsOfFile: #require(FullLog.path).filePath, encoding: .utf8)
                    consoleLines = log.loggedLines
                    try FullLog.close()
                }
            }

            let lines = fullLog.components(separatedBy: "\n")
            let explanation = try #require(lines.firstIndex { $0.hasPrefix("Reading the bundle identifier, version, build number and platform from the Info.plist of the app in ") })
            let unzip = try #require(lines.firstIndex { $0 == "➤ Command /usr/bin/unzip" })
            #expect(explanation < unzip)
            #expect(lines[explanation].hasSuffix(": listing the archive, then extracting only the Info.plist."))
            #expect(!consoleLines.contains { $0.contains("Reading the bundle identifier") })
        }

        /// The escaped pattern is the name with each wildcard character as a class that matches only itself.
        @Test func unzipPatternEscapesWildcardCharacters() {
            #expect(IPAInfo.unzipPattern(for: "My*[1]?.app") == "My[*][[]1][?].app")
            #expect(IPAInfo.unzipPattern(for: "Plain.app") == "Plain.app")
        }
    }
}

/// Registers the real process runner and a log mock, so that `unzip` runs for real and its output goes to the mock.
/// Call it inside a test that restores the global state.
private func useRealRunner() -> LogMock {
    registerDependencies()
    let log = LogMock()
    register(Log.self, log)
    return log
}
#endif
