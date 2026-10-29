import Foundation
import SwiftCI

public struct Slack {
    @Use private var log: Log

    public init(webhookURL: Secret) {
        self.webhookURL = webhookURL
    }

    /// Sends a message to the webhook. A failed request is logged as a warning and does not throw. An invalid webhook
    /// secret throws a usage error before any request is made. The actions block is left out when there are no buttons,
    /// because Slack rejects an empty one.
    ///
    /// Opens a step named "Send Slack message" when called at the top level of a command. `step` renames it.
    public func send(
        header: String = "",
        text: String = "",
        fields: [Field],
        buttons: [Button],
        step name: String? = nil
    ) async throws {
        try await step(default: "Send Slack message", name: name) {
            try await sendMessage(message(header: header, text: text, fields: fields, buttons: buttons))
        }
    }

    /// The message body for the given content. The actions block is added only when there is at least one button.
    func message(header: String, text: String, fields: [Field], buttons: [Button]) -> [String: Any] {
        var blocks = [
            sectionBlock(
                text: text,
                fields: fields
            )
        ]
        if !buttons.isEmpty {
            blocks.append(actionsBlock(buttons.map(\.json)))
        }
        if !header.isEmpty {
            blocks.insert(headerBlock(text: header), at: 0)
        }
        return [
            "blocks": blocks
        ]
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

    public struct Field {
        public init(title: String, text: String) {
            self.titleJson = ["text": "*\(title)*", "type": "mrkdwn"]
            self.textJson = ["text": text, "type": "mrkdwn"]
        }
        let titleJson: [String: String]
        let textJson: [String: String]
    }

    public struct Button {
        public init(text: String, url: String) {
            json = [
				"type": "button",
				"text": [
				    "type": "plain_text",
				    "text": text,
				    "emoji": true
                ],
				"url": url
            ]
        }
        let json: [String: Any]
    }

        func headerBlock(text: String) -> [String: Any] {
            [
                "type": "header",
        		"text": [
			        "type": "plain_text",
    			    "text": text,
                    "emoji": true
                ]
            ]
        }

    func sectionBlock(text: String, fields: [Field]) -> [String: Any] {
		var sortedFields = [[String: String]]()
		var texts = [[String: String]]()
		var counter = 0
		for field in fields {
			sortedFields.append(field.titleJson)
			texts.append(field.textJson)
			counter += 1
			if counter == 2 {
				sortedFields.append(contentsOf: texts)
				texts.removeAll()
			}
		}
		sortedFields.append(contentsOf: texts)

        var result: [String: Any] = [
            "type": "section",
            "fields": sortedFields
        ]
        if !text.isEmpty {
            result["text"] = [
                "text": text,
                "type": "mrkdwn"
            ]
        }
        return result
    }

    func actionsBlock(_ elements: [[String: Any]]) -> [String: Any] {
        [
            "type": "actions",
            "elements": elements
        ]
    }

    private let webhookURL: Secret
}
