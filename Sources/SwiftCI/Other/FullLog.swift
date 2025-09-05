import Foundation
import System

public struct FullLog {
    @Use private static var log: Log

    static var path: FilePath?
    static var file: FileHandle?

    static func open(name: String) throws {
        let path = try TemporaryDirectory().childPath(name: "\(name).log")
        log("Saving full log to file://\(path.string)")
        close()

        if FileManager.default.createFile(atPath: path.string, contents: nil, attributes: nil) {
            file = FileHandle(forWritingAtPath: path.string)
        }
        if file == nil {
            throw BuildError(message: "Failed to write build log to '\(path)'")
        }
        FullLog.path = path
    }

    static func close() {
        do {
            try file?.close()
            FullLog.path.map { log("Saved full log to file://\($0.string)") }
        } catch {
            log.error("Failed to close build log")
        }
        path = nil
        file = nil
    }

    static func write(_ line: String) throws {
        do {
            try line.data(using: .utf8).map {
                try file?.write(contentsOf: $0)
                file?.write(linebreak)
            }
        } catch {
            throw BuildError(message: "Failed to write into build log")
        }
    }

    static func writeHeader(_ line: String) throws {
        let length = line.count
        let divider = String(repeating: "=", count: length)
        try write("\(divider)\n\(line)\n\(divider)")
    }

    static let linebreak = "\n".data(using: .utf8)!
}
