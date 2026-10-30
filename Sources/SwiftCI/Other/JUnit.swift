import Foundation

/// Writes test reports as JUnit XML, the format that Jenkins and `danger-junit` read.
///
/// The file has a `testsuites` element with the totals, one `testsuite` per suite and one `testcase` per case. A failed
/// case has one `failure` element per message, and a skipped case has a `skipped` element. Text is XML-escaped, and
/// characters that XML 1.0 does not allow are dropped.
public enum JUnit {
    /// Writes `report` to `url` as JUnit XML, replacing the file. The directory of `url` is created if it is missing.
    ///
    /// It does not open a step.
    ///
    /// - Throws: ``BuildError`` if the directory or the file cannot be written.
    public static func write(_ report: TestReport, to url: URL) throws {
        let data = Data(xml(for: report).utf8)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            throw BuildError(message: "Failed to write the JUnit report to '\(url.filePath)'. Details: \(error)")
        }
    }

    /// The JUnit XML of `report`, with a trailing newline.
    static func xml(for report: TestReport) -> String {
        var lines = [
            #"<?xml version="1.0" encoding="UTF-8"?>"#,
            "<testsuites tests=\"\(report.tests)\" failures=\"\(report.failures)\" skipped=\"\(report.skipped)\" time=\"\(seconds(report.time))\">",
        ]
        for suite in report.suites {
            lines.append(
                "  <testsuite name=\"\(attributeText(suite.name))\" tests=\"\(suite.tests)\" failures=\"\(suite.failures)\" skipped=\"\(suite.skipped)\" time=\"\(seconds(suite.time))\">"
            )
            for testCase in suite.cases {
                lines += caseLines(testCase)
            }
            lines.append("  </testsuite>")
        }
        lines.append("</testsuites>")
        return lines.joined(separator: "\n") + "\n"
    }

    private static func caseLines(_ testCase: TestCase) -> [String] {
        let open = "    <testcase classname=\"\(attributeText(testCase.className))\" name=\"\(attributeText(testCase.name))\" time=\"\(seconds(testCase.duration))\""
        switch testCase.result {
        case .passed:
            return [open + "/>"]
        case .failed(let messages):
            var lines = [open + ">"]
            // A failed case without messages still has a failure element, so that readers do not count it as passed.
            if messages.isEmpty {
                lines.append("      <failure/>")
            }
            for message in messages {
                lines.append("      <failure message=\"\(attributeText(firstLine(of: message)))\">\(xmlText(message))</failure>")
            }
            lines.append("    </testcase>")
            return lines
        case .skipped(let message):
            let attribute = message.map { " message=\"\(attributeText(firstLine(of: $0)))\"" } ?? ""
            return [open + ">", "      <skipped\(attribute)/>", "    </testcase>"]
        }
    }

    /// The text of an element, escaped and without characters that XML 1.0 does not allow.
    private static func xmlText(_ text: String) -> String {
        let allowed = String(String.UnicodeScalarView(text.unicodeScalars.filter { isXMLCharacter($0) }))
        return allowed
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    /// The value of an attribute. Tabs and line breaks are written as character references, because a reader would
    /// otherwise replace them with spaces.
    private static func attributeText(_ text: String) -> String {
        xmlText(text)
            .replacingOccurrences(of: "\t", with: "&#9;")
            .replacingOccurrences(of: "\n", with: "&#10;")
            .replacingOccurrences(of: "\r", with: "&#13;")
    }

    private static func firstLine(of message: String) -> String {
        message.components(separatedBy: .newlines).first ?? ""
    }

    /// Whether XML 1.0 allows the character: tab, line feed, carriage return, and the ranges of the specification.
    private static func isXMLCharacter(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x9, 0xA, 0xD, 0x20...0xD7FF, 0xE000...0xFFFD, 0x10000...0x10FFFF:
            return true
        default:
            return false
        }
    }

    /// A duration in seconds with three decimals. The locale is POSIX, so the decimal separator is always a point.
    private static func seconds(_ time: TimeInterval) -> String {
        String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), time)
    }
}
