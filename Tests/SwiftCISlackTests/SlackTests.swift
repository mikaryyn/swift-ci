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
            let restore = isolatedGlobalState()
            defer { restore() }
            _ = Secret(value: Self.secret)

            let logged = Slack.logRepresentation(of: makeMessage())

            #expect(logged.contains("login \(SecretRegistry.mask) now"))
            #expect(logged.contains("Open \(SecretRegistry.mask)"))
            #expect(!logged.contains(Self.secret))
            #expect(!logged.contains(Self.jsonEscaped))
            #expect(!logged.contains("pa%22ss%5Cword"))
            #expect(!logged.contains("pa%22ss%5cword"))
        }

        /// The request body is not changed. It still carries the escaped value that Slack receives.
        @Test func requestBodyStillCarriesTheRealValue() throws {
            let restore = isolatedGlobalState()
            defer { restore() }
            _ = Secret(value: Self.secret)

            let body = String(decoding: try Slack.requestBody(for: makeMessage()), as: UTF8.self)

            #expect(body.contains(Self.jsonEscaped))
            #expect(!body.contains(SecretRegistry.mask))
        }

        /// An invalid webhook secret is a usage error. It is thrown before any request, so no network is used: the
        /// secret is missing, and the reveal fails first.
        @Test func sendWithAnInvalidWebhookSecretIsAUsageErrorBeforeAnyRequest() async {
            let restore = isolatedGlobalState()
            defer { restore() }
            _ = registerToolMocks()

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

        /// Each value is shown under its title: a row of two titles, then a row of their values, also beyond the first
        /// two fields. An odd last field has its title, then its value.
        @Test func blockFieldsAlternateTitleRowsAndValueRows() {
            let fields = (1...5).map { Slack.Field(title: "T\($0)", text: "V\($0)") }
            let message = Slack(webhookURL: Secret("SWIFTCI_TEST_UNUSED_WEBHOOK"))
                .message(header: "", text: "", fields: fields, buttons: [])
            let blocks = message["blocks"] as? [[String: Any]] ?? []
            let texts = (blocks.first?["fields"] as? [[String: String]] ?? []).compactMap { $0["text"] }

            #expect(texts == ["*T1*", "*T2*", "V1", "V2", "*T3*", "*T4*", "V3", "V4", "*T5*", "V5"])
        }

        /// A Block Kit message with only a header has no section block, because Slack rejects an empty one. The header
        /// is also the top-level text that notifications show.
        @Test func blockMessageWithOnlyAHeaderHasNoSectionAndHasTopLevelText() {
            let message = Slack(webhookURL: Secret("SWIFTCI_TEST_UNUSED_WEBHOOK"))
                .message(header: "New build!", text: "", fields: [], buttons: [])
            let blocks = message["blocks"] as? [[String: Any]] ?? []

            #expect(blocks.compactMap { $0["type"] as? String } == ["header"])
            #expect(message["text"] as? String == "New build!")
        }

        /// The sender overrides are top-level keys of both formats, and are left out when not set.
        @Test func senderOverridesAreAddedOnlyWhenSet() {
            let custom = Slack(webhookURL: Secret("SWIFTCI_TEST_UNUSED_WEBHOOK"), username: "CI", iconEmoji: ":package:")
            let plain = Slack(webhookURL: Secret("SWIFTCI_TEST_UNUSED_WEBHOOK"))

            for message in [
                custom.message(header: "", text: "hello", fields: [], buttons: []),
                custom.attachmentMessage(pretext: "hello", text: "", color: nil, fields: [], buttons: []),
            ] {
                #expect(message["username"] as? String == "CI")
                #expect(message["icon_emoji"] as? String == ":package:")
            }
            let message = plain.message(header: "", text: "hello", fields: [], buttons: [])
            #expect(message["username"] == nil)
            #expect(message["icon_emoji"] == nil)
        }

        /// An attachment carries the pretext, the fallback, the color, short fields and link buttons.
        @Test func attachmentMessageHasColorFieldsAndLinkButtons() {
            let message = Slack(webhookURL: Secret("SWIFTCI_TEST_UNUSED_WEBHOOK")).attachmentMessage(
                pretext: "New build!",
                text: "",
                color: .good,
                fields: [Slack.Field(title: "Build", text: "42")],
                buttons: [Slack.Button(text: "Open", url: "https://example.com/open")]
            )
            let attachments = message["attachments"] as? [[String: Any]] ?? []
            let attachment = attachments.first ?? [:]

            #expect(attachments.count == 1)
            #expect(message["blocks"] == nil)
            #expect(attachment["pretext"] as? String == "New build!")
            #expect(attachment["fallback"] as? String == "New build!")
            #expect(attachment["text"] == nil)
            #expect(attachment["color"] as? String == "good")
            let field = (attachment["fields"] as? [[String: Any]])?.first ?? [:]
            #expect(field["title"] as? String == "Build")
            #expect(field["value"] as? String == "42")
            #expect(field["short"] as? Bool == true)
            let action = (attachment["actions"] as? [[String: Any]])?.first ?? [:]
            #expect(action["type"] as? String == "button")
            #expect(action["text"] as? String == "Open")
            #expect(action["url"] as? String == "https://example.com/open")
        }

        /// Without a color, fields and buttons, the attachment has no color, fields or actions keys.
        @Test func attachmentMessageLeavesOutEmptyParts() {
            let message = Slack(webhookURL: Secret("SWIFTCI_TEST_UNUSED_WEBHOOK"))
                .attachmentMessage(pretext: "", text: "hello", color: nil, fields: [], buttons: [])
            let attachment = (message["attachments"] as? [[String: Any]])?.first ?? [:]

            #expect(Set(attachment.keys) == ["fallback", "text"])
        }

        /// A hex color is sent as given.
        @Test func hexColorIsSentAsGiven() {
            let message = Slack(webhookURL: Secret("SWIFTCI_TEST_UNUSED_WEBHOOK"))
                .attachmentMessage(pretext: "", text: "hello", color: Slack.Color(hex: "#3bc3a3"), fields: [], buttons: [])
            let attachment = (message["attachments"] as? [[String: Any]])?.first ?? [:]

            #expect(attachment["color"] as? String == "#3bc3a3")
        }

        /// A value without characters that JSON escapes is masked in the logged request.
        @Test func plainValueIsMaskedInTheLoggedRequest() {
            let restore = isolatedGlobalState()
            defer { restore() }
            _ = Secret(value: "plain-token-1")
            let message: [String: Any] = ["text": "token plain-token-1", "fields": [["text": "plain-token-1"]]]

            let logged = Slack.logRepresentation(of: message)

            #expect(!logged.contains("plain-token-1"))
            #expect(logged.contains(SecretRegistry.mask))
        }

        static let webhook = "https://hooks.example.com/services/T000/B000/WEBHOOKTOKEN"

        /// A 2xx status is a success. The request is a POST with the JSON body, and the status and the response body are
        /// logged. The message itself is not on the console.
        @Test func successfulPostLogsTheStatusAndTheBody() async throws {
            let restore = isolatedGlobalState()
            defer { restore() }
            let client = HTTPClientMock()
            let log = LogMock()
            client.respond("POST", URL(string: Self.webhook)!, body: Data("ok".utf8))

            try await SwiftCITest.withMocks(httpClient: client, log: log) {
                try await Slack(webhookURL: Secret(value: Self.webhook)).send(text: "hello")
            }

            let request = try #require(client.requests.first)
            #expect(client.requests.count == 1)
            #expect(request.method == "POST")
            #expect(request.headers["Content-Type"] == "application/json")
            #expect(String(decoding: request.body ?? Data(), as: UTF8.self).contains("hello"))
            #expect(log.loggedLines.contains("Slack: POST webhook -> 200"))
            #expect(log.completions == ["Slack webhook response: ok"])
            #expect(log.titledLines.isEmpty)
        }

        /// A status outside 2xx throws a ``BuildError`` with the status, Slack's reason and no webhook URL. The response
        /// is not logged as a completion.
        @Test func nonSuccessStatusThrowsWithTheStatusAndSlacksReason() async throws {
            let restore = isolatedGlobalState()
            defer { restore() }
            let client = HTTPClientMock()
            let log = LogMock()
            client.respond("POST", URL(string: Self.webhook)!, status: 403, body: Data("invalid_token\n".utf8))

            let error = await SwiftCITest.withMocks(httpClient: client, log: log) {
                await thrownError {
                    try await Slack(webhookURL: Secret(value: Self.webhook)).send(text: "hello")
                }
            }

            #expect(error?.code == .failure)
            #expect(error?.message == "Slack rejected the webhook message with status 403: invalid_token. "
                + "Check that the webhook secret is still valid.")
            #expect(error?.message.contains("WEBHOOKTOKEN") == false)
            #expect(log.loggedLines.contains("Slack: POST webhook -> 403"))
            #expect(log.completions.isEmpty)
        }

        /// A 400 shows Slack's reason and points to the limits of a message.
        @Test func badRequestShowsSlacksReasonAndTheLimits() async throws {
            let restore = isolatedGlobalState()
            defer { restore() }
            let client = HTTPClientMock()
            client.respond("POST", URL(string: Self.webhook)!, status: 400, body: Data("invalid_blocks".utf8))

            let error = await SwiftCITest.withMocks(httpClient: client) {
                await thrownError {
                    try await Slack(webhookURL: Secret(value: Self.webhook)).send(text: "hello")
                }
            }

            #expect(error?.message.hasPrefix("Slack rejected the webhook message with status 400: invalid_blocks. ") == true)
            #expect(error?.message.contains("Slack's limits") == true)
        }

        /// A long response is cut, and an empty one is left out.
        @Test func statusErrorCutsALongReasonAndLeavesOutAnEmptyOne() {
            let long = String(repeating: "x", count: 300)

            #expect(Slack.statusError(500, responseText: long).message
                == "Slack rejected the webhook message with status 500: \(String(repeating: "x", count: 200))….")
            #expect(Slack.statusError(500, responseText: "").message == "Slack rejected the webhook message with status 500.")
        }

        /// A transport error throws a message without the webhook URL, and the log says that no response arrived.
        @Test func transportErrorIsThrownAndLoggedAsNoResponse() async throws {
            let restore = isolatedGlobalState()
            defer { restore() }
            let client = HTTPClientMock()
            let log = LogMock()
            client.respond("POST", URL(string: Self.webhook)!, error: BuildError(message: "SWIFTCI_TEST_TRANSPORT"))

            let error = await SwiftCITest.withMocks(httpClient: client, log: log) {
                await thrownError {
                    try await Slack(webhookURL: Secret(value: Self.webhook)).send(text: "hello")
                }
            }

            #expect(error?.message.hasPrefix("The Slack webhook could not be reached.") == true)
            #expect(error?.message.contains(Self.webhook) == false)
            #expect(log.loggedLines.contains("Slack: POST webhook -> no response"))
            #expect(log.completions.isEmpty)
        }

        /// A cancelled request is thrown as a `CancellationError`, not as an unreachable webhook.
        @Test func cancellationIsNotReportedAsUnreachable() async {
            let restore = isolatedGlobalState()
            defer { restore() }
            let client = HTTPClientMock()
            let log = LogMock()
            client.respond("POST", URL(string: Self.webhook)!, error: CancellationError())

            var cancelled = false
            do {
                try await SwiftCITest.withMocks(httpClient: client, log: log) {
                    try await Slack(webhookURL: Secret(value: Self.webhook)).send(text: "hello")
                }
            } catch is CancellationError {
                cancelled = true
            } catch {}

            #expect(cancelled)
            #expect(!log.loggedLines.contains("Slack: POST webhook -> no response"))
        }

        /// A webhook secret without a scheme or a host is a usage error, and no request is made.
        @Test(arguments: ["hooks.example.com/services/T000/B000/WEBHOOKTOKEN", "ftp://hooks.example.com/x", "https:///x"])
        func webhookURLWithoutASchemeOrHostIsAUsageError(webhook: String) async {
            let restore = isolatedGlobalState()
            defer { restore() }
            let client = HTTPClientMock()

            let error = await SwiftCITest.withMocks(httpClient: client) {
                await thrownError {
                    try await Slack(webhookURL: Secret(value: webhook)).send(text: "hello")
                }
            }

            #expect(error?.code == .usage)
            #expect(error?.message.contains("not a valid URL") == true)
            #expect(error?.message.contains("WEBHOOKTOKEN") == false)
            #expect(client.requests.isEmpty)
        }

        /// A webhook secret that is not a URL is a usage error. The message does not show the value, and no request is made.
        @Test func invalidWebhookURLIsAUsageErrorAndNoRequestIsMade() async throws {
            let restore = isolatedGlobalState()
            defer { restore() }
            let client = HTTPClientMock()
            let log = LogMock()

            let error = await SwiftCITest.withMocks(httpClient: client, log: log) {
                await thrownError {
                    try await Slack(webhookURL: Secret(value: "https://[SWIFTCI_TEST_BAD_WEBHOOK")).send(text: "hello")
                }
            }

            #expect(error?.code == .usage)
            #expect(error?.message.contains("not a valid URL") == true)
            #expect(error?.message.contains("SWIFTCI_TEST_BAD_WEBHOOK") == false)
            #expect(client.requests.isEmpty)
        }
    }
}
