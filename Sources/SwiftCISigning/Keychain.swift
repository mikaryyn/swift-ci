import SwiftCI

/// Unlocks keychains with the `security` command-line tool. A plain type with static methods: tests replace the
/// ``ProcessRunner`` to check the invocation.
public enum Keychain {
    /// Unlocks the keychain `name.keychain` with `password`. The password is sent to `security` on standard input,
    /// never as an argument.
    ///
    /// This call opens a step named "Unlock keychain MyKeychain" when called at the top level of a command. `step`
    /// renames it. The password is never part of the step name.
    ///
    /// - Parameters:
    ///   - name: The keychain name, without the `.keychain` extension.
    ///   - password: The keychain password.
    ///   - step: The step name, or `nil` for the default name.
    public static func unlock(name: String, password: Secret, step stepName: String? = nil) async throws {
        @Use var log: Log

        try await step(default: "Unlock keychain \(name)", name: stepName) {
            try await unlockKeychain(path: "\(name).keychain", password: password)
            log.success("Unlocked keychain '\(name)'.")
        }
    }

    /// Runs `security unlock-keychain` for the keychain at `path`. The password goes to `security -i` on standard
    /// input, so it is not an argument and not in the full log. A non-zero exit throws.
    static func unlockKeychain(path: String, password: Secret) async throws {
        let tool = try SecurityInteractive.tool(for: [
            SecurityArgument(kind: "command", value: "unlock-keychain"),
            SecurityArgument(kind: "option", value: "-p"),
            SecurityArgument(kind: "keychain password", value: try password.revealedValue()),
            SecurityArgument(kind: "keychain path", value: path),
        ])
        try await tool.run()
    }
}
