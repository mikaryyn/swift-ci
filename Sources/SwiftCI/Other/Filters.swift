import Foundation

public typealias Filter = (String) -> String?

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
