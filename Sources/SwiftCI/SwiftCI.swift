import Foundation
import System

public func SwiftCI(script: () async throws -> ()) async {
    @Use var log: Log
    
    do {
        registerDependencies()
        try await script()
        await processCommand()
    } catch let error as BuildError {
        log.error(error.message)
        exit(error.code.rawValue)
    } catch {
        log.error("Error occurred: \(error)")
        exit(ErrorCode.unexpectedError.rawValue)
    }
}

public func command(_ command: Command) {
    commands.append(command)
}

/// Register dependencies.
internal func registerDependencies() {
    register(Log.self, LogImpl())
    register(Shell.self, ShellImpl())
    register(Keychain.self, KeychainImpl())
//    register(Environment.self, EnvironmentImpl())
}

internal func processCommand() async {
    @Use var log: Log

    let arguments = Array(CommandLine.arguments.dropFirst())

    guard !arguments.isEmpty else {
        log.error("No commands specified.")
        
        exit(ErrorCode.unexpectedError.rawValue)
    }
    
    let commandDict = Dictionary(uniqueKeysWithValues: commands.map { ($0.name, $0) })
    for name in arguments {
        if !commandDict.keys.contains(name) {
            log.error("Unsupported command '\(name)'.")
            exit(ErrorCode.unexpectedError.rawValue)
        }
    }

    for name in arguments {
        guard let command = commandDict[name] else { continue }
        await run(command: command)
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
