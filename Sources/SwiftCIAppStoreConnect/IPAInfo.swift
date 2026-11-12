#if os(macOS)
import Foundation
import SwiftCI

/// The facts of an iOS app that an upload needs, read from the `Info.plist` of the app in an IPA.
///
/// Only the `Info.plist` is extracted from the archive, so a large IPA is not unpacked. Reading is a query: it opens no
/// step. The console shows only errors and warnings of `unzip`, and the full log also gets one line that says what is
/// read.
struct IPAInfo: Equatable {
    /// `CFBundleIdentifier`.
    let bundleIdentifier: String
    /// `CFBundleShortVersionString`, the version such as `1.2.3`.
    let shortVersion: String
    /// `CFBundleVersion`, the build number.
    let buildVersion: String
    /// The App Store Connect platform of the app. Only `IOS` is supported.
    let platform: String

    /// Reads the facts of the app in the IPA at `ipa`.
    ///
    /// The archive is listed, and the one `Payload/<name>.app/Info.plist` entry is extracted into a temporary
    /// directory, which is removed again. A binary or XML property list can be read.
    ///
    /// - Parameter ipa: The IPA file.
    /// - Throws: A ``BuildError`` that names the IPA when the file does not exist or is not a zip archive, when the
    ///   archive has no app or more than one app in `Payload`, when a required key is missing from the `Info.plist`, or
    ///   when the app is not for iOS.
    static func read(_ ipa: URL) async throws -> IPAInfo {
        guard FileManager.default.fileExists(atPath: ipa.filePath) else {
            throw BuildError(message: "The IPA \(ipa.filePath) does not exist. Check the path of the IPA.")
        }
        try FullLog.write(
            "Reading the bundle identifier, version, build number and platform from the Info.plist of the app in "
                + "\(ipa.filePath): listing the archive, then extracting only the Info.plist."
        )
        let entries = try await archiveEntries(of: ipa)
        let entry = try appInfoEntry(in: entries, ipa: ipa)

        let directory = try TemporaryDirectory()
        defer { try? directory.remove() }
        try await extract(entry, from: ipa, to: directory.url)
        try checkOnlyEntryIsExtracted(entry, in: directory.url, ipa: ipa)

        let plist = try readPlist(directory.url.appending(path: entry), entry: entry, ipa: ipa)
        return try IPAInfo(propertyList: plist, ipa: ipa)
    }

    /// The platform name that `DTPlatformName` has for an iOS app.
    private static let iOSPlatformName = "iphoneos"

    /// The string `key` of the `Info.plist`. Throws a ``BuildError`` that names the IPA and the key when it is missing.
    private static func string(_ key: String, in plist: [String: Any], ipa: URL) throws -> String {
        guard let value = plist[key] as? String else {
            throw BuildError(
                message: "The Info.plist of the app in \(ipa.filePath) has no \(key). Check that the app's Info.plist "
                    + "sets \(key), then archive and export the IPA again."
            )
        }
        return value
    }

    /// The entries of the archive, as `unzip -Z1` lists them. The listing is hidden from the console, because entry
    /// names such as `ErrorView.nib` would pass the filter of problems. A failure throws a ``BuildError`` that names the
    /// IPA and shows what `unzip` said.
    private static func archiveEntries(of ipa: URL) async throws -> [String] {
        let result = try await Tool(
            command: "/usr/bin/unzip", arguments: ["-Z1", ipa.filePath], filters: [hideAllLines]
        ).result()
        guard result.exitCode == 0 else {
            let said = result.stderr.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            throw BuildError(
                message: "The IPA \(ipa.filePath) is not a readable zip archive. Check that the file is a complete IPA, "
                    + "not a partial download." + (said.isEmpty ? "" : " unzip said: \(said)")
            )
        }
        return result.stdout.components(separatedBy: "\n")
    }

    /// The single entry `Payload/<name>.app/Info.plist` of `entries`. Nested apps such as frameworks are not matched.
    ///
    /// Throws a ``BuildError`` when there is no app or more than one app.
    private static func appInfoEntry(in entries: [String], ipa: URL) throws -> String {
        let apps = entries.compactMap { entry -> (entry: String, name: String)? in
            guard let match = entry.wholeMatch(of: #/Payload\/([^\/]+)\.app\/Info\.plist/#) else { return nil }
            return (entry, String(match.1))
        }
        guard let app = apps.first else {
            throw BuildError(
                message: "The IPA \(ipa.filePath) has no app in its Payload folder. Check that the IPA contains "
                    + "Payload/<name>.app with an Info.plist, and export it as an app IPA."
            )
        }
        guard apps.count == 1 else {
            let names = apps.map(\.name).joined(separator: ", ")
            throw BuildError(
                message: "The IPA \(ipa.filePath) has more than one app in its Payload folder (\(names)). An IPA must "
                    + "contain exactly one app. Check the archive and export it again."
            )
        }
        return app.entry
    }

    /// Extracts `entry` from `ipa` into `directory`. The name is escaped, so that `unzip` matches only this entry.
    private static func extract(_ entry: String, from ipa: URL, to directory: URL) async throws {
        try await Tool(
            command: "/usr/bin/unzip",
            arguments: ["-q", "-o", ipa.filePath, unzipPattern(for: entry), "-d", directory.filePath],
            filters: [unzipFilter]
        ).run()
    }

    /// Checks that extraction produced exactly the directories and the file of `entry`. `unzip` also reads the wildcard
    /// characters of a name, so a wrong match would show up here as an extra file. The check fails before the file is
    /// read.
    private static func checkOnlyEntryIsExtracted(_ entry: String, in directory: URL, ipa: URL) throws {
        let extracted = Set(try FileManager.default.subpathsOfDirectory(atPath: directory.filePath))
        let parts = entry.split(separator: "/").map(String.init)
        let expected = Set(parts.indices.map { parts[...$0].joined(separator: "/") })
        guard extracted == expected else {
            throw BuildError(
                message: "The app's Info.plist in \(ipa.filePath) could not be extracted by itself. Check the app's "
                    + "name in the archive, then export the IPA again."
            )
        }
    }

    /// Reads the property list at `url`, a binary or XML file.
    private static func readPlist(_ url: URL, entry: String, ipa: URL) throws -> [String: Any] {
        do {
            return try Plist.read(url: url)
        } catch {
            throw BuildError(
                message: "The Info.plist (\(entry)) in \(ipa.filePath) can't be read. Check that the IPA was archived "
                    + "and exported by Xcode, and export it again."
            )
        }
    }

    /// Escapes the wildcard characters that `unzip` reads in a name: `*`, `?` and `[`. Each becomes a character class
    /// that matches only itself. `]` is literal outside a class.
    static func unzipPattern(for name: String) -> String {
        var pattern = ""
        for character in name {
            switch character {
            case "[": pattern += "[[]"
            case "*", "?": pattern += "[\(character)]"
            default: pattern.append(character)
            }
        }
        return pattern
    }

    /// Hides the listing and the progress of `unzip`. Its errors and warnings stay on the console.
    private static func unzipFilter(_ line: String) -> String? {
        let lowercased = line.lowercased()
        let isProblem = ["error", "warning", "caution", "not a zipfile"].contains { lowercased.contains($0) }
        return isProblem ? line : nil
    }
}

/// The init is in an extension, so that the struct keeps its memberwise init for tests.
private extension IPAInfo {
    /// Reads the four required keys of the `Info.plist`. Throws a ``BuildError`` for a missing key or an app that is not
    /// for iOS.
    init(propertyList plist: [String: Any], ipa: URL) throws {
        bundleIdentifier = try Self.string("CFBundleIdentifier", in: plist, ipa: ipa)
        shortVersion = try Self.string("CFBundleShortVersionString", in: plist, ipa: ipa)
        buildVersion = try Self.string("CFBundleVersion", in: plist, ipa: ipa)
        let platformName = try Self.string("DTPlatformName", in: plist, ipa: ipa)
        guard platformName == Self.iOSPlatformName else {
            throw BuildError(
                message: "The app in \(ipa.filePath) is for the platform \(platformName). Only iOS IPAs (DTPlatformName "
                    + "\(Self.iOSPlatformName)) can be uploaded. Build the app for iOS, or upload it another way."
            )
        }
        platform = "IOS"
    }
}
#endif
