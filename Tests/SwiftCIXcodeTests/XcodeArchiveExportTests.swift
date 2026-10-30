@testable import SwiftCIXcode
@testable import SwiftCITestSupport
import Foundation
@testable import SwiftCI
import SwiftCITesting
import Testing

extension GlobalStateTests {
    /// The export method and the provisioning profile of `archiveAndExport`, with a mock runner, so no `xcodebuild` is
    /// started. The export options plist is read while the export runs, because the export folder is removed afterwards.
    @Suite(.serialized) struct XcodeArchiveExportTests {
        func makeXcode() -> Xcode {
            Xcode(workspace: URL(filePath: "/work/MyApp.xcworkspace"), scheme: "MyApp", config: .init(xcconfig: [:]))
        }

        /// The export options plist that xcodebuild reads during the export.
        final class ExportOptionsCapture {
            var plist: [String: Any] = [:]
        }

        /// Answers the runs as `XcodeTests.archiveAndExportHandler` does, and stores the export options in `capture`.
        func makeRunner(capture: ExportOptionsCapture) -> ProcessRunnerMock {
            let runner = ProcessRunnerMock()
            let answer = GlobalStateTests.XcodeTests.archiveAndExportHandler(exportedIpaName: "MyApp.ipa")
            runner.handler = { tool in
                if tool.arguments.contains("-exportArchive") {
                    let path = try GlobalStateTests.XcodeTests.argument(after: "-exportOptionsPlist", in: tool)
                    capture.plist = try Plist.read(url: URL(filePath: path))
                }
                return try answer(tool)
            }
            return runner
        }

        /// An App Store export names the profile from the closure, with the bundle identifier of the archive. It writes
        /// the IPA only, and does not manage the version and build numbers.
        @Test func appStoreExportOptionsUseTheProfileOfTheClosureAndExportOnly() async throws {
            let capture = ExportOptionsCapture()
            let runner = makeRunner(capture: capture)
            let xcode = makeXcode()
            var bundleIdentifiers: [String] = []
            let artifacts = temporaryArtifactsDirectory()
            defer { try? FileManager.default.removeItem(at: artifacts.deletingLastPathComponent()) }

            let result = await SwiftCITest.run(["release"], artifactsDirectory: artifacts) {
                register(ProcessRunner.self, runner)
                command(Command("release") {
                    _ = try await xcode.archiveAndExport(
                        ipaFileName: "MyApp",
                        method: .appstore,
                        provisioningProfile: { bundleIdentifier in
                            bundleIdentifiers.append(bundleIdentifier)
                            return "match AppStore \(bundleIdentifier)"
                        }
                    )
                })
            }

            #expect(result.exitCode == 0)
            #expect(bundleIdentifiers == ["com.example.myapp"])
            #expect(capture.plist["method"] as? String == "app-store-connect")
            #expect(capture.plist["destination"] as? String == "export")
            #expect(capture.plist["manageAppVersionAndBuildNumber"] as? Bool == false)
            #expect(capture.plist["provisioningProfiles"] as? [String: String] == [
                "com.example.myapp": "match AppStore com.example.myapp",
            ])
            #expect(Set(capture.plist.keys) == [
                "compileBitcode", "distributionBundleIdentifier", "method", "provisioningProfiles", "signingCertificate",
                "teamID", "destination", "manageAppVersionAndBuildNumber",
            ])
            #expect(capture.plist["distributionBundleIdentifier"] as? String == "com.example.myapp")
            #expect(capture.plist["signingCertificate"] as? String == "Apple Distribution")
            #expect(capture.plist["teamID"] as? String == "TEAMID1234")
        }

        /// With a closure, the build settings are not read for the profile: no `-showBuildSettings` run.
        @Test func closureReplacesTheBuildSettingsRun() async throws {
            let capture = ExportOptionsCapture()
            let runner = makeRunner(capture: capture)
            let xcode = makeXcode()
            let artifacts = temporaryArtifactsDirectory()
            defer { try? FileManager.default.removeItem(at: artifacts.deletingLastPathComponent()) }

            let result = await SwiftCITest.run(["release"], artifactsDirectory: artifacts) {
                register(ProcessRunner.self, runner)
                command(Command("release") {
                    _ = try await xcode.archiveAndExport(ipaFileName: "MyApp", provisioningProfile: { _ in "MyApp Ad Hoc" })
                })
            }

            #expect(result.exitCode == 0)
            #expect(!runner.tools.contains { $0.arguments.contains("-showBuildSettings") })
            #expect(capture.plist["provisioningProfiles"] as? [String: String] == ["com.example.myapp": "MyApp Ad Hoc"])
        }

        /// Without the closure, an ad-hoc export keeps its options: the profile of the build settings, and no App Store
        /// keys.
        @Test func adHocExportWithoutClosureUsesTheBuildSettingsProfile() async throws {
            let capture = ExportOptionsCapture()
            let runner = makeRunner(capture: capture)
            let xcode = makeXcode()
            let artifacts = temporaryArtifactsDirectory()
            defer { try? FileManager.default.removeItem(at: artifacts.deletingLastPathComponent()) }

            let result = await SwiftCITest.run(["release"], artifactsDirectory: artifacts) {
                register(ProcessRunner.self, runner)
                command(Command("release") {
                    _ = try await xcode.archiveAndExport(ipaFileName: "MyApp")
                })
            }

            #expect(result.exitCode == 0)
            #expect(runner.tools.filter { $0.arguments.contains("-showBuildSettings") }.count == 1)
            #expect(capture.plist["method"] as? String == "ad-hoc")
            #expect(capture.plist["provisioningProfiles"] as? [String: String] == ["com.example.myapp": "MyApp AppStore"])
            #expect(Set(capture.plist.keys) == [
                "compileBitcode", "distributionBundleIdentifier", "method", "provisioningProfiles", "signingCertificate",
                "teamID",
            ])
        }
    }
}
