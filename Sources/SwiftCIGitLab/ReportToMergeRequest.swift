import Foundation
import SwiftCI

/// Posts the run report of the running command as the merge request comment of `id`, when the command runs in a merge
/// request build. Call it in the command body. It registers an ``onReport(failure:_:)`` handler that calls
/// ``GitLab/updateComment(for:id:title:on:whenClean:mode:step:)`` with the report and the merge request of the run,
/// which ``GitLabMergeRequest/mergeRequest()`` reads when the handler runs.
///
/// Outside a merge request build the handler logs the step "Update merge request comment <id>" as skipped, with the
/// reason "not a merge request", and makes no request.
///
/// A failing request fails the command, as a failing report handler does. To let the command succeed, call
/// ``GitLab/updateComment(for:id:title:on:whenClean:mode:step:)`` from an ``onReport(failure:_:)`` handler registered with
/// `failure: .allowed`. The handler's work is logged inside the handler's own "Report" step.
///
/// - Parameters:
///   - gitLab: The connection to the GitLab server that hosts the merge request.
///   - id: The report ID. See ``GitLab/updateComment(for:id:title:on:whenClean:mode:step:)``.
///   - title: The heading of the comment, such as the name of the command.
///   - whenClean: What a clean run does with the comment. The default deletes it.
///   - mode: ``CommentMode/post`` to change the merge request, or ``CommentMode/log`` for a dry run.
public func postReportToMergeRequest(
    gitLab: GitLab,
    id: String,
    title: String,
    whenClean: CleanRunBehavior = .deleteComment,
    mode: CommentMode = .post
) {
    onReport { report in
        guard let mergeRequest = GitLabMergeRequest.mergeRequest() else {
            skipStep("Update merge request comment \(id)", reason: "not a merge request")
            return
        }
        try await gitLab.updateComment(
            for: report,
            id: id,
            title: title,
            on: mergeRequest,
            whenClean: whenClean,
            mode: mode
        )
    }
}
