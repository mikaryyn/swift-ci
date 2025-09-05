import Foundation

public class Command {
    public init(_ name: String, perform: @MainActor @escaping (Command) async -> Void) {
        self.name = name
        self.perform = perform
    }

    public init(_ name: String, perform: @MainActor @escaping () async -> Void) {
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

@MainActor public func step(_ name: String, _ when: StepWhen = .onSuccess, _ contents: @MainActor () async throws -> Void) async {
    @Use var log: Log

    let stepStartDate = Date.now
    let hasFailed = Command.current?.hasFailed ?? true
    if (when == .onSuccess && hasFailed) || (when == .onFailure && !hasFailed) {
        try! log.skippedStep(name: name)
        return
    }
    do {
        try log.enteringStep(name: name)
        try await contents()
        try log.finishedStep(name: name, duration: stepStartDate.distance(to: Date.now))
    } catch let error as BuildError {
        Command.current?._hasFailed = true
        log.error(error.message)
        try? log.failedStep(name: name)
    } catch {
        Command.current?._hasFailed = true
        log.error("Unexpected error occurred: \(error)")
        try? log.failedStep(name: name)
    }
}

public enum StepWhen: Hashable {
    case onSuccess
    case onFailure
    case always
}
