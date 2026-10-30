import Foundation
import SwiftCI

extension Xcode {
    /// Reads the test results of a result bundle with `xcrun xcresulttool get test-results tests` (Xcode 16 and
    /// later) and maps them to a ``TestReport``.
    ///
    /// The mapping:
    /// - A "Unit test bundle" or "UI test bundle" node names the bundle. A "Test Suite" node adds its name, so a
    ///   nested suite is `Bundle.Outer.Inner`. The suite name is the bundle prefix of the class name, for example
    ///   `MyAppTests.LoginTests`. A test case that is not in a suite, as a top-level Swift Testing test, takes the
    ///   bundle name only.
    /// - A "Test Case" node becomes a case, with the test's name, such as `testLogin()` or `parameterized(value:)`, and
    ///   `durationInSeconds` (0 if missing). Its class name is the suite name.
    /// - The result is `Passed` or `Expected Failure`: passed. `Failed`: failed, with the messages of all runs.
    ///   `Skipped`: skipped, with the first "Skip Message".
    /// - Each "Failure Message" below the case, in "Arguments", "Repetition", "Test Case Run" or any other node, is one
    ///   message. A source location is added on a second line as `path:line`.
    /// - "Device" nodes are flattened. When the tree has more than one device, the device name is appended to the suite
    ///   name, as `Bundle.Suite (iPhone 17)`.
    /// - Suites with the same name are one suite, in the order of the tree. Other node types are not mapped, but their
    ///   children are searched, so a case below them is still found.
    ///
    /// A query: does not open a step.
    ///
    /// - Throws: ``BuildError`` that names the bundle if `xcresulttool` fails or its output cannot be read.
    public static func testReport(resultBundleURL: URL) async throws -> TestReport {
        let path = resultBundleURL.filePath
        let tool = Tool(
            command: xcrunPath,
            arguments: ["xcresulttool", "get", "test-results", "tests", "--path", path, "--format", "json"],
            filters: [filter(#/./#)]
        )
        let result = try await tool.result()
        guard result.exitCode == 0 else {
            let details = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw BuildError(
                message: "Failed to read the test results of the result bundle at '\(path)'. "
                    + "xcresulttool exited with code \(result.exitCode)."
                    + (details.isEmpty ? "" : " Details: \(details)")
            )
        }
        let results: TestResultsJSON
        do {
            results = try JSONDecoder().decode(TestResultsJSON.self, from: Data(result.stdout.utf8))
        } catch {
            throw BuildError(
                message: "Failed to decode the test results of the result bundle at '\(path)'. Details: \(error)"
            )
        }
        return makeReport(from: results.testNodes)
    }

    /// Writes the test report of a result bundle as JUnit XML to `url`, with ``testReport(resultBundleURL:)`` and
    /// ``JUnit/write(_:to:)``.
    ///
    /// Opens a step named "Write JUnit report" when called at the top level of a command. `step` renames it.
    public static func writeJUnitReport(resultBundleURL: URL, to url: URL, step name: String? = nil) async throws {
        try await step(default: "Write JUnit report", name: name) {
            let report = try await testReport(resultBundleURL: resultBundleURL)
            try JUnit.write(report, to: url)
        }
    }

    private static let xcrunPath = "/usr/bin/xcrun"
}

/// The part of the `xcresulttool get test-results tests` JSON that a report uses. Other fields are ignored.
private struct TestResultsJSON: Decodable {
    var testNodes: [TestNode]
}

/// A node of the test tree. `nodeType` is a string and not an enum, so that a node type that is not known is decoded
/// too.
private struct TestNode: Decodable {
    var nodeType: String
    var name: String
    var result: String?
    var durationInSeconds: Double?
    var sourceLocation: SourceLocation?
    var children: [TestNode]?

    struct SourceLocation: Decodable {
        var filePath: String
        var lineNumber: Int
    }
}

/// Where a node is in the tree: the bundle, the suites above it and the device.
private struct TestContext {
    var bundle: String?
    var suitePath: [String] = []
    var device: String?

    /// The suite name, as `Bundle.Outer.Inner`, with the device appended when `showDevice` is set.
    func suiteName(showDevice: Bool) -> String {
        let name = ([bundle].compactMap { $0 } + suitePath).joined(separator: ".")
        guard showDevice, let device else {
            return name
        }
        return "\(name) (\(device))"
    }
}

/// Maps the test tree to a report. Each case is paired with its suite name, and the cases are grouped by that name in
/// the order of the tree.
private func makeReport(from nodes: [TestNode]) -> TestReport {
    let showDevice = Set(descendants(of: nodes, type: "Device").map(\.name)).count > 1
    var entries: [(suite: String, testCase: TestCase)] = []
    collectCases(in: nodes, context: TestContext(), showDevice: showDevice, into: &entries)

    var suiteNames: [String] = []
    var casesBySuite: [String: [TestCase]] = [:]
    for entry in entries {
        if casesBySuite[entry.suite] == nil {
            suiteNames.append(entry.suite)
        }
        casesBySuite[entry.suite, default: []].append(entry.testCase)
    }
    return TestReport(
        suites: suiteNames.map { TestSuite(name: $0, cases: casesBySuite[$0] ?? []) }
    )
}

private func collectCases(
    in nodes: [TestNode],
    context: TestContext,
    showDevice: Bool,
    into entries: inout [(suite: String, testCase: TestCase)]
) {
    for node in nodes {
        var child = context
        switch node.nodeType {
        case "Test Case":
            let suite = context.suiteName(showDevice: showDevice)
            entries.append((suite, testCase(node, className: suite)))
            continue
        case "Unit test bundle", "UI test bundle":
            child = TestContext(bundle: node.name, device: context.device)
        case "Test Suite":
            child.suitePath.append(node.name)
        case "Device":
            child.device = node.name
        default:
            break
        }
        collectCases(in: node.children ?? [], context: child, showDevice: showDevice, into: &entries)
    }
}

private func testCase(_ node: TestNode, className: String) -> TestCase {
    let children = node.children ?? []
    let messages = descendants(of: children, type: "Failure Message").map(failureText)
    let skipMessage = descendants(of: children, type: "Skip Message").first?.name

    let result: TestResult
    switch node.result {
    case "Passed", "Expected Failure":
        result = .passed
    case "Failed":
        result = .failed(messages: messages)
    case "Skipped":
        result = .skipped(message: skipMessage)
    default:
        // A result that is missing or not known: decided by what the case reports.
        if !messages.isEmpty {
            result = .failed(messages: messages)
        } else if skipMessage != nil {
            result = .skipped(message: skipMessage)
        } else {
            result = .passed
        }
    }
    return TestCase(
        className: className,
        name: node.name,
        duration: node.durationInSeconds ?? 0,
        result: result
    )
}

/// A failure message, with its source location on a second line when the node gives one.
private func failureText(_ node: TestNode) -> String {
    guard let location = node.sourceLocation else {
        return node.name
    }
    return "\(node.name)\n\(location.filePath):\(location.lineNumber)"
}

/// The nodes of `type` in `nodes` and below them, in the order of the tree.
private func descendants(of nodes: [TestNode], type: String) -> [TestNode] {
    nodes.flatMap { node in
        (node.nodeType == type ? [node] : []) + descendants(of: node.children ?? [], type: type)
    }
}
