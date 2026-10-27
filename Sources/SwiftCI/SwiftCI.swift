import Foundation

/// Runs a SwiftCI script: registers the commands, then runs the commands named on the command line.
/// Exits the process with the exit code of the run (see ``ErrorCode``).
///
/// - Parameters:
///   - ciAdapters: Adapters for CI systems that the built-in adapters do not cover. They are asked before the built-in
///     ones, in order. See ``CIAdapter`` and ``CI``.
///   - artifactsDirectory: The artifacts directory when `SWIFTCI_ARTIFACTS_DIR` is not set. A relative path resolves
///     against the working directory at start. Defaults to `artifacts` in the working directory. See ``Artifacts``.
///   - script: Registers the commands with ``command(_:)``.
public func SwiftCI(
    ciAdapters: [any CIAdapter] = [],
    artifactsDirectory: URL? = nil,
    script: () async throws -> ()
) async {
    registerDependencies()
    let exitCode = await runSwiftCI(
        arguments: Array(CommandLine.arguments.dropFirst()),
        ciAdapters: ciAdapters,
        artifactsDirectory: artifactsDirectory,
        script: script
    )
    exit(exitCode)
}

/// Registers a command, so that it can be run from the command line.
///
/// Call it inside the `SwiftCI { }` script, once for each command. Commands run in the order
/// given on the command line, not in the order of registration:
///
/// ```swift
/// let build = Command("build") {
///     try await step("Compile") { … }
/// }
///
/// await SwiftCI {
///     command(build)
/// }
/// ```
public func command(_ command: Command) {
    commands.append(command)
}

/// Register dependencies.
internal func registerDependencies() {
    register(Log.self, LogImpl())
    register(ProcessRunner.self, ProcessRunnerImpl())
//    register(Environment.self, EnvironmentImpl())
}

/// Runs the script and the commands named in `arguments` (without the executable name) and returns the exit code.
/// Does not register dependencies and does not exit the process. Used by `SwiftCITesting`; not for scripts.
///
/// The artifacts directory is chosen here, once, as in ``SwiftCI(ciAdapters:artifactsDirectory:script:)``. The CI
/// environment and the exporter of ``CI/export(_:_:)`` are detected here too, from the environment of the run. All are
/// restored when the run returns, so ``Artifacts/directory`` and ``CI/environment`` are set only inside the run.
@_spi(Testing) public func runSwiftCI(
    arguments: [String],
    ciAdapters: [any CIAdapter] = [],
    artifactsDirectory: URL? = nil,
    script: () async throws -> ()
) async -> Int32 {
    @Use var log: Log

    let previousArtifacts = ArtifactsLocation.current
    ArtifactsLocation.current = ArtifactsLocation.resolve(parameter: artifactsDirectory, defaultDirectory: ArtifactsLocation.defaultURL)
    defer { ArtifactsLocation.current = previousArtifacts }

    let previousCI = CIState.current
    let previousExporter = CIState.exporter
    CIState.current = CIDetection.detect(variables: EnvironmentSource.variables(), adapters: ciAdapters)
    CIState.exporter = CIDetection.exporter(variables: EnvironmentSource.variables(), adapters: ciAdapters)
    defer {
        CIState.current = previousCI
        CIState.exporter = previousExporter
    }

    commands = []
    RunContext.current = nil
    do {
        try await script()
        return try await processCommands(arguments: arguments)
    } catch let error as BuildError {
        log.error(error.message)
        return error.code.rawValue
    } catch {
        log.error(String(describing: error))
        return ErrorCode.failure.rawValue
    }
}

/// Runs the named commands in order. Stops at the first failed command and returns its exit code, or 0.
///
/// `--list` prints the registered commands and returns 0 without running any command. A missing or unknown command
/// name logs the error followed by the list and returns the usage exit code.
internal func processCommands(arguments: [String]) async throws(BuildError) -> Int32 {
    @Use var log: Log

    if arguments.contains("--list") {
        logCommandList()
        return 0
    }

    guard !arguments.isEmpty else {
        log.error("No commands specified.")
        log("")
        logCommandList()
        return ErrorCode.usage.rawValue
    }

    let commandDict = Dictionary(uniqueKeysWithValues: commands.map { ($0.name, $0) })
    for name in arguments {
        if !commandDict.keys.contains(name) {
            log.error("Unsupported command '\(name)'.")
            log("")
            logCommandList()
            return ErrorCode.usage.rawValue
        }
    }

    for name in arguments {
        guard let command = commandDict[name] else { continue }
        if let exitCode = await run(command: command) {
            return exitCode
        }
    }
    return 0
}

/// Logs the registered commands in registration order, each with its description if it has one.
private func logCommandList() {
    @Use var log: Log

    guard !commands.isEmpty else {
        log("No commands are registered.")
        return
    }
    let width = commands.map(\.name.count).max() ?? 0
    log("Available commands:")
    for command in commands {
        if let description = command.description, !description.isEmpty {
            let padding = String(repeating: " ", count: width - command.name.count)
            log("  \(command.name)\(padding)  \(description)")
        } else {
            log("  \(command.name)")
        }
    }
}

/// Runs one command and logs its failure. Returns `nil` if the command succeeded,
/// otherwise the exit code of the failure.
///
/// The order is: create the artifacts directory if needed, open the full log and write the CI summary line to it, run the
/// body, run the `cleanup` handlers in reverse order,
/// run the `onFailure` handlers in reverse order if the command has failed so far, then close
/// the full log. A failure of the body decides the exit code. A failure of a handler decides it
/// only if nothing failed before, and an allowed handler failure never does. A failure to close
/// the full log decides it only if nothing failed before.
///
/// If the close fails and nothing failed before, the `onFailure` handlers have not run yet. They
/// run after the close, and their failures are logged but do not change the exit code (3).
///
/// An internal error recorded by a status-line write is checked after the body and after each
/// handler. It fails the command with ``ErrorCode/internal`` if nothing failed before.
///
/// The run context is created for the command and stays set while the handlers run, so steps
/// work inside them. It is cleared when the command ends, also after a thrown error.
internal func run(command: Command) async -> Int32? {
    @Use var log: Log

    let context = RunContext(commandName: command.name)
    RunContext.current = context
    defer { RunContext.current = nil }

    var exitCode: ErrorCode?
    do {
        try Artifacts.prepareDirectory()
        try FullLog.open(name: command.name)
        try FullLog.write(CIDetection.summary(CI.environment))
        try await command.run()
    } catch {
        exitCode = logFailure(error)
    }
    absorbInternalError(context, into: &exitCode)

    await runHandlers(.cleanup, in: context, exitCode: &exitCode)
    if exitCode != nil {
        await runHandlers(.onFailure, in: context, exitCode: &exitCode)
    }

    do {
        try FullLog.close()
    } catch {
        // Log first: `??` would skip logging when the command already failed.
        let closeCode = logFailure(error)
        if exitCode == nil {
            exitCode = closeCode
            // The full log is closed now, so the output of these handlers goes to the console only.
            await runHandlers(.onFailure, in: context, exitCode: &exitCode)
        }
    }

    guard let exitCode else { return nil }
    log("Command [\(command.name.red().bold())] failed")
    return exitCode.rawValue
}

/// Logs the first internal error recorded since the last check, and sets the exit code
/// to its code if nothing failed before.
@MainActor
internal func absorbInternalError(_ context: RunContext, into exitCode: inout ErrorCode?) {
    guard let error = context.takeInternalError() else { return }
    let internalCode = logFailure(error)
    exitCode = exitCode ?? internalCode
}

/// Logs the message of an error that failed a command, and returns the exit code it maps to.
internal func logFailure(_ error: Error) -> ErrorCode {
    @Use var log: Log

    log.error(errorMessage(error))
    return (error as? BuildError)?.code ?? .failure
}

/// The message shown for an error: the message of a `BuildError`, or the error's description.
internal func errorMessage(_ error: Error) -> String {
    (error as? BuildError)?.message ?? String(describing: error)
}

internal var commands = [Command]()
