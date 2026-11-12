import Foundation
import SwiftCI

/// The part of the `xcresulttool get test-results tests` JSON that a report uses. Other fields are ignored.
struct TestResultsJSON: Decodable {
    var testNodes: [TestNode]
}

/// A node of the test tree. `nodeType` is a string and not an enum, so that a node type that is not known is decoded
/// too.
struct TestNode: Decodable {
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

/// The results of a result bundle: the ``TestReport`` of the mapping, and the failed cases with their messages.
struct TestResults {
    var report: TestReport
    var failures: [FailedTest]
}

/// A failed test case, with the identifier that the report uses and each of its failure messages.
struct FailedTest {
    /// The suite name, as the report's `className` is.
    var className: String
    /// The name of the test, as the report's `name` is, such as `testLogin()`.
    var name: String
    /// The failure messages of all runs, in the order of the tree. Empty if the result has none.
    var messages: [FailureMessage]
}

/// One failure message of a test case. `text` is the message as the result bundle names it, which may have several
/// lines. The first line is the short message.
struct FailureMessage {
    var text: String
    var location: FailureLocation?

    /// The message as the report keeps it: the text, and the location on a second line when there is one.
    var reportText: String {
        guard let location else {
            return text
        }
        return "\(text)\n\(location.filePath):\(location.lineNumber)"
    }
}

/// The source location of a failure message. `filePath` is relative to the current directory when it is inside it.
struct FailureLocation {
    var filePath: String
    var lineNumber: Int
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

/// Maps the test tree of `xcresulttool get test-results tests` to the results.
enum TestResultsMapping {
    /// Maps the test tree to the results. Each case is paired with its suite name, and the cases are grouped by that name
    /// in the order of the tree.
    static func map(_ nodes: [TestNode]) -> TestResults {
        let showDevice = Set(descendants(of: nodes, type: "Device").map(\.name)).count > 1
        var entries: [(suite: String, node: TestNode)] = []
        collectCases(in: nodes, context: TestContext(), showDevice: showDevice, into: &entries)

        var suiteNames: [String] = []
        var casesBySuite: [String: [TestCase]] = [:]
        var failures: [FailedTest] = []
        for entry in entries {
            if casesBySuite[entry.suite] == nil {
                suiteNames.append(entry.suite)
            }
            let mapped = testCase(entry.node, className: entry.suite)
            casesBySuite[entry.suite, default: []].append(mapped)
            if case .failed = mapped.result {
                failures.append(FailedTest(
                    className: entry.suite,
                    name: entry.node.name,
                    messages: failureMessages(of: entry.node)
                ))
            }
        }
        let report = TestReport(
            suites: suiteNames.map { TestSuite(name: $0, cases: casesBySuite[$0] ?? []) }
        )
        return TestResults(report: report, failures: failures)
    }

    private static func collectCases(
        in nodes: [TestNode],
        context: TestContext,
        showDevice: Bool,
        into entries: inout [(suite: String, node: TestNode)]
    ) {
        for node in nodes {
            var child = context
            switch node.nodeType {
            case "Test Case":
                let suite = context.suiteName(showDevice: showDevice)
                entries.append((suite, node))
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

    private static func testCase(_ node: TestNode, className: String) -> TestCase {
        let children = node.children ?? []
        let messages = failureMessages(of: node).map(\.reportText)
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

    /// The failure messages below a case, in the order of the tree.
    private static func failureMessages(of node: TestNode) -> [FailureMessage] {
        descendants(of: node.children ?? [], type: "Failure Message").map { message in
            FailureMessage(
                text: message.name,
                location: message.sourceLocation.map {
                    FailureLocation(filePath: repositoryRelativePath($0.filePath), lineNumber: $0.lineNumber)
                }
            )
        }
    }

    /// The nodes of `type` in `nodes` and below them, in the order of the tree.
    private static func descendants(of nodes: [TestNode], type: String) -> [TestNode] {
        nodes.flatMap { node in
            (node.nodeType == type ? [node] : []) + descendants(of: node.children ?? [], type: type)
        }
    }
}
