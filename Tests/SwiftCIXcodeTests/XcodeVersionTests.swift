@testable import SwiftCIXcode
@testable import SwiftCITestSupport
import Foundation
@testable import SwiftCI
import SwiftCITesting
import Testing

extension GlobalStateTests {
    /// `Xcode.getVersion` and the `target:` of `Xcode.getBuildSettings`, with a mock runner, so no `xcodebuild` is
    /// started. The Info.plist files are in a temporary directory that each test removes.
    @Suite(.serialized) struct XcodeVersionTests {
        static let baseArguments = [
            "-workspace", "/work/MyApp.xcworkspace", "-scheme", "MyApp", "-destination", "generic/platform=iOS",
        ]

        /// The `-showBuildSettings -json` output of a scheme with two targets. The first target also has `MAJOR` and
        /// `MINOR`, for references that are combined with text.
        static let twoTargetsJSON = #"""
        [
          {"action":"build","target":"MyApp","buildSettings":{"MAJOR":"5","MINOR":"2","MARKETING_VERSION":"1.2","CURRENT_PROJECT_VERSION":"42"}},
          {"action":"build","target":"MyAppExtension","buildSettings":{"MARKETING_VERSION":"3.0","CURRENT_PROJECT_VERSION":"7"}}
        ]
        """#

        func makeXcode() -> Xcode {
            Xcode(workspace: URL(filePath: "/work/MyApp.xcworkspace"), scheme: "MyApp", config: .init(xcconfig: [:]))
        }

        /// Runs `body` with an Info.plist that has the two version keys, in a temporary directory that is removed
        /// afterwards. `body` gets the path of the file.
        func withInfoPlist(short: String, build: String, _ body: (URL) async throws -> Void) async throws {
            let dir = try TemporaryDirectory(name: "XcodeVersionTests-$UUID")
            defer { try? FileManager.default.removeItem(at: dir.url) }
            let url = dir.childURL(name: "Info.plist")
            _ = try Plist.save(to: url, contents: [
                "CFBundleIdentifier": "com.example.myapp",
                "CFBundleShortVersionString": short,
                "CFBundleVersion": build,
            ])
            try await body(url)
        }

        @Test func getBuildSettingsWithTargetUsesTheMatchingEntry() async throws {
            let (_, runner) = registerToolMocks()
            runner.responses = [response(stdout: Self.twoTargetsJSON)]

            let settings = try await makeXcode().getBuildSettings(target: "MyAppExtension")

            #expect(try settings.marketingVersion == "3.0")
            #expect(runner.tools.count == 1)
            #expect(runner.tools[0].arguments == ["-showBuildSettings", "-json"] + Self.baseArguments)
        }

        @Test func getBuildSettingsWithoutTargetStillUsesTheFirstEntry() async throws {
            let (_, runner) = registerToolMocks()
            runner.responses = [response(stdout: Self.twoTargetsJSON)]

            let settings = try await makeXcode().getBuildSettings()

            #expect(try settings.marketingVersion == "1.2")
        }

        @Test func getBuildSettingsUnknownTargetListsTheAvailableTargets() async throws {
            let (_, runner) = registerToolMocks()
            runner.responses = [response(stdout: Self.twoTargetsJSON)]

            let error = await thrownError {
                _ = try await makeXcode().getBuildSettings(target: "Nope")
            }

            #expect(error?.message == "Failed to find target 'Nope' in the build settings. Available targets: MyApp, MyAppExtension.")
        }

        @Test func getBuildSettingsUnknownTargetWithoutTargetsSaysNone() async throws {
            let (_, runner) = registerToolMocks()
            runner.responses = [response(stdout: #"[{"action":"build","buildSettings":{}}]"#)]

            let error = await thrownError {
                _ = try await makeXcode().getBuildSettings(target: "MyApp")
            }

            #expect(error?.message == "Failed to find target 'MyApp' in the build settings. Available targets: none.")
        }

        /// Literal values are returned as they are, so `xcodebuild` is not run.
        @Test func getVersionReturnsLiteralValuesWithoutRunningXcodebuild() async throws {
            let (_, runner) = registerToolMocks()

            try await withInfoPlist(short: "1.2", build: "42") { url in
                let version = try await makeXcode().getVersion(infoPlist: url)

                #expect(version.marketingVersion == "1.2")
                #expect(version.buildNumber == "42")
            }
            #expect(runner.tools.isEmpty)
        }

        @Test func getVersionResolvesDollarParenAndDollarBraceReferences() async throws {
            let (_, runner) = registerToolMocks()
            runner.responses = [response(stdout: Self.twoTargetsJSON)]

            try await withInfoPlist(short: "$(MARKETING_VERSION)", build: "${CURRENT_PROJECT_VERSION}") { url in
                let version = try await makeXcode().getVersion(infoPlist: url)

                #expect(version.marketingVersion == "1.2")
                #expect(version.buildNumber == "42")
            }
            #expect(runner.tools.count == 1)
            #expect(runner.tools[0].arguments == ["-showBuildSettings", "-json"] + Self.baseArguments)
        }

        /// With several targets, the references are resolved from the requested target.
        @Test func getVersionResolvesFromTheRequestedTarget() async throws {
            let (_, runner) = registerToolMocks()
            runner.responses = [response(stdout: Self.twoTargetsJSON)]

            try await withInfoPlist(short: "$(MARKETING_VERSION)", build: "$(CURRENT_PROJECT_VERSION)") { url in
                let version = try await makeXcode().getVersion(infoPlist: url, target: "MyAppExtension")

                #expect(version.marketingVersion == "3.0")
                #expect(version.buildNumber == "7")
            }
        }

        /// Text around a reference is kept, so `$(MAJOR).$(MINOR).0` gives `5.2.0`.
        @Test func getVersionCombinesTextAndReferences() async throws {
            let (_, runner) = registerToolMocks()
            runner.responses = [response(stdout: Self.twoTargetsJSON)]

            try await withInfoPlist(short: "$(MAJOR).$(MINOR).0", build: "1.$(CURRENT_PROJECT_VERSION)") { url in
                let version = try await makeXcode().getVersion(infoPlist: url)

                #expect(version.marketingVersion == "5.2.0")
                #expect(version.buildNumber == "1.42")
            }
        }

        /// A reference that the build settings do not define fails, and the message names the variable and the file.
        @Test func getVersionUndefinedVariableNamesTheVariableAndTheFile() async throws {
            let (_, runner) = registerToolMocks()
            runner.responses = [response(stdout: Self.twoTargetsJSON)]

            try await withInfoPlist(short: "$(NOT_DEFINED)", build: "42") { url in
                let error = await thrownError {
                    _ = try await makeXcode().getVersion(infoPlist: url)
                }

                #expect(error?.message == "Failed to find build setting 'NOT_DEFINED' referenced in the Info.plist at '\(url.filePath)'. Check the scheme, configuration and target.")
            }
        }

        @Test func getVersionMissingKeyNamesTheKeyAndTheFile() async throws {
            let (_, runner) = registerToolMocks()
            let dir = try TemporaryDirectory(name: "XcodeVersionTests-$UUID")
            defer { try? FileManager.default.removeItem(at: dir.url) }
            let url = dir.childURL(name: "Info.plist")
            _ = try Plist.save(to: url, contents: ["CFBundleVersion": "42"])

            let error = await thrownError {
                _ = try await makeXcode().getVersion(infoPlist: url)
            }

            #expect(error?.message == "Failed to read key 'CFBundleShortVersionString' from Plist file at '\(url.filePath)'.")
            #expect(runner.tools.isEmpty)
        }

        /// A query does not open a step, also when it reads the build settings.
        @Test func getVersionOpensNoStep() async throws {
            let runner = ProcessRunnerMock()
            runner.responses = [response(stdout: Self.twoTargetsJSON)]
            let xcode = makeXcode()

            let result = await SwiftCITest.run(["query"]) {
                register(ProcessRunner.self, runner)
                command(Command("query") {
                    try await withInfoPlist(short: "$(MARKETING_VERSION)", build: "42") { url in
                        _ = try await xcode.getVersion(infoPlist: url)
                    }
                })
            }

            #expect(result.exitCode == 0)
            #expect(enteredSteps(in: result.log).isEmpty)
        }
    }
}
