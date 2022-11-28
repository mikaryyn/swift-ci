import Foundation
import System

public func SwiftCI(script: () async throws -> ()) async {
    @Use var log: Log
    do {
        registerDependencies()

        try await script()
        await processCommand()
    } catch {
        log.error("Error occurred: \(error)")
        exit(ErrorCode.scriptError.rawValue)
    }
}

public func command(_ command: Command) {
    commands.append(command)
}

enum ErrorCode: Int32 {
    case buildError
    case scriptError
    case unexpectedError
}

/// Register dependencies.
internal func registerDependencies() {
    register(Log.self, LogImpl())
    register(Shell.self, ShellImpl())
    register(Keychain.self, KeychainImpl())
//    register(Environment.self, EnvironmentImpl())
}

internal func processCommand() async {
    let arguments = Array(CommandLine.arguments.dropFirst())
    for command in commands {
        if command.name == arguments.first {
            await run(command: command)
            break
        }
    }
}

internal func run(command: Command) async {
    @Use var log: Log
    do {
        try FullLog.open(name: command.name)
        defer { FullLog.close() }
        await command.run()
        if command.hasFailed {
            exit(ErrorCode.scriptError.rawValue)
        }
    } catch let error as BuildError {
        log.error(error.message)
        exit(ErrorCode.buildError.rawValue)
    } catch {
        log.error("Unexpected error occurred: \(error)")
        exit(ErrorCode.unexpectedError.rawValue)
    }
}

internal var commands = [Command]()
