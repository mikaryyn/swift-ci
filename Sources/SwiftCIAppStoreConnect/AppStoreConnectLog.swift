#if os(macOS)
import Foundation
import SwiftCI

/// Logging of the App Store Connect client and the build upload. Each line goes to the console as usual, and the same
/// text goes to the full log as plain text, without colour codes.
extension Log {
    /// Logs `line` on the console and writes it to the full log.
    func recorded(_ line: String) {
        self(line)
        writeToFullLog(line)
    }

    /// Logs a success line as ``success(_:)`` does, and writes it to the full log as `✔︎ <line>`.
    func recordedSuccess(_ line: String) {
        success(line)
        writeToFullLog("✔︎ \(line)")
    }

    /// Logs a warning as ``warning(_:)`` does, and writes it to the full log as `<Warning> <line>`.
    func recordedWarning(_ line: String) {
        warning(line)
        writeToFullLog("<Warning> \(line)")
    }
}

/// Writes `line` to the full log. A failed write is not thrown from the logging lines, because they are called where a
/// throw would change the upload's result.
private func writeToFullLog(_ line: String) {
    try? FullLog.write(line)
}
#endif
