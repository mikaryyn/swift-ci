import Foundation

/// Prints the summary of the run report to the console and the full log, and writes the report as Markdown to the
/// artifacts directory. An empty report, with no findings and no sections, prints and writes nothing.
///
/// The summary goes to the console in colour, and to the full log without colour. The Markdown file is
/// `report-<command>.md`, rendered by ``MarkdownReport``. Both are masked for secrets, as every output is.
///
/// Errors do not stop the output. A failed full log write is recorded and absorbed as an internal error, and a failed
/// file write is logged once. The full log gets no summary once a write to it has failed, because the log is already
/// broken and that error is logged. Either one sets `failure` only if nothing failed before. Neither changes the outcome of
/// the report, which is already set when this runs.
@MainActor
internal func publishRunReport(_ context: RunContext, failure: inout CommandFailure?) {
    let report = context.report
    guard !report.findings.isEmpty || !report.sections.isEmpty else { return }
    @Use var log: Log

    for line in summaryLines(report, colored: true) {
        log(line)
    }
    if !FullLog.hasFailed {
        for line in summaryLines(report, colored: false) {
            context.writeStatus { try FullLog.write(line) }
        }
    }
    absorbInternalError(context, into: &failure)

    if let writeFailure = writeReportFile(report) {
        failure = failure ?? writeFailure
    }
}

/// The lines of the summary. A blank line and the header `Report` come first. Then one line per finding, failures
/// first, then warnings, then messages, each in the order it was added. Each section follows, with its title and its
/// Markdown, indented by two spaces.
///
/// A finding line starts with two spaces, the label and two more spaces. A text with several lines continues on the
/// following lines, indented to the same column as the start of the text. `colored` styles the header and the labels
/// for the console. The full log gets the same text without styles.
func summaryLines(_ report: RunReport, colored: Bool) -> [String] {
    let findings = report.failures + report.warnings + report.messages
    var lines = ["", style("Report", colored: colored) { $0.bold() }]

    let continuation = String(repeating: " ", count: findingIndent)
    for finding in findings {
        let parts = consoleText(finding).split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        for (index, part) in parts.enumerated() {
            if index == 0 {
                lines.append("  \(label(finding.severity, colored: colored))  \(part)")
            } else {
                lines.append(part.isEmpty ? "" : continuation + part)
            }
        }
    }

    for section in report.sections {
        let title = section.title ?? ""
        let markdown = section.markdown.trimmingCharacters(in: .newlines)
        guard !title.isEmpty || !markdown.isEmpty else { continue }
        lines.append("")
        if !title.isEmpty {
            lines.append("  ### \(title)")
        }
        for line in markdown.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            lines.append(line.isEmpty ? "" : "  \(line)")
        }
    }
    return lines
}

/// The column where the text of a finding starts: two spaces, the label padded to the longest label, and two spaces.
/// All labels are seven characters long, so the padding is the label itself.
private let findingIndent = 11

/// The label of a finding in the summary. A failure is red, a warning is yellow, and a message is not coloured, as in
/// the console lines of ``Report``.
private func label(_ severity: ReportSeverity, colored: Bool) -> String {
    switch severity {
    case .failure: style("failure", colored: colored) { $0.red().bold() }
    case .warning: style("warning", colored: colored) { $0.yellow().bold() }
    case .message: "message"
    }
}

/// `text` with `apply` when `colored` is `true`, and `text` unchanged otherwise.
private func style(_ text: String, colored: Bool, _ apply: (String) -> String) -> String {
    colored ? apply(text) : text
}

/// Writes the Markdown report to `report-<command>.md` in the artifacts directory and logs where it is. Returns the
/// failure if the file cannot be written. The error is logged here, once.
///
/// An error from the artifacts directory or the write is an internal error (exit code 3). The full log fails the same
/// way when the artifacts directory cannot be written.
@MainActor
private func writeReportFile(_ report: RunReport) -> CommandFailure? {
    @Use var log: Log

    let name = "report-\(fileNameComponent(report.commandName)).md"
    let markdown = MarkdownReport(title: report.commandName).render(report)
    do {
        let url = try Artifacts.url(name)
        try Data(markdown.utf8).write(to: url)
        log("Saved report to file://\(url.filePath)")
        return nil
    } catch {
        return logFailure(BuildError(
            message: "Failed to write the run report '\(name)' to the artifacts directory. Check that the directory is writable and that no folder has the same name. Details: \(errorMessage(error))",
            code: .internal
        ))
    }
}

/// The command name as a part of a file name. ASCII letters, digits, `-`, `_` and `.` are kept. Every other character,
/// such as `/` or `:`, becomes `-`.
func fileNameComponent(_ name: String) -> String {
    String(name.map { character in
        (character.isASCII && (character.isLetter || character.isNumber)) || "-_.".contains(character) ? character : "-"
    })
}
