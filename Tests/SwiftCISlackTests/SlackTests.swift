@testable import SwiftCISlack
@testable import SwiftCITestSupport
@testable import SwiftCI
import Foundation
import SwiftCITesting
import Testing

extension GlobalStateTests {
    /// The logged form of a Slack request, built without a network request. The request body is checked too, to show
    /// that it still carries the real value.
    @Suite(.serialized) struct SlackTests {
        /// Contains a quote and a backslash, which JSON escapes.
        static let secret = "pa\"ss\\word"
        static let jsonEscaped = "pa\\\"ss\\\\word"

        func makeMessage() -> [String: Any] {
            let percentEncoded = SecretRegistry.percentEncoded(Self.secret, uppercaseHex: true)
            return [
                "blocks": [
                    [
                        "type": "section",
                        "text": ["type": "mrkdwn", "text": "login \(Self.secret) now"],
                    ],
                    [
                        "type": "actions",
                        "elements": [[
                            "type": "button",
                            "text": ["type": "plain_text", "text": "Open \(Self.secret)"],
                            "url": "https://hooks.example.com/open?key=\(percentEncoded)&raw=\(Self.secret)",
                        ]],
                    ],
                ],
            ]
        }

        /// Raw values, JSON-escaped values and percent-encoded values are all masked in the logged request.
        @Test func loggedRequestMasksEscapedAndPercentEncodedValues() {
            let restore = secretsSetUp()
            defer { restore() }
            _ = Secret(value: Self.secret)

            let logged = Slack.logRepresentation(of: makeMessage())

            #expect(logged.contains("login \(SecretRegistry.mask) now"))
            #expect(logged.contains("Open \(SecretRegistry.mask)"))
            #expect(!logged.contains(Self.secret))
            #expect(!logged.contains(Self.jsonEscaped))
            #expect(!logged.contains("pa%22ss%5Cword"))
            #expect(!logged.contains("pa%22ss%5Cword".lowercased()))
        }

        /// The request body is not changed. It still carries the escaped value that Slack receives.
        @Test func requestBodyStillCarriesTheRealValue() {
            let restore = secretsSetUp()
            defer { restore() }
            _ = Secret(value: Self.secret)

            let body = String(decoding: Slack.requestBody(for: makeMessage()), as: UTF8.self)

            #expect(body.contains(Self.jsonEscaped))
            #expect(!body.contains(SecretRegistry.mask))
        }

        /// An invalid webhook secret is a usage error. It is thrown before any request, so no network is used: the
        /// secret is missing, and the reveal fails first.
        @Test func sendWithAnInvalidWebhookSecretIsAUsageErrorBeforeAnyRequest() async {
            let restore = secretsSetUp()
            defer { restore() }
            let (_, runner) = registerToolMocks()
            _ = runner

            let error = await thrownError {
                try await Slack(webhookURL: Secret("SWIFTCI_TEST_MISSING_WEBHOOK")).send(text: "hello", fields: [], buttons: [])
            }

            #expect(error?.code == .usage)
            #expect(error?.message.contains("SWIFTCI_TEST_MISSING_WEBHOOK") == true)
        }

        /// Without buttons the message has no actions block, because Slack rejects an actions block with no elements.
        @Test func messageWithoutButtonsHasNoActionsBlock() {
            let message = Slack(webhookURL: Secret("SWIFTCI_TEST_UNUSED_WEBHOOK"))
                .message(header: "", text: "hello", fields: [], buttons: [])
            let blocks = message["blocks"] as? [[String: Any]] ?? []

            #expect(blocks.compactMap { $0["type"] as? String } == ["section"])
        }

        /// With one button the message has an actions block that holds that button.
        @Test func messageWithOneButtonHasAnActionsBlock() {
            let button = Slack.Button(text: "Open", url: "https://hooks.example.com/open")
            let message = Slack(webhookURL: Secret("SWIFTCI_TEST_UNUSED_WEBHOOK"))
                .message(header: "", text: "hello", fields: [], buttons: [button])
            let blocks = message["blocks"] as? [[String: Any]] ?? []

            #expect(blocks.compactMap { $0["type"] as? String } == ["section", "actions"])
            let elements = blocks.last?["elements"] as? [[String: Any]] ?? []
            #expect(elements.count == 1)
            #expect(elements.first?["url"] as? String == "https://hooks.example.com/open")
        }

        /// A value without characters that JSON escapes is masked as before.
        @Test func plainValueIsMaskedInTheLoggedRequest() {
            let restore = secretsSetUp()
            defer { restore() }
            _ = Secret(value: "plain-token-1")
            let message: [String: Any] = ["text": "token plain-token-1", "fields": [["text": "plain-token-1"]]]

            let logged = Slack.logRepresentation(of: message)

            #expect(!logged.contains("plain-token-1"))
            #expect(logged.contains(SecretRegistry.mask))
        }
    }
}
