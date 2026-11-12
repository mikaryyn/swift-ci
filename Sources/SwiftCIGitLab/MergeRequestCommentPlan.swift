import Foundation

/// The comment of a report ID as it exists on the merge request, with the state that decides what to change.
struct ExistingComment: Equatable {
    /// The ID of the note that holds the comment.
    let noteID: Int

    /// The ID of the discussion (thread) that holds the note.
    let discussionID: String

    /// Whether the note can be resolved. A plain note cannot, so it has to be replaced by a thread to be resolved.
    let isResolvable: Bool

    /// Whether the thread is resolved.
    let isResolved: Bool
}

/// One change to the comment of a report ID. The changes of a run are computed first, so that the console and the
/// dry run (`CommentMode/log`) show the same decisions as a real run.
enum CommentChange: Equatable {
    /// Posts the comment: as a new thread, or as a plain note.
    case create(thread: Bool)

    /// Replaces the text of the note.
    case updateBody(noteID: Int)

    /// Resolves the thread, or reopens it when `resolved` is `false`.
    case resolve(discussionID: String, resolved: Bool)

    /// Deletes the note.
    case delete(noteID: Int)

    /// The changes that bring the comment to the state of the run. An empty list means there is nothing to do.
    ///
    /// - Parameters:
    ///   - clean: Whether the run is clean, as ``RunReport/isClean`` says.
    ///   - whenClean: What a clean run does with the comment. A run that is not clean uses the same behaviour only for
    ///     the thread form: `resolveThread` posts a thread and reopens it.
    ///   - existing: The comment on the merge request, or `nil` if there is none.
    static func plan(clean: Bool, whenClean: CleanRunBehavior, existing: ExistingComment?) -> [CommentChange] {
        guard !clean else {
            guard let existing else { return [] }
            switch whenClean {
            case .deleteComment:
                return [.delete(noteID: existing.noteID)]
            case .updateComment:
                return [.updateBody(noteID: existing.noteID)]
            case .resolveThread:
                // A plain note cannot be resolved, so a clean run deletes it instead of giving it a new thread.
                guard existing.isResolvable else { return [.delete(noteID: existing.noteID)] }
                var changes: [CommentChange] = [.updateBody(noteID: existing.noteID)]
                if !existing.isResolved {
                    changes.append(.resolve(discussionID: existing.discussionID, resolved: true))
                }
                return changes
            }
        }

        let asThread = whenClean == .resolveThread
        guard let existing else { return [.create(thread: asThread)] }
        // A plain note cannot be resolved later, so the report moves to a new thread.
        if asThread && !existing.isResolvable {
            return [.delete(noteID: existing.noteID), .create(thread: true)]
        }
        var changes: [CommentChange] = [.updateBody(noteID: existing.noteID)]
        if asThread && existing.isResolved {
            changes.append(.resolve(discussionID: existing.discussionID, resolved: false))
        }
        return changes
    }

    /// The completion line of the change after it was made, such as "Created merge request comment tests".
    func completedLine(id: String) -> String {
        switch self {
        case .create:
            "Created merge request comment \(id)"
        case .updateBody:
            "Updated merge request comment \(id)"
        case .resolve(_, let resolved):
            "\(resolved ? "Resolved" : "Reopened") merge request comment \(id)"
        case .delete:
            "Deleted merge request comment \(id)"
        }
    }

    /// The line of the dry run that says what the change would do, such as "Would create thread for merge request
    /// comment tests".
    func wouldLine(id: String) -> String {
        switch self {
        case .create(let thread):
            "Would create \(thread ? "thread" : "comment") for merge request comment \(id)"
        case .updateBody:
            "Would update comment for merge request comment \(id)"
        case .resolve(_, let resolved):
            "Would \(resolved ? "resolve" : "reopen") thread for merge request comment \(id)"
        case .delete:
            "Would delete comment for merge request comment \(id)"
        }
    }
}
