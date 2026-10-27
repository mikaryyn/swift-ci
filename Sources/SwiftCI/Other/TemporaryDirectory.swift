import Foundation

public struct TemporaryDirectory {
    /// Creates the directory `name` inside the `swift-ci` folder of the temporary directory. `$DATE` and `$UUID` in
    /// `name` are replaced.
    public init(name: String = "$UUID") throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appending(path: "swift-ci")
        url = base.appending(path: Self.replacePlaceholders(name), directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    /// The URL of a child named `name` inside the directory. The child is not created. `$DATE` and `$UUID` in `name`
    /// are replaced.
    public func childURL(name: String) -> URL {
        url.appending(path: Self.replacePlaceholders(name))
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

    /// The directory that was created.
    public let url: URL
}
