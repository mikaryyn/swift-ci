import Foundation

let startDate = Date.now

struct Symbols {
    static let success = "✔︎".green()
    static let completion = "▸".yellow()
}

public func log(_ line: String) {
    print(line)
    fflush(stdout)
}

public func logCompletion(_ line: String) {
    log("\(Symbols.completion) \(line)")
}

public func logSuccess(_ line: String) {
    log("\(Symbols.success) \(line)")
}

public func logWarning(_ line: String) {
    log("\("<Warning>".yellow().bold()) \(line)")
}

func logError(_ line: String) {
    log("\("<Error>".red().bold()) \(line)")
}

func logEnteringStep(name: String) throws {
    log("")
    log("Entering step [\(name.cyan())]")
    try FullLog.writeHeader("Entering step [\(name)]")
}

func logSkippedStep(name: String) throws {
    log("")
    log("Step [\(name.yellow())] was skipped")
    try FullLog.writeHeader("Step [\(name)] was skipped")
}

func logFinishedStep(name: String, duration: TimeInterval) throws {
    let formattedDuration = String(format: "%.1f", duration)
    log("Finished step [\(name.cyan())] in \(formattedDuration) seconds")
    try FullLog.write("Finished step [\(name)] in \(formattedDuration) seconds\n")
}

func logFailedStep(name: String) throws {
    log("Step [\(name.red().bold())] failed")
    try FullLog.write("Step [\(name)] failed\n")
}

public func logLines(title: String, lines: String) {
    logLines(title: title, lines: lines.split(whereSeparator: \.isNewline).map(String.init))
}

public func logLines(title: String, lines: [String]) {
    logCompletion(title)
    log("")
    for line in lines {
        log(line)
    }
    log("")
}

private func getTimeStamp() -> String {
    let seconds = Int(ceil(startDate.distance(to: Date.now)))
    let minutes = seconds / 60
    if minutes > 0 {
        return "\(minutes)m \(seconds - minutes * 60)m".darkGray()
    } else {
        return "\(seconds)s".darkGray()
    }
}

public extension String {
    var completion: String {
        "\(Symbols.completion) \(self)"
    }

    var success: String {
        "\(Symbols.success) \(self)"
    }
}

public struct FullLog {
    static var file: FileHandle?

    static func open(name: String) throws {
        let path = try TemporaryDirectory().childPath(name: "\(name).log")
        log("Saving full log to \(path.string)")
        close()

        if FileManager.default.createFile(atPath: path.string, contents: nil, attributes: nil) {
            file = FileHandle(forWritingAtPath: path.string)
        }
        if file == nil {
            throw BuildError(message: "Failed to write build log to '\(path)'")
        }
    }

    static func close() {
        do {
            try file?.close()
        } catch {
            logError("Failed to close build log")
        }
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
