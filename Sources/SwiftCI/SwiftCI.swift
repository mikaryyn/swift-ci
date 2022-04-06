import Foundation
import System

public func SwiftCI(script: () async throws -> ()) async {
    do {
        exitIfRebuildIsNeeded()
        try await script()
        await processCommand()
    } catch {
        logError("Error occurred: \(error)")
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
    do {
        try FullLog.open(name: command.name)
        defer { FullLog.close() }
        await command.run()
        if command.hasFailed {
            exit(ErrorCode.scriptError.rawValue)
        }
    } catch let error as BuildError {
        logError(error.message)
        exit(ErrorCode.buildError.rawValue)
    } catch {
        logError("Unexpected error occurred: \(error)")
        exit(ErrorCode.unexpectedError.rawValue)
    }
}

internal var commands = [Command]()

private func exitIfRebuildIsNeeded() {
    func getModificationDate(_ path: FilePath) -> Date? {
        let attrs = (try? FileManager.default.attributesOfItem(atPath: path.string)) ?? [:]
        return attrs[.modificationDate] as? Date
    }

    let executablePath = FilePath(Bundle.main.executablePath ?? "").removingLastComponent()
    if !executablePath.ends(with: ".build/release") {
        return // Unknown path; cannot continue.
    }
    guard let executableDate = getModificationDate(executablePath) else {
        return // Unknown modification date; cannot continue.
    }

    let sourcesPath = executablePath
        .removingLastComponent()
        .removingLastComponent()

    let sourcesContents = FileManager.default.enumerator(atPath: sourcesPath.string)?.allObjects.map { FilePath($0 as! String) } ?? []

    let timeIntervalToMostRecentSource = sourcesContents
        .filter { $0.extension == "swift" }
        .compactMap { getModificationDate(sourcesPath.appending($0.string)) }
        .max()
        .map { executableDate.distance(to: $0) } ?? .zero
    if timeIntervalToMostRecentSource > 0 {
        print("SwiftCI executable is outdated and needs to be rebuilt.")
        exit(222)
    }
}
