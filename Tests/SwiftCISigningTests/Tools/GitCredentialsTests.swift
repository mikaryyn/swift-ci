@testable import SwiftCISigning
@testable import SwiftCITestSupport
@testable import SwiftCI
import Foundation
import Testing

extension GlobalStateTests {
    /// The Git credential helper of the native match install (E11). Called directly, with the inherited environment
    /// passed in, so no clone runs and no real environment is read.
    @Suite(.serialized) struct GitCredentialsTests {
        static let host = "https://git.example.com/org/match.git"

        func resolve(
            _ url: String,
            basic: Secret? = nil,
            bearer: Secret? = nil,
            environment: [String: String] = [:]
        ) throws -> GitCredentials {
            try GitCredentialHelper.resolve(
                url: url,
                basicAuthorization: basic,
                bearerAuthorization: bearer,
                inheritedEnvironment: environment
            )
        }

        /// The revealed header of the `GIT_CONFIG_VALUE_<n>` entry, or `nil` if the entry is not a secret.
        func header(_ credentials: GitCredentials, index: Int = 0) throws -> String? {
            guard case .secret(let secret)? = credentials.environment["GIT_CONFIG_VALUE_\(index)"] else { return nil }
            return try secret.revealedValue()
        }

        func base64(_ text: String) -> String {
            Data(text.utf8).base64EncodedString()
        }

        @Test func userinfoIsStrippedAndBecomesABasicHeader() throws {
            let restore = secretsSetUp()
            defer { restore() }

            let credentials = try resolve("https://ci-user:ci-token-VALUE@git.example.com/org/match.git")

            #expect(credentials.url == Self.host)
            #expect(!credentials.url.contains("ci-user"))
            #expect(!credentials.url.contains("ci-token-VALUE"))
            #expect(credentials.environment["GIT_CONFIG_COUNT"] == .text("1"))
            #expect(credentials.environment["GIT_CONFIG_KEY_0"] == .text("http.\(Self.host).extraHeader"))
            #expect(try header(credentials) == "Authorization: Basic \(base64("ci-user:ci-token-VALUE"))")
            #expect(SecretRegistry.redact("ci-token-VALUE") == SecretRegistry.mask)
        }

        @Test func tokenOnlyUserinfoIsTheUserWithAnEmptyPassword() throws {
            let restore = secretsSetUp()
            defer { restore() }

            let credentials = try resolve("https://ci-token-ONLY@git.example.com/org/match.git")

            #expect(credentials.url == Self.host)
            #expect(try header(credentials) == "Authorization: Basic \(base64("ci-token-ONLY:"))")
            #expect(SecretRegistry.redact("ci-token-ONLY") == SecretRegistry.mask)
        }

        /// The user and password are percent-decoded before they are encoded in the header.
        @Test func percentEncodedUserinfoIsDecoded() throws {
            let restore = secretsSetUp()
            defer { restore() }

            let credentials = try resolve("https://us%40er:p%2Fa%20ss@git.example.com/org/match.git")

            #expect(credentials.url == Self.host)
            #expect(try header(credentials) == "Authorization: Basic \(base64("us@er:p/a ss"))")
            #expect(SecretRegistry.redact("p/a ss") == SecretRegistry.mask)
        }

        @Test func percentEncodedPathIsKeptAsItIs() throws {
            let restore = secretsSetUp()
            defer { restore() }

            let credentials = try resolve("https://ci-user:ci-token-VALUE@git.example.com/org%20x/match.git")

            #expect(credentials.url == "https://git.example.com/org%20x/match.git")
        }

        @Test func basicAuthorizationBecomesABasicHeader() throws {
            let restore = secretsSetUp()
            defer { restore() }
            let basic = Secret(value: "dXNlcjp0b2tlbi1WQUxVRQ==")

            let credentials = try resolve(Self.host, basic: basic)

            #expect(credentials.url == Self.host)
            #expect(try header(credentials) == "Authorization: Basic dXNlcjp0b2tlbi1WQUxVRQ==")
            #expect(credentials.environment["GIT_CONFIG_KEY_0"] == .text("http.\(Self.host).extraHeader"))
        }

        @Test func bearerAuthorizationBecomesABearerHeader() throws {
            let restore = secretsSetUp()
            defer { restore() }

            let credentials = try resolve(Self.host, bearer: Secret(value: "bearer-VALUE-9"))

            #expect(try header(credentials) == "Authorization: Bearer bearer-VALUE-9")
        }

        @Test func twoSourcesAreAUsageErrorNamingBothVariables() async {
            let restore = secretsSetUp()
            defer { restore() }

            let urlAndBasic = await thrownError {
                _ = try resolve("https://ci-user:ci-token-VALUE@git.example.com/org/match.git", basic: Secret(value: "b64-VALUE-1"))
            }
            #expect(urlAndBasic?.code == .usage)
            #expect(urlAndBasic?.message.contains("MATCH_GIT_URL") == true)
            #expect(urlAndBasic?.message.contains("MATCH_GIT_BASIC_AUTHORIZATION") == true)

            let basicAndBearer = await thrownError {
                _ = try resolve(Self.host, basic: Secret(value: "b64-VALUE-1"), bearer: Secret(value: "bearer-VALUE-2"))
            }
            #expect(basicAndBearer?.code == .usage)
            #expect(basicAndBearer?.message.contains("MATCH_GIT_BASIC_AUTHORIZATION") == true)
            #expect(basicAndBearer?.message.contains("MATCH_GIT_BEARER_AUTHORIZATION") == true)
            #expect(basicAndBearer?.message.contains("VALUE") == false)
        }

        /// The new entry is appended after the inherited entries, and the count is updated.
        @Test func entryIsAppendedAfterAnInheritedGitConfigCount() throws {
            let restore = secretsSetUp()
            defer { restore() }

            let credentials = try resolve(
                "https://ci-user:ci-token-VALUE@git.example.com/org/match.git",
                environment: ["GIT_CONFIG_COUNT": "2"]
            )

            #expect(credentials.environment["GIT_CONFIG_COUNT"] == .text("3"))
            #expect(credentials.environment["GIT_CONFIG_KEY_2"] == .text("http.\(Self.host).extraHeader"))
            #expect(try header(credentials, index: 2) == "Authorization: Basic \(base64("ci-user:ci-token-VALUE"))")
            #expect(credentials.environment["GIT_CONFIG_KEY_0"] == nil)
        }

        @Test func nonNumericInheritedGitConfigCountIsAUsageErrorNamingTheVariable() async {
            let restore = secretsSetUp()
            defer { restore() }

            for value in ["two", "-1", ""] {
                let error = await thrownError {
                    _ = try resolve(
                        "https://ci-user:ci-token-VALUE@git.example.com/org/match.git",
                        environment: ["GIT_CONFIG_COUNT": value]
                    )
                }
                #expect(error?.code == .usage)
                #expect(error?.message.contains("GIT_CONFIG_COUNT") == true)
            }
        }

        /// An scp-style SSH URL is not a web URL. It passes through unchanged, with no header and no environment.
        @Test func scpStyleURLPassesThroughUnchanged() throws {
            let restore = secretsSetUp()
            defer { restore() }

            let credentials = try resolve("git@git.example.com:org/match.git")

            #expect(credentials.url == "git@git.example.com:org/match.git")
            #expect(credentials.environment.isEmpty)
        }

        /// The user of an SSH URL is an SSH user name, not a credential, so it is kept.
        @Test func sshURLWithUserPassesThroughUnchanged() throws {
            let restore = secretsSetUp()
            defer { restore() }

            let credentials = try resolve("ssh://git@git.example.com/org/match.git")

            #expect(credentials.url == "ssh://git@git.example.com/org/match.git")
            #expect(credentials.environment.isEmpty)
        }

        @Test func httpsURLWithoutCredentialsPassesThroughUnchanged() throws {
            let restore = secretsSetUp()
            defer { restore() }

            let credentials = try resolve(Self.host, environment: ["GIT_CONFIG_COUNT": "abc"])

            #expect(credentials.url == Self.host)
            #expect(credentials.environment.isEmpty)
        }

        @Test func basicAuthorizationForAnSSHURLIsAUsageError() async {
            let restore = secretsSetUp()
            defer { restore() }

            let error = await thrownError {
                _ = try resolve("git@git.example.com:org/match.git", basic: Secret(value: "b64-VALUE-3"))
            }

            #expect(error?.code == .usage)
            #expect(error?.message.contains("MATCH_GIT_BASIC_AUTHORIZATION") == true)
        }

        /// A missing secret is a usage error at first use, and the name of the variable is shown.
        @Test func missingBasicAuthorizationIsAUsageError() async {
            let restore = secretsSetUp()
            defer { restore() }

            let error = await thrownError {
                _ = try resolve(Self.host, basic: Secret("SWIFTCI_TEST_MISSING_BASIC"))
            }

            #expect(error?.code == .usage)
            #expect(error?.message.contains("SWIFTCI_TEST_MISSING_BASIC") == true)
        }

        // MARK: URL rules

        /// The scheme and the host are case-insensitive, so an upper-case HTTPS URL gets the same header.
        @Test func upperCaseSchemeIsHandledAsHTTPS() throws {
            let restore = secretsSetUp()
            defer { restore() }

            let credentials = try resolve("HTTPS://ci-user:ci-token-VALUE@git.example.com/org/match.git")

            #expect(credentials.url == "HTTPS://git.example.com/org/match.git")
            #expect(try header(credentials) == "Authorization: Basic \(base64("ci-user:ci-token-VALUE"))")
        }

        /// A password in the user information of a non-HTTP(S) URL is refused, and the message shows no value.
        @Test func passwordInSSHURLIsRefusedWithoutShowingIt() async {
            let restore = secretsSetUp()
            defer { restore() }

            let error = await thrownError {
                _ = try resolve("ssh://user:ssh-password-VALUE@git.example.com/org/match.git")
            }

            #expect(error?.code == .usage)
            #expect(error?.message.contains("MATCH_GIT_URL") == true)
            #expect(error?.message.contains("ssh-password-VALUE") == false)
            #expect(error?.message.contains("user") == false)
        }

        /// A password in an scp-style address is refused too, because it has no scheme to check.
        @Test func passwordInScpStyleAddressIsRefusedWithoutShowingIt() async {
            let restore = secretsSetUp()
            defer { restore() }

            let error = await thrownError {
                _ = try resolve("user:scp-password-VALUE@git.example.com:org/match.git")
            }

            #expect(error?.code == .usage)
            #expect(error?.message.contains("scp-password-VALUE") == false)
        }

        /// An SSH user name without a password passes through unchanged, in both forms.
        @Test func sshUserWithoutPasswordPassesThroughUnchanged() throws {
            let restore = secretsSetUp()
            defer { restore() }

            #expect(try resolve("ssh://deploy@git.example.com/org/match.git").url == "ssh://deploy@git.example.com/org/match.git")
            #expect(try resolve("deploy@git.example.com:org/match.git").url == "deploy@git.example.com:org/match.git")
            #expect(try resolve("git@git.example.com:org/match.git").environment.isEmpty)
        }

        /// An http(s)-looking URL that URLComponents cannot parse is refused: it is not sent unchecked.
        @Test func unparseableHTTPSURLFailsClosedWithoutShowingIt() async {
            let restore = secretsSetUp()
            defer { restore() }

            for url in ["https://ci-user:bad pass-VALUE@git.example.com/org/match.git", "https://", "http:///org/match.git", "HTTPS://"] {
                let error = await thrownError {
                    _ = try resolve(url)
                }
                #expect(error?.code == .usage, "\(url)")
                #expect(error?.message.contains("VALUE") == false, "\(url)")
                #expect(error?.message.contains("ci-user") == false, "\(url)")
            }
        }

        // MARK: GIT_CONFIG_COUNT limits

        /// Int.max cannot take one more entry. It is a usage error, not a trap.
        @Test func inheritedCountAtIntMaxIsAUsageError() async {
            let restore = secretsSetUp()
            defer { restore() }

            let error = await thrownError {
                _ = try resolve(
                    "https://ci-user:ci-token-VALUE@git.example.com/org/match.git",
                    environment: ["GIT_CONFIG_COUNT": String(Int.max)]
                )
            }

            #expect(error?.code == .usage)
            #expect(error?.message.contains("GIT_CONFIG_COUNT") == true)
        }

        /// The largest count that leaves room for one more entry is accepted.
        @Test func inheritedCountOneBelowIntMaxIsAccepted() throws {
            let restore = secretsSetUp()
            defer { restore() }

            let credentials = try resolve(
                "https://ci-user:ci-token-VALUE@git.example.com/org/match.git",
                environment: ["GIT_CONFIG_COUNT": String(Int.max - 1)]
            )

            #expect(credentials.environment["GIT_CONFIG_COUNT"] == .text(String(Int.max)))
        }

        /// Negative counts and numbers too large for Int are usage errors.
        @Test func negativeAndOutOfRangeCountsAreUsageErrors() async {
            let restore = secretsSetUp()
            defer { restore() }

            for value in ["-1", "-9223372036854775808", "99999999999999999999999"] {
                let error = await thrownError {
                    _ = try resolve(
                        "https://ci-user:ci-token-VALUE@git.example.com/org/match.git",
                        environment: ["GIT_CONFIG_COUNT": value]
                    )
                }
                #expect(error?.code == .usage, "\(value)")
                #expect(error?.message.contains("GIT_CONFIG_COUNT") == true, "\(value)")
            }
        }
    }
}
