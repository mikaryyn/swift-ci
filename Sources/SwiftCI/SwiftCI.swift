import Foundation
import System

public class SwiftCI {
    public init(commands: [Command] = []) {
        self.commands = commands
    }

    public func command(_ command: Command) -> SwiftCI {
        commands.append(command)
        return self
    }

    public func main() async {
        exitIfUpdateIsNeeded()

        let arguments = Array(CommandLine.arguments.dropFirst())
        for command in commands {
            if command.name == arguments.first {
                await run(command: command)
                break
            }
        }
    }

    func run(command: Command) async {
        do {
            try FullLog.open(name: command.name)
            defer { FullLog.close() }
            await command.run()
            if command.hasFailed {
                exit(1)
            }
        } catch let error as BuildError {
            logError(error.message)
            exit(1)
        } catch {
            logError("Unexpected error occurred: \(error)")
            exit(2)
        }
    }

    var commands: [Command]
}

private func exitIfUpdateIsNeeded() {
    func getModificationDate(_ path: FilePath) -> Date? {
        let attrs = (try? FileManager.default.attributesOfItem(atPath: path.string)) ?? [:]
        return attrs[.modificationDate] as? Date
    }

    let executablePath = FilePath(Bundle.main.executablePath ?? "")
    if !executablePath.ends(with: ".build/release/ci") {
        return // Unknown path; cannot continue.
    }
    guard let executableDate = getModificationDate(executablePath) else {
        return // Unknown modification date; cannot continue.
    }

    let sourcesPath = executablePath
        .removingLastComponent()
        .removingLastComponent()
        .removingLastComponent()
        .appending("Sources")

    let sourcesContents = FileManager.default.enumerator(atPath: sourcesPath.string)?.allObjects.map { FilePath($0 as! String) } ?? []
    let timeIntervalToMostRecentSource = sourcesContents
        .filter { $0.extension == "swift" }
        .compactMap { getModificationDate(sourcesPath.appending($0.string)) }
        .max()
        .map { executableDate.distance(to: $0) } ?? .zero

    if timeIntervalToMostRecentSource > 0 {
        print("Tool is outdated and needs to be rebuilt.")
        exit(222)
    }
}
