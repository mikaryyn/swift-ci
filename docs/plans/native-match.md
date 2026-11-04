# Native match install

Status: **in progress** (N2 to N4 done). Phase 3 of the
[implementation plan](implementation-plan.md#phase-3-replace-fastlane): the
read-only install of signing assets from a fastlane match repository, without
fastlane.

## Progress

- [x] (2026-11-03) Plan written.
- [x] (2026-11-04) Prototype reviewed against this plan and fastlane 2.232.2's
  source (see Starting point). It cannot have worked on a real repository:
  fastlane's base64 has line breaks, which the prototype's decoder rejects.
- [x] (2026-11-04) N2: decryption, with the fixtures. `MatchDecryption.swift`,
  the fixtures (written by fastlane's own encryption code), 19 unit tests and
  `MatchDecryptionManualCheck`, run against the v1 and v2 fixtures. The
  prototype's `decryptFileInPlace` now calls it.
- [x] (2026-11-04) N3: selection. `MatchSelection.select` (internal) reads
  the profile of each identifier, checks team and expiry, picks the
  certificate by `DeveloperCertificates`, checks its expiry and decrypts its
  `.p12`, each file once. `withCheckout` clones once, shallow, into a 0700
  temporary directory that is deleted afterwards. `ProvisioningProfile`
  (CMS decoding, shared with the N2 content check), `CertificateInfo`
  (common name, SHA-1, expiry) and `MatchType.development`. The fixtures have
  a second certificate that no profile uses, an expired certificate, a
  profile whose certificate is not in the repository, and an App Store
  profile.
- [x] (2026-11-04) N4: installation and check. `MatchKeychainPath` (`<name>-db`
  first), `MatchInstallation.install` (imports through a 0700 directory that
  is deleted right after the imports; a failed import throws; the partition
  list once, a warning on failure; profiles as `<UUID>.mobileprovision` in the
  Xcode 16 folder; the `find-identity -v` check; one log line per profile),
  and `MatchNativeInstall.install`, the whole flow without a step, which N1
  wraps. Unit tests with mocks; `MatchInstallManualCheck` compiles and is
  skipped (not run yet). Next: N1.
- [ ] N1: the API and the fastlane path; `matchUpdateBuiltin` removed.
- [x] (2026-11-04) Real repository check (N2) by the adopter's maintainer: 62
  files, 0 failed; 61 v2 and 1 v1; 1 certificate, 1 PEM private key, no
  PKCS#12, 60 profiles. Recorded in the fixture README.
- [ ] Manual check on a developer Mac: the end-to-end install of the fixture
  repository (`SWIFTCI_MANUAL_MATCH_CHECK=1 swift test --disable-sandbox
  --filter MatchInstallManualCheck`). With the self-signed fixture certificate
  the `find-identity -v` check must fail; the check asserts that, and that the
  identity and the profiles were installed.
- [ ] Parity run of `.native` and `.fastlane` on the adopter's CI Mac
  (adopter side, `docs/plans/swiftci-native-match.md` in the iOS repository).

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
  prototype, added in 7f6335e (2026-10-27, "feat: add native fastlane match
  workflow") and since then only moved by the module split (eeac7e6) and the
  inputs rework (92555af). Nothing calls it, and nothing shows that it ever ran
  against a real match repository. It clones the repository, decrypts v1 and v2 files, imports the
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
  - **It cannot decrypt a real repository.** fastlane writes each file with
    Ruby's `Base64.encode64`, which breaks the text into lines of 60
    characters (`match/lib/match/encryption/encryption.rb`,
    `MatchDataEncryption#encrypt`). The prototype decodes with
    `Data(base64Encoded:)` without options, which returns `nil` for text with
    line breaks (checked with a Swift snippet on 2026-11-04), and it treats
    `nil` as "already decrypted". Every file stays encrypted, `security
    import` fails, and that failure is only a warning.
  - If the checkout of the branch fails, it logs a warning and goes on with the
    default branch.
  - The `.p12` path replaces every `.cer` in the full path
    (`replacingOccurrences(of: ".cer")`), not only the extension.
  - The partition list runs once per import, so twice per call.
  - The `sigh_*` variables that it sets with `setenv` are inherited by every
    later child process.
  - `-P` (the `.p12` passphrase) is an argument, which the tool log shows. It
    is empty for match files, but must stay so.
  - There are no encrypted fixtures, and no tests of decryption, selection or
    installation. Its only test (`FastlaneTests.swift`, a line feed in
    `MATCH_KEYCHAIN_PASSWORD`) stops before any tool runs.

What to keep from `Fastlane.swift` (by function name; the line numbers move):

- Decryption, as the base of N2: `decryptV2` and `pbkdf2sha256`, and
  `decryptV1`, `evpBytesToKey`, `digest` and `aes256cbcDecrypt`. They follow
  fastlane's layout (checked against the source, see Reference). They need
  length checks, the base64 fix and the content check of N2.
- Keychain: `partitionListTool` with `SecurityInteractive` (the password goes
  on standard input), the "already exists" handling of `runImport` (but a
  failure throws, N4.2), and `Keychain.unlock` and `GitCredentialHelper`,
  which have their own tests.
- Names: `mapCertType`, `mapProvType` and `profileFileBaseName`, and the field
  parsing of `decodeProvisioningProfile` as the model for N3.3 (with
  `CMSDecoder` instead of `security cms -D`).

To rewrite: the body of `matchUpdateBuiltin`, `decryptMatchRepository` and
`decryptFileInPlace` (decrypt only the selected files, in memory),
`selectCertURL`, `resolveKeychainURL`, `installProvisioningProfile`, the
`setenv` calls and `envVarName`, and the cleanup of the temporary directories.

The README already documents the N1 API (`Signing.installMatchAssets(using:
.native)`) and marks the native match row "Prototype"; its example does not
compile until N1.

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

- The file is base64 text with line breaks (Ruby's `Base64.encode64`, 60
  characters per line). Decode with `.ignoreUnknownCharacters`, or remove the
  line breaks first. fastlane reads it with `Base64.decode64`, which ignores
  them.
- v2 (`match_encrypted_v2__` prefix after base64 decoding): salt 8 bytes, GCM
  tag 16 bytes, ciphertext; that is, salt at bytes 20..<28, tag at 28..<44,
  ciphertext from 44. Key, IV and AAD from PBKDF2-HMAC-SHA256 with 10,000
  rounds, 68 bytes (32 + 12 + 24). AES-256-GCM with CryptoKit. A wrong password
  fails the tag check.
- v1 (`Salted__` prefix): salt 8 bytes, ciphertext. Key and IV with
  EVP_BytesToKey (one iteration), MD5 first, SHA-256 if MD5 fails, as fastlane
  does. AES-256-CBC with PKCS#7. Padding errors mean a wrong password. v1 has
  no integrity check: a wrong password unpads without an error in about 0.4%
  of cases, in either digest (fastlane's own comment, issue 21663), so the
  content check below is what catches it.
- Every length is checked before slicing. A file that is not base64 text is
  an error, not "already decrypted": match repositories hold only encrypted
  files besides `README.md` and `match_version.txt`.
- After decrypting, the content is checked by type: a `.cer` must be a DER
  certificate (`SecCertificateCreateWithData`), a `.p12` must be a PEM private
  key (what fastlane writes) or a DER PKCS#12 (what `match import` can store),
  checked by structure, and a profile must decode as CMS to a property list
  dictionary. This catches a wrong v1 password that happens to unpad. A v1 file
  whose MD5 result fails the content check is tried with SHA-256 too. See
  Surprises & Discoveries for why `SecPKCS12Import` is not used.
- A failure names the file and says "Couldn't decrypt <file>. Check the match
  password.", as fastlane does. The password is never logged.
- A profile is checked by decoding it as in N3.

**Real repository check.** The fixtures prove the format only as far as the
plan's reading of fastlane goes. Add a manual check, gated like
`KeychainManualCheck.swift`, that decrypts a real match repository in memory:

    SWIFTCI_MANUAL_MATCH_REPOSITORY=<path to a local clone> MATCH_PASSWORD=<password> \
        swift test --disable-sandbox --filter MatchDecryptionManualCheck

It decrypts every `.cer`, `.p12` and `.mobileprovision` under the path, runs
the content check of each, writes nothing, and prints only the relative path,
the format (v1 or v2) and the type of each file. A maintainer with access to
the repository runs it on a developer Mac, then deletes the clone. Note the
result (date, fastlane version that wrote the files, counts per format) in the
fixture README.

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
  `fixture-password`, once with v1 (MD5) and once with v2, by fastlane
  2.232.2's own `Match::Encryption::MatchDataEncryption`, which the script
  runs with Homebrew's Ruby from the installed gem. A v1 file with SHA-256 and
  a PKCS#12 key encrypted with v2 are in `extra/`. (Done 2026-11-04; see
  Decisions.)

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

## Reference and working notes

- **fastlane's source.** fastlane 2.232.2, the version the adopter pins, is
  installed on the development Mac as a gem:
  `/opt/homebrew/lib/ruby/gems/4.0.0/gems/fastlane-2.232.2` (or `gem contents
  fastlane`). The files that matter: `match/lib/match/encryption/encryption.rb`
  (both formats, the key derivation, the base64), `match/lib/match/encryption/openssl.rb`
  (which files are encrypted: `*.cer`, `*.p12`, `*.mobileprovision`,
  `*.provisionprofile`), `match/lib/match/runner.rb` and `match/lib/match/utils.rb`
  (selection, import, profile install),
  `fastlane_core/lib/fastlane_core/keychain_importer.rb` (the `security
  import` arguments and the partition list), and
  `fastlane_core/lib/fastlane_core/provisioning_profile.rb` (the profile
  directory: `UserData` for Xcode 16 and later, `MobileDevice` before).
- **Build and test.** From the repository root: `swift build --disable-sandbox
  --scratch-path "$HOME/Library/Caches/swiftci-lib-build"`, and `swift test`
  with the same flags. Use that scratch path; the default `.build` has had
  stale locks that hang a build. The test suites that use global state are
  nested in `GlobalStateTests`, so filter by suite name, such as `--filter
  MergeRequestCommentTests`, not by target name.
- **What an agent cannot do here.** The development sandbox has no access to
  the adopter's certificates repository or its match password, cannot change
  keychains, and `security cms -D` fails in it. The fixture tests and the
  mocked `security` and `git` calls work; the manual checks and the parity
  run need the maintainer.

## Risks

- fastlane's v2 format is not documented. Reading fastlane 2.232.2's source
  (see Reference) confirms the prototype's layout and key derivation; the
  real repository check of N2 is the proof.
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

## Surprises & Discoveries

- Observation: a match `.p12` is usually not PKCS#12. fastlane `cert`, which
  match runs to create a certificate, writes the private key to `<id>.p12` as
  `OpenSSL::PKey::RSA#to_s`, a PEM text `-----BEGIN RSA PRIVATE KEY-----`. Only
  `match import` copies a user-supplied file, which can be a real PKCS#12.
  `security import` accepts both.
  Evidence: fastlane 2.232.2 `cert/lib/cert/runner.rb` (`create_certificate`,
  `File.write(private_key_path, pkey)`) and
  `spaceship/lib/spaceship/connect_api/models/certificate.rb`
  (`create_certificate_signing_request`); `OpenSSL::PKey::RSA.new(2048).to_s`
  in Ruby 4.0 starts with `-----BEGIN RSA PRIVATE KEY-----`.

- Observation: `SecPKCS12Import` with an empty passphrase fails with
  errSecAuthFailed (-25293) for a correct OpenSSL 4.1 export with an empty
  password (also with `-legacy`), with or without `kSecImportToMemoryOnly`.
  With a non-empty passphrase the memory-only import works. So the `.p12`
  content check is structural (the DER outer SEQUENCE spans the whole data),
  not an import. Whether `security import -P ""` accepts such a file is open
  until N4's manual check. The adopter's repository has no PKCS#12 (real
  repository check, 2026-11-04), so it does not block the adopter.
  Evidence: a Swift snippet in the development sandbox, 2026-11-04.

- Observation: `CMSDecoder` decodes an `openssl cms -sign -nodetach` message in
  the development sandbox without a keychain, and rejects garbage and a DER
  certificate at `CMSDecoderFinalizeMessage` (-25257).
  Evidence: the same snippet, and `MatchDecryptionTests`.

- Observation: a wrong v1 password unpadded by chance after 533 tries
  (`wrong-532` on the app1 profile fixture), about 0.2%, the same order as
  fastlane's 0.4% estimate. `MatchDecryptionTests` keeps that case.
  Evidence: `Tests/SwiftCISigningTests/Fixtures/Match/README.md`.

- Observation: a CMS-signed profile can't be built in a test without a
  keychain identity (an unsigned `CMSEncoder` message has no content), so the
  missing-key cases of the profile decoder are tested through an internal
  `ProvisioningProfile(propertyList:file:)` that the data initializer uses.
  Evidence: `ProvisioningProfileTests`.

- Observation: fastlane sets the partition list only after an import that
  succeeds, so on a persistent keychain where the items already exist it
  never sets it again. SwiftCI sets it once per call, always; it is
  idempotent.
  Evidence: `fastlane_core/lib/fastlane_core/keychain_importer.rb`.

- Observation: the fixture certificate is self-signed, so `find-identity -v`
  never lists it as valid, and the manual install check cannot reach a
  passing check. Making it trusted would change the user's trust settings,
  which needs a password prompt. The parity run with the real certificate
  proves the passing case.

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

- **The fixtures are encrypted by fastlane's own code** (2026-11-04), run
  from `make-fixtures.sh` with Homebrew's Ruby and the installed fastlane gem,
  instead of `openssl enc` and a Swift encoder. They are what fastlane writes,
  so the manual comparison of a Swift encoder with fastlane is not needed.
  Ruby and fastlane are needed only to regenerate the fixtures, not to build
  or test SwiftCI.
- **A v1 file is tried with MD5, then SHA-256, and each result must pass the
  content check** (2026-11-04). fastlane accepts any MD5 result that unpads;
  SwiftCI is stricter, so a wrong password or digest never yields garbage.
- **A file that is not base64 text, or has no match prefix, fails the
  decryption** (2026-11-04), with the file name and the reason. The prototype
  skipped such files as "already decrypted".

- **No check of the profile's `application-identifier` against the bundle
  identifier** (2026-11-04). The file name already selects the profile, and
  old App IDs can have a prefix other than the team ID. The value is read and
  kept for the log.

- **The profiles are written before the identity check** (2026-11-04). A
  failed check leaves them in the folder; they are harmless, and profiles
  from earlier runs stay there anyway.

## Open questions

None at the moment.
