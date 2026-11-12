import Foundation

/// The path relative to the current directory, which is the repository in a SwiftCI run, if the path is inside it.
/// Otherwise the path as given. A relative path is resolved against the current directory first, and `.` and `..`
/// components are removed. A path that reaches the current directory through a symbolic link, such as `/var` and
/// `/private/var`, counts as inside it.
public func repositoryRelativePath(_ path: String) -> String {
    relativePath(of: path, inside: .currentDirectory()) ?? path
}

/// The path of `url` relative to the current directory, if it is inside it. Otherwise its plain path. It follows the
/// same rules as the overload for a path string.
public func repositoryRelativePath(_ url: URL) -> String {
    relativePath(of: url.filePath, inside: .currentDirectory()) ?? url.filePath
}

/// The path relative to `directory`, or `nil` if `path` is not inside it. It compares the standardized paths first,
/// then the paths with symbolic links resolved.
func relativePath(of path: String, inside directory: URL) -> String? {
    let normalizers: [(URL) -> URL] = [{ $0.standardizedFileURL }, { $0.resolvingSymlinksInPath() }]
    for normalize in normalizers {
        let base = normalize(directory).filePath
        let prefix = base.hasSuffix("/") ? base : base + "/"
        let absolutePath = normalize(URL(filePath: path, relativeTo: directory).absoluteURL).filePath
        if absolutePath.hasPrefix(prefix) {
            return String(absolutePath.dropFirst(prefix.count))
        }
    }
    return nil
}
