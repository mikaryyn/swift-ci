public struct Workflow {
    public init(_ name: String, perform: @escaping () async -> Void) {
        self.name = name
        self.perform = perform
    }

    public func callAsFunction() async {
        await perform()
    }

    private let name: String
    private let perform: () async -> Void
}
