# Native match install

Status: **planned**. Phase 3 of the
[implementation plan](implementation-plan.md#phase-3-replace-fastlane): the
read-only install of signing assets from a fastlane match repository, without
fastlane.

## Goal

A script installs the certificates and provisioning profiles that a fastlane
match repository holds for a list of bundle identifiers, with one call:

    let profiles = try await Signing.installMatchAssets(
        type: .adhoc,
        bundleIdentifiers: ["com.example.app", "com.example.app.beta"],
        teamId: "TEAMID1234",
        repository: MatchRepository(url: "git@git.example.com:ios/certificates.git"),
        password: Secret("MATCH_PASSWORD"),
        keychain: .existing(name: "ci.keychain", password: Secret("KEYCHAIN_PASSWORD")),
        using: .native
    )

With `using: .native` no Ruby runs. With `using: .fastlane(…)` the same call
runs `fastlane match --readonly` with the same values, so a project can switch
between the two by changing one argument and compare the results on the same
machine. The README already shows this API in its example and in
[Native implementations and explicit fallbacks](../../README.md#native-implementations-and-explicit-fallbacks);
the code does not have it yet.

The first adopter is an iOS project on a self-hosted Jenkins Mac. It installs
ad-hoc assets for 25 bundle identifiers on every internal build, and App Store
assets for the same identifiers on every App Store deploy, into a persistent
keychain `fastlane.keychain` that already exists on the CI Mac and is unlocked
by the script before the install.

## Starting point

`Sources/SwiftCISigning/Fastlane.swift` has two paths:

- `Fastlane.match(type:appIdentifiers:teamId:invocation:environment:verbose:step:)`
  runs `fastlane match <type> --readonly`. It is the one in use. The repository
  URL and the keychain come from the project's `Matchfile`.
- `Fastlane().matchUpdateBuiltin(type:appIdentifier:teamId:step:)` is a native
  prototype. It clones the repository, decrypts v1 and v2 files, imports the
  certificate and key with `security import`, sets the partition list, and
  copies the profile. Its gaps decide this plan:
  - `Fastlane` has no public initializer, so another module cannot call it.
  - All configuration comes from process environment variables
    (`MATCH_GIT_URL`, `MATCH_KEYCHAIN_NAME`, …). `teamId` is not used.
  - One bundle identifier per call: 25 identifiers mean 25 clones.
  - The default keychain is `login.keychain-db`, and a bare name such as
    `fastlane.keychain` resolves without the `-db` suffix that macOS uses.
  - A failed import other than "already exists" and a failed partition list
    are only warnings. Nothing checks afterwards that `codesign` can use the
    identity.
  - The certificate is the last `*.cer` in sorted order, not the one the
    profile was made for, and its validity is not checked.
  - Profiles go to `~/Library/MobileDevice/Provisioning Profiles`. Xcode 16
    and later read `~/Library/Developer/Xcode/UserData/Provisioning Profiles`,
    and fastlane 2.232 writes there (recording
    `Tests/SwiftCISigningTests/Fixtures/Fastlane/match-readonly.txt`).
  - Decrypted private keys stay in `$TMPDIR/swift-ci/match-<UUID>/`.
  - Decryption reads binary files as UTF-8, slices without length checks, and a
    wrong password can produce garbage in v1 without an error.
  - It sets `sigh_*` environment variables in the process, which nothing reads.
  - There are no encrypted fixtures and no tests of decryption, selection or
    installation.

## Non-goals

- Creating or renewing certificates and profiles (`match --force`). Projects
  keep running fastlane by hand for these rare changes.
- Temporary keychains per run. The keychain must exist and be unlocked by the
  caller (`Keychain.unlock`). See Decisions.
- Changing the keychain search list or the default keychain.
- Downloading Apple's intermediate certificates. They are installed once on a
  CI Mac; a missing one makes the post-install check fail with a clear message.
- Storage backends other than Git (S3, Google Cloud Storage, GitLab secure
  files) and macOS or Developer ID assets. Add them when a project needs them.

## N1: API and the fastlane path

In `Sources/SwiftCISigning/`, add `Signing.swift`:

    public struct MatchRepository: Sendable {
        public init(url: String, branch: String = "master",
                    basicAuthorization: Secret? = nil, bearerAuthorization: Secret? = nil)
    }

    public enum MatchKeychain: Sendable {
        /// An existing keychain in ~/Library/Keychains, unlocked by the caller. The password is used for the
        /// partition list, so that codesign can use the imported key without a prompt.
        case existing(name: String, password: Secret)
    }

    public enum MatchImplementation: Sendable {
        case native
        case fastlane(invocation: FastlaneInvocation = .direct,
                      environment: [String: ToolEnvironmentValue] = [:], verbose: Bool = false)
    }

    public struct InstalledProfile: Equatable, Sendable {
        public var bundleIdentifier: String
        public var name: String          // such as "match AdHoc com.example.app"
        public var uuid: String
        public var teamIdentifier: String
        public var certificateName: String
        public var expirationDate: Date
        public var url: URL
    }

    public enum Signing {
        public static func installMatchAssets(
            type: MatchType,
            bundleIdentifiers: [String],
            teamId: String,
            repository: MatchRepository,
            password: Secret,
            keychain: MatchKeychain,
            using implementation: MatchImplementation,
            step name: String? = nil
        ) async throws -> [InstalledProfile]
    }

It opens the step "Install match <type> signing assets" and logs which
implementation ran, with fastlane's version for the fastlane path (README
rule 3).

The fastlane path calls the existing `Fastlane.match` with
`--git_url`, `--git_branch`, `--keychain_name` and `--team_id` as arguments,
and `MATCH_PASSWORD`, `MATCH_KEYCHAIN_PASSWORD` and the Git authorization
variables in the tool environment, so the values passed to the call win over a
`Matchfile`. It returns the profiles that the native reader (N3) finds in the
profile directory for the identifiers afterwards, so both paths return the
same value.

Remove `matchUpdateBuiltin` and its environment variables; its code moves into
the native path. This is a breaking change, allowed in 0.x, and noted in the
changelog.

## N2: Decryption

Move decryption into `MatchDecryption.swift`, internal, working on `Data`:

- v2 (`match_encrypted_v2__` prefix after base64 decoding): salt 8 bytes, GCM
  tag 16 bytes, ciphertext. Key, IV and AAD from PBKDF2-HMAC-SHA256 with 10,000
  rounds, 68 bytes (32 + 12 + 24). AES-256-GCM with CryptoKit. A wrong password
  fails the tag check.
- v1 (`Salted__` prefix): salt 8 bytes, ciphertext. Key and IV with
  EVP_BytesToKey, MD5 first, SHA-256 if MD5 fails. AES-256-CBC with PKCS#7.
  Padding errors mean a wrong password.
- Every length is checked before slicing. A file that is not base64 text is
  an error, not "already decrypted": match repositories hold only encrypted
  files besides `README.md` and `match_version.txt`.
- After decrypting, the content is checked by type: a `.cer` must be a DER
  certificate (`SecCertificateCreateWithData`), a `.p12` must import into a
  memory-only `SecPKCS12Import` with an empty passphrase, and a profile must
  decode as CMS. This catches a wrong v1 password that happens to unpad.
- A failure names the file and says "Couldn't decrypt <file>. Check the match
  password.", as fastlane does. The password is never logged.
- A profile is checked by decoding it as in N3.

Decrypted data stays in memory where possible. Files that `security import`
needs are written to a directory with mode 0700 that is deleted when the
install ends, successful or not.

## N3: Selection

1. Clone once per call, `git clone --depth 1 --branch <branch>` into a
   temporary directory that is deleted at the end (with the Git authorization
   of N1, through `GIT_CONFIG_*`, as today).
2. For each bundle identifier, read
   `profiles/<adhoc|appstore|enterprise|development>/<AdHoc|AppStore|InHouse|Development>_<id>.mobileprovision`.
   A missing profile fails the install with the identifier and the path.
3. Decode the profile in-process with the Security framework's `CMSDecoder`
   (`CMSDecoderCreate`, `CMSDecoderUpdateMessage`, `CMSDecoderFinalizeMessage`,
   `CMSDecoderCopyContent`) and read from the property list `UUID`,
   `Name`, `TeamIdentifier`, `ExpirationDate`, `Entitlements` and
   `DeveloperCertificates`. A profile of another team, or one that has expired,
   fails the install.
4. The certificate is the one in `certs/<distribution|development>/` whose DER
   data equals one of the profile's `DeveloperCertificates`. Its `.p12` has the
   same file name. No match fails the install with the profile name. An expired
   certificate fails it too. Usually all identifiers share one certificate; it
   is imported once.

## N4: Installation and check

1. **Keychain path.** `existing(name:)` resolves to
   `~/Library/Keychains/<name>-db` if that file exists, else
   `~/Library/Keychains/<name>`, else the install fails with "Keychain <name>
   not found". A name that is already a path is used as is.
2. **Import.** `security import <file> -k <keychain> -P "" -T /usr/bin/codesign
   -T /usr/bin/security -T /usr/bin/productbuild -T /usr/bin/productsign` for
   the certificate and the `.p12`. Exit 1 with "already exists" is success.
   Any other failure fails the install with `security`'s message.
3. **Partition list.** Once per call, after the imports:
   `set-key-partition-list -S apple-tool:,apple:,codesign: -s -k <password>
   <keychain>` through `security -i`, so the password is not an argument. A
   failure is a warning (Known issues: non-ASCII passwords on macOS 26), and
   the check below decides whether the install works.
4. **Profiles.** Each profile is written to
   `~/Library/Developer/Xcode/UserData/Provisioning Profiles/<UUID>.mobileprovision`,
   replacing a file with the same UUID. Other files in the directory are not
   touched.
5. **Check.** `security find-identity -v -p codesigning` (the user's search
   list, as `codesign` sees it) must list the certificate's SHA-1. If it does
   not, the install fails with: the identity is not usable; check that the
   keychain is unlocked and in the search list (`security list-keychains -d
   user`) and that Apple's intermediate certificates are installed.
6. **Log.** One line per profile: name, UUID, expiry and certificate name.
   No `sigh_*` variables are set.

## Fixtures

The fixtures are made once by `Tests/SwiftCISigningTests/Fixtures/Match/make-fixtures.sh`
and committed with the script:

- A self-signed code signing certificate and key for "SwiftCI Test
  Distribution (TEAMID1234)", made with `openssl`, exported as `.cer` (DER) and
  `.p12` (empty passphrase).
- Two profiles, `AdHoc_com.example.app1` and `AdHoc_com.example.app2`, as
  property lists with the fields of N3 and the certificate in
  `DeveloperCertificates`, signed into CMS with `openssl cms -sign -nodetach
  -outform der`. A third profile for another team and a fourth that has
  expired.
- The same repository layout encrypted twice with the password
  `fixture-password`: once with v1 (`openssl enc -aes-256-cbc -md md5 -salt`,
  then base64) and once with v2, by a small Swift encoder in the test support
  that mirrors N2. Check the v2 encoder once against fastlane's
  `Match::Encryption::OpenSSL` (fastlane 2.232) by decrypting a fastlane
  encrypted file in a manual run; note the result in the fixture README.

The key in the fixtures is a test key that signs nothing real.

## Tests

Unit tests, with `ProcessRunnerMock` for `git`, `security` and `fastlane`:
decryption of every fixture file in v1 and v2, a wrong password in both, a
truncated file, a non-base64 file; selection by `DeveloperCertificates`, a
missing profile, another team, an expired profile; the import arguments, the
"already exists" case, a failed import; the partition list once per call with
the password on standard input; the profile file name and replacement; the
check passing and failing; the temporary directories deleted after success and
after failure; the fastlane path's arguments and environment; secrets masked in
the recorded log.

A manual end-to-end check, gated by `SWIFTCI_MANUAL_MATCH_CHECK=1` like
`KeychainManualCheck.swift`: it creates a throwaway keychain, adds it to the
search list, installs the v2 fixture repository from a local `file://` clone,
checks `security find-identity`, and restores the search list and deletes the
keychain and the fixture profiles afterwards.

## Order

N2 first, with the fixtures, since everything depends on correct decryption.
Then N3, N4 and N1. Then the manual check on a developer Mac. Then the adopter
compares `.native` and `.fastlane` on its CI Mac. Each milestone is a separate
change with its own tests and README updates (the signing rows of the
capabilities table, the example, and Known issues).

## Risks

- fastlane's v2 format is not documented. The prototype follows fastlane's
  source; the manual check against a fastlane-encrypted file is the proof.
- The CI Mac's search list or intermediate certificates may differ from a
  developer Mac. The post-install check makes that a clear failure instead of a
  `codesign` error later.
- `security cms -D -i`, which the prototype used, imports the signer's
  certificate into a keychain while decoding: in a sandbox it fails with
  "cert import failed: Operation not permitted". `CMSDecoder` is used instead.
  Check on a developer Mac that it decodes real match profiles and the
  `openssl`-signed fixtures without touching a keychain.
- Profiles from earlier runs pile up in the profile directory, as they do with
  fastlane. Cleaning them is not this plan's job.

## Decisions

- **Persistent keychain, unlocked by the caller** (2026-11-03, adopter
  maintainer). The adopter's CI Mac already has `fastlane.keychain`, and
  changing one thing at a time keeps the parity check meaningful. Temporary
  keychains stay on the roadmap.
- **One call for all identifiers, one clone** (2026-11-03).
- **The certificate is chosen by the profile's `DeveloperCertificates`**
  (2026-11-03), not by file order. It is what Xcode does when it signs.
- **An install that does not leave a usable identity fails** (2026-11-03).
  Whether the step may fail is the caller's choice (`step(_:failure:)`).
- **Profiles go to the Xcode 16 and later directory** (2026-11-03). SwiftCI's
  minimum is Xcode 26.

## Open questions

None at the moment.
