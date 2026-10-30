import Foundation
import SwiftCI

extension Xcode {
    /// The console filter of `test`. It is a block filter, because a `↳` line of Swift Testing is shown only after an
    /// issue line.
    ///
    /// It shows what ``xcodebuildFilter`` shows, and from the test output:
    /// - XCTest: the failed and skipped tests, the reason of a skip, and the `Executed` summary lines. Every summary
    ///   line is shown, including the `Executed 0 tests` of the Swift Testing run.
    /// - Swift Testing: the `✘` lines (issues, failed tests, suites and the run), the `↳` lines after an issue, the
    ///   skipped tests, and the result line of the run.
    /// - The "Failing tests:" and "Testing failed:" lists and the path of the result bundle: the indented lines after
    ///   their header.
    /// - Test infrastructure: the CoreSimulator `[-[Sim...] ERROR :` lines, the
    ///   `IDETestOperationsObserverDebug: Failure` lines, and the lines that report a restart, a crash, a hung test
    ///   runner or an early exit of the test runner.
    ///
    /// Everything else is hidden, passing tests included. The checks ignore a zero-width space and colour codes, and a
    /// shown line is returned as it was written. The filter keeps state, so make a new one for each run.
    static func testOutputFilter() -> BlockFilter {
        var isAfterIssue = false
        var isInIndentedList = false
        return { line in
            let plain = plainTestText(line)
            if plain.hasPrefix("↳") {
                return isAfterIssue ? [line] : []
            }
            isAfterIssue = plain.contains(#/^✘ .* recorded an issue/#)
            if isInIndentedList && plain.hasPrefix("\t") {
                return [line]
            }
            isInIndentedList = indentedListHeaders.contains(plain)
            if isInIndentedList {
                return [line]
            }
            if let shown = Self.xcodebuildFilter(line) {
                return [shown]
            }
            return Self.isTestLineShown(plain) ? [line] : []
        }
    }

    /// Whether a line of test output is shown. The `↳` lines and the indented lists are decided by
    /// ``testOutputFilter()``.
    private static func isTestLineShown(_ plain: String) -> Bool {
        plain.contains(#/^Test Case '.*' (failed|skipped) \(/#)
            || plain.contains(#/: Test skipped - /#)
            || plain.contains(#/Executed \d+ tests?, with /#)
            || plain.contains(#/^✘ /#)
            || plain.contains(#/^➜ Test .* skipped/#)
            || plain.contains(#/^✔ Test run with /#)
            || plain.contains(#/\[-\[Sim.*\] ERROR : /#)
            || plain.contains(#/IDETestOperationsObserverDebug: Failure /#)
            || plain.contains(#/Restarting after unexpected exit, crash, or test timeout/#)
            || plain.contains(#/Test crashed with signal /#)
            || plain.contains(#/[Tt]est runner hung/#)
            || plain.contains(#/Early unexpected exit/#)
    }
}

/// The lines that start an indented list in the output of `xcodebuild test`.
private let indentedListHeaders = [
    "Failing tests:",
    "Testing failed:",
    "Test session results, code coverage, and logs:",
]

/// The text of a line without zero-width spaces and colour codes, which Swift Testing and terminals add.
private func plainTestText(_ line: String) -> String {
    line.replacingOccurrences(of: "\u{200B}", with: "")
        .replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
}
