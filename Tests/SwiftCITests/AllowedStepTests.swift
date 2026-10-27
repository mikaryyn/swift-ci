@testable import SwiftCI
@testable import SwiftCITestSupport
import SwiftCITesting
import Testing

extension GlobalStateTests {
    @Suite(.serialized) struct AllowedStepTests {
        @Test func failedAllowedStepReturnsNilAndCommandSucceeds() async {
            var ranAfter = false
            var value: Int? = 0
            let result = await SwiftCITest.run(["test"]) {
                command(Command("test") {
                    value = await step("Notify", failure: .allowed) { () async throws -> Int in
                        throw TestError.boom
                    }
                    ranAfter = true
                })
            }

            #expect(result.exitCode == 0)
            #expect(value == nil)
            #expect(ranAfter)
            #expect(result.log.map(stripANSI).contains("Step [Notify] failed (allowed)"))
        }

        @Test func successfulAllowedStepReturnsValue() async {
            var value: Int?
            let result = await SwiftCITest.run(["test"]) {
                command(Command("test") {
                    value = await step("Compute", failure: .allowed) { 42 }
                })
            }

            let lines = result.log.map(stripANSI)
            #expect(result.exitCode == 0)
            #expect(value == 42)
            #expect(lines.contains { $0.hasPrefix("Finished step [Compute] in ") })
            #expect(!lines.contains { $0.hasPrefix("<Warning>") })
        }

        /// The message is logged once, as a warning, before the status line. It is never logged as an error.
        @Test func failedAllowedStepLogsMessageOnceAsWarning() async {
            let result = await SwiftCITest.run(["test"]) {
                command(Command("test") {
                    await step("Notify", failure: .allowed) { () async throws -> Void in
                        throw BuildError(message: "Slack is down.")
                    }
                })
            }

            let lines = result.log.map(stripANSI)
            #expect(result.exitCode == 0)
            #expect(lines.filter { $0.contains("Slack is down.") } == ["<Warning> Slack is down."])
            #expect(!lines.contains { $0.hasPrefix("<Error>") })
            guard let warningIndex = lines.firstIndex(of: "<Warning> Slack is down."),
                  let statusIndex = lines.firstIndex(of: "Step [Notify] failed (allowed)") else {
                Issue.record("Expected a warning line and a 'failed (allowed)' status line.")
                return
            }
            #expect(warningIndex < statusIndex)
        }

        /// The inner step logs "failed" and the outer allowed step logs "failed (allowed)". The message is a
        /// single warning, and the command succeeds.
        @Test func nestedFailureInsideAllowedStepIsWarningOnce() async {
            let result = await SwiftCITest.run(["test"]) {
                command(Command("test") {
                    await step("Outer", failure: .allowed) { () async throws -> Void in
                        try await step("Inner") { throw BuildError(message: "Inner broke.") }
                    }
                })
            }

            let lines = result.log.map(stripANSI)
            #expect(result.exitCode == 0)
            #expect(lines.contains("  Step [Inner] failed"))
            #expect(lines.contains("Step [Outer] failed (allowed)"))
            #expect(lines.filter { $0.contains("Inner broke.") } == ["<Warning> Inner broke."])
            #expect(!lines.contains { $0.hasPrefix("<Error>") })
            #expect(!lines.contains("Command [test] failed"))
        }

        @Test func allowedStepWithBuildErrorOfAnyCodeStillContinues() async {
            var ranAfter = false
            let result = await SwiftCITest.run(["test"]) {
                command(Command("test") {
                    await step("Internal", failure: .allowed) { () async throws -> Void in
                        throw BuildError(message: "Internal problem.", code: .internal)
                    }
                    ranAfter = true
                })
            }

            #expect(result.exitCode == 0)
            #expect(ranAfter)
            #expect(result.log.map(stripANSI).contains("<Warning> Internal problem."))
        }

        /// A throwing step may contain an allowed failing step. The outer step still succeeds.
        @Test func throwingStepContainingAllowedFailureContinues() async {
            var ranAfter = false
            let result = await SwiftCITest.run(["test"]) {
                command(Command("test") {
                    try await step("Build") {
                        await step("Upload symbols", failure: .allowed) { () async throws -> Void in
                            throw TestError.boom
                        }
                    }
                    ranAfter = true
                })
            }

            let lines = result.log.map(stripANSI)
            #expect(result.exitCode == 0)
            #expect(ranAfter)
            #expect(lines.contains("  Step [Upload symbols] failed (allowed)"))
            #expect(lines.contains { $0.hasPrefix("Finished step [Build] in ") })
        }

        /// Compile-time check: both overloads must infer their types without annotations.
        /// The statement forms must not produce a warning for an unused result.
        @Test func allowedStepInfersTypesWithoutAnnotations() async {
            func doWork() async throws { }
            func compute() async throws -> Int { 42 }

            var number: Int?
            var multiStatement: Int?
            var fromCall: Int?
            var voidValue: Void?
            let result = await SwiftCITest.run(["test"]) {
                command(Command("test") {
                    await step("Statement form", failure: .allowed) { try await doWork() }
                    await step("Empty", failure: .allowed) { }
                    let fromBlock = await step("Single expression", failure: .allowed) { 42 }
                    number = fromBlock
                    multiStatement = await step("Multi statement", failure: .allowed) {
                        let base = 20
                        let extra = 22
                        return base + extra
                    }
                    fromCall = await step("Returns async value", failure: .allowed) { try await compute() }
                    voidValue = await step("Void value", failure: .allowed) { try await doWork() }
                })
            }

            #expect(result.exitCode == 0)
            #expect(number == 42)
            #expect(multiStatement == 42)
            #expect(fromCall == 42)
            #expect(voidValue != nil)
        }

        /// The throwing overload and the allowed overload, in one command, resolve without annotations.
        @Test func bothOverloadsResolveInOneCommand() async {
            var value: Int?
            let result = await SwiftCITest.run(["test"]) {
                command(Command("test") {
                    let plain = try await step("Plain") { 1 }
                    let allowed = await step("Allowed", failure: .allowed) { 2 }
                    value = plain + (allowed ?? 0)
                })
            }

            #expect(result.exitCode == 0)
            #expect(value == 3)
        }
    }
}
