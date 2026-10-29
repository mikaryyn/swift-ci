import Foundation

extension CI {
    /// Passes `value` to later steps of the CI job as the environment variable `name`, through the mechanism of the runner
    /// the command runs in: `envman` for the Bitrise CLI, `$GITHUB_ENV` on GitHub Actions, and otherwise the file
    /// `outputs.env` in the artifacts directory.
    ///
    /// The name must match `[A-Za-z_][A-Za-z0-9_]*`. The value must be one line and must not contain a registered secret.
    /// Otherwise the call throws a usage error (exit code 2) before anything is written. Exporting does not change the
    /// environment of the running process, so use a Swift variable for that.
    ///
    /// It is not a step. It logs one line in the current step, `Exported NAME`, and not the value. Values are not
    /// secret, but they can be long, and the file or the step output keeps them.
    ///
    /// - Parameters:
    ///   - name: The name of the variable, such as `MYAPP_IPA_PATH`.
    ///   - value: The value. An empty value is allowed.
    /// - Throws: ``BuildError`` with ``ErrorCode/usage`` for a name that does not match, a value with a line break, or a value
    ///   that contains a secret. Also throws if the runner or the file cannot be written.
    public static func export(_ name: String, _ value: String) async throws {
        @Use var log: Log

        guard let exporter = CIState.exporter else {
            preconditionFailure(
                "CI.export was called outside a running SwiftCI { } or SwiftCITest run. Call it inside a command or a step."
            )
        }
        try validateExport(name: name, value: value)
        try await exporter.export(name: name, value: value)
        log("Exported \(name)")
    }

    /// Throws a usage error for a name that is not a variable name, a value with a line break, or a value that contains a
    /// registered secret. The message never shows the secret.
    private static func validateExport(name: String, value: String) throws {
        guard name.wholeMatch(of: #/[A-Za-z_][A-Za-z0-9_]*/#) != nil else {
            throw BuildError(
                message: "CI.export name '\(name)' is not a variable name. Use only letters, digits and underscores, and do not start with a digit, such as 'MYAPP_IPA_PATH'.",
                code: .usage
            )
        }
        guard !value.unicodeScalars.contains(where: { $0 == "\n" || $0 == "\r" }) else {
            throw BuildError(
                message: "The value of CI.export '\(name)' has a line break. Exported values are one line. Write the text to a file with Artifacts.url(_:), and export its path, for example try CI.export(\"\(name)\", Artifacts.url(\"\(name.lowercased()).txt\").filePath).",
                code: .usage
            )
        }
        guard !SecretRegistry.patterns.contains(where: { value.contains($0) }) else {
            throw BuildError(
                message: "The value of CI.export '\(name)' contains a secret, and secrets cannot be exported. Exported values end up in files and later logs, where SwiftCI cannot mask them. Export a value that is not a secret, and give the secret to the later step another way.",
                code: .usage
            )
        }
    }
}

/// Exports through `envman add`, the mechanism of the Bitrise CLI, with the store that the CLI names in
/// `ENVMAN_ENVSTORE_PATH`. The value goes to standard input without a trailing line feed, so it is never an argument.
struct EnvmanExporter: CIExporter {
    /// The envman store of the running workflow, from `ENVMAN_ENVSTORE_PATH`.
    let storePath: String

    func export(name: String, value: String) async throws {
        try await Tool(
            command: "envman",
            arguments: ["add", "--key", name],
            environment: ["ENVMAN_ENVSTORE_PATH": .text(storePath)],
            input: .text(value),
            filters: [envmanOutputFilter]
        ).run()
    }
}

/// Keeps the lines of `envman` that look like errors or warnings. `envman` prints nothing on success, so its other lines
/// are hidden from the console. The full log keeps them.
private let envmanOutputFilter: Filter = { line in
    let lowercased = line.lowercased()
    return lowercased.contains("error") || lowercased.contains("warning") ? line : nil
}

/// Exports to GitHub Actions: `NAME=value` is appended to `$GITHUB_ENV`, and to `$GITHUB_OUTPUT` when it is set too. Later
/// steps of the job read the first, and the outputs of this step read the second.
struct GitHubExporter: CIExporter {
    /// The file of `$GITHUB_ENV`.
    let environmentFile: URL
    /// The file of `$GITHUB_OUTPUT`, or `nil` when it is not set.
    let outputFile: URL?

    func export(name: String, value: String) async throws {
        try appendLine("\(name)=\(value)", to: environmentFile, variable: "GITHUB_ENV")
        if let outputFile {
            try appendLine("\(name)=\(value)", to: outputFile, variable: "GITHUB_OUTPUT")
        }
    }

    /// Appends `line` and a line feed to `file`, and creates the file if it does not exist.
    private func appendLine(_ line: String, to file: URL, variable: String) throws {
        do {
            if !FileManager.default.fileExists(atPath: file.filePath) {
                guard FileManager.default.createFile(atPath: file.filePath, contents: nil) else {
                    throw CocoaError(.fileWriteUnknown)
                }
            }
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data((line + "\n").utf8))
        } catch {
            throw BuildError(
                message: "Failed to write to '\(file.filePath)', the file that \(variable) names. Check that the file is writable. Details: \(error)"
            )
        }
    }
}

/// Exports to `outputs.env` in the artifacts directory: one `NAME=value` line per name, with no quotes or comments. A name
/// that is exported again replaces its line in place, and other lines keep their order. Blank lines are dropped. The file
/// is created on the first export and never deleted (G3).
struct DotenvExporter: CIExporter {
    func export(name: String, value: String) async throws {
        let file = try Artifacts.url("outputs.env")
        let prefix = "\(name)="
        let entry = prefix + value

        var lines: [String] = []
        if FileManager.default.fileExists(atPath: file.filePath) {
            do {
                let text = try String(contentsOf: file, encoding: .utf8)
                lines = text.components(separatedBy: "\n").filter { !$0.isEmpty }
            } catch {
                throw BuildError(
                    message: "Failed to read '\(file.filePath)', the outputs file of CI.export. Check that the file is readable. Details: \(error)"
                )
            }
        }

        // The first line of the name takes the new value, and any later line of the same name is dropped, so each name
        // has one line.
        var result: [String] = []
        var written = false
        for line in lines {
            guard line.hasPrefix(prefix) else {
                result.append(line)
                continue
            }
            if !written {
                result.append(entry)
                written = true
            }
        }
        if !written {
            result.append(entry)
        }

        do {
            try (result.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        } catch {
            throw BuildError(
                message: "Failed to write '\(file.filePath)', the outputs file of CI.export. Check that the artifacts directory is writable. Details: \(error)"
            )
        }
    }
}
