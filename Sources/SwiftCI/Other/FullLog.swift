import Foundation

public struct FullLog {
    @Use private static var log: Log

    static var path: URL?
    static var file: FileHandle?

    /// Creates the `logs` directory in the artifacts directory. Replaced in tests to simulate a failure.
    static var makeDirectory: (URL) throws -> Void = { try FileManager.default.createDirectory(at: $0, withIntermediateDirectories: true) }

    /// Closes the log file. Replaced in tests to simulate a failure, because Foundation does not fail on a double close.
    static var closeHandle: (FileHandle) throws -> Void = { try $0.close() }

    static func open(name: String) throws {
        let path = try logPath(name: name)
        log("Saving full log to file://\(path.filePath)")
        try close()

        if FileManager.default.createFile(atPath: path.filePath, contents: nil, attributes: nil) {
            file = FileHandle(forWritingAtPath: path.filePath)
        }
        if file == nil {
            throw BuildError(
                message: "Failed to create build log file '\(path.filePath)'. Check that the directory is writable and that the command name is a valid file name.",
                code: .internal
            )
        }
        FullLog.path = path
    }

    /// Closes the log file and clears the path and the file, also if closing fails.
    /// Logs the saved location on success. A failure to close is thrown, so the run can fail.
    static func close() throws {
        let closedPath = path
        let handle = file
        path = nil
        file = nil

        do {
            if let handle {
                try closeHandle(handle)
            }
        } catch {
            let location = closedPath.map { " '\($0.filePath)'" } ?? ""
            throw BuildError(
                message: "Failed to close the build log\(location). Check that the disk is not full. Details: \(error)",
                code: .internal
            )
        }
        closedPath.map { log("Saved full log to file://\($0.filePath)") }
    }

    static func write(_ line: String) throws {
        guard let file else { return }
        do {
            try file.write(contentsOf: Data(SecretRegistry.redact(line).utf8))
            try file.write(contentsOf: linebreak)
        } catch {
            throw BuildError(
                message: "Failed to write into the build log. Check that the disk is not full. Details: \(error)",
                code: .internal
            )
        }
    }

    /// Writes a header for a step. Top-level steps use "=" dividers, nested steps use "-" dividers.
    /// Both are indented by two spaces per depth level.
    static func writeHeader(_ line: String, depth: Int = 0) throws {
        let indent = stepIndent(depth)
        let divider = String(repeating: depth == 0 ? "=" : "-", count: line.count)
        try write("\(indent)\(divider)\n\(indent)\(line)\n\(indent)\(divider)")
    }

    /// The path of the log file for `name`: `logs/<name>.log` in the artifacts directory. The `logs` directory is created.
    /// An existing log of the same name is overwritten when the file is created.
    private static func logPath(name: String) throws -> URL {
        let logs = Artifacts.directory.appending(path: "logs")
        do {
            try makeDirectory(logs)
        } catch {
            throw BuildError(
                message: "Failed to create the build log directory '\(logs.filePath)'. Check that the artifacts directory is writable. Details: \(error)",
                code: .internal
            )
        }
        return logs.appending(path: "\(name).log")
    }

    static let linebreak = "\n".data(using: .utf8)!
}
