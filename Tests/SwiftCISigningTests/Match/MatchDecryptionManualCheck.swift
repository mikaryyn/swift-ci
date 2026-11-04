@testable import SwiftCI
@testable import SwiftCISigning
import Foundation
import Testing

/// Decrypts every encrypted file of a local fastlane match repository in memory, with ``MatchDecryption``, and prints
/// the format and the content of each file. Nothing is written, and the password is never printed. It is skipped unless
/// the environment variable `SWIFTCI_MANUAL_MATCH_REPOSITORY` names a directory:
///
///     SWIFTCI_MANUAL_MATCH_REPOSITORY=<path to a local clone> MATCH_PASSWORD=<password> \
///         swift test --disable-sandbox --filter MatchDecryptionManualCheck
///
/// The `.git` directory is skipped. A file that does not decrypt is printed with its error and recorded as a test
/// failure, and the check goes on with the other files.
@Suite(.enabled(if: !(ProcessInfo.processInfo.environment["SWIFTCI_MANUAL_MATCH_REPOSITORY"] ?? "").isEmpty))
struct MatchDecryptionManualCheck {
    @Test func decryptsEveryEncryptedFileOfTheRepository() throws {
        let environment = ProcessInfo.processInfo.environment
        let repository = URL(filePath: try #require(
            environment["SWIFTCI_MANUAL_MATCH_REPOSITORY"],
            "SWIFTCI_MANUAL_MATCH_REPOSITORY must name the directory of a local match repository."
        ))
        let password = try #require(
            environment["MATCH_PASSWORD"].flatMap { $0.isEmpty ? nil : $0 },
            "MATCH_PASSWORD must be set to the password of the match repository."
        )

        var found: [String] = []
        var formats: [MatchFileFormat: Int] = [:]
        var contents: [MatchFileContent: Int] = [:]
        var failures = 0

        let fileManager = FileManager.default
        let enumerator = try #require(fileManager.enumerator(atPath: repository.path))
        var relativePaths: [String] = []
        while let relative = enumerator.nextObject() as? String {
            if URL(filePath: relative).lastPathComponent == ".git" {
                enumerator.skipDescendants()
                continue
            }
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: repository.appending(path: relative).path, isDirectory: &isDirectory),
                  !isDirectory.boolValue,
                  MatchDecryption.encryptedExtensions.contains(URL(filePath: relative).pathExtension.lowercased())
            else { continue }
            relativePaths.append(relative)
        }

        for relative in relativePaths.sorted() {
            found.append(relative)
            do {
                let encrypted = try Data(contentsOf: repository.appending(path: relative))
                let decrypted = try MatchDecryption.decrypt(encrypted, file: relative, password: password)
                formats[decrypted.format, default: 0] += 1
                contents[decrypted.content, default: 0] += 1
                print("\(relative): \(decrypted.format.rawValue), \(decrypted.content.rawValue)")
            } catch let error as BuildError {
                failures += 1
                print("\(relative): FAILED: \(error.message)")
                Issue.record("\(relative) did not decrypt: \(error.message)")
            } catch {
                failures += 1
                print("\(relative): FAILED: \(error)")
                Issue.record("\(relative) did not decrypt: \(error)")
            }
        }

        print("Found \(found.count) encrypted files, \(failures) failed.")
        for format in [MatchFileFormat.v1, .v2] {
            print("\(format.rawValue): \(formats[format, default: 0]) files")
        }
        for content in [MatchFileContent.certificate, .pemPrivateKey, .pkcs12, .profile] {
            print("\(content.rawValue): \(contents[content, default: 0]) files")
        }
        #expect(!found.isEmpty, "No encrypted file was found in \(repository.path).")
    }
}
