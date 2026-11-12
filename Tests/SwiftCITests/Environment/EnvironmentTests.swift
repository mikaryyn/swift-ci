@testable import SwiftCITestSupport
import SwiftCI
import SwiftCITesting
import Testing

extension GlobalStateTests {
    @Suite struct EnvironmentTests {
        @Test func optionalReturnsTheValueOrNil() async {
            await SwiftCITest.withMocks(["MYAPP_SCHEME": "MyApp"]) {
                #expect(Environment.optional("MYAPP_SCHEME") == "MyApp")
                #expect(Environment.optional("MYAPP_MISSING") == nil)
            }
        }

        @Test func emptyVariableCountsAsUnset() async {
            await SwiftCITest.withMocks(["MYAPP_EMPTY": ""]) {
                #expect(Environment.optional("MYAPP_EMPTY") == nil)
                #expect(Environment.optional("MYAPP_EMPTY", fallback: "42") == "42")
            }
        }

        @Test func fallbackAppliesOnlyToUnsetVariables() async {
            await SwiftCITest.withMocks(["MYAPP_BUILD": "7"]) {
                #expect(Environment.optional("MYAPP_BUILD", fallback: "42") == "7")
                #expect(Environment.optional("MYAPP_MISSING", fallback: "42") == "42")
            }
        }

        @Test func requiredReturnsTheValue() async throws {
            try await SwiftCITest.withMocks(["MYAPP_SCHEME": "MyApp"]) {
                let value = try Environment.required("MYAPP_SCHEME")
                #expect(value == "MyApp")
            }
        }

        @Test(arguments: [["MYAPP_SCHEME": ""], [:]])
        func requiredThrowsForUnsetAndEmptyVariables(environment: [String: String]) async {
            await SwiftCITest.withMocks(environment) {
                let error = await thrownError { _ = try Environment.required("MYAPP_SCHEME") }
                #expect(error?.message == "Required environment variable MYAPP_SCHEME is not set or is empty.")
            }
        }
    }
}
