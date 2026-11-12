import Foundation
import SwiftCI
import Testing

/// Root of every suite that touches SwiftCI's global state: all that `isolatedGlobalState()` saves. Tests under it run
/// one at a time, so they cannot interleave at await points.
@Suite(.serialized) enum GlobalStateTests {}

/// An artifacts directory for a test that calls `runSwiftCI` directly, so that the run does not write `artifacts/` into
/// the working directory. The directory is not created. The test must remove its parent folder, which is new for each
/// call. Use ``withTemporaryArtifactsDirectory(_:)`` when the test reads the files of the run, so that this is done.
/// A test of `SwiftCITest` that does not read them passes no directory at all, and gets a temporary one that is removed.
func temporaryArtifactsDirectory() -> URL {
    URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appending(path: "swift-ci-tests", directoryHint: .isDirectory)
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        .appending(path: "artifacts", directoryHint: .isDirectory)
}

/// Runs `body` with a new artifacts directory, and removes it afterwards, also if `body` throws or the test fails.
/// The directory is not created. The run that uses it creates it.
func withTemporaryArtifactsDirectory<T>(_ body: (URL) async throws -> T) async rethrows -> T {
    let directory = temporaryArtifactsDirectory()
    defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
    return try await body(directory)
}

/// Removes terminal escape sequences (colours and styles) from a console line.
func stripANSI(_ line: String) -> String {
    line.withoutTerminalCodes
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
