import Foundation

/// A new directory inside the `swift-ci` folder of the system temporary directory.
///
/// The directory exists once the value is created, and only its owner can read it (mode 0700). Nothing removes it
/// automatically. Call ``remove()`` when you are done with it, for example in a `cleanup` handler or a `defer`.
public struct TemporaryDirectory {
    /// Creates the directory `name` inside the `swift-ci` folder of the temporary directory.
    ///
    /// `name` is a template: `$DATE` (the current time as `yyyyMMdd_HHmmss`) and `$UUID` (a new UUID) in it are replaced.
    /// The default, `"$UUID"`, is a template too, so the default directory is always new. A name that has no `$UUID`, or
    /// has only `$DATE`, can name a directory that exists already, and then the existing directory is used with its
    /// contents.
    public init(name: String = "$UUID") throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appending(path: "swift-ci")
        url = base.appending(path: Self.replacePlaceholders(name), directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.filePath)
    }

    /// The URL of a child named `name` inside the directory. The child is not created. `$DATE` and `$UUID` in `name`
    /// are replaced.
    public func childURL(name: String) -> URL {
        url.appending(path: Self.replacePlaceholders(name))
    }

    /// Removes the directory and everything in it. Does nothing if the directory does not exist any more.
    public func remove() throws {
        guard FileManager.default.fileExists(atPath: url.filePath) else {
            return
        }
        try FileManager.default.removeItem(at: url)
    }

    private static func replacePlaceholders(_ text: String) -> String {
        text
            .replacingOccurrences(of: "$DATE", with: Self.getDateString())
            .replacingOccurrences(of: "$UUID", with: UUID().uuidString)
    }

    private static func getDateString() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return formatter.string(from: Date.now)
    }

    /// The directory that was created.
    public let url: URL
}
