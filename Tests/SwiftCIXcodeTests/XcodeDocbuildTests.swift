@testable import SwiftCIXcode
@testable import SwiftCITestSupport
import Foundation
@testable import SwiftCI
import SwiftCITesting
import Testing

extension GlobalStateTests {
    /// `Xcode.docbuild` and `Xcode.mergeDocumentation` with a mock runner, so no `xcodebuild` or `docc` is started.
    @Suite(.serialized) struct XcodeDocbuildTests {
        /// A products directory with archives of several modules, an older one among them, and other files.
        static func productsDirectory(archives: [String]) throws -> URL {
            let directory = FileManager.default.temporaryDirectory
                .appending(path: "swift-ci-tests/docbuild-\(UUID().uuidString)", directoryHint: .isDirectory)
            for name in archives + ["Other.framework"] {
                try FileManager.default.createDirectory(
                    at: directory.appending(path: name, directoryHint: .isDirectory),
                    withIntermediateDirectories: true
                )
            }
            try Data("x".utf8).write(to: directory.appending(path: "Notes.doccarchive.txt"))
            return directory
        }

        /// `docbuild` runs `xcodebuild docbuild` and returns the archives of the products directory, sorted by name,
        /// and nothing else from it.
        @Test func docbuildReturnsTheSortedArchivesOfTheProductsDirectory() async throws {
            let (_, runner) = registerToolMocks()
            let products = try Self.productsDirectory(archives: ["Zeta.doccarchive", "Alpha.doccarchive", "Mid.doccarchive"])
            defer { try? FileManager.default.removeItem(at: products) }
            let json = #"[{"action":"build","buildSettings":{"BUILT_PRODUCTS_DIR":"\#(products.filePath)"}}]"#
            runner.responses = [.init(stdout: json), .init()]
            Xcode.clearBuildSettingsCache()
            let xcode = Xcode(workspace: URL(filePath: "/work/MyApp.xcworkspace"), scheme: "MyApp", buildSettings: [:])

            let archives = try await xcode.docbuild()

            #expect(archives.map(\.lastPathComponent) == ["Alpha.doccarchive", "Mid.doccarchive", "Zeta.doccarchive"])
            #expect(runner.tools.count == 2)
            #expect(runner.tools[1].arguments == ["docbuild"] + GlobalStateTests.XcodeTests.baseArguments)
        }

        /// `hostingBasePath` becomes the `OTHER_DOCC_FLAGS` build setting of the run.
        @Test func docbuildPassesTheHostingBasePath() async throws {
            let (_, runner) = registerToolMocks()
            let products = try Self.productsDirectory(archives: [])
            defer { try? FileManager.default.removeItem(at: products) }
            let json = #"[{"action":"build","buildSettings":{"BUILT_PRODUCTS_DIR":"\#(products.filePath)"}}]"#
            runner.responses = [.init(stdout: json), .init()]
            Xcode.clearBuildSettingsCache()
            let xcode = Xcode(workspace: URL(filePath: "/work/MyApp.xcworkspace"), scheme: "MyApp", buildSettings: [:])

            let archives = try await xcode.docbuild(hostingBasePath: "ios")

            #expect(archives.isEmpty)
            #expect(runner.tools[1].arguments == ["docbuild", "OTHER_DOCC_FLAGS=--hosting-base-path ios"] + GlobalStateTests.XcodeTests.baseArguments)
        }

        @Test func mergeDocumentationRunsDoccMergeWithTheArchivesAndTheOutput() async throws {
            let (_, runner) = registerToolMocks()

            try await Xcode.mergeDocumentation(
                [URL(filePath: "/work/A.doccarchive"), URL(filePath: "/work/B.doccarchive")],
                to: URL(filePath: "/tmp/Docs.doccarchive")
            )

            #expect(runner.tools.count == 1)
            #expect(runner.tools[0].command == "/usr/bin/xcrun")
            #expect(runner.tools[0].arguments == [
                "docc", "merge", "/work/A.doccarchive", "/work/B.doccarchive", "--output-path", "/tmp/Docs.doccarchive",
            ])
        }

        /// The step opens its default name at the top level of a command.
        @Test func mergeDocumentationOpensItsDefaultStepName() async {
            let runner = ProcessRunnerMock()

            let result = await SwiftCITest.run(["merge"]) {
                register(ProcessRunner.self, runner)
                command(Command("merge") {
                    try await Xcode.mergeDocumentation([URL(filePath: "/work/A.doccarchive")], to: URL(filePath: "/tmp/D"))
                })
            }

            #expect(result.exitCode == 0)
            #expect(enteredSteps(in: result.log) == ["Entering step [Merge documentation archives]"])
        }
    }
}
