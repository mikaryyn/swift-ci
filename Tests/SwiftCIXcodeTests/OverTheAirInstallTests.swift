@testable import SwiftCIXcode
@testable import SwiftCITestSupport
import Foundation
import SwiftCI
import SwiftCITesting
import Testing

extension GlobalStateTests {
    /// The files of an over-the-air install, written by a command of a SwiftCI run into a temporary artifacts directory.
    @Suite(.serialized) struct OverTheAirInstallTests {
        static let ipaURL = URL(string: "https://downloads.example.com/MyApp.ipa")!
        static let manifestURL = URL(string: "https://downloads.example.com/manifest.plist")!

        /// Runs `writeManifest` as the only step of a command, with the manifest in `artifacts`.
        static func runWriteManifest(
            _ artifacts: URL,
            ipaURL: URL = Self.ipaURL,
            title: String = "MyApp",
            step: String? = nil
        ) async -> SwiftCITestResult {
            await SwiftCITest.run(["write"], artifactsDirectory: artifacts) {
                command(Command("write") {
                    try await OverTheAirInstall.writeManifest(
                        to: artifacts.appending(path: "manifest.plist"),
                        ipaURL: ipaURL,
                        bundleIdentifier: "com.example.myapp",
                        bundleVersion: "42",
                        title: title,
                        step: step
                    )
                })
            }
        }

        /// Runs `writeInstallPage` as the only step of a command, with the page in `artifacts`.
        static func runWriteInstallPage(
            _ artifacts: URL,
            manifestURL: URL = Self.manifestURL,
            title: String = "MyApp",
            step: String? = nil
        ) async -> SwiftCITestResult {
            await SwiftCITest.run(["page"], artifactsDirectory: artifacts) {
                command(Command("page") {
                    try await OverTheAirInstall.writeInstallPage(
                        to: artifacts.appending(path: "index.html"),
                        manifestURL: manifestURL,
                        title: title,
                        step: step
                    )
                })
            }
        }

        /// The manifest decodes back to the values that were written, including `&`, `<` and non-ASCII characters.
        @Test func manifestDecodesBackToTheWrittenValues() async throws {
            let artifacts = temporaryArtifactsDirectory()
            defer { try? FileManager.default.removeItem(at: artifacts.deletingLastPathComponent()) }
            let ipaURL = URL(string: "https://downloads.example.com/My%20App.ipa?token=a&b=<c>")!
            let title = "My App & <Beta> — Café"

            let result = await Self.runWriteManifest(artifacts, ipaURL: ipaURL, title: title)

            #expect(result.exitCode == 0)
            let manifest = try Plist.read(url: artifacts.appending(path: "manifest.plist"))
            let items = try #require(manifest["items"] as? [[String: Any]])
            #expect(items.count == 1)
            let assets = try #require(items[0]["assets"] as? [[String: String]])
            #expect(assets == [["kind": "software-package", "url": ipaURL.absoluteString]])
            let metadata = try #require(items[0]["metadata"] as? [String: String])
            #expect(metadata == [
                "bundle-identifier": "com.example.myapp",
                "bundle-version": "42",
                "kind": "software",
                "title": title,
            ])
        }

        /// An IPA URL that is not `https` logs one warning, and the manifest is still written.
        @Test func manifestWithAnHTTPIpaURLLogsOneWarning() async throws {
            let artifacts = temporaryArtifactsDirectory()
            defer { try? FileManager.default.removeItem(at: artifacts.deletingLastPathComponent()) }

            let result = await Self.runWriteManifest(artifacts, ipaURL: URL(string: "http://localhost:8080/MyApp.ipa")!)

            #expect(result.exitCode == 0)
            #expect(result.plainLog.filter { $0.contains("is not https") }.count == 1)
            #expect(FileManager.default.fileExists(atPath: artifacts.appending(path: "manifest.plist").filePath))
        }

        /// An `https` IPA URL logs no warning.
        @Test func manifestWithAnHTTPSIpaURLLogsNoWarning() async {
            let artifacts = temporaryArtifactsDirectory()
            defer { try? FileManager.default.removeItem(at: artifacts.deletingLastPathComponent()) }

            let result = await Self.runWriteManifest(artifacts)

            #expect(result.exitCode == 0)
            #expect(!result.plainLog.contains { $0.contains("is not https") })
        }

        /// The redirect and the link both carry the percent-encoded manifest URL, so the encoded query value is exact.
        @Test func installPageContainsTheEncodedManifestURLInTheRedirectAndTheLink() async throws {
            let artifacts = temporaryArtifactsDirectory()
            defer { try? FileManager.default.removeItem(at: artifacts.deletingLastPathComponent()) }
            let manifestURL = URL(string: "https://downloads.example.com/manifest.plist?x=1&y=2")!

            let result = await Self.runWriteInstallPage(artifacts, manifestURL: manifestURL)

            #expect(result.exitCode == 0)
            let html = try String(contentsOf: artifacts.appending(path: "index.html"), encoding: .utf8)
            let encoded = "itms-services://?action=download-manifest&amp;url=https%3A%2F%2Fdownloads.example.com%2Fmanifest.plist%3Fx%3D1%26y%3D2"
            #expect(html.components(separatedBy: encoded).count == 3)
            #expect(html.contains("<meta http-equiv=\"refresh\" content=\"0; url=\(encoded)\">"))
            #expect(html.contains("<a href=\"\(encoded)\">MyApp</a>"))
        }

        /// The title is HTML-escaped where it is shown, so markup in it does not change the page.
        @Test func installPageEscapesTheTitle() async throws {
            let artifacts = temporaryArtifactsDirectory()
            defer { try? FileManager.default.removeItem(at: artifacts.deletingLastPathComponent()) }

            let result = await Self.runWriteInstallPage(artifacts, title: #"A & <B> "C" 'D'"#)

            #expect(result.exitCode == 0)
            let html = try String(contentsOf: artifacts.appending(path: "index.html"), encoding: .utf8)
            let escaped = "A &amp; &lt;B&gt; &quot;C&quot; &#39;D&#39;"
            #expect(html.contains("<title>\(escaped)</title>"))
            #expect(html.contains("<a href=\"itms-services://?action=download-manifest&amp;url=https%3A%2F%2Fdownloads.example.com%2Fmanifest.plist\">\(escaped)</a>"))
            #expect(!html.contains("<B>"))
        }

        /// A manifest URL that is not `https` logs one warning, and the page is still written.
        @Test func installPageWithAnHTTPManifestURLLogsOneWarning() async throws {
            let artifacts = temporaryArtifactsDirectory()
            defer { try? FileManager.default.removeItem(at: artifacts.deletingLastPathComponent()) }

            let result = await Self.runWriteInstallPage(artifacts, manifestURL: URL(string: "http://localhost:8080/manifest.plist")!)

            #expect(result.exitCode == 0)
            #expect(result.plainLog.filter { $0.contains("is not https") }.count == 1)
            #expect(FileManager.default.fileExists(atPath: artifacts.appending(path: "index.html").filePath))
        }

        /// An `https` manifest URL logs no warning.
        @Test func installPageWithAnHTTPSManifestURLLogsNoWarning() async {
            let artifacts = temporaryArtifactsDirectory()
            defer { try? FileManager.default.removeItem(at: artifacts.deletingLastPathComponent()) }

            let result = await Self.runWriteInstallPage(artifacts)

            #expect(result.exitCode == 0)
            #expect(!result.plainLog.contains { $0.contains("is not https") })
        }

        /// Each call opens one step with its default name.
        @Test func eachCallOpensOneStepWithItsDefaultName() async {
            let artifacts = temporaryArtifactsDirectory()
            defer { try? FileManager.default.removeItem(at: artifacts.deletingLastPathComponent()) }

            let manifest = await Self.runWriteManifest(artifacts)
            let page = await Self.runWriteInstallPage(artifacts)

            #expect(enteredSteps(in: manifest.log) == ["Entering step [Write over-the-air manifest]"])
            #expect(enteredSteps(in: page.log) == ["Entering step [Write over-the-air install page]"])
        }

        /// `step:` renames the step of each call.
        @Test func stepNameCanBeChanged() async {
            let artifacts = temporaryArtifactsDirectory()
            defer { try? FileManager.default.removeItem(at: artifacts.deletingLastPathComponent()) }

            let manifest = await Self.runWriteManifest(artifacts, step: "Write the manifest")
            let page = await Self.runWriteInstallPage(artifacts, step: "Write the page")

            #expect(enteredSteps(in: manifest.log) == ["Entering step [Write the manifest]"])
            #expect(enteredSteps(in: page.log) == ["Entering step [Write the page]"])
        }
    }
}
