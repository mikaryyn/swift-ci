import Foundation

public typealias Filter = (String) -> String?

/// A filter that decides each line together with the lines around it. For each line it returns the lines to show now.
/// That can be none, one or several: a line can be held back and shown later, with the lines it waits for. The state of
/// a filter belongs to the ``Tool`` that uses it, so make a new filter for each tool. Lines still held when the output
/// ends are not shown.
public typealias BlockFilter = (String) -> [String]

/// A ``BlockFilter`` for output with tables, drawn with `+` borders and `|` rows, such as the boxes of a command-line
/// tool. A table is a run of such lines, ended by any other line. A table is shown or hidden as a whole, with its
/// borders. `keepTable` gets the title of the table, which is its first row without the borders, spaces and colour
/// codes, and returns `true` to show the table. A table with no title row is hidden. Lines outside tables go to
/// `otherLines`.
public func tableFilter(keeping keepTable: @escaping (_ title: String) -> Bool, otherLines: @escaping Filter) -> BlockFilter {
    var state = TableState.outside
    return { line in
        let plain = plainText(line)
        let isBorder = plain.hasPrefix("+")
        let isRow = plain.hasPrefix("|")
        guard isBorder || (isRow && !state.isOutside) else {
            state = .outside
            return otherLines(line).map { [$0] } ?? []
        }
        switch state {
        case .outside:
            state = .undecided([line])
            return []
        case .undecided(let held):
            guard isRow else {
                state = .hidden
                return []
            }
            if keepTable(plain.trimmingCharacters(in: CharacterSet(charactersIn: "| "))) {
                state = .shown
                return held + [line]
            }
            state = .hidden
            return []
        case .shown:
            return [line]
        case .hidden:
            return []
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

/// The text of a line without its colour codes and other terminal control sequences.
private func plainText(_ line: String) -> String {
    line.replacingOccurrences(of: "\u{1B}\\[[0-9;]*[A-Za-z]", with: "", options: .regularExpression)
}

public func filter(_ text: String, _ replacement: String? = nil) -> Filter {
   { line in
        if line.contains(text) {
            return replacement
        }
        return line
    }
}

public func filter<Output>(_ regex: Regex<Output>, _ replacement: String? = nil) -> Filter {
    return { (line: String) -> String? in
        if (try? regex.firstMatch(in: line)) == nil {
            return line
        }
        return replacement.map {
            line.replacing(regex, with: $0)
        }
    }
}

public func filter<Output>(_ regex: Regex<Output>, _ replacement: @escaping (Output) -> String) -> Filter {
    return { (line: String) -> String? in
        if (try? regex.firstMatch(in: line)) == nil {
            return line
        }
        return line.replacing(regex) { replacement($0.output) }
    }
}
