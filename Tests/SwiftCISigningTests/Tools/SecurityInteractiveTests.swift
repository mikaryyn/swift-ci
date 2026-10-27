@testable import SwiftCISigning
@testable import SwiftCITestSupport
@testable import SwiftCI
import Testing

extension GlobalStateTests {
    /// The `security -i` line builder. Pure functions, no process is started.
    @Suite(.serialized) struct SecurityInteractiveTests {
        func arg(_ value: String, kind: String = "test value") -> SecurityArgument {
            SecurityArgument(kind: kind, value: value)
        }

        /// The exact line for a simple command, written by hand: each character is a backslash and the character, and
        /// the arguments are separated by a space.
        @Test func simpleCommandIsEncodedCharacterByCharacter() throws {
            let line = try SecurityInteractive.commandLine([arg("ab"), arg("")])

            #expect(line == "\\a\\b \"\"\n")
        }

        @Test func everySpecialCharacterRoundTrips() throws {
            let values = ["a b", "it's", "say \"hi\"", "back\\slash", "tab\there", "cr\rhere", "#hash", "$HOME", "é ü 中", "", "x;y&z|w"]

            let line = try SecurityInteractive.commandLine(values.map { arg($0) })

            #expect(line.hasSuffix("\n"))
            #expect(line.dropLast().contains("\n") == false)
            #expect(splitSecurityLine(line) == values)
        }

        @Test func argumentsAreSeparatedByOneSpaceAndEndWithOneLineFeed() throws {
            let line = try SecurityInteractive.commandLine([arg("a"), arg("b"), arg("c")])

            #expect(line == "\\a \\b \\c\n")
        }

        // MARK: Rejections

        @Test func lineFeedIsRejectedWithoutShowingTheValue() async {
            let error = await thrownError {
                _ = try SecurityInteractive.commandLine([arg("VALUE-SECRET-123\nmore", kind: "keychain password")])
            }

            #expect(error?.code == .usage)
            #expect(error?.message.contains("keychain password") == true)
            #expect(error?.message.contains("VALUE-SECRET-123") == false)
        }

        @Test func nulIsRejectedWithoutShowingTheValue() async {
            let error = await thrownError {
                _ = try SecurityInteractive.commandLine([arg("VALUE-SECRET-456\u{0}", kind: "keychain password")])
            }

            #expect(error?.code == .usage)
            #expect(error?.message.contains("keychain password") == true)
            #expect(error?.message.contains("VALUE-SECRET-456") == false)
        }

        /// Each byte of an ASCII argument takes two bytes in the line. 2047 bytes make 4094, the limit. 2048 do not.
        @Test func lineAtTheLimitIsAcceptedAndOneOverIsRejected() async throws {
            let atLimit = String(repeating: "x", count: 2047)
            let line = try SecurityInteractive.commandLine([arg(atLimit)])
            #expect(line.utf8.count == SecurityInteractive.maxLineBytes + 1)
            #expect(splitSecurityLine(line) == [atLimit])

            let overLimit = String(repeating: "y", count: 2048)
            let error = await thrownError {
                _ = try SecurityInteractive.commandLine([arg(overLimit, kind: "keychain password")])
            }
            #expect(error?.code == .usage)
            #expect(error?.message.contains("keychain password") == true)
            #expect(error?.message.contains(overLimit) == false)
        }

        @Test func thirtyTwoArgumentsAreAcceptedAndThirtyThreeAreRejected() async throws {
            let thirtyTwo = (0..<32).map { arg("a\($0)") }
            #expect(splitSecurityLine(try SecurityInteractive.commandLine(thirtyTwo)).count == 32)

            let thirtyThree = (0..<33).map { arg("a\($0)") }
            let error = await thrownError {
                _ = try SecurityInteractive.commandLine(thirtyThree)
            }
            #expect(error?.code == .usage)
            #expect(error?.message.contains("33") == true)
        }

        /// The tool sends the line as a secret input, so the password is never an argument.
        @Test func toolSendsTheLineAsASecretInputWithoutDashV() throws {
            let tool = try SecurityInteractive.tool(for: [arg("pw-VALUE-7", kind: "keychain password")])

            #expect(tool.command == "/usr/bin/security")
            #expect(tool.arguments == ["-i"])
            #expect(try securityLine(of: tool) == "\\p\\w\\-\\V\\A\\L\\U\\E\\-\\7\n")
        }

        // MARK: Byte-level safety of the encoding

        /// VT and FF are whitespace for `isspace()`, so each is escaped. The line holds a backslash before each one.
        @Test func verticalTabAndFormFeedAreEscaped() throws {
            let value = "a\u{0B}b\u{0C}c"

            let line = try SecurityInteractive.commandLine([arg(value)])

            #expect(line == "\\a\\\u{0B}\\b\\\u{0C}\\c\n")
            #expect(splitSecurityLine(line) == [value])
        }

        /// Every ASCII control character, and the whitespace ones in particular, round-trips.
        @Test func everyASCIIControlCharacterRoundTrips() throws {
            let value = (0x01...0x7F).compactMap { $0 == 0x0A || $0 == 0x00 ? nil : Unicode.Scalar($0).map(String.init) }.joined()

            let line = try SecurityInteractive.commandLine([arg(value)])

            #expect(splitSecurityLine(line) == [value])
        }

        /// One scalar of each UTF-8 length: 2 bytes (é), 3 bytes (€) and 4 bytes (😀). Each is written after one backslash.
        @Test func twoThreeAndFourByteScalarsRoundTrip() throws {
            let value = "é€😀"

            let line = try SecurityInteractive.commandLine([arg(value)])

            #expect(line == "\\é\\€\\😀\n")
            #expect(line.utf8.count == 1 + 2 + 1 + 3 + 1 + 4 + 1)
            #expect(splitSecurityLine(line) == [value])
        }

        /// The limit counts the encoded UTF-8 bytes. Each é costs 3 bytes (a backslash and two bytes), so 1,364 of them
        /// plus one x cost 4,094 bytes, which is accepted. 1,365 of them cost 4,095, which is refused.
        @Test func encodedByteBoundaryWithMultibyteContent() async throws {
            let atLimit = String(repeating: "é", count: 1364) + "x"
            let line = try SecurityInteractive.commandLine([arg(atLimit)])
            #expect(line.utf8.count == SecurityInteractive.maxLineBytes + 1)
            #expect(splitSecurityLine(line) == [atLimit])

            let overLimit = String(repeating: "é", count: 1365)
            let error = await thrownError {
                _ = try SecurityInteractive.commandLine([arg(overLimit, kind: "keychain password")])
            }
            #expect(error?.code == .usage)
            #expect(error?.message.contains("keychain password") == true)
            #expect(error?.message.contains("é") == false)
        }
    }
}
