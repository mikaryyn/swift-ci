@testable import SwiftCIXcode
@testable import SwiftCITestSupport
import Foundation
@testable import SwiftCI
import SwiftCITesting
import Testing

extension GlobalStateTests {
    /// The cache of `Xcode.getBuildSettings`: one `xcodebuild -showBuildSettings` run serves every call with the same
    /// arguments in a run. The mock runner counts the runs, so no `xcodebuild` is started.
    @Suite(.serialized) struct XcodeBuildSettingsCacheTests {
        /// The `-showBuildSettings -json` output of a scheme with two targets.
        static let twoTargetsJSON = #"""
        [
          {"action":"build","target":"MyApp","buildSettings":{"MARKETING_VERSION":"1.2","CURRENT_PROJECT_VERSION":"42"}},
          {"action":"build","target":"MyAppExtension","buildSettings":{"MARKETING_VERSION":"3.0","CURRENT_PROJECT_VERSION":"7"}}
        ]
        """#

        init() {
            Xcode.clearBuildSettingsCache()
        }

        func makeXcode(scheme: String = "MyApp", config: String? = nil, buildSettings: [String: String] = [:]) -> Xcode {
            Xcode(
                workspace: URL(filePath: "/work/MyApp.xcworkspace"),
                scheme: scheme,
                config: config,
                buildSettings: buildSettings
            )
        }

        /// The runs of `xcodebuild -showBuildSettings`, not counting other tools.
        func settingsRuns(_ runner: ProcessRunnerMock) -> Int {
            runner.tools.filter { $0.arguments.contains("-showBuildSettings") }.count
        }

        @Test func secondCallWithTheSameArgumentsRunsXcodebuildOnce() async throws {
            let (log, runner) = registerToolMocks()
            runner.responses = [.init(stdout: Self.twoTargetsJSON)]
            let xcode = makeXcode()

            let first = try await xcode.getBuildSettings(target: "MyApp")
            let second = try await xcode.getBuildSettings(target: "MyAppExtension")

            #expect(try first.marketingVersion == "1.2")
            #expect(try second.marketingVersion == "3.0")
            #expect(settingsRuns(runner) == 1)
            #expect(log.completions.filter { $0.contains("Getting Xcode build settings") }.count == 1)
        }

        /// A new `Xcode` value with the same arguments shares the cache, because the key is the arguments and not the value.
        @Test func anEqualXcodeValueUsesTheCache() async throws {
            let (_, runner) = registerToolMocks()
            runner.responses = [.init(stdout: Self.twoTargetsJSON)]

            _ = try await makeXcode(buildSettings: ["A": "B"]).getBuildSettings()
            _ = try await makeXcode(buildSettings: ["A": "B"]).getBuildSettings()

            #expect(settingsRuns(runner) == 1)
        }

        @Test func differentConfigRunsXcodebuildAgain() async throws {
            let (_, runner) = registerToolMocks()
            runner.responses = [.init(stdout: Self.twoTargetsJSON), .init(stdout: Self.twoTargetsJSON)]

            _ = try await makeXcode(config: "Debug").getBuildSettings()
            _ = try await makeXcode(config: "Release").getBuildSettings()

            #expect(settingsRuns(runner) == 2)
        }

        @Test func differentSchemeRunsXcodebuildAgain() async throws {
            let (_, runner) = registerToolMocks()
            runner.responses = [.init(stdout: Self.twoTargetsJSON), .init(stdout: Self.twoTargetsJSON)]

            _ = try await makeXcode(scheme: "MyApp").getBuildSettings()
            _ = try await makeXcode(scheme: "MyAppTests").getBuildSettings()

            #expect(settingsRuns(runner) == 2)
        }

        @Test func differentBuildSettingsRunXcodebuildAgain() async throws {
            let (_, runner) = registerToolMocks()
            runner.responses = [.init(stdout: Self.twoTargetsJSON), .init(stdout: Self.twoTargetsJSON)]

            _ = try await makeXcode(buildSettings: ["A": "B"]).getBuildSettings()
            _ = try await makeXcode(buildSettings: ["A": "C"]).getBuildSettings()

            #expect(settingsRuns(runner) == 2)
        }

        /// Output that is not JSON is a `BuildError` that names the scheme, and it is not cached.
        @Test func outputThatIsNotJSONIsABuildError() async throws {
            let (_, runner) = registerToolMocks()
            runner.responses = [.init(stdout: "xcodebuild: error: no such scheme"), .init(stdout: Self.twoTargetsJSON)]

            let error = await thrownError { _ = try await makeXcode().getBuildSettings() }
            _ = try await makeXcode().getBuildSettings()

            let message = try #require(error).message
            #expect(message.contains("Failed to read the build settings of MyApp"))
            #expect(settingsRuns(runner) == 2)
        }

        /// `value(for:)` throws for a missing setting and tells what to check, and the default form returns its default.
        @Test func valueForMissingSettingThrowsOrFallsBack() async throws {
            let (_, runner) = registerToolMocks()
            runner.responses = [.init(stdout: Self.twoTargetsJSON)]
            let settings = try await makeXcode().getBuildSettings()

            let error = await thrownError { _ = try settings.value(for: "NOT_DEFINED") }

            #expect(error?.message == "Failed to find the build setting 'NOT_DEFINED'. Check the scheme, configuration and target.")
            #expect(settings.value(for: "NOT_DEFINED", default: "x") == "x")
            #expect(settings.value(for: "MARKETING_VERSION", default: "x") == "1.2")
        }

        /// An empty list is a `BuildError`, so a missing value is not blamed on the build setting, and it is not cached.
        @Test func noBuildSettingsEntriesIsABuildError() async throws {
            let (_, runner) = registerToolMocks()
            runner.responses = [.init(stdout: "[]"), .init(stdout: Self.twoTargetsJSON)]

            let error = await thrownError { _ = try await makeXcode().getBuildSettings() }
            _ = try await makeXcode().getBuildSettings()

            #expect(error?.message == "xcodebuild reported no build settings for MyApp. Check that the scheme and the destination exist.")
            #expect(settingsRuns(runner) == 2)
        }

        /// The temporary xcconfig path is random, so the cache must not key on it. The same content gives one run.
        @Test func sameBuildSettingsContentWithDifferentXcconfigPathsUsesOneRun() async throws {
            let (_, runner) = registerToolMocks()
            runner.responses = [.init(stdout: Self.twoTargetsJSON)]

            _ = try await makeXcode(buildSettings: ["A": "B", "C": "D"]).getBuildSettings()
            let firstPath = try XcodeTests.argument(after: "-xcconfig", in: runner.tools[0])
            _ = try await makeXcode(buildSettings: ["C": "D", "A": "B"]).getBuildSettings()

            #expect(settingsRuns(runner) == 1)
            #expect(firstPath.hasSuffix(".xcconfig"))
        }

        /// `getVersion` reads the build settings once for two references, and it reads the Info.plist each time, so a
        /// build number written in between is seen.
        @Test func getVersionTwiceRunsXcodebuildOnce() async throws {
            let (_, runner) = registerToolMocks()
            runner.responses = [.init(stdout: Self.twoTargetsJSON)]
            let xcode = makeXcode()

            try await XcodeTestSupport.withInfoPlist(short: "$(MARKETING_VERSION)", build: "$(CURRENT_PROJECT_VERSION)") { url in
                let first = try await xcode.getVersion(infoPlist: url)
                #expect(first.marketingVersion == "1.2")
                #expect(first.buildNumber == "42")

                try Plist.save(to: url, contents: [
                    "CFBundleIdentifier": "com.example.myapp",
                    "CFBundleShortVersionString": "$(MARKETING_VERSION)",
                    "CFBundleVersion": "43",
                ])
                let second = try await xcode.getVersion(infoPlist: url)
                #expect(second.marketingVersion == "1.2")
                #expect(second.buildNumber == "43")
            }

            #expect(settingsRuns(runner) == 1)
        }

        /// A run that exits with an error is not cached, so the next call runs `xcodebuild` again.
        @Test func aFailedRunIsNotCached() async throws {
            let (_, runner) = registerToolMocks()
            runner.responses = [
                .init(stderr: "xcodebuild: error: scheme not found", exitCode: 65),
                .init(stdout: Self.twoTargetsJSON),
            ]
            let xcode = makeXcode()

            let error = await thrownError {
                _ = try await xcode.getBuildSettings()
            }
            #expect(error != nil)

            let settings = try await xcode.getBuildSettings()

            #expect(try settings.marketingVersion == "1.2")
            #expect(settingsRuns(runner) == 2)
        }
    }
}
