import Foundation
import System

public func SwiftCI(script: () async throws -> ()) async {
    @Use var log: Log
    
    do {
        registerDependencies()
        try await script()
        try await processCommands()
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

internal func processCommands() async throws(BuildError) {
    @Use var log: Log

    let arguments = Array(CommandLine.arguments.dropFirst())

    guard !arguments.isEmpty else {
        throw BuildError(message: "No commands specified.", code: .unexpectedError)
    }
    
    let commandDict = Dictionary(uniqueKeysWithValues: commands.map { ($0.name, $0) })
    for name in arguments {
        if !commandDict.keys.contains(name) {
            throw BuildError(message:"Unsupported command '\(name)'.", code: .unexpectedError)
        }
    }

    for name in arguments {
        guard let command = commandDict[name] else { continue }
        try await run(command: command)
    }
}

internal func run(command: Command) async throws (BuildError) {
    @Use var log: Log
    do {
        try FullLog.open(name: command.name)
        defer { FullLog.close() }
        await command.run()
        if command.hasFailed {
            throw BuildError(message: "Aborted due to a failed command.", code: .scriptError)
        }
    } catch let error as BuildError {
        log.error(error.message)
        exit(ErrorCode.buildError.rawValue)
    } catch {
        throw BuildError(message: "Unexpected error occurred: \(error)", code: .unexpectedError)
    }
}

internal var commands = [Command]()
