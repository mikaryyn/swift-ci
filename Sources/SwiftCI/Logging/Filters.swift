import Foundation

/// Decides what the console shows of one line of tool output. It returns the line to show, which can be changed, or `nil`
/// to hide the line. The full log keeps every line as it was. A ``Tool`` takes a list of filters and passes each line
/// through them in order.
///
/// A filter is a closure, so it can keep state, for example to decide a line by the lines before it. Make a new filter
/// for each tool, because the state belongs to the tool that uses the filter. A filter may return several lines joined
/// with line breaks. They are split, so the filters after it get them one at a time, and the console shows them as
/// separate lines. Lines that a filter holds back are shown only if a later line makes the filter return them. At the
/// end of the output nothing is flushed.
public typealias Filter = (String) -> String?

/// A ``Filter`` that hides every line from the console. The full log keeps them.
public func hideAllLines(_ line: String) -> String? {
    nil
}

/// A ``Filter`` for output with tables, drawn with `+` borders and `|` rows, such as the boxes of a command-line tool.
/// A table is a run of such lines, ended by any other line. A table is shown or hidden as a whole, with its borders.
/// `keepTable` gets the title of the table, which is its first row without the borders, spaces and colour codes, and
/// returns `true` to show the table. A table with no title row is hidden. Lines outside tables go to `otherLines`.
///
/// The filter holds the lines of a table until its title row arrives, then returns them together, joined with line
/// breaks. The state belongs to the ``Tool`` that uses the filter, so make a new filter for each tool. Lines still held
/// when the output ends are not shown.
public func tableFilter(keeping keepTable: @escaping (_ title: String) -> Bool, otherLines: @escaping Filter) -> Filter {
    var state = TableState.outside
    return { line in
        let plain = line.withoutTerminalCodes
        let isBorder = plain.hasPrefix("+")
        let isRow = plain.hasPrefix("|")
        guard isBorder || (isRow && !state.isOutside) else {
            state = .outside
            return otherLines(line)
        }
        switch state {
        case .outside:
            state = .undecided([line])
            return nil
        case .undecided(let held):
            guard isRow else {
                state = .hidden
                return nil
            }
            if keepTable(plain.trimmingCharacters(in: CharacterSet(charactersIn: "| "))) {
                state = .shown
                return (held + [line]).joined(separator: "\n")
            }
            state = .hidden
            return nil
        case .shown:
            return line
        case .hidden:
            return nil
        }
    }
}

/// Where ``tableFilter(keeping:otherLines:)`` is: outside a table, in a table whose title has not come yet, or in a table
/// that is shown or hidden.
private enum TableState {
    case outside
    case undecided([String])
    case shown
    case hidden

    var isOutside: Bool {
        if case .outside = self { return true }
        return false
    }
}

/// A ``Filter`` for lines that contain `text`. Other lines are shown unchanged.
///
/// - Parameters:
///   - text: The text to look for.
///   - replacement: What to show instead of the whole line. `nil` hides the line.
public func filter(_ text: String, _ replacement: String? = nil) -> Filter {
    { line in
        line.contains(text) ? replacement : line
    }
}

/// A ``Filter`` for lines that match `regex`. Other lines are shown unchanged.
///
/// - Parameters:
///   - regex: The pattern to look for in each line.
///   - replacement: What to show in place of each match, in the rest of the line. `nil` hides the whole line.
public func filter<Output>(_ regex: Regex<Output>, _ replacement: String? = nil) -> Filter {
    { line in
        guard line.contains(regex) else { return line }
        return replacement.map { line.replacing(regex, with: $0) }
    }
}

/// A ``Filter`` for lines that match `regex`, which shows the line with each match replaced. Other lines are shown
/// unchanged.
///
/// - Parameters:
///   - regex: The pattern to look for in each line.
///   - replacement: Gets the output of a match and returns the text to show in its place.
public func filter<Output>(_ regex: Regex<Output>, _ replacement: @escaping (Output) -> String) -> Filter {
    { line in
        guard line.contains(regex) else { return line }
        return line.replacing(regex) { replacement($0.output) }
    }
}
