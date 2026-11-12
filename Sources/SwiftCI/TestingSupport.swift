import Foundation

// The test hooks of SwiftCI. They are `@_spi(Testing)`, not ordinary public API, so they are not part of the API that
// scripts and extensions see. `SwiftCITesting` imports them with `@_spi(Testing) import SwiftCI`.

/// Registers a log, a process runner and an HTTP client for a test, after the default dependencies. The mocks replace the
/// console, the process runner and the HTTP client for every command and step that runs afterwards. The defaults are
/// registered first, so a dependency that has no mock here keeps its real implementation. Use it inside
/// ``isolateGlobalState(environment:artifactsDirectory:)`` so that the registrations are restored after the test.
@_spi(Testing) public func installTestDependencies(log: Log, runner: ProcessRunner, httpClient: HTTPClient) {
    registerDependencies()
    register(Log.self, log)
    register(ProcessRunner.self, runner)
    register(HTTPClient.self, httpClient)
}

/// The global state of SwiftCI that a test changes: the dependency registrations, the secret registry, the environment
/// that `Environment` and `Secret` read, the CI environment and its exporter, the commands, the options of the running
/// run, the running command, the full log (its file and its per-name counts) and the artifacts directory.
/// Created by ``isolateGlobalState(environment:artifactsDirectory:ciAdapters:)`` and given back to
/// ``restoreGlobalState(_:)``.
///
/// A new piece of global state must be added here, in both functions below, and in `RunScope` (`SwiftCI.swift`), which
/// saves and resets the part of the state that a run sets up. The compiler does not check that they agree.
@_spi(Testing) public struct GlobalStateSnapshot {
    fileprivate let registrations: [ObjectIdentifier: Any]
    fileprivate let secrets: SecretRegistry.State
    fileprivate let environment: () -> [String: String]
    fileprivate let commands: [Command]
    fileprivate let runOptions: RunOptions?
    fileprivate let runContext: RunContext?
    fileprivate let fullLogPath: URL?
    fileprivate let fullLogFile: FileHandle?
    fileprivate let fullLogOpenCounts: [String: Int]
    fileprivate let artifacts: ArtifactsLocation?
    fileprivate let ci: CIEnvironment?
    fileprivate let ciExporter: (any CIExporter)?
}

/// Saves the global state and replaces the environment that `Environment` and `Secret` read with `environment`. The
/// secret registry is kept, so a value registered before the call stays masked. If `artifactsDirectory` is given, it is
/// the artifacts directory of the code inside, as `Artifacts.directory`, unless `SWIFTCI_ARTIFACTS_DIR` in `environment`
/// overrides it. The CI environment of the code inside, as `CI.environment`, is detected from `environment` with
/// `ciAdapters`. Returns the saved state, which ``restoreGlobalState(_:)`` puts back. Call the restore in a `defer`, so
/// that a failing test does not leave state behind for the next one.
///
/// Tests that change global state must not run at the same time. See the `SwiftCITesting` documentation.
@_spi(Testing) public func isolateGlobalState(
    environment: [String: String],
    artifactsDirectory: URL? = nil,
    ciAdapters: [any CIAdapter] = []
) -> GlobalStateSnapshot {
    let snapshot = GlobalStateSnapshot(
        registrations: registrations,
        secrets: SecretRegistry.snapshot(),
        environment: EnvironmentSource.variables,
        commands: commands,
        runOptions: RunOptions.current,
        runContext: RunContext.current,
        fullLogPath: FullLog.path,
        fullLogFile: FullLog.file,
        fullLogOpenCounts: FullLog.openCounts,
        artifacts: ArtifactsLocation.current,
        ci: CIState.current,
        ciExporter: CIState.exporter
    )
    EnvironmentSource.variables = { environment }
    if let artifactsDirectory {
        ArtifactsLocation.current = ArtifactsLocation.resolve(parameter: artifactsDirectory, defaultDirectory: artifactsDirectory)
    }
    CIState.current = CIDetection.detect(variables: environment, adapters: ciAdapters)
    CIState.exporter = CIDetection.exporter(variables: environment, adapters: ciAdapters)
    return snapshot
}

/// Puts back the global state saved by ``isolateGlobalState(environment:artifactsDirectory:ciAdapters:)``, all of what
/// ``GlobalStateSnapshot`` lists.
@_spi(Testing) public func restoreGlobalState(_ snapshot: GlobalStateSnapshot) {
    registrations = snapshot.registrations
    SecretRegistry.restore(snapshot.secrets)
    EnvironmentSource.variables = snapshot.environment
    commands = snapshot.commands
    RunOptions.current = snapshot.runOptions
    RunContext.current = snapshot.runContext
    FullLog.path = snapshot.fullLogPath
    FullLog.file = snapshot.fullLogFile
    FullLog.openCounts = snapshot.fullLogOpenCounts
    ArtifactsLocation.current = snapshot.artifacts
    CIState.current = snapshot.ci
    CIState.exporter = snapshot.ciExporter
}
