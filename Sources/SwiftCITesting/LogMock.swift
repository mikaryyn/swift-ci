import Foundation
@_spi(Testing) import SwiftCI

/// A log for tests. It records each line the console would show, and the arguments of each ``Log`` method.
///
/// The console lines are formatted by the default implementations of ``Log``, so they match the real console: a
/// warning reads `<Warning> …` with its colour codes, and a step reads `Entering step [...]`. Use ``SwiftCITestResult/plainLog``
/// to compare the text without the colour codes.
///
/// Register it with ``SwiftCITest/withMocks(_:runner:log:artifactsDirectory:_:)`` or ``SwiftCITest/run(_:environment:artifactsDirectory:runner:script:)``.
/// The lines it receives are already masked for secrets, as the real console is.
public final class LogMock: Log {
    /// Creates an empty log.
    public init() {}

    /// Every console line, in order, with its colour codes. Each line is what the console would show.
    public private(set) var loggedLines: [String] = []

    /// The messages passed to ``completion(_:)``, without the symbol.
    public private(set) var completions: [String] = []
    /// The messages passed to ``success(_:)``, without the symbol.
    public private(set) var successes: [String] = []
    /// The messages passed to ``warning(_:)``.
    public private(set) var warnings: [String] = []
    /// The messages passed to ``error(_:)``.
    public private(set) var errors: [String] = []
    /// The step events, in order: each step that starts, finishes, fails or fails with the failure allowed.
    public private(set) var steps: [StepEvent] = []
    /// The arguments of each ``lines(title:lines:)`` call, in order.
    public private(set) var titledLines: [TitledLines] = []

    /// A step event that ``LogMock`` recorded.
    public enum StepEvent: Equatable, Sendable {
        /// The step started. `depth` is 0 for a top-level step, 1 for a step inside a step, and so on.
        case entered(name: String, depth: Int)
        /// The step finished, with its duration in seconds.
        case finished(name: String, duration: Double, depth: Int)
        /// The step failed.
        case failed(name: String, depth: Int)
        /// The step failed, and the command continues.
        case allowedFailed(name: String, depth: Int)
    }

    /// The arguments of a ``lines(title:lines:)`` call.
    public struct TitledLines: Equatable, Sendable {
        /// The title, shown as a completion line.
        public let title: String
        /// The lines below the title.
        public let lines: [String]
    }

    public func callAsFunction(_ line: String) {
        loggedLines.append(line)
    }

    public func completion(_ line: String) {
        completions.append(line)
        formatter.completion(line)
    }

    public func success(_ line: String) {
        successes.append(line)
        formatter.success(line)
    }

    public func warning(_ line: String) {
        warnings.append(line)
        formatter.warning(line)
    }

    public func error(_ line: String) {
        errors.append(line)
        formatter.error(line)
    }

    public func enteringStep(name: String, depth: Int) throws {
        steps.append(.entered(name: name, depth: depth))
        try formatter.enteringStep(name: name, depth: depth)
    }

    public func finishedStep(name: String, duration: TimeInterval, depth: Int) throws {
        steps.append(.finished(name: name, duration: duration, depth: depth))
        try formatter.finishedStep(name: name, duration: duration, depth: depth)
    }

    public func failedStep(name: String, depth: Int) throws {
        steps.append(.failed(name: name, depth: depth))
        try formatter.failedStep(name: name, depth: depth)
    }

    public func allowedFailedStep(name: String, depth: Int) throws {
        steps.append(.allowedFailed(name: name, depth: depth))
        try formatter.allowedFailedStep(name: name, depth: depth)
    }

    public func lines(title: String, lines: [String]) {
        titledLines.append(TitledLines(title: title, lines: lines))
        formatter.lines(title: title, lines: lines)
    }

    /// Formats with the default `Log` implementations, and passes each console line back to this log.
    private var formatter: LineFormatter {
        LineFormatter { [self] line in loggedLines.append(line) }
    }
}

/// Uses the default formatting of ``Log`` and hands each formatted console line to `record`. Only `callAsFunction` is
/// written here. The other requirements come from the defaults, so the formatting is the same as in SwiftCI.
private struct LineFormatter: Log {
    let record: (String) -> Void

    func callAsFunction(_ line: String) {
        record(line)
    }
}
