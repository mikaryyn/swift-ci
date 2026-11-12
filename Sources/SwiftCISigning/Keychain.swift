import SwiftCI

/// Unlocks keychains with the `security` command-line tool. A plain type with static methods: tests replace the
/// ``ProcessRunner`` to check the invocation.
public enum Keychain {
    /// Unlocks the keychain `name.keychain` with `password`. A `name` that already ends in `.keychain` or
    /// `.keychain-db` is used as it is, so `login.keychain-db` unlocks that file. The password is sent to `security` on
    /// standard input, never as an argument.
    ///
    /// A keychain that does not exist, a wrong password or any other failure of `security` throws a ``BuildError`` that
    /// names the keychain and gives the output of `security`. An argument that `security` cannot read, such as a password
    /// with a line feed, is a usage error.
    ///
    /// This call opens a step named "Unlock keychain MyKeychain" when called at the top level of a command. `step`
    /// renames it. The password is never part of the step name.
    ///
    /// - Parameters:
    ///   - name: The keychain name, without the `.keychain` extension, or the file name with its extension.
    ///   - password: The keychain password.
    ///   - stepName: The step name, or `nil` for the default name.
    public static func unlock(name: String, password: Secret, step stepName: String? = nil) async throws {
        @Use var log: Log

        try await step(default: "Unlock keychain \(name)", name: stepName) {
            do {
                try await unlockKeychain(path: keychainPath(name: name), password: password)
            } catch let error as BuildError where error.code != .usage {
                throw BuildError(
                    message: "Failed to unlock the keychain '\(name)'. Check that the keychain exists and that the password "
                        + "is correct. Details: \(error.message)",
                    code: error.code
                )
            }
            log.success("Unlocked keychain '\(name)'.")
        }
    }

    /// The path that `security` gets for `name`: `name.keychain`, or `name` itself if it already has an extension.
    static func keychainPath(name: String) -> String {
        name.hasSuffix(".keychain") || name.hasSuffix(".keychain-db") ? name : "\(name).keychain"
    }

    /// Runs `security unlock-keychain` for the keychain at `path`. The password goes to `security -i` on standard
    /// input, so it is not an argument and not in the full log. The full log gets a line that names the operation, since
    /// its header shows only `security -i`. A non-zero exit throws.
    static func unlockKeychain(path: String, password: Secret) async throws {
        let tool = try SecurityInteractive.tool(for: [
            SecurityArgument(kind: "command", value: "unlock-keychain"),
            SecurityArgument(kind: "option", value: "-p"),
            SecurityArgument(kind: "keychain password", value: try password.revealedValue()),
            SecurityArgument(kind: "keychain path", value: path),
        ])
        try FullLog.write("Unlocking keychain \(path) with security unlock-keychain. The command is sent to security -i on standard input.")
        try await tool.run()
    }
}
