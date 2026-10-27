import Foundation

public protocol Log {
    func callAsFunction(_ line: String)
    func completion(_ line: String)
    func success(_ line: String)
    func warning(_ line: String)
    func error(_ line: String)
    /// Logs that a step starts. `depth` is the nesting level: 0 for a top-level step, 1 for a step
    /// inside a step, and so on. Depth 0 starts a new group with a blank line. Deeper steps are indented
    /// by two spaces per level, and their full-log headers use "-" dividers.
    func enteringStep(name: String, depth: Int) throws
    /// Logs that a step finished, with its duration. `depth` is the nesting level (see ``enteringStep(name:depth:)``).
    func finishedStep(name: String, duration: TimeInterval, depth: Int) throws
    /// Logs that a step failed. `depth` is the nesting level (see ``enteringStep(name:depth:)``).
    /// The error message is not logged here; it is logged once where the error is handled.
    func failedStep(name: String, depth: Int) throws
    /// Logs that a step failed but was allowed to fail, so the command continues. `depth` is the nesting level
    /// (see ``enteringStep(name:depth:)``). The error message is logged separately, as a warning.
    func allowedFailedStep(name: String, depth: Int) throws
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

    func enteringStep(name: String, depth: Int) throws {
        if depth == 0 {
            self("")
        }
        self("\(stepIndent(depth))Entering step [\(name.cyan())]")
        try FullLog.writeHeader("Entering step [\(name)]", depth: depth)
    }

    func finishedStep(name: String, duration: TimeInterval, depth: Int) throws {
        let formattedDuration = String(format: "%.1f", duration)
        let indent = stepIndent(depth)
        self("\(indent)Finished step [\(name.cyan())] in \(formattedDuration) seconds")
        try FullLog.write("\(indent)Finished step [\(name)] in \(formattedDuration) seconds\n")
    }

    func failedStep(name: String, depth: Int) throws {
        let indent = stepIndent(depth)
        self("\(indent)Step [\(name.red().bold())] failed")
        try FullLog.write("\(indent)Step [\(name)] failed\n")
    }

    func allowedFailedStep(name: String, depth: Int) throws {
        let indent = stepIndent(depth)
        self("\(indent)Step [\(name.yellow().bold())] failed (allowed)")
        try FullLog.write("\(indent)Step [\(name)] failed (allowed)\n")
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

/// Indentation of a step line: two spaces per nesting level.
func stepIndent(_ depth: Int) -> String {
    String(repeating: "  ", count: depth)
}

internal struct LogImpl: Log {
    /// Writes one line to the console. This is the final console boundary: every line is masked here, after the
    /// default formatting of the `Log` requirements has added its text. Tests replace it to capture the output.
    static var printLine: (String) -> Void = { line in
        print(line)
        fflush(stdout)
    }

    public func callAsFunction(_ line: String) {
        LogImpl.printLine(SecretRegistry.redact(line))
    }

    private func getTimeStamp() -> String {
        LogImpl.formatElapsed(startDate.distance(to: Date.now)).darkGray()
    }

    /// Formats an elapsed time, rounded up to whole seconds, as `42s` or `3m 5s`.
    static func formatElapsed(_ interval: TimeInterval) -> String {
        let seconds = Int(ceil(interval))
        let minutes = seconds / 60
        if minutes > 0 {
            return "\(minutes)m \(seconds - minutes * 60)s"
        } else {
            return "\(seconds)s"
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
