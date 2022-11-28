import Foundation

public protocol Log {
    func callAsFunction(_ line: String)
    func completion(_ line: String)
    func success(_ line: String)
    func warning(_ line: String)
    func error(_ line: String)
    func enteringStep(name: String) throws
    func skippedStep(name: String) throws
    func finishedStep(name: String, duration: TimeInterval) throws
    func failedStep(name: String) throws
    func lines(title: String, lines: String)
    func lines(title: String, lines: [String])
}

public extension Log {
    func completion(_ line: String) {
        self("\(Symbols.completion) \(line)")
    }

    func success(_ line: String) {
        self("\(Symbols.success) \(line)")
    }

    func warning(_ line: String) {
        self("\("<Warning>".yellow().bold()) \(line)")
    }

    func error(_ line: String) {
        self("\("<Error>".red().bold()) \(line)")
    }

    func enteringStep(name: String) throws {
        self("")
        self("Entering step [\(name.cyan())]")
        try FullLog.writeHeader("Entering step [\(name)]")
    }

    func skippedStep(name: String) throws {
        self("")
        self("Step [\(name.yellow())] was skipped")
        try FullLog.writeHeader("Step [\(name)] was skipped")
    }

    func finishedStep(name: String, duration: TimeInterval) throws {
        let formattedDuration = String(format: "%.1f", duration)
        self("Finished step [\(name.cyan())] in \(formattedDuration) seconds")
        try FullLog.write("Finished step [\(name)] in \(formattedDuration) seconds\n")
    }

    func failedStep(name: String) throws {
        self("Step [\(name.red().bold())] failed")
        try FullLog.write("Step [\(name)] failed\n")
    }

    func lines(title: String, lines: String) {
        self.lines(title: title, lines: lines.split(whereSeparator: \.isNewline).map(String.init))
    }

    func lines(title: String, lines: [String]) {
        completion(title)
        self("")
        for line in lines {
            self(line)
        }
        self("")
    }
}

internal struct LogImpl: Log {
    public func callAsFunction(_ line: String) {
        print(line)
        fflush(stdout)
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

    private let startDate = Date.now
}

struct Symbols {
    static let success = "✔︎".green()
    static let completion = "▸".yellow()
}

public extension String {
    var completion: String {
        "\(Symbols.completion) \(self)"
    }

    var success: String {
        "\(Symbols.success) \(self)"
    }
}
