import Foundation
@_spi(Testing) import SwiftCI

/// Runs CI scripts and extension code in tests, without running real tools.
///
/// ``run(_:environment:artifactsDirectory:runner:script:)`` runs the commands of a script the way `./ci <command>` does,
/// but with mocks in place of the console and the process runner, and returns the exit code, the log and the artifacts
/// directory. ``withMocks(_:runner:log:artifactsDirectory:_:)``
/// does the same setup for code that is not a command, such as a call of a module's function.
///
/// ```swift
/// import SwiftCI
/// import SwiftCITesting
/// import Testing
///
/// @Test func buildRunsTheTool() async {
///     let runner = ProcessRunnerMock()
///     let result = await SwiftCITest.run(["build"], runner: runner) {
///         command(Command("build") {
///             try await step("Compile") {
///                 try await Tool(command: "mytool", arguments: ["compile", "MyApp"]).run()
///             }
///         })
///     }
///
///     #expect(result.exitCode == 0)
///     #expect(runner.tools.map(\.arguments) == [["compile", "MyApp"]])
/// }
/// ```
///
/// ## Tests must not run in parallel
///
/// SwiftCI keeps its state in globals: the dependency registrations, the secret registry, the environment, the commands
/// and the full log. These functions save that state, change it, and restore it afterwards, but two tests that run at
/// the same time would still see each other's changes. Run every test that uses `SwiftCITesting` one at a time.
///
/// - Swift Testing: put the tests in a suite marked `.serialized`, for example `@Suite(.serialized) struct BuildTests`.
///   A suite runs its tests one at a time, but two suites can still run at the same time, so put all suites that use
///   `SwiftCITesting` under one serialized parent suite.
/// - XCTest: test methods run one at a time by default. Do not run them in parallel, for example with `--parallel`.
public enum SwiftCITest {
    /// Runs `body` with the mocks registered and the environment set, then restores the global state.
    ///
    /// The environment is empty unless `environment` gives values. `Environment`, `@Env` and `Secret` read only these
    /// values, never the real process environment, so a test does not depend on the shell that runs it. `Tool` runs go
    /// to `runner` and the console to `log`. A secret declared before the call stays masked.
    ///
    /// `Artifacts.directory` is set inside `body`. If `artifactsDirectory` is `nil`, it is a new directory in a new
    /// temporary folder, which is removed when `withMocks` returns. The directory is not created in advance. Pass a
    /// directory of your own to inspect the files that `body` writes. `SWIFTCI_ARTIFACTS_DIR` in `environment` overrides
    /// the directory, as in a real run.
    ///
    /// `CI.environment` is detected inside `body` from `environment`, with `ciAdapters` asked first.
    ///
    /// - Parameters:
    ///   - environment: The variables that `Environment`, `@Env` and `Secret` read inside `body`, and that CI detection reads.
    ///   - runner: The process runner that receives every `Tool` run inside `body`.
    ///   - log: The log that receives every console line inside `body`.
    ///   - artifactsDirectory: The artifacts directory inside `body`. `nil` for a temporary one, removed afterwards.
    ///   - ciAdapters: Adapters for CI systems that the built-in adapters do not cover. They are asked first.
    ///   - body: The code under test.
    /// - Returns: The value returned by `body`.
    public static func withMocks<T>(
        _ environment: [String: String] = [:],
        runner: ProcessRunnerMock = ProcessRunnerMock(),
        log: LogMock = LogMock(),
        artifactsDirectory: URL? = nil,
        ciAdapters: [any CIAdapter] = [],
        _ body: () async throws -> T
    ) async rethrows -> T {
        let temporaryRoot = makeTemporaryRoot()
        let snapshot = isolateGlobalState(
            environment: environment,
            artifactsDirectory: artifactsDirectory ?? temporaryRoot.appending(path: "artifacts", directoryHint: .isDirectory),
            ciAdapters: ciAdapters
        )
        defer {
            restoreGlobalState(snapshot)
            if artifactsDirectory == nil { removeTemporaryRoot(temporaryRoot) }
        }
        installTestDependencies(log: log, runner: runner)
        return try await body()
    }

    /// Runs the script and the commands named in `arguments`, as `./ci` does, and returns the exit code, the log and the
    /// artifacts directory of the run. It does not exit the process. A failure of a command, or a usage error such as an
    /// unknown command name, gives the exit code that the process would have.
    ///
    /// The script is the `script` closure. It registers the commands with `command(_:)`, as the closure of `SwiftCI { }`
    /// does. `runner` and the log are fresh for this run, and the global state is restored when it returns. The
    /// environment is set as in ``withMocks(_:runner:log:artifactsDirectory:_:)``, so pass the variables the script reads
    /// in `environment`. The run never uses the working directory for artifacts.
    ///
    /// If `artifactsDirectory` is `nil`, the run uses a new temporary directory, and removes it when the run returns. The
    /// directory is in ``SwiftCITestResult/artifactsDirectory``, but its files are gone by then. To check the files a run
    /// writes, pass a directory of your own, which is not removed.
    ///
    /// - Parameters:
    ///   - arguments: The command names, as given on the command line, for example `["build", "test"]`.
    ///   - environment: The variables that `Environment`, `@Env` and `Secret` read during the run. Includes
    ///     `SWIFTCI_ARTIFACTS_DIR`, which overrides `artifactsDirectory`, as in a real run. CI detection reads them too,
    ///     so pass `CI`, `GITHUB_ACTIONS` or the variables of another CI system to test it.
    ///   - artifactsDirectory: The artifacts directory of the run. `nil` for a temporary one, removed afterwards.
    ///   - ciAdapters: Adapters for CI systems that the built-in adapters do not cover. They are asked first, as in
    ///     `SwiftCI(ciAdapters:)`.
    ///   - runner: The process runner that receives every `Tool` run during the run. Configure its responses first.
    ///   - script: Registers the commands.
    /// - Returns: The exit code, the log and the artifacts directory of the run.
    public static func run(
        _ arguments: [String],
        environment: [String: String] = [:],
        artifactsDirectory: URL? = nil,
        ciAdapters: [any CIAdapter] = [],
        runner: ProcessRunnerMock = ProcessRunnerMock(),
        script: () async throws -> Void
    ) async -> SwiftCITestResult {
        let log = LogMock()
        let (exitCode, directory) = await withMocks(
            environment,
            runner: runner,
            log: log,
            artifactsDirectory: artifactsDirectory
        ) {
            // The directory resolved by the mocks, which already applies `SWIFTCI_ARTIFACTS_DIR`.
            let exitCode = await runSwiftCI(
                arguments: arguments,
                ciAdapters: ciAdapters,
                artifactsDirectory: Artifacts.directory,
                script: script
            )
            return (exitCode, Artifacts.directory)
        }
        return SwiftCITestResult(exitCode: exitCode, log: log.loggedLines, artifactsDirectory: directory)
    }

    /// A new, unique folder for one test call. Its `artifacts` child is the default artifacts directory of the call, and
    /// the folder is removed after the call. Nothing is created here.
    private static func makeTemporaryRoot() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appending(path: "swift-ci-tests", directoryHint: .isDirectory)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    }

    /// Removes a folder made by ``makeTemporaryRoot()``. A folder that does not exist is left alone.
    private static func removeTemporaryRoot(_ root: URL) {
        try? FileManager.default.removeItem(at: root)
    }
}

/// The result of ``SwiftCITest/run(_:environment:artifactsDirectory:runner:script:)``.
public struct SwiftCITestResult: Equatable, Sendable {
    /// The exit code the process would have returned: 0 on success, or the code of the failing command or error.
    public let exitCode: Int32

    /// Every console line of the run, in order, with the colour codes that a terminal would show.
    public let log: [String]

    /// The artifacts directory the run used. If the run used a temporary directory, it has been removed, so pass your
    /// own directory to inspect files. Its full logs are in `logs/<command>.log`.
    public let artifactsDirectory: URL

    /// The console lines with the colour codes removed, so that a test can compare the text.
    public var plainLog: [String] {
        log.map { $0.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression) }
    }

    /// Creates a result. ``SwiftCITest/run(_:environment:artifactsDirectory:runner:script:)`` creates the results.
    public init(exitCode: Int32, log: [String], artifactsDirectory: URL) {
        self.exitCode = exitCode
        self.log = log
        self.artifactsDirectory = artifactsDirectory
    }
}
