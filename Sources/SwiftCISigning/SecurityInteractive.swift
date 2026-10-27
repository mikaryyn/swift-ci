import Foundation
import SwiftCI

/// One argument of a `security -i` command. `kind` names the argument in error messages (for example "keychain
/// password"), so that an error never shows the value.
struct SecurityArgument {
    let kind: String
    let value: String
}

/// Builds the line that `security -i` reads, and the ``Tool`` that sends it.
///
/// Source: Security-61901.0.87.0.1 (macOS 26), in the `SecurityTool/macOS` directory of
/// https://github.com/apple-oss-distributions/Security
/// - Reading: `readline.c`, lines 37–80. A line ends at LF, which is not stored. CR is not removed.
/// - Limits: `security.c`, `MAX_LINE_LEN` (lines 79–81) is 4096, and the reader stops one byte before it. So the text
///   before the LF may be at most 4094 bytes. A longer line is not drained, and its rest becomes another command.
///   The tokenizer takes at most 32 tokens.
/// - Tokenizing: `security.c`, lines 895–1002. Separators are `isspace()` characters. A quote opens an argument only at
///   the start of a token. A backslash makes the next byte literal, even inside quotes.
/// - Status: `security.c`, lines 1180–1216. At end of input the process returns the status of the last command. With
///   one command that is the command's status.
/// - Prompt: `security> ` is written only if standard input is a terminal. With a pipe there is no prompt.
///
/// Encoding: each Unicode scalar of an argument is written as a backslash followed by the scalar's UTF-8 bytes, and an
/// empty argument is written as `""`. Arguments are separated by one space, and the line ends with one LF.
///
/// Why this is byte-transparent for the tokenizer, in three parts:
/// - ASCII bytes. Every ASCII character, including space, tab, LF, VT (0x0B), FF (0x0C), CR, quotes and backslash, is
///   written with a backslash in front, so the tokenizer copies it literally. VT and FF are separators for `isspace()`,
///   so their escape is needed, and the tests cover it.
/// - The lead byte of a multi-byte scalar (0xC2–0xF4) is escaped, so it is copied literally too.
/// - The continuation bytes (0x80–0xBF) are not escaped. They cannot be: a `Secret` holds a Swift `String`, and a
///   backslash between two bytes of a UTF-8 sequence would make it invalid. So the tokenizer's `isspace()` sees them.
///   This is safe on the assumption that `security` runs in the C locale (it does not call `setlocale`, per the source
///   research), where `isspace()` is false for every byte from 0x80 to 0xFF, read as an unsigned or a signed `char`.
///   That was checked on macOS 27 with a probe calling `isspace()` for all of those values in the C locale: none is
///   whitespace. The check is an assumption about one libc version, so the manual keychain check, which sends
///   non-ASCII passwords through unlock, is the second check. The first byte-transparent alternative needs `Secret`
///   to hold bytes, which is a larger change.
enum SecurityInteractive {
    /// The longest text before the LF, in bytes.
    static let maxLineBytes = 4094
    /// The most tokens in one command.
    static let maxArguments = 32

    /// Returns the line for one command, including its final LF. Throws a usage error if an argument contains a LF or
    /// NUL, if the line is longer than ``maxLineBytes``, or if there are more than ``maxArguments`` arguments. The
    /// message names the kind of the argument, never its value.
    static func commandLine(_ arguments: [SecurityArgument]) throws -> String {
        guard arguments.count <= maxArguments else {
            throw BuildError(
                message: "security -i takes at most \(maxArguments) arguments in one command, and this command has \(arguments.count).",
                code: .usage
            )
        }
        var text = ""
        for (index, argument) in arguments.enumerated() {
            if argument.value.unicodeScalars.contains(where: { $0.value == 0x0A || $0.value == 0 }) {
                throw BuildError(
                    message: "The \(argument.kind) contains a line feed or NUL character, which security -i cannot read. Use a value without them.",
                    code: .usage
                )
            }
            if index > 0 {
                text += " "
            }
            if argument.value.isEmpty {
                text += "\"\""
            } else {
                for scalar in argument.value.unicodeScalars {
                    text += "\\"
                    text.unicodeScalars.append(scalar)
                }
            }
        }
        if text.utf8.count > maxLineBytes, let longest = arguments.max(by: { $0.value.utf8.count < $1.value.utf8.count }) {
            throw BuildError(
                message: "The \(longest.kind) is too long for security -i: the command would be \(text.utf8.count) bytes, and security -i reads at most \(maxLineBytes) bytes per line. Use a shorter value.",
                code: .usage
            )
        }
        return text + "\n"
    }

    /// The `security -i` tool for one command. The line is sent on standard input as a secret, so it never appears in
    /// the arguments or in the full log. `-v` is not used, because it would print the arguments.
    static func tool(for arguments: [SecurityArgument]) throws -> Tool {
        let line = try commandLine(arguments)
        return Tool(command: "/usr/bin/security", arguments: ["-i"], input: .secret(Secret(value: line)))
    }
}
