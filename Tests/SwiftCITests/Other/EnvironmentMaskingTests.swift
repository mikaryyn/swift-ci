@testable import SwiftCI
import SwiftCITesting
import Testing

@Suite struct EnvironmentMaskingTests {
    @Test(arguments: [
        "MATCH_PASSWORD", "JENKINS_PASSWORD", "keychain_password", "DB_PASSWD", "SIGNING_PASSPHRASE",
        "CLIENT_SECRET", "SECRETS", "GITLAB_API_TOKEN", "GITHUBTOKEN", "ACCESS_TOKENS", "API_KEY", "MYAPIKEY",
        "PRIVATE_KEY", "PRIVATE_KEY_PEM", "SSH_PRIVATEKEY", "SMTP_PASS", "CARD_PIN", "GIT_AUTH", "SENTRY_DSN",
        "SESSION_COOKIE", "AWS_CREDENTIALS", "PROXY_AUTHORIZATION", "SLACK_WEBHOOK_URL", "KEY",
    ])
    func secretNamesAreMasked(name: String) {
        #expect(EnvironmentMasking.isSecretName(name))
        #expect(EnvironmentMasking.masked(name: name, value: "plain-value") == SecretRegistry.mask)
    }

    @Test(arguments: [
        "PATH", "HOME", "PWD", "OLDPWD", "SSH_AUTH_SOCK", "KEYCHAIN_NAME", "PASSENGER_COUNT", "TOKENIZER_PATH",
        "ASC_KEY_ID", "ASC_KEY_ISSUER_ID", "KEY_PATH", "PRIVATE_KEY_PATH", "SIGNING_KEY_FILE", "API_KEY_NAME",
        "MONKEY", "PINNED_VERSION", "AUTHOR", "GIT_COMMIT", "BUILD_ID",
    ])
    func otherNamesAreShown(name: String) {
        #expect(!EnvironmentMasking.isSecretName(name))
        #expect(EnvironmentMasking.masked(name: name, value: "plain-value") == "plain-value")
    }

    @Test(arguments: [
        "ghp_abcdefghijklmnopqrstuvwxyz0123456789",
        "Bearer github_pat_11ABCDEFG0abcdefghijklmnop",
        "glpat-abcdefghijklmnopqrst",
        "xoxb-1234567890-abcdefghij",
        "https://hooks.slack.com/services/T000/B000/XXXX",
        "AKIAIOSFODNN7EXAMPLE",
        "-----BEGIN EC PRIVATE KEY-----\nMHcCAQEE\n-----END EC PRIVATE KEY-----",
        "eyJhbGciOiJFUzI1NiJ9.eyJpc3MiOiJ4In0.c2lnbmF0dXJl",
    ])
    func secretFormatsAreMaskedUnderAnyName(value: String) {
        #expect(EnvironmentMasking.masked(name: "SOME_SETTING", value: value) == SecretRegistry.mask)
    }

    @Test(arguments: [
        "0123456789abcdef0123456789abcdef01234567",  // a commit hash
        "3F2504E0-4F89-11D3-9A0C-0305E82C3301",  // a UUID
        "/Users/example/Library/Keychains/login.keychain-db",
        "https://git.example.com/group/project.git",
        "https://user@git.example.com/group/project.git",
    ])
    func ordinaryValuesAreShown(value: String) {
        #expect(EnvironmentMasking.masked(name: "SOME_SETTING", value: value) == value)
    }

    @Test func urlPasswordIsMaskedAndTheRestIsShown() {
        let value = "https://user:pa55word@git.example.com/certificates.git"

        #expect(EnvironmentMasking.masked(name: "MATCH_GIT_URL", value: value)
            == "https://user:\(SecretRegistry.mask)@git.example.com/certificates.git")
    }

    @Test func emptyValueStaysEmpty() {
        #expect(EnvironmentMasking.masked(name: "API_TOKEN", value: "") == "")
    }

    @Test func writeToLogMasksGuessedSecretsAndRevealsOnRequest() async {
        let log = LogMock()
        await SwiftCITest.withMocks(
            ["GITLAB_API_TOKEN": "token-value-1", "ASC_KEY_ID": "ABC123", "BUILD_SETTING_KEY": "shown-on-request"],
            log: log
        ) {
            Environment.writeToLog(reveal: ["BUILD_SETTING_KEY"])
        }

        #expect(log.loggedLines.contains("GITLAB_API_TOKEN: \(SecretRegistry.mask)"))
        #expect(log.loggedLines.contains("ASC_KEY_ID: ABC123"))
        #expect(log.loggedLines.contains("BUILD_SETTING_KEY: shown-on-request"))
        #expect(log.loggedLines.allSatisfy { !$0.contains("token-value-1") })
    }
}
