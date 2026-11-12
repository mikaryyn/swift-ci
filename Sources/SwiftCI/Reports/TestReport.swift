import Foundation

/// The results of a test run, as suites of test cases. A report is a plain value: a script or an extension builds it,
/// and a writer such as ``JUnit`` turns it into a file.
public struct TestReport: Equatable, Sendable {
    /// Creates a report with `suites`, in the order they are written.
    public init(suites: [TestSuite]) {
        self.suites = suites
    }

    /// The suites of the run, in the order they are written.
    public var suites: [TestSuite]

    /// The number of test cases in all suites.
    public var tests: Int {
        suites.reduce(0) { $0 + $1.tests }
    }

    /// The number of failed test cases in all suites. A case with several failure messages counts once.
    public var failures: Int {
        suites.reduce(0) { $0 + $1.failures }
    }

    /// The number of skipped test cases in all suites.
    public var skipped: Int {
        suites.reduce(0) { $0 + $1.skipped }
    }

    /// The total duration of all test cases, in seconds.
    public var time: TimeInterval {
        suites.reduce(0) { $0 + $1.time }
    }
}

/// A group of test cases, such as the tests of one test class or one test bundle.
public struct TestSuite: Equatable, Sendable {
    /// Creates a suite named `name` with `cases`, in the order they are written.
    public init(name: String, cases: [TestCase]) {
        self.name = name
        self.cases = cases
    }

    /// The name of the suite, such as `LoginTests`.
    public var name: String

    /// The test cases of the suite, in the order they ran.
    public var cases: [TestCase]

    /// The number of test cases.
    public var tests: Int {
        cases.count
    }

    /// The number of failed test cases. A case with several failure messages counts once.
    public var failures: Int {
        cases.filter { $0.result.isFailed }.count
    }

    /// The number of skipped test cases.
    public var skipped: Int {
        cases.filter { $0.result.isSkipped }.count
    }

    /// The total duration of the test cases, in seconds.
    public var time: TimeInterval {
        cases.reduce(0) { $0 + $1.duration }
    }
}

/// One test case and its result.
public struct TestCase: Equatable, Sendable {
    /// Creates a test case. `className` is the class or type that owns the test, which may be the suite name.
    public init(className: String, name: String, duration: TimeInterval, result: TestResult) {
        self.className = className
        self.name = name
        self.duration = duration
        self.result = result
    }

    /// The class or type that owns the test, such as `LoginTests`. Writers use it to tell tests with the same name apart.
    public var className: String

    /// The name of the test, such as `testLoginWithValidPassword()`.
    public var name: String

    /// How long the test took, in seconds.
    public var duration: TimeInterval

    /// The result of the test.
    public var result: TestResult
}

/// The result of one test case.
public enum TestResult: Equatable, Sendable {
    /// The test passed.
    case passed

    /// The test failed. `messages` are the failure messages, one per failed assertion. A message may have several lines;
    /// the first line is the short message of a report, and the whole message is its details.
    case failed(messages: [String])

    /// The test was skipped, with the reason if it has one.
    case skipped(message: String?)

    /// Whether the result is ``failed(messages:)``.
    var isFailed: Bool {
        if case .failed = self {
            return true
        }
        return false
    }

    /// Whether the result is ``skipped(message:)``.
    var isSkipped: Bool {
        if case .skipped = self {
            return true
        }
        return false
    }
}
