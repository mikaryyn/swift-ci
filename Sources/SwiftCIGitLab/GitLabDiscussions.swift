import Foundation
import SwiftCI

/// The user that the token belongs to, as `GET /user` returns it. Only the ID and the username are decoded.
struct CurrentUser: Decodable {
    let id: Int
    let username: String
}

/// A discussion of a merge request (a thread, or a plain note), as `GET …/discussions` returns it. Only the fields that
/// the comment uses are decoded.
struct Discussion: Decodable {
    let id: String
    let notes: [Note]

    /// Whether the thread is resolved, as GitLab shows it: every resolvable note of the thread is resolved. A thread
    /// without a resolvable note is not resolved.
    var isResolved: Bool {
        let resolvable = notes.filter(\.resolvable)
        return !resolvable.isEmpty && resolvable.allSatisfy(\.resolved)
    }
}

/// A note of a discussion. Only the fields that the comment uses are decoded. A missing `resolvable` or `resolved` is
/// `false`, as it is for a plain note.
struct Note: Decodable {
    let id: Int
    let body: String
    let author: Author
    let resolvable: Bool
    let resolved: Bool

    /// The author of the note. Only the ID is decoded.
    struct Author: Decodable {
        let id: Int
    }

    private enum CodingKeys: String, CodingKey {
        case id, body, author, resolvable, resolved
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        body = try container.decode(String.self, forKey: .body)
        author = try container.decode(Author.self, forKey: .author)
        resolvable = try container.decodeIfPresent(Bool.self, forKey: .resolvable) ?? false
        resolved = try container.decodeIfPresent(Bool.self, forKey: .resolved) ?? false
    }
}

/// The body of a note, as the create and update requests send it.
struct NoteBody: Encodable {
    let body: String
}

/// The resolved state of a thread, as the update request of a discussion sends it.
struct ThreadState: Encodable {
    let resolved: Bool
}

extension GitLab {
    /// Finds the comment of `id` on `mergeRequest`: the first note, in the order of the discussions, whose author is `user`
    /// and whose text has the marker as a line of its own. Notes of other users are never a match. Reads only: the
    /// discussions of the merge request.
    ///
    /// - Returns: The comment, or `nil` if there is none.
    func existingComment(id: String, on mergeRequest: GitLabMergeRequest, user: CurrentUser) async throws -> ExistingComment? {
        let discussions: [Discussion] = try await paginated(mergeRequest.apiPath + "/discussions")
        let marker = Self.marker(for: id)
        for discussion in discussions {
            guard let note = discussion.notes.first(where: { $0.author.id == user.id && $0.body.containsLine(marker) }) else {
                continue
            }
            return ExistingComment(
                noteID: note.id,
                discussionID: discussion.id,
                isResolvable: note.resolvable,
                isResolved: discussion.isResolved
            )
        }
        return nil
    }

    /// Sends the request of one change to the comment. Every request is a write, so the caller decides whether to make
    /// it at all (`CommentMode`).
    func write(_ change: CommentChange, body: String, on mergeRequest: GitLabMergeRequest) async throws {
        let base = mergeRequest.apiPath
        switch change {
        case .create(let thread):
            let path = base + (thread ? "/discussions" : "/notes")
            _ = try await send("POST", path, body: try JSONEncoder().encode(NoteBody(body: body)))
        case .updateBody(let noteID):
            _ = try await send("PUT", "\(base)/notes/\(noteID)", body: try JSONEncoder().encode(NoteBody(body: body)))
        case .resolve(let discussionID, let resolved):
            let path = "\(base)/discussions/\(discussionID)"
            _ = try await send("PUT", path, body: try JSONEncoder().encode(ThreadState(resolved: resolved)))
        case .delete(let noteID):
            _ = try await send("DELETE", "\(base)/notes/\(noteID)")
        }
    }
}

private extension String {
    /// Whether one of the lines of the text, without surrounding spaces, is `line`. A marker that is only part of a line,
    /// such as the marker of `ab` for `a`, does not match.
    func containsLine(_ line: String) -> Bool {
        components(separatedBy: .newlines).contains { $0.trimmingCharacters(in: .whitespaces) == line }
    }
}
