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
        programName: programName(executablePath: CommandLine.arguments.first),
        ciAdapters: ciAdapters,
        artifactsDirectory: artifactsDirectory,
        script: script
    )
    exit(exitCode)
}

/// The name of the script in the usage: `./` and the executable's file name, for example `./ci`. The executable has
/// the name of the script's product, which is also the usual name of its wrapper script.
internal func programName(executablePath: String?) -> String {
    guard let executablePath, !executablePath.isEmpty else { return "./ci" }
    return "./" + URL(filePath: executablePath).lastPathComponent
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
/// `programName` is the name shown in the usage.
/// Does not register dependencies and does not exit the process. Used by `SwiftCITesting`; not for scripts.
///
/// The artifacts directory is chosen here, once, as in ``SwiftCI(ciAdapters:artifactsDirectory:script:)``. The CI
/// environment and the exporter of ``CI/export(_:_:)`` are detected here too, from the environment of the run. All are
/// restored when the run returns, so ``Artifacts/directory`` and ``CI/environment`` are set only inside the run.
@_spi(Testing) public func runSwiftCI(
    arguments: [String],
    programName: String = "./ci",
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

    let previousOptions = RunOptions.current
    defer { RunOptions.current = previousOptions }

    commands = []
    RunContext.current = nil
    do {
        // Parsing comes first, so a malformed option stops the run before the script runs. Inputs read the parsed
        // options from inside the script and from the commands.
        let parsed = try RunArguments(parsing: arguments)
        RunOptions.current = RunOptions(parsed)
        try await script()
        return try await processCommands(arguments: parsed, programName: programName)
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
/// `--help` prints the usage and the command list, and `--list` prints the command list. Both return 0 without running
/// any command, and `--help` wins if both are given. A missing or unknown command name logs the error followed by the
/// list and returns the usage exit code. When commands ran, the options that no `input` call read are logged as a
/// warning, whether the run succeeded or failed. The warning does not change the exit code.
internal func processCommands(arguments: RunArguments, programName: String) async throws(BuildError) -> Int32 {
    @Use var log: Log

    if arguments.flags.contains("help") {
        logUsage(programName: programName)
        log("")
        logCommandList()
        return 0
    }

    if arguments.flags.contains("list") {
        logCommandList()
        return 0
    }

    let names = arguments.commandNames
    guard !names.isEmpty else {
        log.error("No commands specified.")
        log("")
        logCommandList()
        return ErrorCode.usage.rawValue
    }

    let commandDict = Dictionary(uniqueKeysWithValues: commands.map { ($0.name, $0) })
    for name in names {
        if !commandDict.keys.contains(name) {
            log.error("Unsupported command '\(name)'.")
            log("")
            logCommandList()
            return ErrorCode.usage.rawValue
        }
    }

    for name in names {
        guard let command = commandDict[name] else { continue }
        if let exitCode = await run(command: command) {
            logUnreadOptions()
            return exitCode
        }
    }
    logUnreadOptions()
    return 0
}

/// Logs the usage of the script named `programName`: the command forms, the option form and the reserved flags.
private func logUsage(programName: String) {
    @Use var log: Log

    let forms = [
        ("<command> [<command> ...] [--name=value ...]", "Run commands in order; stop at the first failed command."),
        ("--list", "List available commands."),
        ("--verbose <command> ...", "Show unfiltered tool output on the console."),
        ("--help", "Show this usage and the command list."),
    ]
    let width = forms.map { programName.count + 1 + $0.0.count }.max() ?? 0
    log("Usage:")
    for (form, description) in forms {
        let usage = "\(programName) \(form)".padding(toLength: width, withPad: " ", startingAt: 0)
        log("  \(usage)  \(description)")
    }
    log("")
    log("Options are written --name=value, with a value after '='. Each input reads --name=value, then the environment")
    log("variable with the upper-case name (build-number reads BUILD_NUMBER), then its default. Flags --list, --help and")
    log("--verbose never take a value. Each option may be given once.")
}

/// Logs a warning that lists the options no `input` call read in this run. Logs nothing if every option was read.
private func logUnreadOptions() {
    @Use var log: Log

    guard let unread = RunOptions.current?.unreadNames, !unread.isEmpty else { return }
    let flags = unread.map { "--\($0)" }.joined(separator: ", ")
    log.warning("No input read these options: \(flags). Check their spelling, or remove them.")
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
