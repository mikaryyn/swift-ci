import Foundation

/// The console log of a run. `@Use var log: Log` gives the log of the running script. A custom log only has to
/// implement ``consoleOnly(_:)``, every other requirement has a default implementation that builds on it.
///
/// The lines of the log are output only. They do not change the run report or the exit code. To add a finding to the
/// report, use `Report`.
public protocol Log {
    /// Writes a line to the console only, after the secrets are masked. ``callAsFunction(_:)`` writes to the console
    /// through it, and the step lines use it because they write their own full-log lines. Scripts do not call it.
    func consoleOnly(_ line: String)
    /// Logs the result of a piece of work that is done, marked with ``LogSymbol/completion``.
    func completion(_ line: String)
    /// Logs a success, marked with ``LogSymbol/success``.
    func success(_ line: String)
    /// Logs a warning, marked with `<Warning>`. The line is only written. It is not added to the run report.
    func warning(_ line: String)
    /// Logs an error, marked with `<Error>`. The line is only written. It does not fail the command or enter the run
    /// report.
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
    /// Logs that a step was skipped, and why. `depth` is the nesting level (see ``enteringStep(name:depth:)``). In the
    /// full log the line is a step header, with dividers as for ``enteringStep(name:depth:)``.
    func skippedStep(name: String, reason: String, depth: Int) throws
    /// Logs `title` as a completion line, followed by `lines` split at line breaks and surrounded by blank lines.
    func lines(title: String, lines: String)
    /// Logs `title` as a completion line, followed by `lines` and surrounded by blank lines.
    func lines(title: String, lines: [String])
}

public extension Log {
    /// Logs `line` to the console, and writes it to the full log as plain text, without colour codes. Secrets are masked in
    /// both. A line logged outside a command or before the full log is open is written to the console only.
    func callAsFunction(_ line: String) {
        consoleOnly(line)
        FullLog.writeConsoleLine(line)
    }

    func completion(_ line: String) {
        self("\(LogSymbol.completion) \(line)")
    }

    func success(_ line: String) {
        self("\(LogSymbol.success) \(line)")
    }

    func warning(_ line: String) {
        self("\("<Warning>".yellow().bold()) \(line)")
    }

    func error(_ line: String) {
        self("\("<Error>".red().bold()) \(line)")
    }

    func enteringStep(name: String, depth: Int) throws {
        if depth == 0 {
            consoleOnly("")
        }
        consoleOnly("\(stepIndent(depth))Entering step [\(name.cyan())]")
        try FullLog.writeHeader("Entering step [\(name)]", depth: depth)
    }

    func finishedStep(name: String, duration: TimeInterval, depth: Int) throws {
        let formattedDuration = String(format: "%.1f", duration)
        let indent = stepIndent(depth)
        consoleOnly("\(indent)Finished step [\(name.cyan())] in \(formattedDuration) seconds")
        try FullLog.write("\(indent)Finished step [\(name)] in \(formattedDuration) seconds\n")
    }

    func failedStep(name: String, depth: Int) throws {
        let indent = stepIndent(depth)
        consoleOnly("\(indent)Step [\(name.red().bold())] failed")
        try FullLog.write("\(indent)Step [\(name)] failed\n")
    }

    func allowedFailedStep(name: String, depth: Int) throws {
        let indent = stepIndent(depth)
        consoleOnly("\(indent)Step [\(name.yellow().bold())] failed (allowed)")
        try FullLog.write("\(indent)Step [\(name)] failed (allowed)\n")
    }

    func skippedStep(name: String, reason: String, depth: Int) throws {
        if depth == 0 {
            consoleOnly("")
        }
        let indent = stepIndent(depth)
        consoleOnly("\(indent)Skipped step [\(name.darkGray())]: \(reason)")
        try FullLog.writeHeader("Skipped step [\(name)]: \(reason)", depth: depth)
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

struct LogImpl: Log {
    /// Writes one line to the console. This is the final console boundary: every line is masked here, after the
    /// default formatting of the `Log` requirements has added its text. Tests replace it to capture the output.
    static var printLine: (String) -> Void = { line in
        print(line)
        fflush(stdout)
    }

    func consoleOnly(_ line: String) {
        LogImpl.printLine(SecretRegistry.redact(line))
    }
}

/// The colored symbols that mark the lines of ``Log/completion(_:)`` and ``Log/success(_:)``. Use them to build a line
/// with the same marker, for example in a ``Filter``: `"\(LogSymbol.success) Done"`.
public enum LogSymbol {
    /// The marker of a success line, a green check mark.
    public static let success = "✔︎".green()
    /// The marker of a completion line, a yellow triangle.
    public static let completion = "▸".yellow()
}
