import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Checks of the files in a repository that add findings to the run report.
extension Git {
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
    ///   - name: The step name chosen by the caller, or `nil` for the default.
    /// - Returns: The paths that remain after `patterns` are applied, as `git` prints them. Empty if there are none.
    @discardableResult
    public func reportUncommittedChanges(
        ignoring patterns: [String] = [],
        message: String,
        step name: String? = nil
    ) async throws -> [String] {
        try await step(default: "Check for uncommitted changes", name: name) {
            let output = try await gitTool(["diff", "HEAD", "--name-only", "-z"]).output()
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
    ///   - name: The step name chosen by the caller, or `nil` for the default.
    /// - Returns: The findings that were added, in order.
    @discardableResult
    public func reportLines(
        matching pattern: String,
        in pathspecs: [String],
        message: String,
        severity: ReportSeverity = .failure,
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

            let output = try await gitTool(["ls-files", "-z", "--"] + pathspecs).output()
            var findings: [ReportFinding] = []
            for file in output.split(separator: "\0").map(String.init) {
                // A submodule or a link to a folder is listed as a file, and has no lines to check.
                guard !isDirectory(file) else { continue }
                guard let lines = textLines(ofFile: file) else {
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

    /// The URL of a path that `git ls-files` prints, which is relative to the repository folder of the calls.
    private func fileURL(_ path: String) -> URL {
        URL(fileURLWithPath: path, relativeTo: repository)
    }

    private func isDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: fileURL(path).filePath, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// The lines of a file, or `nil` if it cannot be read as UTF-8. Lines are split on LF, and a CR before the LF is
    /// removed. A final LF does not start another line.
    private func textLines(ofFile file: String) -> [String]? {
        guard let data = try? Data(contentsOf: fileURL(file)), let text = String(data: data, encoding: .utf8) else { return nil }
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" {
            lines.removeLast()
        }
        return lines.map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
    }

    /// Adds `finding` to the run report with its severity and location.
    private func addToReport(_ finding: ReportFinding) {
        switch finding.severity {
        case .failure: Report.failure(finding.text, file: finding.file, line: finding.line)
        case .warning: Report.warning(finding.text, file: finding.file, line: finding.line)
        case .message: Report.message(finding.text, file: finding.file, line: finding.line)
        }
    }
}
