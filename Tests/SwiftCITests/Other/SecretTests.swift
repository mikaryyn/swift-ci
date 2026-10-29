@testable import SwiftCI
@testable import SwiftCITestSupport
import Foundation
import SwiftCITesting
import Testing

/// Sets a real environment variable while `body` runs, then restores the previous value, or removes the variable if it
/// had none.
func withRealEnvironmentVariable<T>(_ name: String, _ value: String, _ body: () -> T) -> T {
    let original = getenv(name).map { String(cString: $0) }
    setenv(name, value, 1)
    defer {
        if let original {
            setenv(name, original, 1)
        } else {
            unsetenv(name)
        }
    }
    return body()
}

/// Records each call with its name and arguments. It implements every requirement of `Log` itself, so each one is
/// checked by the forwarding test.
final class RecordingLog: Log {
    var calls: [String] = []

    func callAsFunction(_ line: String) { calls.append("line:\(line)") }
    func completion(_ line: String) { calls.append("completion:\(line)") }
    func success(_ line: String) { calls.append("success:\(line)") }
    func warning(_ line: String) { calls.append("warning:\(line)") }
    func error(_ line: String) { calls.append("error:\(line)") }
    func enteringStep(name: String, depth: Int) throws { calls.append("enteringStep:\(name)") }
    func finishedStep(name: String, duration: TimeInterval, depth: Int) throws { calls.append("finishedStep:\(name)") }
    func failedStep(name: String, depth: Int) throws { calls.append("failedStep:\(name)") }
    func allowedFailedStep(name: String, depth: Int) throws { calls.append("allowedFailedStep:\(name)") }
    func skippedStep(name: String, reason: String, depth: Int) throws {
        calls.append("skippedStep:\(name)|\(reason)")
    }
    func lines(title: String, lines: String) { calls.append("linesText:\(title)|\(lines)") }
    func lines(title: String, lines: [String]) { calls.append("linesArray:\(title)|\(lines.joined(separator: ","))") }
}

extension GlobalStateTests {
    /// Secrets, the masking function, and every writer that must mask. The registry and the secret environment are
    /// restored after each test.
    @Suite(.serialized) struct SecretTests {
        static let value = "s3cr3t-value"

        // MARK: Declaring and validating

        @Test func declaringASecretDoesNotThrowWhenTheVariableIsMissing() async throws {
            let restore = secretsSetUp()
            defer { restore() }

            let secret = Secret("SWIFTCI_TEST_MISSING")

            let error = await thrownError { _ = try secret.revealedValue() }
            #expect(error?.code == .usage)
            #expect(error?.message.contains("SWIFTCI_TEST_MISSING") == true)
        }

        @Test func emptyVariableIsAUsageErrorAtFirstUse() async throws {
            let restore = secretsSetUp(["SWIFTCI_TEST_EMPTY": ""])
            defer { restore() }
            let secret = Secret("SWIFTCI_TEST_EMPTY")

            let error = await thrownError { _ = try secret.revealedValue() }
            #expect(error?.code == .usage)
            #expect(error?.message.contains("SWIFTCI_TEST_EMPTY") == true)
        }

        /// A short value is a usage error at first use, but it is masked from the declaration on.
        @Test func shortValueIsAUsageErrorButIsMaskedBeforeFirstUse() async throws {
            let restore = secretsSetUp(["SWIFTCI_TEST_SHORT": "abc"])
            defer { restore() }
            let secret = Secret("SWIFTCI_TEST_SHORT")

            #expect(SecretRegistry.redact("x abc y") == "x \(SecretRegistry.mask) y")
            let error = await thrownError { _ = try secret.revealedValue() }
            #expect(error?.code == .usage)
            #expect(error?.message.contains("SWIFTCI_TEST_SHORT") == true)
            #expect(error?.message.contains("abc") == false)
        }

        // MARK: Secret.optional

        @Test func optionalIsNilWhenTheVariableIsUnset() throws {
            let restore = secretsSetUp()
            defer { restore() }

            #expect(Secret.optional("SWIFTCI_TEST_OPTIONAL_UNSET") == nil)
        }

        @Test func optionalIsTheSecretWhenTheVariableIsSet() async throws {
            let restore = secretsSetUp(["SWIFTCI_TEST_OPTIONAL_SET": Self.value])
            defer { restore() }

            let secret = try #require(Secret.optional("SWIFTCI_TEST_OPTIONAL_SET"))
            #expect(try secret.revealedValue() == Self.value)
            #expect(SecretRegistry.redact("x \(Self.value) y") == "x \(SecretRegistry.mask) y")
        }

        /// An empty variable counts as unset, as in `Environment.required`.
        @Test func optionalIsNilWhenTheVariableIsEmpty() throws {
            let restore = secretsSetUp(["SWIFTCI_TEST_OPTIONAL_EMPTY": ""])
            defer { restore() }

            #expect(Secret.optional("SWIFTCI_TEST_OPTIONAL_EMPTY") == nil)
        }

        // MARK: Secret.redact

        @Test func redactMasksARegisteredValueAndLeavesOtherText() throws {
            let restore = secretsSetUp()
            defer { restore() }
            _ = Secret(value: "redact-VALUE-1")

            #expect(Secret.redact("token redact-VALUE-1 end") == "token \(SecretRegistry.mask) end")
            #expect(Secret.redact("plain text") == "plain text")
        }

        @Test func validValueIsRevealed() async throws {
            let restore = secretsSetUp(["SWIFTCI_TEST_VALID": Self.value])
            defer { restore() }

            #expect(try Secret("SWIFTCI_TEST_VALID").revealedValue() == Self.value)
        }

        @Test func derivedSecretIsValidAndMasked() throws {
            let restore = secretsSetUp()
            defer { restore() }

            let secret = Secret(value: "token-value-123")

            #expect(try secret.revealedValue() == "token-value-123")
            #expect(SecretRegistry.redact("token-value-123") == SecretRegistry.mask)
        }

        // MARK: Descriptions and reflection

        @Test func interpolationDescriptionsAndDumpShowNoPartOfTheValue() throws {
            let restore = secretsSetUp()
            defer { restore() }
            let secret = Secret(value: Self.value)

            let interpolated = "\(secret)"
            let described = String(describing: secret)
            let reflected = String(reflecting: secret)
            var dumped = ""
            dump(secret, to: &dumped)

            for text in [interpolated, described, reflected, dumped] {
                #expect(!text.contains("3cr3"))
            }
            #expect(interpolated == SecretRegistry.mask)
            #expect(described == SecretRegistry.mask)
            #expect(reflected == SecretRegistry.mask)
            #expect(dumped.contains("value:"))
            #expect(dumped.contains(SecretRegistry.mask))
        }

        // MARK: Registry and masking

        @Test func registeredValueIsMaskedInsideALongerLine() {
            let restore = secretsSetUp()
            defer { restore() }
            _ = Secret(value: Self.value)

            #expect(SecretRegistry.redact("login with \(Self.value) now") == "login with \(SecretRegistry.mask) now")
        }

        @Test func percentEncodedFormsWithReservedSpacesAndNonASCIIAreMasked() {
            let restore = secretsSetUp()
            defer { restore() }
            let value = "a b/c?d=é&e+f"
            _ = Secret(value: value)

            #expect(SecretRegistry.percentEncoded(value, uppercaseHex: true) == "a%20b%2Fc%3Fd%3D%C3%A9%26e%2Bf")
            #expect(SecretRegistry.percentEncoded(value, uppercaseHex: false) == "a%20b%2fc%3fd%3d%c3%a9%26e%2bf")
            #expect(SecretRegistry.redact("x a%20b%2Fc%3Fd%3D%C3%A9%26e%2Bf y") == "x \(SecretRegistry.mask) y")
            #expect(SecretRegistry.redact("x a%20b%2fc%3fd%3d%c3%a9%26e%2bf y") == "x \(SecretRegistry.mask) y")
            #expect(SecretRegistry.redact("x \(value) y") == "x \(SecretRegistry.mask) y")
        }

        /// Form encoding (`+` for a space) and base64 are not masked. Only the RFC 3986 form is. The base64 text of a
        /// header that carries the secret stays visible, so the test checks that it is unchanged.
        @Test func formEncodingAndBase64AreNotMasked() {
            let restore = secretsSetUp()
            defer { restore() }
            _ = Secret(value: "a b")
            _ = Secret(value: "s3cr3t-value")
            let base64 = Data("user:s3cr3t-value".utf8).base64EncodedString()
            #expect(!base64.contains("s3cr3t"))

            #expect(SecretRegistry.redact("a+b") == "a+b")
            #expect(SecretRegistry.redact("Authorization: Basic \(base64)") == "Authorization: Basic \(base64)")
        }

        /// The defaults add text after `RedactingLog` has masked the arguments. The console boundary masks the final
        /// line too. Here the value is "Warning", which the default `warning` adds around the message as `<Warning>`.
        @Test func consoleMasksValuesThatOnlyAppearAfterDefaultFormatting() {
            let restore = secretsSetUp()
            defer { restore() }
            _ = Secret(value: "Warning")
            let original = LogImpl.printLine
            defer { LogImpl.printLine = original }
            var printed: [String] = []
            LogImpl.printLine = { printed.append($0) }
            register(Log.self, LogImpl())
            @Use var log: Log

            log.warning("hello")

            #expect(printed.count == 1)
            #expect(printed.allSatisfy { !$0.contains("Warning") })
            #expect(printed.allSatisfy { $0.contains("<\(SecretRegistry.mask)>") })
        }

        /// A value made only of unreserved characters has no encoded form that differs from it.
        @Test func unreservedValueIsMaskedOnce() {
            let restore = secretsSetUp()
            defer { restore() }
            _ = Secret(value: "abc-_.~1")

            #expect(SecretRegistry.patterns == ["abc-_.~1"])
        }

        @Test func multiLineValueMasksEachLine() {
            let restore = secretsSetUp()
            defer { restore() }
            _ = Secret(value: "first-line-x\nsecond-line-y")

            #expect(SecretRegistry.redact("first-line-x") == SecretRegistry.mask)
            #expect(SecretRegistry.redact("k second-line-y") == "k \(SecretRegistry.mask)")
            #expect(SecretRegistry.redact("first-line-x\nsecond-line-y") == SecretRegistry.mask)
        }

        /// A secret that contains another secret is masked as a whole, whichever was registered first.
        @Test func longerSecretContainingAnotherIsMaskedAsAWhole() {
            let restore = secretsSetUp()
            defer { restore() }
            _ = Secret(value: "abc")
            _ = Secret(value: "abcdef")

            #expect(SecretRegistry.redact("abcdef") == SecretRegistry.mask)
            #expect(SecretRegistry.redact("x abcdef y") == "x \(SecretRegistry.mask) y")
        }

        @Test func longerSecretRegisteredFirstIsStillMaskedAsAWhole() {
            let restore = secretsSetUp()
            defer { restore() }
            _ = Secret(value: "abcdef")
            _ = Secret(value: "abc")

            #expect(SecretRegistry.redact("abcdef") == SecretRegistry.mask)
        }

        @Test func resetForgetsEveryValue() {
            let restore = secretsSetUp()
            defer { restore() }
            _ = Secret(value: Self.value)
            SecretRegistry.reset()

            #expect(SecretRegistry.redact(Self.value) == Self.value)
        }

        /// Ten secrets and 10,000 lines. There is no strict timing check. The test only shows that the masking stays
        /// usable at this size.
        @Test func maskingTenSecretsOverTenThousandLinesStaysReasonable() {
            let restore = secretsSetUp()
            defer { restore() }
            for number in 0..<10 {
                _ = Secret(value: "secret-number-\(number)-value")
            }
            let lines = (0..<10_000).map { "line \($0) has secret-number-\($0 % 10)-value and more text" }

            let masked = lines.map { SecretRegistry.redact($0) }

            #expect(masked.count == 10_000)
            #expect(masked[3] == "line 3 has \(SecretRegistry.mask) and more text")
        }

        // MARK: The console

        @Test func registeredLogReceivesOnlyMaskedTextThroughEveryRequirement() throws {
            let restore = secretsSetUp()
            defer { restore() }
            _ = Secret(value: Self.value)
            let recording = RecordingLog()
            register(Log.self, recording)
            @Use var log: Log

            log("line \(Self.value)")
            log.completion("completion \(Self.value)")
            log.success("success \(Self.value)")
            log.warning("warning \(Self.value)")
            log.error("error \(Self.value)")
            try log.enteringStep(name: "step \(Self.value)", depth: 1)
            try log.finishedStep(name: "step \(Self.value)", duration: 1.5, depth: 1)
            try log.failedStep(name: "step \(Self.value)", depth: 1)
            try log.allowedFailedStep(name: "step \(Self.value)", depth: 1)
            try log.skippedStep(name: "step \(Self.value)", reason: "reason \(Self.value)", depth: 1)
            log.lines(title: "title \(Self.value)", lines: "text \(Self.value)")
            log.lines(title: "title \(Self.value)", lines: ["one \(Self.value)", "two"])

            let mask = SecretRegistry.mask
            #expect(recording.calls == [
                "line:line \(mask)",
                "completion:completion \(mask)",
                "success:success \(mask)",
                "warning:warning \(mask)",
                "error:error \(mask)",
                "enteringStep:step \(mask)",
                "finishedStep:step \(mask)",
                "failedStep:step \(mask)",
                "allowedFailedStep:step \(mask)",
                "skippedStep:step \(mask)|reason \(mask)",
                "linesText:title \(mask)|text \(mask)",
                "linesArray:title \(mask)|one \(mask),two",
            ])
            #expect(recording.calls.allSatisfy { !$0.contains(Self.value) })
        }

        /// `register(Log.self, …)` stores the logger as a `RedactingLog`, and the mock is inside it.
        @Test func registerWrapsTheLoggerInARedactingLog() throws {
            let restore = secretsSetUp()
            defer { restore() }
            let mock = LogMock()
            register(Log.self, mock)

            @Use var log: Log
            let redacting = try #require(log as? RedactingLog)
            #expect(redacting.inner is LogMock)
        }

        /// Registering an already wrapped logger does not wrap it again.
        @Test func doubleRegistrationDoesNotDoubleWrap() throws {
            let restore = secretsSetUp()
            defer { restore() }
            let mock = LogMock()
            register(Log.self, RedactingLog(mock))

            @Use var log: Log
            let redacting = try #require(log as? RedactingLog)
            #expect(redacting.inner is LogMock)
        }

        @Test func registeredValueIsMaskedInConsoleLines() {
            let restore = secretsSetUp()
            defer { restore() }
            let (log, _) = registerToolMocks()
            _ = Secret(value: Self.value)
            @Use var logger: Log

            logger("password is \(Self.value), really")

            #expect(log.loggedLines == ["password is \(SecretRegistry.mask), really"])
        }

        /// The raw value is in the filter's output. Masking is applied after the filters, so the console still gets
        /// the mask.
        @Test func filterThatReturnsTheRawLineStillProducesMaskedOutput() async throws {
            let restore = secretsSetUp()
            defer { restore() }
            let (log, runner) = registerToolMocks()
            _ = Secret(value: Self.value)
            runner.responses = [.init(lines: [stdoutLine("token \(Self.value)")])]

            try await Tool(command: "/usr/bin/fake-tool", filters: [{ $0 }]).run()

            #expect(log.loggedLines == ["token \(SecretRegistry.mask)"])
        }

        /// A filter that adds the raw value to the line does not bypass the mask either.
        @Test func filterThatAddsTheRawValueStillProducesMaskedOutput() async throws {
            let restore = secretsSetUp()
            defer { restore() }
            let (log, runner) = registerToolMocks()
            _ = Secret(value: Self.value)
            runner.responses = [.init(lines: [stdoutLine("hello")])]

            try await Tool(command: "/usr/bin/fake-tool", filters: [{ "\($0) \(Self.value)" }]).run()

            #expect(log.loggedLines == ["hello \(SecretRegistry.mask)"])
        }

        /// The console gets masked lines, even when the value is in an error message of a failed step.
        @Test func errorMessagesAreMasked() async {
            let restore = secretsSetUp()
            defer { restore() }
            _ = Secret(value: Self.value)
            let result = await SwiftCITest.run(["error"]) {
                command(Command("error") {
                    throw BuildError(message: "Failed with \(Self.value)")
                })
            }

            let lines = result.log.map(stripANSI)
            #expect(result.exitCode == 1)
            #expect(lines.contains("<Error> Failed with \(SecretRegistry.mask)"))
            #expect(lines.allSatisfy { !$0.contains(Self.value) })
        }

        @Test func stepNamesAreMaskedOnTheConsole() async {
            let restore = secretsSetUp()
            defer { restore() }
            _ = Secret(value: Self.value)
            let result = await SwiftCITest.run(["step"]) {
                command(Command("step") {
                    try await step("Deploy \(Self.value)") { }
                })
            }

            #expect(enteredSteps(in: result.log) == ["Entering step [Deploy \(SecretRegistry.mask)]"])
            #expect(result.log.allSatisfy { !stripANSI($0).contains(Self.value) })
        }

        @Test func environmentWriteToLogMasksSecretValues() {
            let name = "SWIFTCI_TEST_WRITE_TO_LOG"
            let restore = secretsSetUp([name: "write-secret-42"])
            defer { restore() }
            let (log, _) = registerToolMocks()
            _ = Secret(name)

            withRealEnvironmentVariable(name, "write-secret-42") {
                Environment.writeToLog()
            }

            #expect(log.loggedLines.contains("\(name): \(SecretRegistry.mask)"))
            #expect(log.loggedLines.allSatisfy { !$0.contains("write-secret-42") })
        }

        // MARK: The full log

        /// Inside a running command, the full log holds the masked text of every writer: a direct write, a step
        /// name, and an error message.
        @Test func fullLogIsMaskedInsideACommand() async {
            let restore = secretsSetUp()
            defer { restore() }
            _ = Secret(value: Self.value)
            var fullLog = ""
            let result = await SwiftCITest.run(["full"]) {
                command(Command("full") {
                    try FullLog.write("direct \(Self.value)")
                    try await step("Deploy \(Self.value)") { }
                    fullLog = try readFullLog()
                })
            }

            #expect(result.exitCode == 0)
            #expect(fullLog.contains("direct \(SecretRegistry.mask)"))
            #expect(fullLog.contains("Deploy \(SecretRegistry.mask)"))
            #expect(!fullLog.contains(Self.value))
        }

        @Test func fullLogOfAFailedCommandIsMasked() async {
            let restore = secretsSetUp()
            defer { restore() }
            _ = Secret(value: Self.value)
            var fullLog = ""
            let result = await SwiftCITest.run(["failed"]) {
                command(Command("failed") {
                    do {
                        try await step("Fail") { throw BuildError(message: "Bad \(Self.value)") }
                    } catch {
                        fullLog = try readFullLog()
                    }
                })
            }

            #expect(result.exitCode == 0)
            #expect(!fullLog.contains(Self.value))
            #expect(fullLog.contains("Step [Fail] failed"))
        }
    }
}
