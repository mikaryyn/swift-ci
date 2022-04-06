import Foundation

public typealias Filter = (String) -> String?

public func textFilter(_ text: String, _ replacement: String?) -> Filter {
    { line in
        if line.contains(text) {
            return replacement
        }
        return line
    }
}

public func reFilter(_ pattern: String, _ replacement: String?) -> Filter {
    guard let regularExpression = try? NSRegularExpression(pattern: pattern) else {
        logWarning("Invalid filter pattern: \(pattern)")
        return { $0 }
    }
    return { line in
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        if regularExpression.rangeOfFirstMatch(in: line, range: range).location == NSNotFound {
            return line
        }
        return replacement.map {
            regularExpression.stringByReplacingMatches(
                in: line,
                options: [],
                range: range,
                withTemplate: $0)
            }
    }
}
