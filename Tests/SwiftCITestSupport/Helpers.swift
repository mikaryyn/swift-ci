import Foundation
import SwiftCI
import SwiftCITesting
import Testing

/// Root of every suite that touches SwiftCI's global state (dependency registry,
/// registered commands, the running command, the full log). Tests under it run
/// one at a time, so they cannot interleave at await points.
@Suite(.serialized) enum GlobalStateTests {}

/// An artifacts directory for a test that calls `runSwiftCI` directly, so that the run does not write `artifacts/` into
/// the working directory. The directory is not created. The test removes it.
func temporaryArtifactsDirectory() -> URL {
    URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appending(path: "swift-ci-tests", directoryHint: .isDirectory)
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        .appending(path: "artifacts", directoryHint: .isDirectory)
}

/// Removes ANSI escape sequences (colours and styles) from a console line.
func stripANSI(_ line: String) -> String {
    line.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
}

/// A plain error thrown by test scripts. Its description is `boom`.
enum TestError: Error, Equatable {
    case boom
}

/// Runs `body` and returns the `BuildError` it throws, or `nil` if it throws nothing.
/// Records an issue for any other error.
func thrownError(_ body: () async throws -> Void) async -> BuildError? {
    do {
        try await body()
        return nil
    } catch let error as BuildError {
        return error
    } catch {
        Issue.record("Expected a BuildError, got \(error)")
        return nil
    }
}

/// The step names of the lines that enter a step, without indentation or colour codes.
func enteredSteps(in lines: [String]) -> [String] {
    lines.map(stripANSI)
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { $0.hasPrefix("Entering step [") }
}
