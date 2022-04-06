import Foundation

public struct Slack {
    public init(webhookURL: String) {
        self.webhookURL = webhookURL
    }

    public func send(
        header: String = "",
        text: String = "",
        fields: [Field],
        buttons: [Button]
    ) async throws {
        var blocks = [
            sectionBlock(
                text: text,
                fields: fields
            ),
            actionsBlock(buttons.map(\.json))
        ]
        if !header.isEmpty {
            blocks.insert(headerBlock(text: header), at: 0)
        }
        await sendMessage([
            "blocks": blocks
        ])
    }

    private func sendMessage(_ message: [String: Any]) async {
		guard let url = URL(string: webhookURL) else {
			logWarning("Invalid Slack webhook URL")
			return
		}
        var req = URLRequest(url: url)
        req.addValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpMethod = "POST"
       	req.httpBody = try! JSONSerialization.data(withJSONObject: message, options: .prettyPrinted)
       	logLines(title: "Slack webhook request", lines: String(data: req.httpBody!, encoding: .utf8)!)

       	guard let (data, _) = try? await URLSession.shared.data(for: req) else {
            logWarning("Failed to call Slack webhook.")
            return
        }
       	logCompletion("Slack webhook response: \(String(data: data, encoding: .utf8) ?? "unknown")")
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

    private let webhookURL: String
}
