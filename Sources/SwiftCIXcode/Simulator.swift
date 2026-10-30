import Foundation
import SwiftCI

/// Simulator management with `xcrun simctl`.
///
/// Only the shutdown is implemented. Booting and erasing come with the UI tests. ``shutdownAll(step:)`` is meant for a
/// `cleanup` handler on CI, as in the README example:
///
///     cleanup { try await Simulator.shutdownAll() }
public enum Simulator {
    /// Runs `xcrun simctl shutdown all`, which shuts down every simulator. A non-zero exit code fails the step.
    ///
    /// Opens a step named "Shut down simulators" when called at the top level of a command. `step` renames it.
    public static func shutdownAll(step name: String? = nil) async throws {
        try await step(default: "Shut down simulators", name: name) {
            let tool = Tool(
                command: xcrunPath,
                arguments: ["simctl", "shutdown", "all"]
            )
            try await tool.run()
        }
    }

    private static let xcrunPath = "/usr/bin/xcrun"
}
