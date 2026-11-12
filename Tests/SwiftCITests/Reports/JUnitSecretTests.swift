@testable import SwiftCI
@testable import SwiftCITestSupport
import Testing

extension GlobalStateTests {
    /// Registered secrets are masked in the JUnit XML, as in every other output. It changes the secret registry, so it is
    /// not part of `JUnitTests`.
    @Suite(.serialized) struct JUnitSecretTests {
        @Test func registeredSecretIsMaskedInEveryNameAndMessage() {
            let restore = isolatedGlobalState()
            defer { restore() }
            _ = Secret(value: "s3cret-&-token")
            let report = TestReport(suites: [
                TestSuite(name: "Suite s3cret-&-token", cases: [
                    TestCase(className: "Class s3cret-&-token", name: "test s3cret-&-token", duration: 0, result: .failed(messages: ["got s3cret-&-token\nmore"])),
                    TestCase(className: "Class", name: "skipped", duration: 0, result: .skipped(message: "because s3cret-&-token")),
                ]),
            ])

            let xml = JUnit.xml(for: report)

            #expect(!xml.contains("s3cret"))
            #expect(!xml.contains("token"))
            #expect(xml.contains("Suite \(SecretRegistry.mask)"))
            #expect(xml.contains("<failure message=\"got \(SecretRegistry.mask)\">got \(SecretRegistry.mask)\nmore</failure>"))
            #expect(xml.contains("<skipped message=\"because \(SecretRegistry.mask)\"/>"))
        }
    }
}
