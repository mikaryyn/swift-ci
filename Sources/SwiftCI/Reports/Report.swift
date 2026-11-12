import Foundation

/// Adds findings and sections to the run report of the running command.
///
/// Each finding is also logged when it is added, so the console shows it in the step where it was added:
/// a failure as an error line, a warning as a warning line and a message as a completion line. The line
/// starts with the location when the finding has a file, as `path:line: text`, or `path: text` without a line.
/// The full log does not get these lines, as with the other error and warning lines of the console.
///
/// Only call these inside a command body, or in a `cleanup` or `onFailure` handler, directly or through a
/// function called from it. Calling them outside a running command stops the process with a
/// `preconditionFailure`, as ``step(_:_:)`` does. This check is not unit tested.
///
/// When the command ends, a report that is not empty is printed after the handlers that add to it, as a summary, and
/// written to `report-<command>.md` in the artifacts directory, rendered by ``MarkdownReport``. The summary is printed
/// before the `onReport` handlers run. Findings added in an `onReport` handler are not in the summary or the file.
///
/// The report is final in an `onReport` handler, so these functions stop the process with a `preconditionFailure`
/// there too. Only ``current`` may be read in that handler. This check is not unit tested.
public enum Report {
    /// Adds a failure. The command fails at the end of its handlers, with the exit code of a failed command.
    ///
    /// - Parameters:
    ///   - text: Markdown inline text, one paragraph.
    ///   - file: Repository-relative path, if the failure has a location.
    ///   - line: The line in `file`, if the failure has one.
    public static func failure(_ text: String, file: String? = nil, line: Int? = nil) {
        addFinding(ReportFinding(severity: .failure, text: text, file: file, line: line))
    }

    /// Adds a warning. It does not fail the command, but the command is not clean.
    ///
    /// - Parameters:
    ///   - text: Markdown inline text, one paragraph.
    ///   - file: Repository-relative path, if the warning has a location.
    ///   - line: The line in `file`, if the warning has one.
    public static func warning(_ text: String, file: String? = nil, line: Int? = nil) {
        addFinding(ReportFinding(severity: .warning, text: text, file: file, line: line))
    }

    /// Adds a message. It neither fails the command nor makes it unclean.
    ///
    /// - Parameters:
    ///   - text: Markdown inline text, one paragraph.
    ///   - file: Repository-relative path, if the message has a location.
    ///   - line: The line in `file`, if the message has one.
    public static func message(_ text: String, file: String? = nil, line: Int? = nil) {
        addFinding(ReportFinding(severity: .message, text: text, file: file, line: line))
    }

    /// Adds a section with Markdown content, such as a table or a `<details>` block. It is not logged.
    ///
    /// - Parameters:
    ///   - markdown: Markdown block content.
    ///   - title: The heading of the section, or `nil` for none.
    public static func markdown(_ markdown: String, title: String? = nil) {
        addingContext("Report.markdown").report.sections.append(ReportSection(title: title, markdown: markdown))
    }

    /// A copy of the report of the running command, with the findings and sections added so far.
    /// Its ``RunReport/outcome`` is `nil` until the outcome is set, before the `onReport` handlers run.
    public static var current: RunReport {
        runningContext("Report.current").report
    }
}

/// Stores a finding in the running command's report and logs it.
private func addFinding(_ finding: ReportFinding) {
    @Use var log: Log

    addingContext("Report").report.findings.append(finding)

    let text = consoleText(finding)
    switch finding.severity {
    case .failure: log.error(text)
    case .warning: log.warning(text)
    case .message: log.completion(text)
    }
}

/// The text of the console line of `finding`: the text, after its location if it has a file. The summary of the run
/// report uses it too.
func consoleText(_ finding: ReportFinding) -> String {
    guard let file = finding.file else { return finding.text }
    let location = finding.line.map { "\(file):\($0)" } ?? file
    return "\(location): \(finding.text)"
}

/// The running command's context. Stops the process if no command runs.
private func runningContext(_ name: String) -> RunContext {
    guard let context = RunContext.current else {
        preconditionFailure("\(name) may only be called while a command runs, inside a Command body.")
    }
    return context
}

/// The running command's context, for a call that adds to the report. Stops the process if no command runs, or if the
/// call is made inside an `onReport` handler, where the report is final.
private func addingContext(_ name: String) -> RunContext {
    let context = runningContext(name)
    guard !context.isRunningReportHandler else {
        preconditionFailure("\(name) may not be called inside an onReport handler. The report is final there; read it with Report.current.")
    }
    return context
}
