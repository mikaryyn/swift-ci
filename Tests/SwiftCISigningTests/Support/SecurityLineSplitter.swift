@testable import SwiftCI
import Testing

/// Splits a `security -i` line the way `security` does (see `SecurityInteractive`): separators are whitespace, a quote
/// opens an argument only at the start of a token, and a backslash makes the next byte literal. Tests use it to check
/// that the encoding round-trips. It is not used by the product.
func splitSecurityLine(_ line: String) -> [String] {
    var bytes = Array(line.utf8)
    if bytes.last == 0x0A {
        bytes.removeLast()
    }
    let backslash: UInt8 = 0x5C
    func isSeparator(_ byte: UInt8) -> Bool {
        [0x20, 0x09, 0x0A, 0x0B, 0x0C, 0x0D].contains(byte)
    }

    var tokens: [String] = []
    var index = 0
    while index < bytes.count {
        if isSeparator(bytes[index]) {
            index += 1
            continue
        }
        var token: [UInt8] = []
        let first = bytes[index]
        if first == 0x22 || first == 0x27 {
            index += 1
            while index < bytes.count && bytes[index] != first {
                token.append(bytes[index])
                index += 1
            }
            index += 1
        } else {
            while index < bytes.count && !isSeparator(bytes[index]) {
                if bytes[index] == backslash {
                    if index + 1 < bytes.count {
                        token.append(bytes[index + 1])
                    }
                    index += 2
                } else {
                    token.append(bytes[index])
                    index += 1
                }
            }
        }
        tokens.append(String(decoding: token, as: UTF8.self))
    }
    return tokens
}

/// The `security -i` line of a tool built by `SecurityInteractive.tool(for:)`, with the secret revealed.
func securityLine(of tool: Tool) throws -> String {
    guard case .secret(let secret)? = tool.input else {
        Issue.record("Expected the security -i line as a secret input")
        return ""
    }
    return try secret.revealedValue()
}
