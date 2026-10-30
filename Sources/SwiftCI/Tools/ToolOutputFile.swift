import Foundation

/// The copy of a tool's output that ``Tool/outputFile`` names. The file is created or truncated when the tool starts.
/// Each line is written as it arrives, without buffering, so a long run is on disk while it runs.
///
/// Lines are masked through ``SecretRegistry/redact(_:)``, as the full log is, and have no `[stderr] ` prefix.
final class ToolOutputFile {
    private let url: URL
    private let handle: FileHandle

    /// Creates the parent directory if it is missing, then creates the file, or truncates it if it exists.
    init(url: URL) throws {
        self.url = url
        let directory = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw BuildError(
                message: "Failed to create the directory '\(directory.filePath)' of the tool output file. Check that the directory is writable. Details: \(error)",
                code: .internal
            )
        }
        guard FileManager.default.createFile(atPath: url.filePath, contents: Data(), attributes: nil),
              let handle = FileHandle(forWritingAtPath: url.filePath)
        else {
            throw BuildError(
                message: "Failed to create the tool output file '\(url.filePath)'. Check that the directory is writable and that the name is a valid file name.",
                code: .internal
            )
        }
        self.handle = handle
    }

    /// Writes one line, with its line feed. The caller passes the text as the tool printed it.
    func write(_ line: String) throws {
        do {
            try handle.write(contentsOf: Data((SecretRegistry.redact(line) + "\n").utf8))
        } catch {
            throw BuildError(
                message: "Failed to write into the tool output file '\(url.filePath)'. Check that the disk is not full. Details: \(error)",
                code: .internal
            )
        }
    }

    /// Closes the file. A failure is thrown, so the run can fail.
    func close() throws {
        do {
            try handle.close()
        } catch {
            throw BuildError(
                message: "Failed to close the tool output file '\(url.filePath)'. Check that the disk is not full. Details: \(error)",
                code: .internal
            )
        }
    }
}
