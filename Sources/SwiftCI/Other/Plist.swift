import Foundation

public struct Plist {
    /// A property list file at `url`. The file is read and written on each call.
    public init(url: URL) {
        self.url = url
    }

    /// Reads the string `key` from the file. Returns `fallback` if the key is missing and a fallback is given.
    ///
    /// A query: does not open a step.
    public func getString(_ key: String, fallback: String? = nil) throws -> String {
        let dict = try Self.read(url: url)
        guard let result = dict[key] as? String ?? fallback else {
            throw BuildError(message: "Failed to read key '\(key)' from Plist file at '\(url.filePath)'.")
        }
        return result
    }

    /// Sets the string `key` in the file and writes the file back.
    public func set(_ key: String, _ value: String) throws {
        guard let dict = NSDictionary(contentsOf: url) else {
            throw BuildError(message: "Failed to write key '\(key)' from Plist file at '\(url.filePath)'.")
        }
        dict.setValue(value, forKey: key)
        do {
            try dict.write(to: url)
        } catch {
            throw BuildError(message: "Failed to write key '\(key)' from Plist file at '\(url.filePath)'.")
        }
    }

    /// Reads the property list file at `url` as a dictionary.
    ///
    /// A query: does not open a step.
    public static func read(url: URL) throws -> [String: Any] {
        guard let result = NSDictionary(contentsOf: url) as? [String: Any] else {
            throw BuildError(message: "Failed to read plist file at '\(url.filePath)'.")
        }
        return result
    }

    /// Writes `contents` as an XML property list to `url`, replacing the file. Returns the lines of the written XML.
    public static func save(to url: URL, contents: [String: Any]) throws -> [String] {
        do {
            let data = try PropertyListSerialization.data(fromPropertyList: contents, format: .xml, options: 0)
            let lines = String(data: data, encoding: .utf8)?.split(whereSeparator: \.isNewline) ?? []
            try data.write(to: url, options: .atomic)
            return lines.map(String.init)
        } catch {
            throw BuildError(message: "Failed to write file '\(url.filePath)'. Details: \(error)")
        }
    }

    let url: URL
}
