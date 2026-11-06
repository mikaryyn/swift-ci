#if os(macOS)
import Foundation

/// Finds the phrases of a text rule that occur in `text`, as fastlane's text-match rules do.
///
/// The text is trimmed and lower-cased, and every occurrence of each allowed phrase is removed. A phrase occurs when it
/// is a plain substring of the text, so `testing` is found inside `contesting`. An empty text passes.
///
/// - Parameters:
///   - text: The value to check.
///   - phrases: The lower-case phrases that fail the rule.
///   - allowed: The lower-case phrases that are removed before the search, such as a brand name that contains a
///     competitor's name.
/// - Returns: `found: ` followed by the phrases that occur, in the order of `phrases` and joined by `, `, or nil when
///   none occurs.
nonisolated func textMatch(_ text: String, phrases: [String], allowed: [String]) -> String? {
    var remaining = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !remaining.isEmpty else { return nil }
    for phrase in allowed {
        remaining = remaining.replacingOccurrences(of: phrase, with: "", options: .literal)
    }
    let found = phrases.filter { remaining.range(of: $0, options: .literal) != nil }
    guard !found.isEmpty else { return nil }
    return "found: " + found.joined(separator: ", ")
}
#endif
