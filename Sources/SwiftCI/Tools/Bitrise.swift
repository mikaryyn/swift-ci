import Foundation

/// Temporary: runs Bitrise CLI workflows, for outside-in migration. It is removed before 1.0, once the migration no
/// longer needs it (see [Incremental adoption](docs/plans/incremental-adoption.md#decisions)).
///
/// Values that the workflow exports with `envman` are lost when the workflow exits. Pass inputs with `environment`, and
/// use names that the workflow's `app: envs:` do not define, because those can take precedence over the process
/// environment.
public enum Bitrise {
    /// Temporary: runs `bitrise --ci run <workflow>` and fails if the workflow fails. Does work: opens a step.
    ///
    /// The output is filtered: the workflow and step headers, each step's result, the summary and the final status are
    /// shown, together with lines that look like errors or warnings. The full log keeps all output.
    ///
    /// - Parameters:
    ///   - workflow: The workflow ID in `bitrise.yml`.
    ///   - configuration: The `--config` file. The CLI reads `bitrise.yml` in the working directory if `nil`.
    ///   - inventory: The `--inventory` file, with the secrets of the workflow.
    ///   - environment: Variables for the workflow. A ``Secret`` value is revealed only when the process starts, and is
    ///     not an argument. `BITRISE_DEPLOY_DIR` is the artifacts directory unless this sets it.
    ///   - step: The step name, or `nil` for "Run Bitrise workflow <workflow>".
    /// - Throws: ``BuildError`` if the workflow exits with a non-zero code. The message names the workflow.
    public static func run(
        workflow: String,
        configuration: URL? = nil,
        inventory: URL? = nil,
        environment: [String: ToolEnvironmentValue] = [:],
        step: String? = nil
    ) async throws {
        try await runWorkflow(
            workflow,
            configuration: configuration,
            inventory: inventory,
            environment: environment,
            stepName: step
        )
    }
}

/// Opens the step and runs the CLI. ``Bitrise/run(workflow:configuration:inventory:environment:step:)`` has a parameter
/// named `step`, which would hide the function `step(default:name:)`, so the step is opened here.
private func runWorkflow(
    _ workflow: String,
    configuration: URL?,
    inventory: URL?,
    environment: [String: ToolEnvironmentValue],
    stepName: String?
) async throws {
    try await step(default: "Run Bitrise workflow \(workflow)", name: stepName) {
        var arguments = ["--ci", "run", workflow]
        if let configuration {
            arguments += ["--config", configuration.filePath]
        }
        if let inventory {
            arguments += ["--inventory", inventory.filePath]
        }
        var environment = environment
        if environment["BITRISE_DEPLOY_DIR"] == nil {
            environment["BITRISE_DEPLOY_DIR"] = .text(Artifacts.directory.filePath)
        }

        // A failed workflow is reported with its name below, so the exit code is read here, not thrown by the tool.
        let result = try await Tool(
            command: "bitrise",
            arguments: arguments,
            environment: environment,
            filters: [bitriseOutputFilter]
        ).result()
        guard result.exitCode == 0 else {
            throw BuildError(
                message: "The Bitrise workflow '\(workflow)' failed with exit code \(result.exitCode). See the summary above for the failed step, or the full log."
            )
        }
    }
}

/// Keeps the workflow and step headers, each step's result, the summary, the final status, and any line that looks like
/// an error or a warning. Other output of the steps is hidden. The checks use the text without colour codes, and a kept
/// line keeps its colours. The fixtures in `Tests/SwiftCITests/Fixtures/Bitrise` show the lines that are matched.
private let bitriseOutputFilter: Filter = { line in
    let plain = line.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
    let lowercased = plain.lowercased()
    let isWorkflowHeader = plain.hasPrefix("Running workflow:") || plain.hasPrefix("Switching to workflow:")
    let isStepHeader = plain.hasPrefix("| (")
    let isStepResult = plain.range(of: #"^\| \S \| "#, options: .regularExpression) != nil
    let isSummary = plain.contains("bitrise summary:") || plain.hasPrefix("| Total runtime")
    let isFinalStatus = plain.hasPrefix("Bitrise build")
    let isErrorOrWarning = lowercased.contains("error") || lowercased.contains("warning")
    let keep = isWorkflowHeader || isStepHeader || isStepResult || isSummary || isFinalStatus || isErrorOrWarning
    return keep ? line : nil
}
