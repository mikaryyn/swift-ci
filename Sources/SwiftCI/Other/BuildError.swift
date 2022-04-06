public struct BuildError: Error {
    public init(message: String) {
        self.message = message
    }

    let message: String
}
