import Foundation

/// The captured result of a run: stdout and stderr as lines joined with LF (without a final LF), and the exit code.
public struct ToolResult: Equatable, Sendable {
    /// Creates a result. Tools return results from the runner. Tests create them for mocks.
    public init(stdout: String, stderr: String, exitCode: Int32) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
    }

    /// The lines of stdout, joined with LF.
    public let stdout: String
    /// The lines of stderr, joined with LF.
    public let stderr: String
    /// The exit code of the program.
    public let exitCode: Int32
}

/// One line of output of a program, with the stream it came from.
nonisolated public struct ToolOutputLine: Equatable, Sendable {
    /// The stream a line was read from.
    nonisolated public enum Stream: Equatable, Sendable {
        /// Standard output.
        case stdout
        /// Standard error.
        case stderr
    }

    /// Creates a line. The runner creates lines. Tests create them for mocks.
    public init(stream: Stream, text: String) {
        self.stream = stream
        self.text = text
    }

    /// The stream the line was read from.
    public let stream: Stream
    /// The text of the line, without its line feed. A carriage return before the line feed is removed.
    public let text: String
}

/// The value of an environment variable of a ``Tool``. A plain string literal is a `.text` value. A ``Secret`` is
/// revealed only when the process starts, and its value is masked in every log.
public enum ToolEnvironmentValue: ExpressibleByStringLiteral, Equatable, Sendable {
    /// A plain value.
    case text(String)
    /// A secret value.
    case secret(Secret)

    /// Creates a plain value from a string literal.
    public init(stringLiteral value: String) {
        self = .text(value)
    }
}

/// The standard input of a ``Tool``. It is written, and then standard input is closed.
public enum ToolInput: Equatable, Sendable {
    /// Text, written as UTF-8.
    case text(String)
    /// Raw bytes.
    case data(Data)
    /// A secret, written as UTF-8. It is revealed only when the process starts.
    case secret(Secret)

    /// The bytes to write. Reveals a secret, so the runner calls it only when it starts the process.
    func revealedBytes() throws -> Data {
        switch self {
        case .text(let text):
            return Data(text.utf8)
        case .data(let data):
            return data
        case .secret(let secret):
            return Data(try secret.revealedValue().utf8)
        }
    }
}
