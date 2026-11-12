@testable import SwiftCI
import Foundation
import Testing

/// The report model counts its cases, and the JUnit writer escapes text and writes the file. The XML of a small report is
/// compared exactly. The file test removes the directory it creates under the temporary directory.
@Suite struct JUnitTests {
    private let login = TestSuite(
        name: "LoginTests",
        cases: [
            TestCase(className: "LoginTests", name: "testLogin", duration: 0.5, result: .passed),
            TestCase(className: "LoginTests", name: "testLogout", duration: 1.25, result: .failed(messages: ["Expected \"out\" & <in>"])),
            TestCase(className: "LoginTests", name: "testReset", duration: 0, result: .skipped(message: nil)),
        ]
    )

    @Test func totalsCountTheCasesFailuresSkippedAndTime() {
        let report = TestReport(suites: [
            login,
            TestSuite(
                name: "ProfileTests",
                cases: [
                    TestCase(className: "ProfileTests", name: "testName", duration: 0.25, result: .skipped(message: "Needs a device")),
                    TestCase(className: "ProfileTests", name: "testAvatar", duration: 2, result: .failed(messages: ["one", "two"])),
                ]
            ),
        ])

        #expect(login.tests == 3)
        #expect(login.failures == 1)
        #expect(login.skipped == 1)
        #expect(login.time == 1.75)
        #expect(report.tests == 5)
        #expect(report.failures == 2)
        #expect(report.skipped == 2)
        #expect(report.time == 4)
    }

    @Test func xmlOfASmallReportIsExact() {
        let report = TestReport(suites: [login])

        #expect(JUnit.xml(for: report) == """
        <?xml version="1.0" encoding="UTF-8"?>
        <testsuites tests="3" failures="1" skipped="1" time="1.750">
          <testsuite name="LoginTests" tests="3" failures="1" skipped="1" time="1.750">
            <testcase classname="LoginTests" name="testLogin" time="0.500"/>
            <testcase classname="LoginTests" name="testLogout" time="1.250">
              <failure message="Expected &quot;out&quot; &amp; &lt;in&gt;">Expected &quot;out&quot; &amp; &lt;in&gt;</failure>
            </testcase>
            <testcase classname="LoginTests" name="testReset" time="0.000">
              <skipped/>
            </testcase>
          </testsuite>
        </testsuites>

        """)
    }

    @Test func emptyReportHasZeroTotalsAndNoSuites() {
        #expect(JUnit.xml(for: TestReport(suites: [])) == """
        <?xml version="1.0" encoding="UTF-8"?>
        <testsuites tests="0" failures="0" skipped="0" time="0.000">
        </testsuites>

        """)
    }

    @Test func angleBracketsAmpersandsAndQuotesAreEscapedInNamesAndMessages() {
        let report = TestReport(suites: [
            TestSuite(
                name: "A&B <C>",
                cases: [
                    TestCase(
                        className: "A&B <C>",
                        name: "it's \"quoted\"",
                        duration: 0,
                        result: .failed(messages: ["a < b && c > d"])
                    ),
                ]
            ),
        ])

        let xml = JUnit.xml(for: report)

        #expect(xml.contains(#"<testsuite name="A&amp;B &lt;C&gt;""#))
        #expect(xml.contains(#"<testcase classname="A&amp;B &lt;C&gt;" name="it&apos;s &quot;quoted&quot;" time="0.000">"#))
        #expect(xml.contains(#"<failure message="a &lt; b &amp;&amp; c &gt; d">a &lt; b &amp;&amp; c &gt; d</failure>"#))
        #expect(!xml.contains("<C>"))
        #expect(!xml.contains("a < b"))
    }

    @Test func failureWithSeveralMessagesHasOneElementPerMessage() {
        let report = TestReport(suites: [
            TestSuite(
                name: "LoginTests",
                cases: [
                    TestCase(
                        className: "LoginTests",
                        name: "testLogin",
                        duration: 0.5,
                        result: .failed(messages: ["First line\nsecond line", "Other failure"])
                    ),
                ]
            ),
        ])

        // The attribute has the first line only; the text has the whole message.
        let failures = "      <failure message=\"First line\">First line\nsecond line</failure>\n"
            + "      <failure message=\"Other failure\">Other failure</failure>\n"
        #expect(JUnit.xml(for: report).contains(failures))
        #expect(report.failures == 1)
    }

    @Test func failedCaseWithoutMessagesStillHasAFailureElement() {
        let report = TestReport(suites: [
            TestSuite(
                name: "LoginTests",
                cases: [TestCase(className: "LoginTests", name: "testLogin", duration: 0, result: .failed(messages: []))]
            ),
        ])

        #expect(JUnit.xml(for: report).contains("      <failure/>\n"))
    }

    @Test func skippedCaseWithAndWithoutMessage() {
        let report = TestReport(suites: [
            TestSuite(
                name: "ProfileTests",
                cases: [
                    TestCase(className: "ProfileTests", name: "testName", duration: 0, result: .skipped(message: "Needs a device")),
                    TestCase(className: "ProfileTests", name: "testAvatar", duration: 0, result: .skipped(message: nil)),
                ]
            ),
        ])

        let xml = JUnit.xml(for: report)

        #expect(xml.contains(#"      <skipped message="Needs a device"/>"#))
        #expect(xml.contains("      <skipped/>\n"))
        #expect(report.skipped == 2)
    }

    @Test func controlCharactersNotAllowedInXMLAreDropped() {
        let report = TestReport(suites: [
            TestSuite(
                name: "ProfileTests",
                cases: [
                    TestCase(
                        className: "ProfileTests",
                        name: "a\u{1B}[31mb\u{0}\u{FFFE}c\td",
                        duration: 0,
                        result: .passed
                    ),
                ]
            ),
        ])

        // The tab is allowed in XML, and it is written as a character reference in the attribute.
        #expect(JUnit.xml(for: report).contains(#"name="a[31mbc&#9;d""#))
    }

    @Test func writeCreatesTheFileAndItsDirectory() throws {
        let dir = try TemporaryDirectory(name: "JUnitTests-$UUID")
        defer { try? FileManager.default.removeItem(at: dir.url) }
        let url = dir.childURL(name: "reports/junit.xml")
        let report = TestReport(suites: [login])

        try JUnit.write(report, to: url)

        #expect(try String(contentsOf: url, encoding: .utf8) == JUnit.xml(for: report))
    }
}
