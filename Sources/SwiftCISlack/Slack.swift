import Foundation
import SwiftCI

/// Sends messages to a Slack incoming webhook, in one of two formats:
///
/// - ``send(header:text:fields:buttons:step:)`` sends Block Kit blocks, the format Slack recommends. Slack treats a
///   Block Kit button as interactive, even one that only opens a URL. A legacy "Incoming WebHooks" integration cannot
///   receive the click, so Slack shows a warning next to the button. The link still opens.
/// - ``sendAttachment(pretext:text:color:fields:buttons:step:)`` sends a legacy attachment, as the Bitrise `slack`
///   step did. It has a colored bar, and its link buttons work without interactivity. Slack still supports
///   attachments, but calls them legacy.
///
/// `username` and `iconEmoji` override the sender of every message. A legacy "Incoming WebHooks" integration honors
/// them. A webhook of a Slack app ignores them and always uses the app's name and icon.
public struct Slack {
    @Use private var log: Log

    /// - Parameters:
    ///   - webhookURL: The webhook URL. It is revealed only to make the request.
    ///   - username: The sender name shown instead of the webhook's, or `nil` to keep the webhook's.
    ///   - iconEmoji: The sender icon as an emoji code, such as `:package:`, or `nil` to keep the webhook's.
    public init(webhookURL: Secret, username: String? = nil, iconEmoji: String? = nil) {
        self.webhookURL = webhookURL
        self.username = username
        self.iconEmoji = iconEmoji
    }

    /// Sends a Block Kit message: an optional header, a section with the text and the fields, and the buttons. A failed
    /// request is logged as a warning and does not throw. An invalid webhook secret throws a usage error before any
    /// request is made. The actions block is left out when there are no buttons, because Slack rejects an empty one.
    ///
    /// Opens a step named "Send Slack message" when called at the top level of a command. `step` renames it.
    public func send(
        header: String = "",
        text: String = "",
        fields: [Field] = [],
        buttons: [Button] = [],
        step name: String? = nil
    ) async throws {
        try await step(default: "Send Slack message", name: name) {
            try await sendMessage(message(header: header, text: text, fields: fields, buttons: buttons))
        }
    }

    /// Sends a legacy attachment message: the pretext above the attachment, and an attachment with a colored bar, the
    /// text, the fields in two columns and the link buttons. A failed request is logged as a warning and does not
    /// throw. An invalid webhook secret throws a usage error before any request is made.
    ///
    /// Opens a step named "Send Slack message" when called at the top level of a command. `step` renames it.
    public func sendAttachment(
        pretext: String = "",
        text: String = "",
        color: Color? = nil,
        fields: [Field] = [],
        buttons: [Button] = [],
        step name: String? = nil
    ) async throws {
        try await step(default: "Send Slack message", name: name) {
            try await sendMessage(
                attachmentMessage(pretext: pretext, text: text, color: color, fields: fields, buttons: buttons)
            )
        }
    }

    /// The Block Kit message body. The section block is added only when there is text or a field, and the actions block
    /// only when there is at least one button, because Slack rejects empty ones. The top-level text is the plain-text
    /// summary that Slack shows in notifications.
    func message(header: String, text: String, fields: [Field], buttons: [Button]) -> [String: Any] {
        var blocks = [[String: Any]]()
        if !text.isEmpty || !fields.isEmpty {
            blocks.append(sectionBlock(text: text, fields: fields))
        }
        if !buttons.isEmpty {
            blocks.append(actionsBlock(buttons.map(\.blockJSON)))
        }
        if !header.isEmpty {
            blocks.insert(headerBlock(text: header), at: 0)
        }
        var result: [String: Any] = ["blocks": blocks]
        let summary = summary(of: [header, text])
        if !summary.isEmpty {
            result["text"] = summary
        }
        return withSender(result)
    }

    /// The legacy attachment message body. Empty values are left out, because Slack rejects an attachment action
    /// list with no elements and shows empty fields. The fallback is the plain-text summary that Slack shows in
    /// notifications.
    func attachmentMessage(
        pretext: String,
        text: String,
        color: Color?,
        fields: [Field],
        buttons: [Button]
    ) -> [String: Any] {
        var attachment: [String: Any] = [:]
        let fallback = summary(of: [pretext, text])
        if !fallback.isEmpty {
            attachment["fallback"] = fallback
        }
        if !pretext.isEmpty {
            attachment["pretext"] = pretext
        }
        if !text.isEmpty {
            attachment["text"] = text
        }
        if let color {
            attachment["color"] = color.value
        }
        if !fields.isEmpty {
            attachment["fields"] = fields.map(\.attachmentJSON)
        }
        if !buttons.isEmpty {
            attachment["actions"] = buttons.map(\.attachmentJSON)
        }
        return withSender(["attachments": [attachment]])
    }

    /// The body of the webhook request. It holds the real values, because it is what Slack receives.
    static func requestBody(for message: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: message, options: .prettyPrinted)
    }

    /// The text of the request for the log. Every string value is redacted before the message is encoded. JSON escapes
    /// characters such as quotes and backslashes, so an escaped secret would no longer match its registered forms.
    /// The request itself is not changed.
    static func logRepresentation(of message: [String: Any]) -> String {
        let redacted = redactValues(message) as? [String: Any] ?? [:]
        let data = (try? JSONSerialization.data(withJSONObject: redacted, options: .prettyPrinted)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// A copy of `value` in which every string is redacted. Dictionaries and arrays are copied recursively.
    static func redactValues(_ value: Any) -> Any {
        switch value {
        case let text as String:
            return Secret.redact(text)
        case let dictionary as [String: Any]:
            return dictionary.mapValues { redactValues($0) }
        case let array as [Any]:
            return array.map { redactValues($0) }
        default:
            return value
        }
    }

    private func sendMessage(_ message: [String: Any]) async throws {
        // The webhook URL is revealed only here, to build the request.
        let webhook = try webhookURL.revealedValue()
        guard let url = URL(string: webhook) else {
            log.warning("Invalid Slack webhook URL")
            return
        }
        var req = URLRequest(url: url)
        req.addValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpMethod = "POST"
        req.httpBody = Self.requestBody(for: message)
        log.lines(title: "Slack webhook request", lines: Self.logRepresentation(of: message))

        guard let (data, _) = try? await URLSession.shared.data(for: req) else {
            log.warning("Failed to call Slack webhook.")
            return
        }
        log.completion("Slack webhook response: \(String(data: data, encoding: .utf8) ?? "unknown")")
    }

    /// `message` with the sender overrides that are set.
    private func withSender(_ message: [String: Any]) -> [String: Any] {
        var result = message
        if let username {
            result["username"] = username
        }
        if let iconEmoji {
            result["icon_emoji"] = iconEmoji
        }
        return result
    }

    /// The non-empty texts, joined with a space.
    private func summary(of texts: [String]) -> String {
        texts.filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// A field with a bold title and a value. Block Kit shows the fields of a section in two columns. An attachment
    /// shows them as short fields, also in two columns.
    public struct Field {
        public init(title: String, text: String) {
            self.title = title
            self.text = text
        }

        let title: String
        let text: String

        var blockTitleJSON: [String: String] { ["text": "*\(title)*", "type": "mrkdwn"] }
        var blockTextJSON: [String: String] { ["text": text, "type": "mrkdwn"] }
        var attachmentJSON: [String: Any] { ["title": title, "value": text, "short": true] }
    }

    /// A button that opens a URL.
    public struct Button {
        public init(text: String, url: String) {
            self.text = text
            self.url = url
        }

        let text: String
        let url: String

        var blockJSON: [String: Any] {
            [
                "type": "button",
                "text": [
                    "type": "plain_text",
                    "text": text,
                    "emoji": true,
                ],
                "url": url,
            ]
        }

        var attachmentJSON: [String: Any] { ["type": "button", "text": text, "url": url] }
    }

    /// The color of the bar of an attachment.
    public struct Color: Sendable {
        /// Slack's green.
        public static let good = Color(value: "good")
        /// Slack's yellow.
        public static let warning = Color(value: "warning")
        /// Slack's red.
        public static let danger = Color(value: "danger")

        /// A color as a hex string, such as `#3bc3a3`.
        public init(hex: String) {
            self.value = hex
        }

        private init(value: String) {
            self.value = value
        }

        let value: String
    }

    func headerBlock(text: String) -> [String: Any] {
        [
            "type": "header",
            "text": [
                "type": "plain_text",
                "text": text,
                "emoji": true,
            ],
        ]
    }

    /// A section whose fields alternate a row of two titles with a row of their two values, so that each value is
    /// shown under its title in Slack's two-column layout.
    func sectionBlock(text: String, fields: [Field]) -> [String: Any] {
        var sortedFields = [[String: String]]()
        var texts = [[String: String]]()
        for field in fields {
            sortedFields.append(field.blockTitleJSON)
            texts.append(field.blockTextJSON)
            if texts.count == 2 {
                sortedFields.append(contentsOf: texts)
                texts.removeAll()
            }
        }
        sortedFields.append(contentsOf: texts)

        var result: [String: Any] = ["type": "section"]
        if !sortedFields.isEmpty {
            result["fields"] = sortedFields
        }
        if !text.isEmpty {
            result["text"] = [
                "text": text,
                "type": "mrkdwn",
            ]
        }
        return result
    }

    func actionsBlock(_ elements: [[String: Any]]) -> [String: Any] {
        [
            "type": "actions",
            "elements": elements,
        ]
    }

    private let webhookURL: Secret
    private let username: String?
    private let iconEmoji: String?
}
