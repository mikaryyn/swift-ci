#if os(macOS)
@testable import SwiftCI
@testable import SwiftCIAppStoreConnect
@testable import SwiftCITestSupport
import Foundation
import SwiftCITesting
import Testing

extension GlobalStateTests {
    /// The metadata that the App Store check reads, and the URL rule. The HTTP client is a mock. Its responses are the
    /// JSON fixtures of `Fixtures/precheck`, and it matches each request URL exactly, query included, so a request that
    /// the check should not send fails the test. No request leaves the test.
    @Suite(.serialized) struct PrecheckMetadataTests {
        /// The ID of the app in the fixtures.
        static let appID = "1"

        /// The URL that the version list is requested from. Its query has the iOS filter, the two fields and `limit=200`.
        static let versionsURL = AppStoreConnectTests.url(
            "/v1/apps/1/appStoreVersions?filter%5Bplatform%5D=IOS&fields%5BappStoreVersions%5D=createdDate,copyright&limit=200"
        )
        static let appInfosURL = AppStoreConnectTests.url("/v1/apps/1/appInfos")
        static let appInfoLocalizationsURL = AppStoreConnectTests.url(
            "/v1/appInfos/info-1/appInfoLocalizations?fields%5BappInfoLocalizations%5D=locale,name,subtitle,privacyPolicyText,privacyPolicyUrl&limit=200"
        )
        static let versionLocalizationsURL = AppStoreConnectTests.url(
            "/v1/appStoreVersions/version-2/appStoreVersionLocalizations?fields%5BappStoreVersionLocalizations%5D=locale,keywords,description,whatsNew,supportUrl,marketingUrl&limit=200"
        )
        /// The `links.next` URL of the first page of the version localizations, as the fixture has it.
        static let versionLocalizationsPage2URL = URL(
            string: "https://api.appstoreconnect.apple.com/v1/appStoreVersions/version-2/appStoreVersionLocalizations?cursor=page-2"
        )!

        /// The URL that the URL rule requests, without fragment.
        static let exampleURL = URL(string: "https://example.com/x")!

        /// The fixture `Fixtures/precheck/<name>.json`.
        static func fixture(_ name: String) throws -> Data {
            let url = try #require(Bundle.module.resourceURL?.appending(path: "Fixtures/precheck/\(name).json"))
            return try Data(contentsOf: url)
        }

        /// The client of the tests, with the API key of the App Store Connect tests.
        static func client() -> AppStoreConnect {
            AppStoreConnect(apiKey: AppStoreConnectTests.apiKey())
        }

        /// A mock that answers every request for the app in the fixtures: the newest version, the app info and both pages of
        /// the version localizations.
        static func fullMock() throws -> HTTPClientMock {
            let client = HTTPClientMock()
            client.respond("GET", versionsURL, body: try fixture("appStoreVersions"))
            client.respond("GET", appInfosURL, body: try fixture("appInfos"))
            client.respond("GET", appInfoLocalizationsURL, body: try fixture("appInfoLocalizations"))
            client.respond("GET", versionLocalizationsURL, body: try fixture("appStoreVersionLocalizationsPage1"))
            client.respond("GET", versionLocalizationsPage2URL, body: try fixture("appStoreVersionLocalizationsPage2"))
            return client
        }

        /// The items of the app info of the fixtures, for the en-US localization.
        static let appInfoItems = [
            PrecheckItem(field: .appName, locale: "en-US", value: "MyApp"),
            PrecheckItem(field: .appSubtitle, locale: "en-US", value: "Track your tasks", isOptional: true),
            PrecheckItem(field: .privacyPolicyText, locale: "en-US", value: "We do not collect personal data."),
            PrecheckItem(field: .privacyPolicyURL, locale: "en-US", value: "https://example.com/privacy", isOptional: true),
        ]

        /// The items of the newest version of the fixtures: the copyright, then the localizations en-US and fi.
        static let versionItems = [
            PrecheckItem(field: .copyright, locale: nil, value: "© 2026 Example Team"),
            PrecheckItem(field: .keywords, locale: "en-US", value: "tasks,todo,planner"),
            PrecheckItem(field: .description, locale: "en-US", value: "MyApp helps you plan your day."),
            PrecheckItem(field: .releaseNotes, locale: "en-US", value: "Bug fixes and performance improvements."),
            PrecheckItem(field: .supportURL, locale: "en-US", value: "https://example.com/support"),
            PrecheckItem(field: .marketingURL, locale: "en-US", value: "https://example.com", isOptional: true),
            PrecheckItem(field: .keywords, locale: "fi", value: "tehtävät,suunnittelu"),
            PrecheckItem(field: .description, locale: "fi", value: "MyApp auttaa suunnittelemaan päivän."),
            PrecheckItem(field: .releaseNotes, locale: "fi", value: nil),
            PrecheckItem(field: .supportURL, locale: "fi", value: "https://example.com/tuki"),
            PrecheckItem(field: .marketingURL, locale: "fi", value: nil, isOptional: true),
        ]

        /// The rule named `No broken urls` of the current rules.
        static func urlRule() throws -> PrecheckRule {
            try #require(PrecheckRules.rules(currentYear: 2026).first { $0.name == "No broken urls" })
        }

        /// A URL item of the support URL field in the locale `en-US`.
        static func urlItem(_ value: String?, optional: Bool = false) -> PrecheckItem {
            PrecheckItem(field: .supportURL, locale: "en-US", value: value, isOptional: optional)
        }

        // MARK: Items

        @Test func itemsAreInFastlaneOrderWithFastlaneNames() async throws {
            let client = try Self.fullMock()
            let log = LogMock()

            let items = try await SwiftCITest.withMocks(httpClient: client, log: log) {
                try await Self.client().precheckItems(appID: Self.appID)
            }

            #expect(items == Self.appInfoItems + Self.versionItems)
            #expect(items.map(\.friendlyName) == [
                "app name: (en-US)",
                "app name subtitle: (en-US)",
                "\u{F8FF} tv privacy policy: (en-US)",
                "privacy URL: (en-US)",
                "copyright",
                "keywords: (en-US)",
                "description: (en-US)",
                "what's new: (en-US)",
                "support URL: (en-US)",
                "marketing URL: (en-US)",
                "keywords: (fi)",
                "description: (fi)",
                "what's new: (fi)",
                "support URL: (fi)",
                "marketing URL: (fi)",
            ])
            #expect(log.warnings.isEmpty)
        }

        @Test func theNewestVersionIsUsedAndEveryPageIsRead() async throws {
            let client = try Self.fullMock()

            _ = try await SwiftCITest.withMocks(httpClient: client) {
                try await Self.client().precheckItems(appID: Self.appID)
            }

            // The fixture lists the older version second, so the newest one is not the first of the list. Its
            // localizations are requested, and the second page is followed to the end.
            #expect(client.requests.map(\.url) == [
                Self.versionsURL,
                Self.appInfosURL,
                Self.appInfoLocalizationsURL,
                Self.versionLocalizationsURL,
                Self.versionLocalizationsPage2URL,
            ])
            #expect(client.requests.allSatisfy { $0.method == "GET" })
        }

        @Test func noVersionLogsAWarningAndChecksOnlyTheAppItems() async throws {
            let client = HTTPClientMock()
            client.respond("GET", Self.versionsURL, body: try Self.fixture("appStoreVersionsWithoutVersion"))
            client.respond("GET", Self.appInfosURL, body: try Self.fixture("appInfos"))
            client.respond("GET", Self.appInfoLocalizationsURL, body: try Self.fixture("appInfoLocalizations"))
            let log = LogMock()

            let items = try await SwiftCITest.withMocks(httpClient: client, log: log) {
                try await Self.client().precheckItems(appID: Self.appID)
            }

            #expect(items == Self.appInfoItems)
            #expect(log.warnings == ["No App Store version of app 1 to check."])
            #expect(client.requests.count == 3)
        }

        @Test func noAppInfoLogsAWarningAndChecksOnlyTheVersionItems() async throws {
            let client = HTTPClientMock()
            client.respond("GET", Self.versionsURL, body: try Self.fixture("appStoreVersions"))
            client.respond("GET", Self.appInfosURL, body: Data(#"{"data":[]}"#.utf8))
            client.respond("GET", Self.versionLocalizationsURL, body: try Self.fixture("appStoreVersionLocalizationsPage1"))
            client.respond("GET", Self.versionLocalizationsPage2URL, body: try Self.fixture("appStoreVersionLocalizationsPage2"))
            let log = LogMock()

            let items = try await SwiftCITest.withMocks(httpClient: client, log: log) {
                try await Self.client().precheckItems(appID: Self.appID)
            }

            #expect(items == Self.versionItems)
            #expect(log.warnings == ["No app info of app 1 to check."])
        }

        /// A version whose `createdDate` is not a timestamp stops the check with an error that names the field. The value
        /// is not in the message.
        @Test func invalidCreatedDateThrows() async throws {
            let client = HTTPClientMock()
            client.respond(
                "GET", Self.versionsURL,
                body: Data(#"{"data":[{"type":"appStoreVersions","id":"version-2","attributes":{"createdDate":"yesterday"}}]}"#.utf8)
            )

            let error = await SwiftCITest.withMocks(httpClient: client) {
                await thrownError {
                    _ = try await Self.client().precheckItems(appID: Self.appID)
                }
            }

            let message = try #require(error?.message)
            #expect(message.contains("createdDate"))
            #expect(!message.contains("yesterday"))
            #expect(client.requests.count == 1)
        }

        // MARK: URL rule

        @Test func reachableURLPassesWithAHeadRequestWithoutHeaders() async throws {
            let client = HTTPClientMock()
            client.respond("HEAD", Self.exampleURL, status: 200)

            let failure = try await SwiftCITest.withMocks(httpClient: client) {
                try await Self.urlRule().failure(for: Self.urlItem("https://example.com/x"))
            }

            #expect(failure == nil)
            let request = try #require(client.requests.first)
            #expect(client.requests.count == 1)
            #expect(request.method == "HEAD")
            #expect(request.url == Self.exampleURL)
            #expect(request.headers.isEmpty)
            #expect(request.secretHeaders.isEmpty)
            #expect(request.secretHeaders["Authorization"] == nil)
        }

        @Test func notFoundFailsWithTheStatusAndTheURL() async throws {
            let client = HTTPClientMock()
            client.respond("HEAD", Self.exampleURL, status: 404)

            let failure = try await SwiftCITest.withMocks(httpClient: client) {
                try await Self.urlRule().failure(for: Self.urlItem("https://example.com/x"))
            }

            #expect(failure == "HTTP 404: https://example.com/x")
        }

        @Test func transportErrorFailsAsUnreachable() async throws {
            let client = HTTPClientMock()
            client.respond("HEAD", Self.exampleURL, error: BuildError(message: "The connection was lost."))

            let failure = try await SwiftCITest.withMocks(httpClient: client) {
                try await Self.urlRule().failure(for: Self.urlItem("https://example.com/x"))
            }

            #expect(failure == "unreachable: https://example.com/x")
        }

        /// The fragment is not sent, but the failure shows the URL as it is written.
        @Test func fragmentIsRemovedFromTheRequestAndKeptInTheMessage() async throws {
            let client = HTTPClientMock()
            client.respond("HEAD", Self.exampleURL, status: 404)

            let failure = try await SwiftCITest.withMocks(httpClient: client) {
                try await Self.urlRule().failure(for: Self.urlItem("https://example.com/x#top"))
            }

            #expect(failure == "HTTP 404: https://example.com/x#top")
            #expect(client.requests.first?.url == Self.exampleURL)
        }

        @Test func surroundingWhitespaceIsTrimmed() async throws {
            let client = HTTPClientMock()
            client.respond("HEAD", Self.exampleURL, status: 404)

            let failure = try await SwiftCITest.withMocks(httpClient: client) {
                try await Self.urlRule().failure(for: Self.urlItem("  https://example.com/x \n"))
            }

            #expect(failure == "HTTP 404: https://example.com/x")
        }

        @Test func emptyURLFailsWithoutARequest() async throws {
            let client = HTTPClientMock()

            let failures = try await SwiftCITest.withMocks(httpClient: client) {
                let rule = try Self.urlRule()
                return [
                    await rule.failure(for: Self.urlItem("  ")),
                    await rule.failure(for: Self.urlItem("", optional: true)),
                    await rule.failure(for: Self.urlItem(nil)),
                ]
            }

            #expect(failures == ["empty url", nil, "empty url"])
            #expect(client.requests.isEmpty)
        }

        @Test func urlWithoutSchemeIsUnreachableWithoutARequest() async throws {
            let client = HTTPClientMock()

            let failure = try await SwiftCITest.withMocks(httpClient: client) {
                try await Self.urlRule().failure(for: Self.urlItem("example.com/x"))
            }

            #expect(failure == "unreachable: example.com/x")
            #expect(client.requests.isEmpty)
        }
    }
}
#endif
