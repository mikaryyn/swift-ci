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

internal var commands = [Command]()

/// The name of the script in the usage: `./` and the executable's file name, for example `./ci`. The executable has
/// the name of the script's product, which is also the usual name of its wrapper script.
internal func programName(executablePath: String?) -> String {
    guard let executablePath, !executablePath.isEmpty else { return "./ci" }
    return "./" + URL(filePath: executablePath).lastPathComponent
}

/// Registers the real log, process runner and HTTP client. Tests replace them afterwards.
internal func registerDependencies() {
    register(Log.self, LogImpl())
    register(ProcessRunner.self, ProcessRunnerImpl())
    register(HTTPClient.self, URLSessionHTTPClient())
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

    let scope = RunScope(artifactsDirectory: artifactsDirectory, ciAdapters: ciAdapters)
    defer { scope.restore() }

    do {
        // Parsing comes first, so a malformed option stops the run before the script runs. Inputs read the parsed
        // options from inside the script and from the commands.
        let parsed = try RunArguments(parsing: arguments)
        RunOptions.current = RunOptions(parsed)
        try await script()
        return await processCommands(arguments: parsed, programName: programName)
    } catch let error as BuildError {
        log.error(error.message)
        return error.code.rawValue
    } catch {
        log.error(String(describing: error))
        return ErrorCode.failure.rawValue
    }
}

/// The global state that a run sets up. It is saved when the run starts and put back by ``restore()``, so the artifacts
/// directory, the CI environment, the options, the commands and the running command exist only inside the run.
///
/// `GlobalStateSnapshot` in `TestingSupport.swift` saves the same state, and more, for tests. Keep the two in step.
private struct RunScope {
    private let artifacts = ArtifactsLocation.current
    private let ci = CIState.current
    private let ciExporter = CIState.exporter
    private let options = RunOptions.current
    private let openCounts = FullLog.openCounts
    private let registeredCommands = commands
    private let context = RunContext.current

    /// Saves the state, then chooses the artifacts directory, detects the CI environment and clears the commands, the
    /// counts of the full log and the running command.
    init(artifactsDirectory: URL?, ciAdapters: [any CIAdapter]) {
        ArtifactsLocation.current = ArtifactsLocation.resolve(parameter: artifactsDirectory, defaultDirectory: ArtifactsLocation.defaultURL)
        CIState.current = CIDetection.detect(variables: EnvironmentSource.variables(), adapters: ciAdapters)
        CIState.exporter = CIDetection.exporter(variables: EnvironmentSource.variables(), adapters: ciAdapters)
        FullLog.openCounts = [:]
        commands = []
        RunContext.current = nil
    }

    func restore() {
        ArtifactsLocation.current = artifacts
        CIState.current = ci
        CIState.exporter = ciExporter
        RunOptions.current = options
        FullLog.openCounts = openCounts
        commands = registeredCommands
        RunContext.current = context
    }
}

/// Runs the named commands in order. Stops at the first failed command and returns its exit code, or 0. A command name
/// that cannot be typed as an argument, and two commands with the same name, are usage errors, which are reported before
/// anything else.
///
/// `--help` prints the usage and the command list, and `--list` prints the command list. Both return 0 without running
/// any command, and `--help` wins if both are given. A missing or unknown command name logs the error followed by the
/// list and returns the usage exit code. When commands ran, the options that no `input` call read are logged as a
/// warning in the full log of the last command that ran, whether the run succeeded or failed. The warning does not change
/// the exit code.
internal func processCommands(arguments: RunArguments, programName: String) async -> Int32 {
    @Use var log: Log

    var seenNames = Set<String>()
    for command in commands {
        guard isValidCommandName(command.name) else {
            log.error("Command name '\(command.name)' is not valid. Use a name without spaces that does not start with '-'.")
            return ErrorCode.usage.rawValue
        }
        guard seenNames.insert(command.name).inserted else {
            log.error("Command '\(command.name)' is registered twice. Give each command a unique name.")
            return ErrorCode.usage.rawValue
        }
    }

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

    for (index, name) in names.enumerated() {
        guard let command = commandDict[name] else { continue }
        let exitCode = await runCommand(command, isLast: index == names.count - 1)
        if exitCode != 0 {
            return exitCode
        }
    }
    return 0
}

/// Whether `name` can be given as one command-line argument that is not an option: not empty, no whitespace, and not
/// starting with `-`.
private func isValidCommandName(_ name: String) -> Bool {
    !name.isEmpty && !name.hasPrefix("-") && name.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
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
