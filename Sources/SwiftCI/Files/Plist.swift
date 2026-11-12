import Foundation

/// A property list file whose root is a dictionary, such as an `Info.plist` or an export options file.
///
/// Reading and writing never open a step. The static functions read or write a file in one call. The instance functions
/// work on one file.
public struct Plist {
    /// A property list file at `url`. The file is read and written on each call.
    public init(url: URL) {
        self.url = url
    }

    /// Reads the string `key` from the file. Returns `fallback` if the key is missing and a fallback is given.
    ///
    /// A query: does not open a step.
    public func string(_ key: String, fallback: String? = nil) throws -> String {
        let contents = try Self.read(url: url)
        guard let result = contents[key] as? String ?? fallback else {
            throw BuildError(message: "The property list file at '\(url.filePath)' has no string for the key '\(key)'.")
        }
        return result
    }

    /// Sets the string `key` in the file and writes the file back in the format it has, XML or binary. The other keys
    /// are kept. If the file cannot be read or written, the file is not changed.
    ///
    /// Not a step.
    public func set(_ key: String, _ value: String) throws {
        var (contents, format) = try Self.readWithFormat(url: url)
        contents[key] = value
        try Self.write(contents, format: format, to: url)
    }

    /// Reads the property list file at `url`, XML or binary, as a dictionary.
    ///
    /// A query: does not open a step.
    ///
    /// - Throws: ``BuildError`` that names the file if it does not exist, cannot be read or is not a property list, or if
    ///   its root is not a dictionary.
    public static func read(url: URL) throws -> [String: Any] {
        try readWithFormat(url: url).contents
    }

    /// Writes `contents` as an XML property list to `url`, replacing the file. Returns the lines of the written XML.
    ///
    /// Not a step.
    ///
    /// - Throws: ``BuildError`` that names the file if the contents are not a property list or the file cannot be written.
    @discardableResult
    public static func save(to url: URL, contents: [String: Any]) throws -> [String] {
        let data = try write(contents, format: .xml, to: url)
        return String(data: data, encoding: .utf8)?.split(whereSeparator: \.isNewline).map(String.init) ?? []
    }

    private static func readWithFormat(
        url: URL
    ) throws -> (contents: [String: Any], format: PropertyListSerialization.PropertyListFormat) {
        guard FileManager.default.fileExists(atPath: url.filePath) else {
            throw BuildError(message: "The property list file at '\(url.filePath)' does not exist.")
        }
        var format = PropertyListSerialization.PropertyListFormat.xml
        let object: Any
        do {
            let data = try Data(contentsOf: url)
            object = try PropertyListSerialization.propertyList(from: data, options: [], format: &format)
        } catch {
            throw BuildError(message: "Failed to read the property list file at '\(url.filePath)'. Details: \(error)")
        }
        guard let contents = object as? [String: Any] else {
            throw BuildError(message: "The property list file at '\(url.filePath)' does not have a dictionary as its root.")
        }
        return (contents, format)
    }

    @discardableResult
    private static func write(
        _ contents: [String: Any],
        format: PropertyListSerialization.PropertyListFormat,
        to url: URL
    ) throws -> Data {
        do {
            let data = try PropertyListSerialization.data(fromPropertyList: contents, format: format, options: 0)
            try data.write(to: url, options: .atomic)
            return data
        } catch {
            throw BuildError(message: "Failed to write the property list file at '\(url.filePath)'. Details: \(error)")
        }
    }

    private let url: URL
}
