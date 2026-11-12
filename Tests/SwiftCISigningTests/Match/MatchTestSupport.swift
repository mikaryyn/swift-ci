@testable import SwiftCI
import Foundation
import Testing

/// The URL of a fixture under `Fixtures/Match`, from the test bundle. `path` is relative to that directory.
func matchFixtureURL(_ path: String) throws -> URL {
    try #require(Bundle.module.resourceURL?.appending(path: "Fixtures/Match/\(path)"))
}

/// The bytes of the plain fixture `path`, which is relative to `plain/`.
func matchPlainData(_ path: String) throws -> Data {
    try Data(contentsOf: matchFixtureURL("plain/\(path)"))
}

/// The ``BuildError`` that `body` throws. Records an issue and returns nil when `body` throws another error or nothing.
func matchBuildError(_ body: () throws -> Void, sourceLocation: SourceLocation = #_sourceLocation) -> BuildError? {
    do {
        try body()
        Issue.record("Expected a BuildError, but nothing was thrown.", sourceLocation: sourceLocation)
    } catch let error as BuildError {
        return error
    } catch {
        Issue.record("Expected a BuildError, got \(error).", sourceLocation: sourceLocation)
    }
    return nil
}

/// The property list of a provisioning profile with every key that the decoder reads, without the key `removed`.
func matchProfileDictionary(removing removed: String? = nil) -> [String: Any] {
    var dictionary: [String: Any] = [
        "UUID": "11111111-1111-4111-8111-111111111111",
        "Name": "match AdHoc com.example.app1",
        "TeamIdentifier": ["TEAMID1234"],
        "ExpirationDate": Date(timeIntervalSince1970: 2_208_988_800),
        "DeveloperCertificates": [Data([0x30, 0x00])],
    ]
    if let removed {
        dictionary[removed] = nil
    }
    return dictionary
}
