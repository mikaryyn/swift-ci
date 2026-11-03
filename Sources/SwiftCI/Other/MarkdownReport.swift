import Foundation

/// Renders a run report as Markdown, for a merge request comment, a step summary or a file.
///
/// The layout is fixed. Blocks are separated by one blank line, and the output ends with one newline:
/// - The heading is `## <title> failed` if the report has a failure or its outcome is ``CommandOutcome/failed(message:)``.
///   Otherwise it is `## <title> passed`. That includes a report with only warnings, and a report without an outcome.
/// - The failures table, under the line `**Failures**`, if there are failures.
/// - The warnings table, under the line `**Warnings**`, if there are warnings.
/// - The messages as a bullet list, if there are messages.
/// - Each section, in order. A section with a title starts with `### <title>`, and its Markdown follows unchanged,
///   except that leading and trailing line breaks are removed. A section with an empty title is treated as untitled,
///   and a section without Markdown is left out.
/// - The footer, if one was given.
///
/// A table has the columns `Location` and `Message`. The location is `path:line` in inline code, `path` in inline code
/// if the finding has no line, and empty if it has no file. A path that contains backticks is wrapped in a code span
/// with a longer fence. In a cell, `|` is written `\|`, and a line break is written `<br>`. Messages are written with
/// their line breaks as `<br>`.
///
/// Secrets are masked in every part, as the console masks them, before the length is measured.
///
/// When the complete text is longer than `maximumLength`, the output is truncated. Sections are dropped from the end
/// first. Then the messages, then the warning rows and the failure rows, each from the end. A list or table that is
/// cut ends with a line that says how many entries were left out. A note says that the full report is in the artifacts
/// of the build, and the note is added once. The heading, the note and the footer are always kept, even if they alone
/// are longer than the limit. Table headers are kept too.
public struct MarkdownReport {
    /// Creates a renderer.
    ///
    /// - Parameters:
    ///   - title: The name in the heading, for example the command name.
    ///   - footer: Markdown for the last block. It is never cut, so a caller can put a hidden marker on its last line.
    ///   - maximumLength: The longest output, in `Character`s, when the fixed parts fit. See the type's description.
    public init(title: String, footer: String? = nil, maximumLength: Int = 100_000) {
        self.title = title
        self.footer = footer
        self.maximumLength = maximumLength
    }

    private let title: String
    private let footer: String?
    private let maximumLength: Int

    /// Renders `report` as Markdown. The report is not changed, and nothing is logged.
    ///
    /// - Parameter report: The report to render.
    /// - Returns: The Markdown text, ending with one newline, truncated to ``init(title:footer:maximumLength:)``'s limit
    ///   if it is longer.
    public func render(_ report: RunReport) -> String {
        let parts = Parts(title: title, footer: footer, report: report)
        let complete = parts.render(Keep(parts, truncated: false))
        guard complete.count > maximumLength else { return complete }

        let limit = maximumLength
        func fits(_ keep: Keep) -> Bool {
            parts.render(keep).count <= limit
        }

        var keep = Keep(parts, truncated: true)
        keep = keepAsManyAsFit(\.sections, total: parts.sections.count, keep, fits: fits)
        keep = keepAsManyAsFit(\.messages, total: parts.messages.count, keep, fits: fits)
        keep = keepAsManyAsFit(\.warnings, total: parts.warnings.count, keep, fits: fits)
        keep = keepAsManyAsFit(\.failures, total: parts.failures.count, keep, fits: fits)
        return parts.render(keep)
    }
}

/// The parts of a rendered report, each already masked and escaped. The counts of ``Keep`` say how many entries of each
/// list are written.
private struct Parts {
    let heading: String
    /// The rows of the failures table, without the header.
    let failures: [String]
    /// The rows of the warnings table, without the header.
    let warnings: [String]
    /// The text of each message, without the bullet.
    let messages: [String]
    /// Each section as a complete block, with its heading if it has one.
    let sections: [String]
    let footer: String?

    init(title: String, footer: String?, report: RunReport) {
        let failed: Bool
        if case .failed = report.outcome {
            failed = true
        } else {
            failed = !report.failures.isEmpty
        }
        heading = "## \(SecretRegistry.redact(title)) \(failed ? "failed" : "passed")"

        failures = report.failures.map(Parts.row)
        warnings = report.warnings.map(Parts.row)
        messages = report.messages.map { breakLines(SecretRegistry.redact($0.text)) }
        sections = report.sections.compactMap(Parts.sectionBlock)
        let markedFooter = footer.map { SecretRegistry.redact($0).trimmingCharacters(in: .newlines) }
        self.footer = markedFooter?.isEmpty == true ? nil : markedFooter
    }

    /// The Markdown of the report with the given number of entries of each list. A cut list ends with a line that says
    /// how many entries were left out.
    func render(_ keep: Keep) -> String {
        var blocks = [heading]
        blocks += table(label: "**Failures**", rows: failures, kept: keep.failures)
        blocks += table(label: "**Warnings**", rows: warnings, kept: keep.warnings)
        if !messages.isEmpty {
            blocks.append(messageList(kept: keep.messages))
        }
        blocks += sections.prefix(keep.sections)
        if keep.truncated {
            blocks.append(note)
        }
        if let footer {
            blocks.append(footer)
        }
        return blocks.joined(separator: "\n\n") + "\n"
    }

    /// The label and the table of one kind of finding. Both are empty if there are no rows.
    private func table(label: String, rows: [String], kept: Int) -> [String] {
        guard !rows.isEmpty else { return [] }
        var lines = ["| Location | Message |", "| --- | --- |"]
        lines += rows.prefix(kept)
        let left = rows.count - kept
        if left > 0 {
            lines.append("| | \(left) more left out |")
        }
        return [label, lines.joined(separator: "\n")]
    }

    private func messageList(kept: Int) -> String {
        var lines = messages.prefix(kept).map { "- \($0)" }
        let left = messages.count - kept
        if left > 0 {
            lines.append("- \(left) more left out")
        }
        return lines.joined(separator: "\n")
    }

    private static func row(_ finding: ReportFinding) -> String {
        "| \(location(finding)) | \(tableCell(SecretRegistry.redact(finding.text))) |"
    }

    /// The location of a finding in a table cell: `path:line` or `path` in inline code, or empty without a file.
    private static func location(_ finding: ReportFinding) -> String {
        guard let file = finding.file, !file.isEmpty else { return "" }
        let path = finding.line.map { "\(file):\($0)" } ?? file
        return tableCell(codeSpan(SecretRegistry.redact(path)))
    }

    /// A section as a block. Leading and trailing line breaks of its Markdown are removed. A section without Markdown
    /// is left out, so this returns `nil` for it.
    private static func sectionBlock(_ section: ReportSection) -> String? {
        let markdown = SecretRegistry.redact(section.markdown).trimmingCharacters(in: .newlines)
        guard !markdown.isEmpty else { return nil }
        guard let title = section.title, !title.isEmpty else { return markdown }
        return "### \(SecretRegistry.redact(title))\n\n\(markdown)"
    }

    private var note: String {
        "Some of this report was left out to fit the length limit. The full report is in the artifacts of the build."
    }
}

/// How many entries of each list are written. ``truncated`` is `true` when the output is cut, which adds the note.
private struct Keep {
    var failures: Int
    var warnings: Int
    var messages: Int
    var sections: Int
    let truncated: Bool

    /// Keeps every entry of `parts`.
    init(_ parts: Parts, truncated: Bool) {
        failures = parts.failures.count
        warnings = parts.warnings.count
        messages = parts.messages.count
        sections = parts.sections.count
        self.truncated = truncated
    }
}

/// Keeps as many entries of one list as fit, with the other lists as `keep` says. Sets the count in `keep` and returns
/// the result. Entries are dropped from the end, so the count is the largest one that fits, or zero if none fits.
private func keepAsManyAsFit(
    _ count: WritableKeyPath<Keep, Int>,
    total: Int,
    _ keep: Keep,
    fits: (Keep) -> Bool
) -> Keep {
    var result = keep
    result[keyPath: count] = largestFitting(total) { kept in
        var trial = keep
        trial[keyPath: count] = kept
        return fits(trial)
    }
    return result
}

/// The largest number in `0...total` for which `fits` is `true`, or `0` if none is.
///
/// The full count is tested first. A cut list is longer than a full one only by its "left out" line, so the search
/// below the full count is over cut lists only. Each extra entry makes a cut list longer, and that is what makes
/// the binary search valid there. A binary search, so a long list needs only a few renders.
private func largestFitting(_ total: Int, _ fits: (Int) -> Bool) -> Int {
    if fits(total) {
        return total
    }
    var low = 0
    var high = total - 1
    while low < high {
        let middle = (low + high + 1) / 2
        if fits(middle) {
            low = middle
        } else {
            high = middle - 1
        }
    }
    return low
}

/// Wraps `text` in inline code. The fence is one backtick longer than the longest run of backticks in `text`, so the
/// text may contain backticks. A space is added inside the fence if the text starts or ends with a backtick.
private func codeSpan(_ text: String) -> String {
    var longest = 0
    var run = 0
    for character in text {
        run = character == "`" ? run + 1 : 0
        longest = max(longest, run)
    }
    let fence = String(repeating: "`", count: longest + 1)
    let padding = text.hasPrefix("`") || text.hasSuffix("`") ? " " : ""
    return "\(fence)\(padding)\(text)\(padding)\(fence)"
}

/// Escapes text for a table cell: `|` becomes `\|`, and line breaks become `<br>`.
private func tableCell(_ text: String) -> String {
    breakLines(text.replacingOccurrences(of: "|", with: "\\|"))
}

/// Replaces each line break, `\r\n`, `\r` or `\n`, with `<br>`. `\r\n` is replaced first, because it is one `Character`.
private func breakLines(_ text: String) -> String {
    text.replacingOccurrences(of: "\r\n", with: "<br>")
        .replacingOccurrences(of: "\r", with: "<br>")
        .replacingOccurrences(of: "\n", with: "<br>")
}
