@_spi(Testing) import SwiftCI

/// Isolates all global state for one test: the environment that `Secret("NAME")` and `Environment` read from, the
/// secret registry, the registrations (log, runner, HTTP client), CI detection, commands, options, the running
/// command, the full log and the artifacts location. It returns a function that restores what was saved. Call the
/// function in a `defer`.
func isolatedGlobalState(_ environment: [String: String] = [:]) -> () -> Void {
    let snapshot = isolateGlobalState(environment: environment)
    return { restoreGlobalState(snapshot) }
}
