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
            Xcode.clearBuildSettingsCache()
            return Xcode(workspace: URL(filePath: "/work/MyApp.xcworkspace"), scheme: "MyApp", buildSettings: [:])
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
                "distributionBundleIdentifier", "method", "provisioningProfiles", "signingCertificate",
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
                "distributionBundleIdentifier", "method", "provisioningProfiles", "signingCertificate",
                "teamID",
            ])
        }

        /// The `xcodebuild archive` run.
        func archiveTool(_ runner: ProcessRunnerMock) throws -> Tool {
            try #require(runner.tools.first { $0.arguments.contains("-archivePath") && !$0.arguments.contains("-exportArchive") })
        }

        /// The temporary directory of the archive and the export is removed when the step ends.
        @Test func temporaryDirectoryIsRemovedAfterTheStep() async throws {
            let runner = ProcessRunnerMock()
            runner.handler = GlobalStateTests.XcodeTests.archiveAndExportHandler(exportedIpaName: "MyApp.ipa")
            let xcode = makeXcode()
            let artifacts = temporaryArtifactsDirectory()
            defer { try? FileManager.default.removeItem(at: artifacts.deletingLastPathComponent()) }

            let result = await SwiftCITest.run(["release"], artifactsDirectory: artifacts) {
                register(ProcessRunner.self, runner)
                command(Command("release") {
                    let exported = try await xcode.archiveAndExport(ipaFileName: "MyApp")
                    #expect(exported.archiveURL == nil)
                })
            }

            #expect(result.exitCode == 0)
            let archivePath = try GlobalStateTests.XcodeTests.argument(after: "-archivePath", in: try archiveTool(runner))
            let directory = URL(filePath: archivePath).deletingLastPathComponent().filePath
            #expect(!FileManager.default.fileExists(atPath: directory))
        }

        /// A failed export removes the temporary directory too.
        @Test func temporaryDirectoryIsRemovedWhenTheExportFails() async throws {
            let runner = ProcessRunnerMock()
            let answer = GlobalStateTests.XcodeTests.archiveAndExportHandler(exportedIpaName: "MyApp.ipa")
            runner.handler = { tool in
                if tool.arguments.contains("-exportArchive") {
                    return .init(stderr: "error: export failed", exitCode: 70)
                }
                return try answer(tool)
            }
            let xcode = makeXcode()
            let artifacts = temporaryArtifactsDirectory()
            defer { try? FileManager.default.removeItem(at: artifacts.deletingLastPathComponent()) }

            let result = await SwiftCITest.run(["release"], artifactsDirectory: artifacts) {
                register(ProcessRunner.self, runner)
                command(Command("release") {
                    _ = try await xcode.archiveAndExport(ipaFileName: "MyApp")
                })
            }

            #expect(result.exitCode != 0)
            let archivePath = try GlobalStateTests.XcodeTests.argument(after: "-archivePath", in: try archiveTool(runner))
            let directory = URL(filePath: archivePath).deletingLastPathComponent().filePath
            #expect(!FileManager.default.fileExists(atPath: directory))
        }

        /// With `archiveURL`, the archive is written there and kept, an archive of an earlier run is replaced, and the
        /// dSYMs are zipped from it. Only the export folder is removed.
        @Test func archiveURLKeepsTheArchive() async throws {
            let runner = ProcessRunnerMock()
            runner.handler = GlobalStateTests.XcodeTests.archiveAndExportHandler(exportedIpaName: "MyApp.ipa")
            let xcode = makeXcode()
            let artifacts = temporaryArtifactsDirectory()
            defer { try? FileManager.default.removeItem(at: artifacts.deletingLastPathComponent()) }
            let kept = artifacts.appending(path: "kept/MyApp.xcarchive", directoryHint: .isDirectory)
            let old = kept.appending(path: "old.txt")
            try FileManager.default.createDirectory(at: kept, withIntermediateDirectories: true)
            try Data("old".utf8).write(to: old)
            var exported: Xcode.ExportedApp?

            let result = await SwiftCITest.run(["release"], artifactsDirectory: artifacts) {
                register(ProcessRunner.self, runner)
                command(Command("release") {
                    exported = try await xcode.archiveAndExport(ipaFileName: "MyApp", archiveURL: kept)
                })
            }

            #expect(result.exitCode == 0)
            #expect(exported?.archiveURL == kept)
            #expect(try GlobalStateTests.XcodeTests.argument(after: "-archivePath", in: try archiveTool(runner)) == kept.filePath)
            #expect(FileManager.default.fileExists(atPath: kept.appending(path: "Info.plist").filePath))
            #expect(!FileManager.default.fileExists(atPath: old.filePath))
            let ditto = try #require(runner.tools.first { $0.command == "/usr/bin/ditto" })
            #expect(ditto.arguments.contains(kept.appending(path: "dSYMs").filePath))
            let exportTool = try #require(runner.tools.first { $0.arguments.contains("-exportArchive") })
            let exportPath = try GlobalStateTests.XcodeTests.argument(after: "-exportPath", in: exportTool)
            #expect(!FileManager.default.fileExists(atPath: exportPath))
        }
    }
}
