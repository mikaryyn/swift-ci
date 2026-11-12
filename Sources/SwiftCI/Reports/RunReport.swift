import Foundation

/// The findings and sections that a command adds to its run report.
///
/// A plain value, so that renderers and tests can build one. The running command's report is read
/// with ``Report/current``.
public struct RunReport: Equatable, Sendable {
    /// Creates a report.
    ///
    /// - Parameters:
    ///   - commandName: The name of the command that the report belongs to.
    ///   - findings: The findings, in the order they were added.
    ///   - sections: The sections, in the order they were added.
    ///   - outcome: How the command ended, or `nil` while it runs.
    public init(
        commandName: String,
        findings: [ReportFinding] = [],
        sections: [ReportSection] = [],
        outcome: CommandOutcome? = nil
    ) {
        self.commandName = commandName
        self.findings = findings
        self.sections = sections
        self.outcome = outcome
    }

    /// The name of the command that the report belongs to.
    public var commandName: String
    /// The findings, in the order they were added.
    public var findings: [ReportFinding]
    /// The sections, in the order they were added.
    public var sections: [ReportSection]
    /// How the command ended, or `nil` until the outcome is set. It is set before the `onReport` handlers run, and
    /// `nil` in the `cleanup` and `onFailure` handlers.
    public var outcome: CommandOutcome?

    /// The findings with severity ``ReportSeverity/failure``, in the order they were added.
    public var failures: [ReportFinding] {
        filtered(.failure)
    }

    /// The findings with severity ``ReportSeverity/warning``, in the order they were added.
    public var warnings: [ReportFinding] {
        filtered(.warning)
    }

    /// The findings with severity ``ReportSeverity/message``, in the order they were added.
    public var messages: [ReportFinding] {
        filtered(.message)
    }

    /// `true` if there are no failures and no warnings, and the command succeeded.
    public var isClean: Bool {
        failures.isEmpty && warnings.isEmpty && outcome == .succeeded
    }

    private func filtered(_ severity: ReportSeverity) -> [ReportFinding] {
        findings.filter { $0.severity == severity }
    }
}

/// A finding of the run report: a failure, a warning or a message, with an optional location.
public struct ReportFinding: Equatable, Sendable {
    /// Creates a finding.
    ///
    /// - Parameters:
    ///   - severity: How serious the finding is.
    ///   - text: Markdown inline text, one paragraph.
    ///   - file: Repository-relative path, if the finding has a location.
    ///   - line: The line in `file`, if the finding has one.
    public init(severity: ReportSeverity, text: String, file: String? = nil, line: Int? = nil) {
        self.severity = severity
        self.text = text
        self.file = file
        self.line = line
    }

    /// How serious the finding is.
    public var severity: ReportSeverity
    /// Markdown inline text, one paragraph.
    public var text: String
    /// Repository-relative path, if the finding has a location.
    public var file: String?
    /// The line in `file`, if the finding has one.
    public var line: Int?
}

/// How serious a finding of the run report is.
public enum ReportSeverity: Hashable, Sendable {
    /// The finding fails the command.
    case failure
    /// The finding does not fail the command, but the run is not clean.
    case warning
    /// The finding is information, such as a summary of a check.
    case message
}

/// A block of the run report: an optional title and Markdown content.
public struct ReportSection: Equatable, Sendable {
    /// Creates a section.
    ///
    /// - Parameters:
    ///   - title: The heading of the section, or `nil` for none.
    ///   - markdown: Markdown block content, such as a table or `<details>`.
    public init(title: String? = nil, markdown: String) {
        self.title = title
        self.markdown = markdown
    }

    /// The heading of the section, or `nil` for none.
    public var title: String?
    /// Markdown block content, such as a table or `<details>`.
    public var markdown: String
}

/// How a command ended.
public enum CommandOutcome: Equatable, Sendable {
    /// The command body and its handlers succeeded.
    case succeeded
    /// The command failed with `message`.
    case failed(message: String)
}
