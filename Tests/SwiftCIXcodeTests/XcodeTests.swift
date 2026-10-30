@testable import SwiftCIXcode
@testable import SwiftCITestSupport
import Foundation
@testable import SwiftCI
import SwiftCITesting
import Testing

extension GlobalStateTests {
    /// `Xcode` with a mock runner, so no `xcodebuild` is started. The configuration has no xcconfig, so no file is
    /// written and the arguments are exact.
    @Suite(.serialized) struct XcodeTests {
        static let baseArguments = [
            "-workspace", "/work/MyApp.xcworkspace", "-scheme", "MyApp", "-destination", "generic/platform=iOS",
        ]

        func makeXcode() -> Xcode {
            Xcode(workspace: URL(filePath: "/work/MyApp.xcworkspace"), scheme: "MyApp", config: .init(xcconfig: [:]))
        }

        @Test func cleanRunsXcodebuildWithTheExpectedArguments() async throws {
            let (_, runner) = registerToolMocks()

            try await makeXcode().clean()

            #expect(runner.tools.count == 1)
            #expect(runner.tools[0].command == "/usr/bin/xcodebuild")
            #expect(runner.tools[0].arguments == ["clean"] + Self.baseArguments)
        }

        @Test func buildRunsXcodebuildWithTheExpectedArguments() async throws {
            let (_, runner) = registerToolMocks()

            try await makeXcode().build()

            #expect(runner.tools.count == 1)
            #expect(runner.tools[0].command == "/usr/bin/xcodebuild")
            #expect(runner.tools[0].arguments == ["build"] + Self.baseArguments)
        }

        @Test func resolvePackagesRunsXcodebuildWithTheExpectedArguments() async throws {
            let (_, runner) = registerToolMocks()

            try await makeXcode().resolvePackages()

            #expect(runner.tools.count == 1)
            #expect(runner.tools[0].command == "/usr/bin/xcodebuild")
            #expect(runner.tools[0].arguments == ["-resolvePackageDependencies"] + Self.baseArguments)
        }

        /// The three steps open their default names at the top level of a command.
        @Test func stepsOpenTheirDefaultNamesAtTopLevel() async {
            let runner = ProcessRunnerMock()
            let xcode = makeXcode()

            let result = await SwiftCITest.run(["all"]) {
                register(ProcessRunner.self, runner)
                command(Command("all") {
                    try await xcode.clean()
                    try await xcode.build()
                    try await xcode.resolvePackages()
                })
            }

            #expect(result.exitCode == 0)
            #expect(enteredSteps(in: result.log) == [
                "Entering step [Clean MyApp]",
                "Entering step [Build MyApp]",
                "Entering step [Resolve packages for MyApp]",
            ])
            #expect(runner.tools.count == 3)
        }

        /// The step name can be changed with `step:`.
        @Test func stepNameCanBeChanged() async {
            let runner = ProcessRunnerMock()
            let xcode = makeXcode()

            let result = await SwiftCITest.run(["named"]) {
                register(ProcessRunner.self, runner)
                command(Command("named") {
                    try await xcode.build(step: "Compile the app")
                })
            }

            #expect(enteredSteps(in: result.log) == ["Entering step [Compile the app]"])
        }

        /// Build settings are decoded from stdout. stderr holds noise, which is not part of the value. The console
        /// filter hides the build settings lines, so the noise does not reach the console either.
        @Test func getBuildSettingsDecodesStdoutWhileStderrHasNoise() async throws {
            let (log, runner) = registerToolMocks()
            let json = #"[{"action":"build","buildSettings":{"BUILT_PRODUCTS_DIR":"/out","MARKETING_VERSION":"1.2"}}]"#
            runner.responses = [ProcessRunnerMock.Response(
                lines: [stdoutLine(json), stderrLine("warning: noise")],
                result: ToolResult(stdout: json, stderr: "warning: noise", exitCode: 0)
            )]

            let settings = try await makeXcode().getBuildSettings()

            #expect(try settings.get(key: "MARKETING_VERSION") == "1.2")
            #expect(try settings.builtProductsDir == "/out")
            #expect(runner.tools.count == 1)
            #expect(runner.tools[0].command == "/usr/bin/xcodebuild")
            #expect(runner.tools[0].arguments == ["-showBuildSettings", "-json"] + Self.baseArguments)
            #expect(!log.loggedLines.contains { $0.contains("noise") })
        }

        /// A query does not open a step.
        @Test func getBuildSettingsOpensNoStep() async {
            let runner = ProcessRunnerMock()
            let json = #"[{"action":"build","buildSettings":{}}]"#
            runner.responses = [response(stdout: json)]
            let xcode = makeXcode()

            let result = await SwiftCITest.run(["query"]) {
                register(ProcessRunner.self, runner)
                command(Command("query") {
                    _ = try await xcode.getBuildSettings()
                })
            }

            #expect(result.exitCode == 0)
            #expect(enteredSteps(in: result.log).isEmpty)
        }

        /// What the archive's `dSYMs` folder holds: nothing (no folder), an empty folder, or one `.dSYM` bundle.
        enum DSYMsFolder {
            case missing, empty, withBundle
        }

        /// Answers the xcodebuild runs of `archiveAndExport` as Xcode does: the build settings, the archive's `Info.plist`
        /// in `-archivePath` with the `dSYMs` folder that `dSYMs` describes, and an exported IPA named `exportedIpaName`
        /// in `-exportPath`. It answers `ditto` by writing `new zip` to the last argument, the zip.
        static func archiveAndExportHandler(
            exportedIpaName: String,
            dSYMs: DSYMsFolder = .withBundle
        ) -> ProcessRunnerMock.Handler {
            { tool in
                if tool.command == "/usr/bin/ditto" {
                    try Data("new zip".utf8).write(to: URL(filePath: try #require(tool.arguments.last)))
                    return ProcessRunnerMock.Response()
                }
                if tool.arguments.contains("-showBuildSettings") {
                    let json = #"[{"action":"build","buildSettings":{"PROVISIONING_PROFILE_SPECIFIER":"MyApp AppStore"}}]"#
                    return response(stdout: json)
                }
                if tool.arguments.contains("archive") {
                    let archiveURL = URL(filePath: try argument(after: "-archivePath", in: tool))
                    try FileManager.default.createDirectory(at: archiveURL, withIntermediateDirectories: true)
                    let info: [String: Any] = ["ApplicationProperties": [
                        "CFBundleIdentifier": "com.example.myapp",
                        "SigningIdentity": "Apple Distribution",
                        "Team": "TEAMID1234",
                    ]]
                    let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
                    try data.write(to: archiveURL.appending(path: "Info.plist"))
                    let dSYMsURL = archiveURL.appending(path: "dSYMs", directoryHint: .isDirectory)
                    switch dSYMs {
                    case .missing:
                        break
                    case .empty:
                        try FileManager.default.createDirectory(at: dSYMsURL, withIntermediateDirectories: true)
                    case .withBundle:
                        let bundleURL = dSYMsURL.appending(path: "MyApp.app.dSYM", directoryHint: .isDirectory)
                        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
                        try Data("dsym".utf8).write(to: bundleURL.appending(path: "Info.plist"))
                    }
                    return ProcessRunnerMock.Response()
                }
                if tool.arguments.contains("-exportArchive") {
                    let exportURL = URL(filePath: try argument(after: "-exportPath", in: tool))
                    try FileManager.default.createDirectory(at: exportURL, withIntermediateDirectories: true)
                    try Data("new ipa".utf8).write(to: exportURL.appending(path: exportedIpaName))
                    return ProcessRunnerMock.Response()
                }
                return ProcessRunnerMock.Response()
            }
        }

        static func argument(after flag: String, in tool: Tool) throws -> String {
            guard let index = tool.arguments.firstIndex(of: flag), index + 1 < tool.arguments.count else {
                throw BuildError(message: "Test expected the argument \(flag) in \(tool.arguments)")
            }
            return tool.arguments[index + 1]
        }

        /// Without `outputURL`, the IPA is copied into the artifacts directory of the run.
        @Test func archiveAndExportCopiesTheIpaToTheArtifactsDirectory() async throws {
            let runner = ProcessRunnerMock()
            runner.handler = Self.archiveAndExportHandler(exportedIpaName: "MyApp-export.ipa")
            let artifacts = temporaryArtifactsDirectory()
            defer { try? FileManager.default.removeItem(at: artifacts.deletingLastPathComponent()) }
            let xcode = makeXcode()

            let result = await SwiftCITest.run(["release"], artifactsDirectory: artifacts) {
                register(ProcessRunner.self, runner)
                command(Command("release") {
                    _ = try await xcode.archiveAndExport(ipaFileName: "MyApp")
                })
            }

            #expect(result.exitCode == 0)
            // The directory URL may carry a trailing slash, so compare the paths without it.
            #expect(result.artifactsDirectory.filePath.trimmingCharacters(in: ["/"]) == artifacts.filePath.trimmingCharacters(in: ["/"]))
            let ipa = artifacts.appending(path: "MyApp.ipa")
            #expect(try String(contentsOf: ipa, encoding: .utf8) == "new ipa")
            // The full log is in the same directory, in logs/.
            #expect(try Set(FileManager.default.contentsOfDirectory(atPath: artifacts.filePath)) == ["MyApp.ipa", "MyApp.dSYM.zip", "logs"])
            #expect(runner.tools.count == 4)
        }

        /// The dSYMs of the archive are zipped with `ditto` to `<ipaFileName>.dSYM.zip` in the output directory. The zip
        /// keeps the `.dSYM` bundles at its root, so `ditto` zips the `dSYMs` folder itself, not `--keepParent`.
        @Test func archiveAndExportZipsTheDSYMsToTheArtifactsDirectory() async throws {
            let runner = ProcessRunnerMock()
            runner.handler = Self.archiveAndExportHandler(exportedIpaName: "MyApp.ipa")
            let artifacts = temporaryArtifactsDirectory()
            defer { try? FileManager.default.removeItem(at: artifacts.deletingLastPathComponent()) }
            let xcode = makeXcode()

            let result = await SwiftCITest.run(["release"], artifactsDirectory: artifacts) {
                register(ProcessRunner.self, runner)
                command(Command("release") {
                    _ = try await xcode.archiveAndExport(ipaFileName: "MyApp")
                })
            }

            #expect(result.exitCode == 0)
            #expect(runner.tools.count == 4)
            let ditto = runner.tools[3]
            #expect(ditto.command == "/usr/bin/ditto")
            #expect(ditto.arguments.count == 5)
            #expect(Array(ditto.arguments.prefix(3)) == ["-c", "-k", "--sequesterRsrc"])
            #expect(ditto.arguments[3].hasSuffix("/MyApp.xcarchive/dSYMs"))
            #expect(ditto.arguments[4].hasSuffix("/MyApp.dSYM.zip"))
            #expect(try String(contentsOf: artifacts.appending(path: "MyApp.dSYM.zip"), encoding: .utf8) == "new zip")
        }

        /// The export passes only the archive, the export path and the options plist. xcodebuild rejects a workspace
        /// without a scheme there.
        @Test func archiveAndExportRunsTheExportWithoutProjectArguments() async throws {
            let runner = ProcessRunnerMock()
            runner.handler = Self.archiveAndExportHandler(exportedIpaName: "MyApp.ipa")
            let artifacts = temporaryArtifactsDirectory()
            defer { try? FileManager.default.removeItem(at: artifacts.deletingLastPathComponent()) }
            let xcode = Xcode(
                workspace: URL(filePath: "/work/MyApp.xcworkspace"),
                scheme: "MyApp",
                configuration: "Release",
                config: .init(xcconfig: ["A": "B"])
            )

            let result = await SwiftCITest.run(["release"], artifactsDirectory: artifacts) {
                register(ProcessRunner.self, runner)
                command(Command("release") {
                    _ = try await xcode.archiveAndExport(ipaFileName: "MyApp")
                })
            }

            #expect(result.exitCode == 0)
            let export = try #require(runner.tools.first { $0.arguments.contains("-exportArchive") })
            #expect(export.arguments.count == 7)
            #expect(export.arguments.first == "-exportArchive")
            #expect(export.arguments[1] == "-archivePath")
            #expect(export.arguments[2].hasSuffix("/MyApp.xcarchive"))
            #expect(export.arguments[3] == "-exportPath")
            #expect(export.arguments[5] == "-exportOptionsPlist")
            #expect(export.arguments[6].hasSuffix("/export_options.plist"))
        }

        /// `includeDSYMZip: false` writes the IPA only, and runs no `ditto`.
        @Test func archiveAndExportWithoutDSYMZipRunsNoDitto() async throws {
            let runner = ProcessRunnerMock()
            runner.handler = Self.archiveAndExportHandler(exportedIpaName: "MyApp.ipa")
            let artifacts = temporaryArtifactsDirectory()
            defer { try? FileManager.default.removeItem(at: artifacts.deletingLastPathComponent()) }
            let xcode = makeXcode()

            let result = await SwiftCITest.run(["release"], artifactsDirectory: artifacts) {
                register(ProcessRunner.self, runner)
                command(Command("release") {
                    _ = try await xcode.archiveAndExport(ipaFileName: "MyApp", includeDSYMZip: false)
                })
            }

            #expect(result.exitCode == 0)
            #expect(runner.tools.count == 3)
            #expect(!runner.tools.contains { $0.command == "/usr/bin/ditto" })
            #expect(try Set(FileManager.default.contentsOfDirectory(atPath: artifacts.filePath)) == ["MyApp.ipa", "logs"])
        }

        /// An archive without dSYMs, a missing or an empty `dSYMs` folder, logs a warning and succeeds without a zip. A zip
        /// from an earlier run is removed, so it does not sit next to the new IPA.
        @Test func archiveAndExportWarnsAndContinuesWithoutDSYMs() async throws {
            for dSYMs in [DSYMsFolder.missing, .empty] {
                let runner = ProcessRunnerMock()
                runner.handler = Self.archiveAndExportHandler(exportedIpaName: "MyApp.ipa", dSYMs: dSYMs)
                let artifacts = temporaryArtifactsDirectory()
                defer { try? FileManager.default.removeItem(at: artifacts.deletingLastPathComponent()) }
                try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
                try Data("old zip".utf8).write(to: artifacts.appending(path: "MyApp.dSYM.zip"))
                let xcode = makeXcode()

                let result = await SwiftCITest.run(["release"], artifactsDirectory: artifacts) {
                    register(ProcessRunner.self, runner)
                    command(Command("release") {
                        _ = try await xcode.archiveAndExport(ipaFileName: "MyApp")
                    })
                }

                #expect(result.exitCode == 0)
                #expect(runner.tools.count == 3)
                #expect(!FileManager.default.fileExists(atPath: artifacts.appending(path: "MyApp.dSYM.zip").filePath))
                #expect(result.log.contains { stripANSI($0).contains("No dSYMs in") })
            }
        }

        /// A zip of the same name from an earlier run is replaced by the new one.
        @Test func archiveAndExportReplacesADSYMZipFromAnEarlierRun() async throws {
            let runner = ProcessRunnerMock()
            runner.handler = Self.archiveAndExportHandler(exportedIpaName: "MyApp.ipa")
            let artifacts = temporaryArtifactsDirectory()
            defer { try? FileManager.default.removeItem(at: artifacts.deletingLastPathComponent()) }
            try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
            try Data("old zip".utf8).write(to: artifacts.appending(path: "MyApp.dSYM.zip"))
            let xcode = makeXcode()

            let result = await SwiftCITest.run(["release"], artifactsDirectory: artifacts) {
                register(ProcessRunner.self, runner)
                command(Command("release") {
                    _ = try await xcode.archiveAndExport(ipaFileName: "MyApp")
                })
            }

            #expect(result.exitCode == 0)
            #expect(try String(contentsOf: artifacts.appending(path: "MyApp.dSYM.zip"), encoding: .utf8) == "new zip")
        }

        /// A custom `outputURL` that does not exist yet is created.
        @Test func archiveAndExportCreatesAMissingOutputDirectory() async throws {
            let runner = ProcessRunnerMock()
            runner.handler = Self.archiveAndExportHandler(exportedIpaName: "MyApp.ipa")
            let artifacts = temporaryArtifactsDirectory()
            defer { try? FileManager.default.removeItem(at: artifacts.deletingLastPathComponent()) }
            let output = artifacts.appending(path: "ipas/nested", directoryHint: .isDirectory)
            let xcode = makeXcode()

            let result = await SwiftCITest.run(["release"], artifactsDirectory: artifacts) {
                register(ProcessRunner.self, runner)
                command(Command("release") {
                    _ = try await xcode.archiveAndExport(ipaFileName: "MyApp", outputURL: output)
                })
            }

            #expect(result.exitCode == 0)
            #expect(try String(contentsOf: output.appending(path: "MyApp.ipa"), encoding: .utf8) == "new ipa")
        }

        /// An IPA of the same name from an earlier run is replaced, so a second run into the same directory succeeds.
        @Test func archiveAndExportReplacesAnIpaFromAnEarlierRun() async throws {
            let runner = ProcessRunnerMock()
            runner.handler = Self.archiveAndExportHandler(exportedIpaName: "MyApp.ipa")
            let artifacts = temporaryArtifactsDirectory()
            defer { try? FileManager.default.removeItem(at: artifacts.deletingLastPathComponent()) }
            try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
            try Data("old ipa".utf8).write(to: artifacts.appending(path: "MyApp.ipa"))
            let xcode = makeXcode()

            let result = await SwiftCITest.run(["release"], artifactsDirectory: artifacts) {
                register(ProcessRunner.self, runner)
                command(Command("release") {
                    _ = try await xcode.archiveAndExport(ipaFileName: "MyApp")
                })
            }

            #expect(result.exitCode == 0)
            #expect(try String(contentsOf: artifacts.appending(path: "MyApp.ipa"), encoding: .utf8) == "new ipa")
        }

        /// A temporary folder for the result bundle of a test run. The test removes it.
        func temporaryTestDirectory() -> URL {
            FileManager.default.temporaryDirectory.appending(path: "xcode-test-\(UUID().uuidString)", directoryHint: .isDirectory)
        }

        /// The arguments of a test run with the workspace of `makeXcode()`, the default destination and coverage on.
        static func testArguments(resultBundle: URL, coverage: String = "YES") -> [String] {
            ["test", "-resultBundlePath", resultBundle.filePath, "-enableCodeCoverage", coverage] + baseArguments
        }

        @Test func testRunsXcodebuildWithTheExpectedArguments() async throws {
            let (_, runner) = registerToolMocks()
            let root = temporaryTestDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let bundle = root.appending(path: "Result.xcresult", directoryHint: .isDirectory)

            try await makeXcode().test(resultBundleURL: bundle)

            #expect(runner.tools.count == 1)
            #expect(runner.tools[0].command == "/usr/bin/xcodebuild")
            #expect(runner.tools[0].arguments == Self.testArguments(resultBundle: bundle))
        }

        @Test func testRunsXcodebuildWithAProject() async throws {
            let (_, runner) = registerToolMocks()
            let root = temporaryTestDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let bundle = root.appending(path: "Result.xcresult", directoryHint: .isDirectory)
            let xcode = Xcode(project: URL(filePath: "/work/MyApp.xcodeproj"), scheme: "MyApp", config: .init(xcconfig: [:]))

            try await xcode.test(resultBundleURL: bundle)

            #expect(runner.tools[0].arguments == [
                "test", "-resultBundlePath", bundle.filePath, "-enableCodeCoverage", "YES",
                "-project", "/work/MyApp.xcodeproj", "-scheme", "MyApp", "-destination", "generic/platform=iOS",
            ])
        }

        /// The destination of the call replaces the destination of the value.
        @Test func testUsesTheDestinationOfTheCall() async throws {
            let (_, runner) = registerToolMocks()
            let root = temporaryTestDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let bundle = root.appending(path: "Result.xcresult", directoryHint: .isDirectory)
            let destination = "platform=iOS Simulator,name=iPhone 17,OS=latest"

            try await makeXcode().test(destination: destination, resultBundleURL: bundle)

            #expect(runner.tools[0].arguments == [
                "test", "-resultBundlePath", bundle.filePath, "-enableCodeCoverage", "YES",
                "-workspace", "/work/MyApp.xcworkspace", "-scheme", "MyApp", "-destination", destination,
            ])
        }

        @Test func testWithTestPlanPassesIt() async throws {
            let (_, runner) = registerToolMocks()
            let root = temporaryTestDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let bundle = root.appending(path: "Result.xcresult", directoryHint: .isDirectory)

            try await makeXcode().test(testPlan: "SmokeTests", resultBundleURL: bundle)

            #expect(runner.tools[0].arguments == [
                "test", "-resultBundlePath", bundle.filePath, "-enableCodeCoverage", "YES", "-testPlan", "SmokeTests",
            ] + Self.baseArguments)
        }

        @Test func testWithCoverageOffPassesNo() async throws {
            let (_, runner) = registerToolMocks()
            let root = temporaryTestDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let bundle = root.appending(path: "Result.xcresult", directoryHint: .isDirectory)

            try await makeXcode().test(resultBundleURL: bundle, enableCodeCoverage: false)

            #expect(runner.tools[0].arguments == Self.testArguments(resultBundle: bundle, coverage: "NO"))
        }

        @Test func testWithConfigurationAndXcconfigPassesBoth() async throws {
            let (_, runner) = registerToolMocks()
            let root = temporaryTestDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let bundle = root.appending(path: "Result.xcresult", directoryHint: .isDirectory)
            let xcode = Xcode(
                workspace: URL(filePath: "/work/MyApp.xcworkspace"),
                scheme: "MyApp",
                configuration: "Release",
                config: .init(xcconfig: ["A": "B"])
            )

            try await xcode.test(resultBundleURL: bundle)

            let arguments = runner.tools[0].arguments
            #expect(try Self.argument(after: "-configuration", in: runner.tools[0]) == "Release")
            #expect(try Self.argument(after: "-xcconfig", in: runner.tools[0]).hasSuffix(".xcconfig"))
            #expect(arguments.starts(with: ["test", "-resultBundlePath", bundle.filePath, "-enableCodeCoverage", "YES"]))
        }

        /// A bundle of an earlier run is removed, because xcodebuild refuses to write over it.
        @Test func testRemovesAnExistingResultBundle() async throws {
            _ = registerToolMocks()
            let root = temporaryTestDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let bundle = root.appending(path: "Result.xcresult", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
            try Data("old".utf8).write(to: bundle.appending(path: "old.txt"))

            try await makeXcode().test(resultBundleURL: bundle)

            #expect(!FileManager.default.fileExists(atPath: bundle.filePath))
        }

        /// The parent directory of the result bundle is created when it is missing.
        @Test func testCreatesTheMissingParentOfTheResultBundle() async throws {
            _ = registerToolMocks()
            let root = temporaryTestDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let parent = root.appending(path: "nested/results", directoryHint: .isDirectory)
            let bundle = parent.appending(path: "Result.xcresult", directoryHint: .isDirectory)

            try await makeXcode().test(resultBundleURL: bundle)

            #expect(FileManager.default.fileExists(atPath: parent.filePath))
        }

        /// A failing run names the scheme, the exit code and the result bundle, which the run has written by then.
        @Test func testFailureNamesTheSchemeExitCodeAndTheWrittenBundle() async throws {
            let (_, runner) = registerToolMocks()
            let root = temporaryTestDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let bundle = root.appending(path: "Result.xcresult", directoryHint: .isDirectory)
            runner.handler = { tool in
                let path = try Self.argument(after: "-resultBundlePath", in: tool)
                try FileManager.default.createDirectory(at: URL(filePath: path), withIntermediateDirectories: true)
                return response(stderr: "error: boom", exitCode: 65)
            }

            let error = await thrownError {
                try await makeXcode().test(resultBundleURL: bundle)
            }

            #expect(error?.message == "xcodebuild test of scheme 'MyApp' exited with code 65. The result bundle is at '\(bundle.filePath)'.")
        }

        /// Without a bundle on disk, the error names the scheme and the exit code only.
        @Test func testFailureWithoutABundleOmitsItsPath() async throws {
            let (_, runner) = registerToolMocks()
            let root = temporaryTestDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let bundle = root.appending(path: "Result.xcresult", directoryHint: .isDirectory)
            runner.handler = { _ in response(exitCode: 65) }

            let error = await thrownError {
                try await makeXcode().test(resultBundleURL: bundle)
            }

            #expect(error?.message == "xcodebuild test of scheme 'MyApp' exited with code 65.")
        }

        /// The raw log gets every line as xcodebuild printed it, without the `[stderr] ` prefix. The passing test line,
        /// which the console filter hides, is in it.
        @Test func testRawLogGetsEveryLineUnfiltered() async throws {
            let (_, runner) = registerToolMocks()
            let root = temporaryTestDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let bundle = root.appending(path: "Result.xcresult", directoryHint: .isDirectory)
            let rawLog = root.appending(path: "logs/raw.log")
            runner.responses = [ProcessRunnerMock.Response(
                lines: [
                    stdoutLine("Test Case '-[MyAppTests testPasses]' passed (0.001 seconds)."),
                    stderrLine("error: broken"),
                ],
                result: ToolResult(stdout: "", stderr: "error: broken", exitCode: 0)
            )]

            try await makeXcode().test(resultBundleURL: bundle, rawLogURL: rawLog)

            #expect(runner.tools[0].outputFile == rawLog)
            #expect(try String(contentsOf: rawLog, encoding: .utf8) == "Test Case '-[MyAppTests testPasses]' passed (0.001 seconds).\nerror: broken\n")
        }

        /// The step is named "Test MyApp" by default, and `step:` renames it.
        @Test func testStepOpensItsDefaultNameAndCanBeRenamed() async {
            let runner = ProcessRunnerMock()
            let xcode = makeXcode()
            let root = temporaryTestDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let bundle = root.appending(path: "Result.xcresult", directoryHint: .isDirectory)

            let result = await SwiftCITest.run(["check"]) {
                register(ProcessRunner.self, runner)
                command(Command("check") {
                    try await xcode.test(resultBundleURL: bundle)
                    try await xcode.test(resultBundleURL: bundle, step: "Run unit tests")
                })
            }

            #expect(result.exitCode == 0)
            #expect(enteredSteps(in: result.log) == [
                "Entering step [Test MyApp]",
                "Entering step [Run unit tests]",
            ])
            #expect(runner.tools.count == 2)
        }
    }
}
