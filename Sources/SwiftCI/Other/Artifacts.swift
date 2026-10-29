import Foundation

/// The artifacts directory of a run: where SwiftCI and the script keep the files that CI archives, such as full logs,
/// IPAs and reports.
///
/// The directory is chosen once when `SwiftCI { }` starts. `SWIFTCI_ARTIFACTS_DIR` wins, then the `artifactsDirectory:`
/// argument of `SwiftCI { }`, then `artifacts` in the working directory at start. SwiftCI never deletes anything in it.
public enum Artifacts {
    /// The artifacts directory of the running run, as an absolute file URL. A query: it does not open a step.
    ///
    /// The directory is created when the first command starts, so it exists inside a command body. Reading it outside a
    /// running `SwiftCI { }` or a `SwiftCITest` run is a programming error and stops the process with a message that
    /// says so.
    public static var directory: URL {
        guard let location = ArtifactsLocation.current else {
            preconditionFailure(
                "Artifacts.directory was read outside a running SwiftCI { } or SwiftCITest run. Read it inside a command or a step."
            )
        }
        return location.url
    }

    /// The URL of `relativePath` inside the artifacts directory. A query: it does not open a step.
    ///
    /// The parent directories of the URL are created, but the file is not. Use it for every file the user keeps, such
    /// as a report or an export: `try Artifacts.url("reports/junit.xml")`.
    ///
    /// - Parameter relativePath: A path relative to the artifacts directory, such as `release-notes.txt`. It must not be
    ///   empty, absolute, or leave the directory with `..`.
    /// - Throws: ``BuildError`` if the path is empty, absolute or leaves the directory, or if its parent directories
    ///   cannot be created.
    public static func url(_ relativePath: String) throws -> URL {
        let base = directory
        guard !relativePath.isEmpty else {
            throw BuildError(message: "Artifacts.url needs a file path, but the path is empty. Pass a path such as 'release-notes.txt'.")
        }
        guard !relativePath.hasPrefix("/") else {
            throw BuildError(
                message: "Artifacts.url needs a path relative to the artifacts directory, not the absolute path '\(relativePath)'. Pass a path such as 'release-notes.txt'."
            )
        }

        // The URL of an existing directory can end in "/", so the prefix is compared without it.
        var folder = base.filePath
        while folder.count > 1, folder.hasSuffix("/") {
            folder.removeLast()
        }
        let url = base.appending(path: relativePath).standardizedFileURL
        guard url.filePath.hasPrefix(folder + "/") else {
            throw BuildError(
                message: "Artifacts.url path '\(relativePath)' leaves the artifacts directory '\(folder)'. Remove the '..' components from the path."
            )
        }

        let parent = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        } catch {
            throw BuildError(
                message: "Failed to create the directory '\(parent.filePath)' in the artifacts directory. Check that it is writable and that no file has the same name. Details: \(error)"
            )
        }
        return url
    }
}

extension Artifacts {
    /// Creates the artifacts directory if it does not exist. Called when the first command starts, before its full log opens.
    ///
    /// - Throws: a usage error (exit code 2) if the path exists and is not a directory, and an internal error (exit code 3)
    ///   if the directory cannot be created.
    static func prepareDirectory() throws {
        try ArtifactsLocation.current?.prepareDirectory()
    }
}

/// Where the artifacts directory of the running run comes from. Chosen once by `runSwiftCI` (and by `SwiftCITest`
/// through the global state), and read through ``Artifacts``.
struct ArtifactsLocation {
    /// The setting that chose the directory. Named in error messages.
    enum Source {
        /// The `SWIFTCI_ARTIFACTS_DIR` environment variable.
        case environment
        /// The `artifactsDirectory:` argument of `SwiftCI { }`, or of a `SwiftCITest` run or `withMocks`.
        case script
        /// The default of the run: `artifacts` in the working directory, or a temporary directory of a test.
        case `default`

        var description: String {
            switch self {
            case .environment: "SWIFTCI_ARTIFACTS_DIR"
            case .script: "the artifactsDirectory: argument of SwiftCI { }"
            case .default: "the default artifacts directory"
            }
        }
    }

    static let environmentVariable = "SWIFTCI_ARTIFACTS_DIR"

    /// The default directory of a run: `artifacts` in the working directory when the run starts. A computed property, so
    /// that it uses the working directory of each run, not of the first use.
    static var defaultURL: URL { URL(fileURLWithPath: "artifacts") }

    /// The location of the running run, or `nil` outside a run. Set by `runSwiftCI` and restored when it returns.
    static var current: ArtifactsLocation?

    let url: URL
    let source: Source

    /// Chooses the directory: `SWIFTCI_ARTIFACTS_DIR` if it is set and not empty, otherwise `parameter`, otherwise
    /// `defaultDirectory`. A relative path resolves against the working directory now, so later changes of the working
    /// directory do not move it.
    static func resolve(parameter: URL?, defaultDirectory: URL) -> ArtifactsLocation {
        if let value = EnvironmentSource.value(environmentVariable), !value.isEmpty {
            return ArtifactsLocation(url: absolute(URL(fileURLWithPath: value)), source: .environment)
        }
        if let parameter {
            return ArtifactsLocation(url: absolute(parameter), source: .script)
        }
        return ArtifactsLocation(url: absolute(defaultDirectory), source: .default)
    }

    /// Creates the directory with its intermediate directories. Nothing is deleted.
    func prepareDirectory() throws {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.filePath, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw BuildError(
                    message: "The artifacts directory '\(url.filePath)' from \(source.description) exists and is not a directory. Remove or rename that file, or point the artifacts directory somewhere else with \(Self.environmentVariable) or the artifactsDirectory: argument of SwiftCI { }.",
                    code: .usage
                )
            }
            return
        }
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            throw BuildError(
                message: "Failed to create the artifacts directory '\(url.filePath)' from \(source.description). Check that its parent directory is writable. Details: \(error)",
                code: .internal
            )
        }
    }

    /// The absolute, standardized URL of `url` in the working directory now, without a trailing slash, so that paths
    /// compare equal.
    private static func absolute(_ url: URL) -> URL {
        var path = url.filePath
        if !path.hasPrefix("/") {
            path = FileManager.default.currentDirectoryPath + "/" + path
        }
        var standardized = URL(fileURLWithPath: path).standardizedFileURL.filePath
        while standardized.count > 1, standardized.hasSuffix("/") {
            standardized.removeLast()
        }
        return URL(fileURLWithPath: standardized)
    }
}
