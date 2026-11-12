#if os(macOS)
@testable import SwiftCI
@testable import SwiftCIAppStoreConnect
@testable import SwiftCITestSupport
import Foundation
import SwiftCITesting
import Testing

extension GlobalStateTests {
    /// The public check run as a command, so that its step, its console lines and its report warnings are real. The HTTP
    /// client is a mock that answers the fixtures of ``PrecheckMetadataTests`` and a HEAD request for each of their URLs.
    @Suite(.serialized) struct PrecheckTests {
        /// The outcome of one run of the check: its result or error, the report at the end of the command body, and the
        /// console lines of the run.
        struct CheckRun {
            let result: PrecheckResult?
            let error: BuildError?
            let report: RunReport?
            let run: SwiftCITestResult
        }

        /// Runs `precheck(appID:step:)` inside a command, with `client` as the HTTP client.
        static func check(_ client: HTTPClientMock, step: String? = nil) async -> CheckRun {
            var result: PrecheckResult?
            var error: BuildError?
            var report: RunReport?
            let run = await SwiftCITest.run(["check"], httpClient: client) {
                command(Command("check") {
                    error = await thrownError {
                        result = try await PrecheckMetadataTests.client().precheck(appID: PrecheckMetadataTests.appID, step: step)
                    }
                    report = Report.current
                })
            }
            return CheckRun(result: result, error: error, report: report, run: run)
        }

        /// A mock of the fixtures of the app. Each `replacing` pair replaces every occurrence of its first text in every
        /// fixture, so a test can change one value. `supportStatus` is the status of the HEAD request to the en-US support URL.
        static func mock(replacing replacements: [(String, String)] = [], supportStatus: Int = 200) throws -> HTTPClientMock {
            func body(_ name: String) throws -> Data {
                var text = String(decoding: try PrecheckMetadataTests.fixture(name), as: UTF8.self)
                for (old, new) in replacements {
                    text = text.replacingOccurrences(of: old, with: new)
                }
                return Data(text.utf8)
            }
            let client = HTTPClientMock()
            client.respond("GET", PrecheckMetadataTests.versionsURL, body: try body("appStoreVersions"))
            client.respond("GET", PrecheckMetadataTests.appInfosURL, body: try body("appInfos"))
            client.respond("GET", PrecheckMetadataTests.appInfoLocalizationsURL, body: try body("appInfoLocalizations"))
            client.respond("GET", PrecheckMetadataTests.versionLocalizationsURL, body: try body("appStoreVersionLocalizationsPage1"))
            client.respond("GET", PrecheckMetadataTests.versionLocalizationsPage2URL, body: try body("appStoreVersionLocalizationsPage2"))
            client.respond("HEAD", URL(string: "https://example.com/privacy")!, status: 200)
            client.respond("HEAD", URL(string: "https://example.com/support")!, status: supportStatus)
            client.respond("HEAD", URL(string: "https://example.com")!, status: 200)
            client.respond("HEAD", URL(string: "https://example.com/tuki")!, status: 200)
            return client
        }

        // MARK: Findings

        /// Findings come in rule order, then item order, and each rule logs one line. Each finding is then a report warning, in the
        /// same order.
        @Test func findingsAreListedInRuleOrderAndReported() async throws {
            let client = try Self.mock(
                replacing: [
                    ("Bug fixes and performance improvements.", "Coming soon: sync."),
                    ("MyApp auttaa suunnittelemaan päivän.", "MyApp placeholder päivän."),
                ],
                supportStatus: 404
            )

            let outcome = await Self.check(client)

            let expected = [
                PrecheckFinding(rule: "No placeholder text", field: "description: (fi)", reason: "found: placeholder"),
                PrecheckFinding(
                    rule: "No future functionality promises", field: "what's new: (en-US)", reason: "found: coming soon"
                ),
                PrecheckFinding(
                    rule: "No broken urls", field: "support URL: (en-US)", reason: "HTTP 404: https://example.com/support"
                ),
            ]
            #expect(outcome.error == nil)
            #expect(outcome.result == PrecheckResult(findings: expected))
            #expect(outcome.run.exitCode == 0)

            let lines = outcome.run.plainLog
            #expect(lines.filter { $0.contains("Failed: ") } == [
                "<Warning> Failed: No placeholder text -> using placeholder text (e.g.:\"lorem ipsum\", \"text here\", etc...)",
                "<Warning> Failed: No future functionality promises -> mentioning features or content that is not currently available in your app",
                "<Warning> Failed: No broken urls -> unreachable URLs in app metadata",
            ])
            // Each finding is a report warning, which prints its own console line, and the closing line comes last.
            let index = try #require(lines.firstIndex { $0.hasPrefix("<Warning> App Store metadata: ") })
            #expect(Array(lines[index...(index + 2)]) == [
                "<Warning> App Store metadata: description: (fi): found: placeholder",
                "<Warning> App Store metadata: what's new: (en-US): found: coming soon",
                "<Warning> App Store metadata: support URL: (en-US): HTTP 404: https://example.com/support",
            ])
            #expect(lines[index + 3] == "App Store metadata check found potential problems. They do not fail the build.")

            let warnings = try #require(outcome.report?.warnings.map(\.text))
            #expect(warnings == [
                "App Store metadata: description: (fi): found: placeholder",
                "App Store metadata: what's new: (en-US): found: coming soon",
                "App Store metadata: support URL: (en-US): HTTP 404: https://example.com/support",
            ])
        }

        // MARK: No findings

        /// Without findings every rule logs `Passed:`, the closing line says there are no potential problems, and the report
        /// has no warnings.
        @Test func noFindingsLogsThePassedRulesAndNoReportWarnings() async throws {
            let client = try Self.mock()

            let outcome = await Self.check(client)

            #expect(outcome.error == nil)
            #expect(outcome.result == PrecheckResult(findings: []))
            #expect(outcome.run.exitCode == 0)
            let lines = outcome.run.plainLog
            for rule in PrecheckRules.all {
                #expect(lines.contains("Passed: \(rule.name)"))
            }
            #expect(lines.filter { $0.hasPrefix("Passed: ") }.count == PrecheckRules.all.count)
            #expect(lines.contains("App Store metadata check found no potential problems."))
            #expect(!lines.contains { $0.contains("<Warning>") })
            #expect(outcome.report?.warnings.isEmpty == true)
        }

        /// The step has the default name unless the caller gives one.
        @Test func stepNameCanBeChanged() async throws {
            let client = try Self.mock()

            let outcome = await Self.check(client, step: "Check App Store metadata of MyApp")

            #expect(outcome.run.plainLog.contains("Entering step [Check App Store metadata of MyApp]"))
            #expect(!outcome.run.plainLog.contains("Entering step [Check App Store metadata]"))
        }

        // MARK: Errors

        /// An App Store Connect error stops the check. It throws, the step is logged as failed, no rule runs and no warning is
        /// added to the report.
        @Test func appStoreConnectErrorThrows() async throws {
            let client = HTTPClientMock()
            client.respond("GET", PrecheckMetadataTests.versionsURL, status: 403)

            let outcome = await Self.check(client)

            #expect(outcome.result == nil)
            #expect(outcome.error != nil)
            #expect(outcome.run.plainLog.contains("Step [Check App Store metadata] failed"))
            #expect(!outcome.run.plainLog.contains { $0.hasPrefix("Passed: ") || $0.contains("Failed: ") })
            #expect(outcome.report?.warnings.isEmpty == true)
        }
    }
}
#endif
