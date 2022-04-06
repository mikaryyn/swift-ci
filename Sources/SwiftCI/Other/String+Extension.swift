import Foundation

extension String {
    func firstMatch(of pattern: String) -> String? {
        guard let regularExpression = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else {
            return nil
        }
        let range = NSRange(startIndex..<endIndex, in: self)
        guard let match = regularExpression.firstMatch(in: self, range: range) else {
            return nil
        }
        let matchRange = match.range(at: min(1, match.numberOfRanges - 1))
        return String(self[Range(matchRange, in: self)!])
    }

    func matches(of pattern: String) -> [String] {
        guard let regularExpression = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else {
            return []
        }
        let range = NSRange(startIndex..<endIndex, in: self)
        guard let match = regularExpression.firstMatch(in: self, range: range) else {
            return []
        }
        return (1..<match.numberOfRanges).map {
            String(self[Range(match.range(at: $0), in: self)!])
        }
    }
}
