import Foundation

public class Command {
    public init(_ name: String, perform: @escaping (Command) async -> Void) {
        self.name = name
        self.perform = perform
    }

    public init(_ name: String, perform: @escaping () async -> Void) {
        self.name = name
        self.perform = { _ in await perform() }
    }

    public var hasFailed: Bool { _hasFailed }

    func run() async {
        Self.current = self
        await perform(self)
        Self.current = nil
    }

    let name: String

    fileprivate static var current: Command?

    fileprivate var _hasFailed = false

    private let perform: (Command) async -> Void
}

public func step(_ name: String, _ when: StepWhen = .onSuccess, _ contents: () async throws -> Void) async {
    let stepStartDate = Date.now
    let hasFailed = Command.current?.hasFailed ?? true
    if (when == .onSuccess && hasFailed) || (when == .onFailure && !hasFailed) {
        try! logSkippedStep(name: name)
        return
    }
    do {
        try logEnteringStep(name: name)
        try await contents()
        try logFinishedStep(name: name, duration: stepStartDate.distance(to: Date.now))
    } catch let error as BuildError {
        Command.current?._hasFailed = true
        logError(error.message)
        try? logFailedStep(name: name)
    } catch {
        Command.current?._hasFailed = true
        logError("Unexpected error occurred: \(error)")
        try? logFailedStep(name: name)
    }
}

public enum StepWhen: Hashable {
    case onSuccess
    case onFailure
    case always
}
