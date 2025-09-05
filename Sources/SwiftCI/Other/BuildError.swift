public struct BuildError: Error {
    public init(message: String, code: ErrorCode = .buildError) {
        self.message = message
        self.code = code
    }

    let message: String
    let code: ErrorCode
}

public enum ErrorCode: Int32 {
    case buildError
    case scriptError
    case unexpectedError
}
