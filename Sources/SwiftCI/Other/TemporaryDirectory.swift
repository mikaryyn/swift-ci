import Foundation
import System

public struct TemporaryDirectory {
    public init(name: String = "$UUID") throws {
        let base = FilePath(NSTemporaryDirectory()).appending("swift-ci")
        path = base.appending(Self.replacePlaceholders(name))
        try FileManager.default.createDirectory(atPath: path.string, withIntermediateDirectories: true)
    }

    public func childPath(name: String) -> FilePath {
        path.appending(Self.replacePlaceholders(name))
    }

    private static func replacePlaceholders(_ text: String) -> String {
        text
            .replacingOccurrences(of: "$DATE", with: Self.getDateString())
            .replacingOccurrences(of: "$UUID", with: UUID().uuidString)
    }

    private static func getDateString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return formatter.string(from: Date.now)
    }

    let path: FilePath
}

struct Files {

}
