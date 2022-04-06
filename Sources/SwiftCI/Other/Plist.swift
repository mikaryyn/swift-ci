import Foundation

public struct Plist {
    public init(path: String) {
        self.path = path
    }

    public func getString(_ key: String, fallback: String? = nil) throws -> String {
        let dict = try Self.read(file: path)
        guard let result = dict[key] as? String ?? fallback else {
            throw BuildError(message: "Failed to read key '\(key)' from Plist file at '\(path)'.")
        }
        return result
    }

    public func set(_ key: String, _ value: String) throws {
        guard let dict = NSDictionary(contentsOf: URL(fileURLWithPath: path)) else {
            throw BuildError(message: "Failed to write key '\(key)' from Plist file at '\(path)'.")
        }
        dict.setValue(value, forKey: key)
        do {
            try dict.write(to: URL(fileURLWithPath: path))
        } catch {
            throw BuildError(message: "Failed to write key '\(key)' from Plist file at '\(path)'.")
        }
    }

    public static func read(file path: String) throws -> [String: Any] {
        guard let result = NSDictionary(contentsOf: URL(fileURLWithPath: path)) as? [String: Any] else {
            throw BuildError(message: "Failed to read plist file at '\(path)'.")
        }
        return result
    }

    public static func save(toFile path: String, contents: [String: Any]) throws -> [String] {
        do {
            let data = try PropertyListSerialization.data(fromPropertyList: contents, format: .xml, options: 0)
            let lines = String(data: data, encoding: .utf8)?.split(whereSeparator: \.isNewline) ?? []
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            return lines.map(String.init)
        } catch {
            throw BuildError(message: "Failed to write file'\(path)'. Details: \(error)")
        }
    }

    let path: String
}
