import Foundation

public struct Tool {
    public init(command: String, arguments: [String]? = nil, filters: [Filter] = [], allowFailure: Bool = false) {
        self.command = command
        self.arguments = arguments
        self.filters = filters
        self.allowFailure = allowFailure
    }

    public init(shellCommand: String, filters: [Filter] = [], allowFailure: Bool = false) {
        self.init(command: "/bin/sh", arguments: ["-c", shellCommand], filters: filters, allowFailure: allowFailure)
    }

    public func run(includeStandardError: Bool = true) async throws {
        var outputLines: [String]?
        try await run(outputLines: &outputLines, includeStandardError: includeStandardError)
    }

    public func run(outputLines: inout [String]?, includeStandardError: Bool = true) async throws {
        try FullLog.write("➤ Command \(command)")
        try arguments.map { args in
            try FullLog.write(args.map { "  ➤ \($0)" }.joined(separator: "\n"))
        }
        try FullLog.write("")

        let process = Process()
        let pipe = Pipe()
        process.standardOutput = pipe
        if includeStandardError {
            process.standardError = pipe
        } else {
            process.standardError = FileHandle(forWritingAtPath: "/dev/null")!
        }
        process.executableURL = URL(fileURLWithPath: command)
        arguments.map { process.arguments = $0 }
        do {
            try process.run()
            try await processLines(file: pipe.fileHandleForReading, outputLines: &outputLines)
        } catch {
            throw BuildError(message: "Failed to execute tool '\(command)': \(error)")
        }
        process.waitUntilExit()
        if !allowFailure && process.terminationStatus != 0 {
            throw BuildError(message: "Tool exited with code \(process.terminationStatus).")
        }
    }

    public func runAndGetOutput(includeStandardError: Bool = true) async throws -> String {
        var outputLines: [String]! = []
        try await run(outputLines: &outputLines, includeStandardError: includeStandardError)
        return outputLines.joined(separator: "\n")
    }

    private func processLines(file: FileHandle, outputLines: inout [String]?) async throws {
        for try await line in file.bytes.lines {
            try FullLog.write(line)
            outputLines?.append(line)
            try applyFilters(line: line).map(log)
        }
    }

    private func applyFilters(line: String) throws -> String? {
        var filteredLine: String? = line
        for filter in filters {
            guard let line = filteredLine else { break }
            filteredLine = filter(line)
        }
        return filteredLine
    }

    private let command: String
    private let arguments: [String]?
    private let filters: [Filter]
    private let allowFailure: Bool
}
