@_spi(Testing) import SwiftCI

/// Prepares a test that uses secrets. Replaces the environment that `Secret("NAME")` reads from. It returns a function
/// that restores the global state that was saved: the registry, the environment source and the registrations (loggers,
/// runners), whatever they were. Call the function in a `defer`.
@MainActor
func secretsSetUp(_ environment: [String: String] = [:]) -> () -> Void {
    let snapshot = isolateGlobalState(environment: environment)
    return { restoreGlobalState(snapshot) }
}
