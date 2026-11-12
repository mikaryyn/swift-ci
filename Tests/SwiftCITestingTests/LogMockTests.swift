import SwiftCI
import SwiftCITesting
import Testing

/// The log mock as an extension author uses it: passed to `SwiftCITest.run`, with only the public API.
@Suite(.serialized) struct LogMockTests {
    private struct Failure: Error {}

    @Test func stepEventsAreRecordedInOrderWithTheirDepth() async {
        let log = LogMock()

        let result = await SwiftCITest.run(["build"], log: log) {
            command(Command("build") {
                try await step("Outer") {
                    try await step("Inner") {}
                }
                await step("Optional", failure: .allowed) { throw Failure() }
                skipStep("Skipped", reason: "not needed")
            })
        }

        #expect(result.exitCode == 0)
        #expect(log.steps.map(description) == [
            "entered Outer 0",
            "entered Inner 1",
            "finished Inner 1",
            "finished Outer 0",
            "entered Optional 0",
            "allowedFailed Optional 0",
            "skipped Skipped 0 not needed",
        ])
    }

    @Test func aFailedStepIsRecordedAsFailed() async {
        let log = LogMock()

        let result = await SwiftCITest.run(["build"], log: log) {
            command(Command("build") {
                try await step("Compile") { throw Failure() }
            })
        }

        #expect(result.exitCode == 1)
        #expect(log.steps.map(description) == ["entered Compile 0", "failed Compile 0"])
    }

    @Test func eachLogMethodFillsItsListAndWritesTheConsoleLineOfTheRealLog() async {
        let log = LogMock()

        let result = await SwiftCITest.run(["build"], log: log) {
            command(Command("build") {
                @Use var console: Log
                console.completion("done")
                console.success("great")
                console.warning("careful")
                console.error("broken")
                console.lines(title: "Findings", lines: ["one", "two"])
            })
        }

        #expect(log.completions == ["done"])
        #expect(log.successes == ["great"])
        #expect(log.warnings == ["careful"])
        #expect(log.errors == ["broken"])
        #expect(log.titledLines == [LogMock.TitledLines(title: "Findings", lines: ["one", "two"])])
        let plain = result.plainLog
        #expect(plain.contains("▸ done"))
        #expect(plain.contains("✔︎ great"))
        #expect(plain.contains("<Warning> careful"))
        #expect(plain.contains("<Error> broken"))
        #expect(plain.contains("one"))
        #expect(plain.contains("two"))
    }

    @Test func theResultLogIsTheLoggedLinesOfTheMockThatWasPassed() async {
        let log = LogMock()

        let result = await SwiftCITest.run(["build"], log: log) {
            command(Command("build") {
                try await step("Compile") {}
            })
        }

        #expect(result.log == log.loggedLines)
        #expect(!log.loggedLines.isEmpty)
    }

    @Test func registeredSecretsAreMaskedInWhatTheMockRecords() async {
        let log = LogMock()

        _ = await SwiftCITest.run(["build"], environment: ["MYAPP_TOKEN": "s3cr3t-token"], log: log) {
            command(Command("build") {
                _ = Secret("MYAPP_TOKEN")
                @Use var console: Log
                console.warning("token is s3cr3t-token")
            })
        }

        #expect(log.warnings.count == 1)
        #expect(!log.warnings.joined().contains("s3cr3t-token"))
        #expect(!log.loggedLines.joined().contains("s3cr3t-token"))
    }

    private func description(of event: LogMock.StepEvent) -> String {
        switch event {
        case .entered(let name, let depth): "entered \(name) \(depth)"
        case .finished(let name, _, let depth): "finished \(name) \(depth)"
        case .failed(let name, let depth): "failed \(name) \(depth)"
        case .allowedFailed(let name, let depth): "allowedFailed \(name) \(depth)"
        case .skipped(let name, let reason, let depth): "skipped \(name) \(depth) \(reason)"
        }
    }
}
