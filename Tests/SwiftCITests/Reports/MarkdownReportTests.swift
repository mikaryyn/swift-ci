@testable import SwiftCI
@testable import SwiftCITestSupport
import Foundation
import SwiftCITesting
import Testing

extension GlobalStateTests {
    @Suite(.serialized) struct MarkdownReportTests {
        /// The note added to a truncated report.
        private let note = "Some of this report was left out to fit the length limit. The full report is in the artifacts of the build."

        private func lines(_ text: String) -> [String] {
            text.components(separatedBy: "\n")
        }

        @Test func headingSaysFailedWhenReportHasAFailure() {
            let report = RunReport(commandName: "lint", findings: [ReportFinding(severity: .failure, text: "Bad.")])
            #expect(MarkdownReport(title: "Lint").render(report).hasPrefix("## Lint failed\n\n"))
        }

        @Test func headingSaysFailedWhenOutcomeFailedWithoutFindings() {
            let report = RunReport(commandName: "lint", outcome: .failed(message: "Boom."))
            #expect(MarkdownReport(title: "Lint").render(report) == "## Lint failed\n")
        }

        @Test func headingSaysPassedWithWarningsOnly() {
            let report = RunReport(
                commandName: "lint",
                findings: [ReportFinding(severity: .warning, text: "Careful.")],
                outcome: .succeeded
            )
            #expect(MarkdownReport(title: "Lint").render(report).hasPrefix("## Lint passed\n\n**Warnings**\n"))
        }

        @Test func headingSaysPassedWithoutOutcomeAndWithoutFailures() {
            #expect(MarkdownReport(title: "Lint").render(RunReport(commandName: "lint")) == "## Lint passed\n")
        }

        @Test func headingSaysPassedWithSucceededOutcome() {
            #expect(MarkdownReport(title: "Lint").render(RunReport(commandName: "lint", outcome: .succeeded)) == "## Lint passed\n")
        }

        @Test func layoutOfMixedReportIsExact() {
            let report = RunReport(
                commandName: "lint",
                findings: [
                    ReportFinding(severity: .failure, text: "Force unwrap of the `value`.", file: "Sources/App/View.swift", line: 12),
                    ReportFinding(severity: .failure, text: "Pipe in name.", file: "Sources/App/A|B.swift"),
                    ReportFinding(severity: .warning, text: "Line one\nline two", file: "README.md", line: 3),
                    ReportFinding(severity: .warning, text: "No location."),
                    ReportFinding(severity: .message, text: "Checked 3 files."),
                ],
                sections: [
                    ReportSection(title: "Coverage", markdown: "| File | % |\n| --- | --- |\n| A | 90 |\n"),
                    ReportSection(markdown: "<details>\n<summary>More</summary>\n\nBody\n</details>\n"),
                ],
                outcome: .failed(message: "The run report has 2 failure(s).")
            )

            let output = MarkdownReport(title: "Lint", footer: "<!-- swift-ci:lint -->").render(report)

            #expect(output == #"""
            ## Lint failed

            **Failures**

            | Location | Message |
            | --- | --- |
            | `Sources/App/View.swift:12` | Force unwrap of the `value`. |
            | `Sources/App/A\|B.swift` | Pipe in name. |

            **Warnings**

            | Location | Message |
            | --- | --- |
            | `README.md:3` | Line one<br>line two |
            |  | No location. |

            - Checked 3 files.

            ### Coverage

            | File | % |
            | --- | --- |
            | A | 90 |

            <details>
            <summary>More</summary>

            Body
            </details>

            <!-- swift-ci:lint -->

            """#)
        }

        @Test func emptyTablesAreOmitted() {
            let report = RunReport(
                commandName: "lint",
                findings: [ReportFinding(severity: .message, text: "Checked 3 files.")],
                outcome: .succeeded
            )

            #expect(MarkdownReport(title: "Lint").render(report) == "## Lint passed\n\n- Checked 3 files.\n")
        }

        @Test func sectionsWithAndWithoutTitle() {
            let report = RunReport(
                commandName: "lint",
                sections: [
                    ReportSection(title: "Coverage", markdown: "A\n"),
                    ReportSection(title: "", markdown: "\nB"),
                    ReportSection(markdown: "C"),
                    ReportSection(title: "Empty", markdown: "\n"),
                ],
                outcome: .succeeded
            )

            #expect(MarkdownReport(title: "Lint").render(report) == "## Lint passed\n\n### Coverage\n\nA\n\nB\n\nC\n")
        }

        @Test func footerIsTheLastBlock() {
            let report = RunReport(
                commandName: "lint",
                findings: [ReportFinding(severity: .message, text: "Done.")],
                sections: [ReportSection(markdown: "Section.")],
                outcome: .succeeded
            )

            let output = MarkdownReport(title: "Lint", footer: "Footer.\n<!-- marker -->").render(report)

            #expect(output == "## Lint passed\n\n- Done.\n\nSection.\n\nFooter.\n<!-- marker -->\n")
        }

        @Test func pipesAndLineBreaksAreEscapedInCells() {
            let report = RunReport(
                commandName: "lint",
                findings: [ReportFinding(severity: .failure, text: "a | b\r\nc\nd\re")]
            )

            let output = MarkdownReport(title: "Lint").render(report)

            #expect(output.contains("|  | a \\| b<br>c<br>d<br>e |\n"))
        }

        @Test func messagesKeepLineBreaksAsBreaks() {
            let report = RunReport(commandName: "lint", findings: [ReportFinding(severity: .message, text: "x\ny")], outcome: .succeeded)

            #expect(MarkdownReport(title: "Lint").render(report) == "## Lint passed\n\n- x<br>y\n")
        }

        @Test func backticksInPathsStayInsideTheCodeSpan() {
            let report = RunReport(
                commandName: "lint",
                findings: [
                    ReportFinding(severity: .failure, text: "m1", file: "Sources/a`b.swift", line: 3),
                    ReportFinding(severity: .failure, text: "m2", file: "`start.swift"),
                    ReportFinding(severity: .failure, text: "m3", file: "x``y.swift"),
                ]
            )

            let output = MarkdownReport(title: "Lint").render(report)

            #expect(output.contains("| ``Sources/a`b.swift:3`` | m1 |\n"))
            #expect(output.contains("| `` `start.swift `` | m2 |\n"))
            #expect(output.contains("| ```x``y.swift``` | m3 |\n"))
        }

        @Test func registeredSecretIsMaskedInEveryPart() {
            let restore = isolatedGlobalState()
            defer { restore() }
            _ = Secret(value: "s3cret-token")
            let report = RunReport(
                commandName: "lint",
                findings: [
                    ReportFinding(severity: .failure, text: "token s3cret-token", file: "s3cret-token.swift"),
                    ReportFinding(severity: .message, text: "Message s3cret-token."),
                ],
                sections: [ReportSection(title: "Section", markdown: "value s3cret-token")],
                outcome: .succeeded
            )

            let output = MarkdownReport(title: "Lint", footer: "footer s3cret-token").render(report)

            #expect(!output.contains("s3cret-token"))
            #expect(output.contains("token \(SecretRegistry.mask)"))
            #expect(output.contains("Message \(SecretRegistry.mask)."))
            #expect(output.contains("value \(SecretRegistry.mask)"))
            #expect(output.hasSuffix("footer \(SecretRegistry.mask)\n"))
        }

        /// Three sections of 400 characters each. Two do not fit the limit, one does, so the second and third are dropped.
        @Test func sectionsAreDroppedFromTheEndFirstAndNoteIsAddedOnce() {
            let report = RunReport(
                commandName: "lint",
                findings: [ReportFinding(severity: .failure, text: "Bad.")],
                sections: [
                    ReportSection(markdown: String(repeating: "a", count: 400)),
                    ReportSection(markdown: String(repeating: "b", count: 400)),
                    ReportSection(markdown: String(repeating: "c", count: 400)),
                ],
                outcome: .failed(message: "Boom.")
            )

            let output = MarkdownReport(title: "Lint", maximumLength: 700).render(report)

            #expect(output.contains(String(repeating: "a", count: 400)))
            #expect(!output.contains("bbb"))
            #expect(!output.contains("ccc"))
            #expect(output.contains("| Bad. |"))
            #expect(output.components(separatedBy: note).count == 2)
            #expect(output.count <= 700)
        }

        /// No sections are left, so the messages are cut before the warning rows, and the warnings before the failures.
        /// The failures are kept in full. The warning rows that are left are counted in the last line of the table.
        @Test func messagesAreCutThenWarningRowsThenFailuresKeptLongest() {
            let report = RunReport(
                commandName: "lint",
                findings: (1...3).map { ReportFinding(severity: .failure, text: "F\($0)") }
                    + (1...200).map { ReportFinding(severity: .warning, text: "warning \($0)") }
                    + (1...200).map { ReportFinding(severity: .message, text: "message \($0)") },
                outcome: .succeeded
            )

            let output = MarkdownReport(title: "Lint", maximumLength: 1500).render(report)

            let keptWarnings = lines(output).filter { $0.contains("| warning ") }.count
            #expect(keptWarnings > 0)
            #expect(keptWarnings < 200)
            #expect(output.contains("|  | F1 |\n"))
            #expect(output.contains("|  | F2 |\n"))
            #expect(output.contains("|  | F3 |\n"))
            #expect(output.contains("- 200 more left out\n"))
            #expect(!output.contains("- message "))
            #expect(output.contains("| | \(200 - keptWarnings) more left out |\n"))
            #expect(output.components(separatedBy: note).count == 2)
            #expect(output.count <= 1500)
        }

        /// The heading, the note and the footer stay even if they alone are longer than the limit. The failure rows are
        /// all cut, and the table keeps its header and the count line.
        @Test func headingNoteAndFooterAreKeptWhenTheyAloneExceedTheLimit() {
            let report = RunReport(commandName: "lint", findings: [ReportFinding(severity: .failure, text: "Bad.")])

            let output = MarkdownReport(title: "Lint", footer: "<!-- footer -->", maximumLength: 10).render(report)

            #expect(output.hasPrefix("## Lint failed\n\n**Failures**\n"))
            #expect(output.contains("| Location | Message |\n| --- | --- |\n| | 1 more left out |\n"))
            #expect(output.contains("\n\n\(note)\n\n<!-- footer -->\n"))
            #expect(!output.contains("Bad."))
        }

        /// Failure rows are the last to be cut. The count of kept and left out rows adds up to the total.
        @Test func failureRowsAreCutLastWithCountLine() {
            let report = RunReport(
                commandName: "lint",
                findings: (1...300).map { ReportFinding(severity: .failure, text: "failure \($0)") }
            )

            let output = MarkdownReport(title: "Lint", maximumLength: 2000).render(report)

            let kept = lines(output).filter { $0.contains("| failure ") }.count
            #expect(kept > 0)
            #expect(kept < 300)
            #expect(output.contains("| | \(300 - kept) more left out |\n"))
            #expect(output.count <= 2000)
        }

        /// The fixed parts (heading, note, footer and table headers) are far below the limit, so the output must fit.
        /// Thousands of rows make sure the cut applies to every part of a large report.
        @Test func outputNeverExceedsTheLimitWhenFixedPartsFit() {
            let report = RunReport(
                commandName: "lint",
                findings: (1...3000).flatMap { (index: Int) -> [ReportFinding] in
                    [
                        ReportFinding(severity: .failure, text: "failure \(index)", file: "F.swift", line: index),
                        ReportFinding(severity: .warning, text: "warning \(index)"),
                        ReportFinding(severity: .message, text: "message \(index)"),
                    ]
                },
                sections: (1...5).map { ReportSection(title: "Section \($0)", markdown: String(repeating: "x", count: 300)) },
                outcome: .failed(message: "Boom.")
            )

            let output = MarkdownReport(title: "Lint", footer: "<!-- marker -->", maximumLength: 5000).render(report)

            #expect(output.count <= 5000)
            #expect(output.contains(note))
            #expect(output.hasSuffix("<!-- marker -->\n"))
        }

        @Test func outputEndsWithExactlyOneNewline() {
            let report = RunReport(commandName: "lint", sections: [ReportSection(markdown: "Text\n\n\n")], outcome: .succeeded)

            let output = MarkdownReport(title: "Lint").render(report)

            #expect(output == "## Lint passed\n\nText\n")
        }
    }
}
