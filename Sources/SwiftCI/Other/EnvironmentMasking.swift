import Foundation

/// Guesses which environment values are secret, so that ``Environment/writeToLog(reveal:)`` can mask them.
///
/// It masks a value when the variable name looks like the name of a secret, or when the value has a well-known secret
/// format. A URL with a password keeps the URL and masks only the password. Values are not judged by how random they
/// look, because commit hashes, build IDs and UUIDs would be masked too. This only affects the variable dump; it does
/// not register the values as secrets.
enum EnvironmentMasking {
    /// Name parts that mark a secret when they stand alone, for example `KEY` in `API_KEY`.
    private static let secretParts: Set<String> = ["KEY", "PASS", "PIN", "AUTH", "DSN", "COOKIE"]

    /// Name parts that mark a secret when a part ends with them, also in plural, for example `GITLABTOKEN`.
    private static let secretSuffixes = [
        "PASSWORD", "PASSWD", "PASSPHRASE", "SECRET", "TOKEN", "APIKEY", "CREDENTIAL", "AUTHORIZATION", "WEBHOOK",
        "PRIVATEKEY",
    ]

    /// Parts that, right after a key part, name something about the key rather than the key itself, for example
    /// `ASC_KEY_ID` or `PRIVATE_KEY_PATH`.
    private static let keyMetadataParts: Set<String> = ["ID", "ISSUER", "PATH", "FILE", "NAME"]

    /// Names that match the rules but are not secret.
    private static let exemptNames: Set<String> = ["PWD", "OLDPWD", "SSH_AUTH_SOCK"]

    /// Values in these formats are masked whatever the variable is called.
    nonisolated(unsafe) private static let secretValuePatterns: [Regex<Substring>] = [
        /gh[pousr]_[A-Za-z0-9]{20,}/,  // GitHub tokens
        /github_pat_[A-Za-z0-9_]{20,}/,
        /gl(?:pat|cbt|dt|rt)-[A-Za-z0-9_\-]{20,}/,  // GitLab tokens
        /xox[abprs]-[A-Za-z0-9\-]{10,}/,  // Slack tokens
        /hooks\.slack\.com\/services\//,  // Slack webhook URLs
        /AKIA[0-9A-Z]{16}/,  // AWS access key IDs
        /-----BEGIN [A-Z ]*PRIVATE KEY-----/,
        /eyJ[A-Za-z0-9_\-]+\.eyJ[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]*/,  // JWTs
    ]

    /// The password of a URL such as `https://user:password@host`, between the scheme and user (group 1) and the `@`.
    nonisolated(unsafe) private static let urlPassword = /([A-Za-z][A-Za-z0-9+.\-]*:\/\/[^\/\s:@]*):([^\/\s@]+)@/

    /// The value to print for the variable `name`: the value itself, the value with URL passwords masked, or the mask.
    static func masked(name: String, value: String) -> String {
        if value.isEmpty { return value }
        if isSecretName(name) || secretValuePatterns.contains(where: { value.contains($0) }) {
            return SecretRegistry.mask
        }
        return value.replacing(urlPassword) { "\($0.1):\(SecretRegistry.mask)@" }
    }

    /// Whether `name` looks like the name of a variable that holds a secret. The name is split at `_` and compared
    /// without case.
    static func isSecretName(_ name: String) -> Bool {
        let upper = name.uppercased()
        if exemptNames.contains(upper) { return false }
        let parts = upper.split(separator: "_").map(String.init)
        for (index, part) in parts.enumerated() {
            let isKey = part == "KEY" || part.hasSuffix("APIKEY") || part.hasSuffix("PRIVATEKEY")
            if isKey, index + 1 < parts.count, keyMetadataParts.contains(parts[index + 1]) {
                continue
            }
            if secretParts.contains(part) { return true }
            if secretSuffixes.contains(where: { part.hasSuffix($0) || part.hasSuffix($0 + "S") }) { return true }
        }
        return false
    }
}
