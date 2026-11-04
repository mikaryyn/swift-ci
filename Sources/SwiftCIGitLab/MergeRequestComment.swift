import Foundation
import SwiftCI

/// What happens to the comment of a report ID when the run is clean, which means it has no failures and no warnings.
public enum CleanRunBehavior: Sendable {
    /// Deletes the comment, so nothing stays on the merge request. A run that is not clean posts or updates a plain note.
    case deleteComment

    /// Keeps the comment and replaces its text with the report of the clean run.
    case updateComment

    /// Keeps the comment as a resolvable thread. A clean run replaces its text and resolves the thread. A run that is
    /// not clean posts the report as a thread, and reopens the thread if it was resolved. A plain note that exists is
    /// replaced by a thread, because a plain note cannot be resolved.
    case resolveThread
}

/// Whether ``GitLab/updateComment(for:id:title:on:whenClean:mode:step:)`` changes the merge request or only reports what
/// it would change.
public enum CommentMode: Sendable {
    /// Creates, updates, resolves or deletes the comment, and logs each change as it is made.
    case post

    /// Sends only the reads, logs the rendered comment and the change it would make. Nothing on the merge request
    /// changes, so it is the dry run.
    case log
}

extension GitLab {
    /// Creates, updates, resolves or deletes the comment of one report ID on a merge request, so that each command
    /// keeps one comment on the merge request, whatever the number of its findings. Two commands with different IDs
    /// have two comments.
    ///
    /// The comment is the first note by the token's user whose text has the line
    /// `<!-- swiftci-report-id: <id> -->`. Notes of other users are never changed, even if they contain the marker. The
    /// text is ``MarkdownReport`` output with the title, followed by a footer that links the CI build and names the commit
    /// when the CI environment knows them. The marker is the last line of the text.
    ///
    /// What changes depends on whether the run is clean and on `whenClean`. The table is in ``CleanRunBehavior``. Every
    /// change logs one completion line, such as "Created merge request comment tests". A clean run without a comment
    /// logs "Nothing to do for merge request comment tests".
    ///
    /// The requests are `GET /user`, the discussions of the merge request (all pages), and the writes that bring the
    /// comment up to date, which are created notes or threads, note updates, thread resolutions and note deletions. In `CommentMode/log` only the
    /// reads are sent, and the rendered text and the "Would …" line of each change are logged instead.
    ///
    /// Opens a step named "Update merge request comment <id>" when called at the top level of a command, and does
    /// nothing else. Inside a report handler, the step is the handler's own, so the name is not used.
    ///
    /// - Parameters:
    ///   - report: The report to post. Secrets in its text are masked in the comment.
    ///   - id: The report ID. Only letters, digits, `-`, `_` and `.` are allowed, since the ID is written into the marker.
    ///   - title: The heading of the comment, such as the name of the command.
    ///   - mergeRequest: The merge request to comment on, such as ``GitLabMergeRequest/mergeRequest()``.
    ///   - whenClean: What a clean run does with the comment. The default deletes it.
    ///   - mode: ``CommentMode/post`` to change the merge request, or ``CommentMode/log`` for a dry run.
    ///   - name: The name of the step, or `nil` for the default.
    /// - Throws: A ``BuildError`` for an invalid `id` before any request, and for a failed request. The error of a request
    ///   names the request and the status, and never the token.
    public func updateComment(
        for report: RunReport,
        id: String,
        title: String,
        on mergeRequest: GitLabMergeRequest,
        whenClean: CleanRunBehavior = .deleteComment,
        mode: CommentMode = .post,
        step name: String? = nil
    ) async throws {
        try await step(default: "Update merge request comment \(id)", name: name) {
            guard Self.isValidCommentID(id) else {
                throw BuildError(
                    message: "The merge request comment ID \"\(id)\" is not valid. Use only letters, digits, \"-\", \"_\" and \".\", such as \"unit-tests\"."
                )
            }
            let body = Self.commentBody(for: report, id: id, title: title)
            let existing = try await existingComment(id: id, on: mergeRequest)
            let changes = CommentChange.plan(clean: report.isClean, whenClean: whenClean, existing: existing)
            try await applyChanges(changes, body: body, id: id, on: mergeRequest, mode: mode)
        }
    }

    /// The hidden line that marks the comment of `id`. The ID is written as it is, so it must pass ``isValidCommentID(_:)``.
    static func marker(for id: String) -> String {
        "<!-- swiftci-report-id: \(id) -->"
    }

    /// Whether `id` can be a report ID: at least one character, and only ASCII letters, digits, `-`, `_` and `.`.
    static func isValidCommentID(_ id: String) -> Bool {
        !id.isEmpty && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) }
    }

    /// The Markdown of the comment: the report under `title`, and a footer with the CI build link and the commit when
    /// they are known, and the marker as its last line. Unknown facts are left out of the footer.
    static func commentBody(for report: RunReport, id: String, title: String) -> String {
        var footerLines: [String] = []
        var facts: [String] = []
        if let buildURL = CI.environment.buildURL {
            // Parentheses would end the link target early.
            let target = buildURL.absoluteString
                .replacingOccurrences(of: "(", with: "%28")
                .replacingOccurrences(of: ")", with: "%29")
            facts.append("[CI build](\(target))")
        }
        if let commit = CI.environment.commit {
            facts.append("commit `\(commit)`")
        }
        if !facts.isEmpty {
            footerLines.append(facts.joined(separator: ", "))
        }
        footerLines.append(marker(for: id))
        return MarkdownReport(title: title, footer: footerLines.joined(separator: "\n")).render(report)
    }

    /// Makes the changes in order and logs one completion line for each. In `CommentMode/log` nothing is written: the
    /// rendered text is logged, and each change is logged as the line that says what it would do.
    func applyChanges(
        _ changes: [CommentChange],
        body: String,
        id: String,
        on mergeRequest: GitLabMergeRequest,
        mode: CommentMode
    ) async throws {
        @Use var log: Log
        if mode == .log {
            log.lines(title: "Merge request comment \(id)", lines: body)
        }
        guard !changes.isEmpty else {
            log.completion("Nothing to do for merge request comment \(id)")
            return
        }
        for change in changes {
            switch mode {
            case .post:
                try await write(change, body: body, on: mergeRequest)
                log.completion(change.completedLine(id: id))
            case .log:
                log.completion(change.wouldLine(id: id))
            }
        }
    }
}
