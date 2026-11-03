import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public struct Git {
    /// Returns the short hash of `HEAD`.
    ///
    /// A query: does not open a step.
    public static func getCommitHash() async throws -> String {
        try await Tool(
            command: "git",
            arguments: ["rev-parse", "--short", "HEAD"],
            filters: [filter(#/.*/#)]
        ).output()
    }

    /// Returns the tag that points exactly at `HEAD`, or `nil` if there is none.
    ///
    /// A query: does not open a step.
    public static func getCommitTag() async throws -> String? {
        // "No tag" is expected, so a non-zero exit is not an error and gets no warning.
        let result = try await Tool(
            command: "git",
            arguments: ["describe", "--tags", "--exact-match"],
            filters: [filter(#/^fatal:/#)]
        ).result()
        guard result.exitCode == 0, !result.stdout.isEmpty else { return nil }
        return result.stdout
    }

    /// Adds a failure with `message`, and a section that lists the paths, if a tracked file differs from `HEAD`.
    ///
    /// The changes can be staged or not. Untracked files are not checked, as in Danger's `git.diff('HEAD')` check.
    /// A path is dropped if one of `patterns` matches the whole path with `fnmatch`, without `FNM_PATHNAME`, so `*.png`
    /// also matches `assets/icon.png`.
    ///
    /// Opens a step, named "Check for uncommitted changes" unless `name` is given. The failure fails the command at its
    /// end, as any report failure does.
    ///
    /// - Parameters:
    ///   - patterns: Glob patterns of paths to ignore, such as `*.png`.
    ///   - message: The text of the failure, added if a path remains.
    ///   - repository: The working directory of `git`, inside the repository. The current directory if `nil`.
    ///   - name: The step name chosen by the caller, or `nil` for the default.
    /// - Returns: The paths that remain after `patterns` are applied, as `git` prints them. Empty if there are none.
    @discardableResult
    public static func reportUncommittedChanges(
        ignoring patterns: [String] = [],
        message: String,
        repository: URL? = nil,
        step name: String? = nil
    ) async throws -> [String] {
        try await step(default: "Check for uncommitted changes", name: name) {
            let output = try await Tool(
                command: "git",
                arguments: ["diff", "HEAD", "--name-only", "-z"],
                workingDirectory: repository,
                filters: [filter(#/.*/#)]
            ).output()
            let paths = output.split(separator: "\0").map(String.init).filter { path in
                !patterns.contains { fnmatch($0, path, 0) == 0 }
            }
            guard !paths.isEmpty else { return [] }

            Report.failure(message)
            Report.markdown(paths.map { "- \(codeSpan($0))" }.joined(separator: "\n"), title: "Uncommitted changes")
            return paths
        }
    }

    /// Adds one finding for each line of a tracked file that matches `pattern`, with the file and the line number.
    ///
    /// `pattern` is a Swift `Regex` in string form. It is compiled before `git` runs, and an invalid pattern throws a
    /// ``BuildError``. The files are the tracked files that `git ls-files` lists for `pathspecs`. A file that cannot be
    /// read as UTF-8 is skipped, with one warning in the log. Lines are split on LF, and a CR before the LF is not part
    /// of the line.
    ///
    /// A pattern written literally in a checked file matches itself. In Swift code that checks `*.swift`, `Y{4}` is
    /// therefore safer than `YYYY`, because the line that holds the pattern would match.
    ///
    /// Opens a step, named "Check lines matching <pattern>" unless `name` is given.
    ///
    /// - Parameters:
    ///   - pattern: The Swift `Regex` in string form, such as `Y{4}`.
    ///   - pathspecs: Pathspecs for `git ls-files`, such as `*.swift`. An empty list checks every tracked file.
    ///   - message: The text of each finding.
    ///   - severity: The severity of each finding. The default is ``ReportSeverity/failure``.
    ///   - repository: The working directory of `git`, inside the repository. The current directory if `nil`.
    ///   - name: The step name chosen by the caller, or `nil` for the default.
    /// - Returns: The findings that were added, in order.
    @discardableResult
    public static func reportLines(
        matching pattern: String,
        in pathspecs: [String],
        message: String,
        severity: ReportSeverity = .failure,
        repository: URL? = nil,
        step name: String? = nil
    ) async throws -> [ReportFinding] {
        try await step(default: "Check lines matching \(pattern)", name: name) {
            let regex: Regex<AnyRegexOutput>
            do {
                regex = try Regex(pattern)
            } catch {
                throw BuildError(
                    message: "The pattern \"\(pattern)\" is not a valid Swift Regex (\(error)). Pass a pattern that Regex accepts."
                )
            }
            @Use var log: Log

            let output = try await Tool(
                command: "git",
                arguments: ["ls-files", "-z", "--"] + pathspecs,
                workingDirectory: repository,
                filters: [filter(#/.*/#)]
            ).output()
            var findings: [ReportFinding] = []
            for file in output.split(separator: "\0").map(String.init) {
                guard let lines = textLines(ofFile: file, in: repository) else {
                    log.warning("Skipped \(file) in the line check: it cannot be read as UTF-8 text.")
                    continue
                }
                for (index, line) in lines.enumerated() where line.contains(regex) {
                    let finding = ReportFinding(severity: severity, text: message, file: file, line: index + 1)
                    addToReport(finding)
                    findings.append(finding)
                }
            }
            return findings
        }
    }

    /// The lines of a file, or `nil` if it cannot be read as UTF-8. Lines are split on LF, and a CR before the LF is
    /// removed. A final LF does not start another line.
    private static func textLines(ofFile file: String, in repository: URL?) -> [String]? {
        let url = URL(fileURLWithPath: file, relativeTo: repository)
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else { return nil }
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" {
            lines.removeLast()
        }
        return lines.map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
    }

    /// Adds `finding` to the run report with its severity and location.
    private static func addToReport(_ finding: ReportFinding) {
        switch finding.severity {
        case .failure: Report.failure(finding.text, file: finding.file, line: finding.line)
        case .warning: Report.warning(finding.text, file: finding.file, line: finding.line)
        case .message: Report.message(finding.text, file: finding.file, line: finding.line)
        }
    }
}
