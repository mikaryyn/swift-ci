import SwiftCI

class ShellMock: Shell {
   func exec(_ command: ShellCommand) async throws {
        execCommands.append(command)
   }

    func execAndGetOutput(_ command: ShellCommand) async throws -> String {
        return "ZZZ"
    }

    var execCommands = [ShellCommand]()
}
