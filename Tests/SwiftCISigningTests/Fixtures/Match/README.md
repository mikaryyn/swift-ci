# fastlane match fixtures

Test fixtures for `MatchDecryption` (`Sources/SwiftCISigning/MatchDecryption.swift`). They are a generic match
repository for the team `TEAMID1234`, with a certificate and four ad hoc profiles, in the layout that fastlane match
uses.

## Layout

- `plain/`: the repository unencrypted: the certificate (`.cer`, DER), its private key (`.p12`, PEM RSA key, as
  fastlane's `cert` writes it), the signed profiles (`.mobileprovision`, CMS, DER), `README.md` and
  `match_version.txt`.
- `v1/`: the same repository, with every `.cer`, `.p12` and `.mobileprovision` encrypted in fastlane's v1 format (MD5).
- `v2/`: the same repository, encrypted in fastlane's v2 format.
- `extra/v1-sha256/`: the certificate encrypted in v1 with SHA-256, the fallback that fastlane uses when MD5 fails.
- `extra/pkcs12/plain/`: the key and the certificate as PKCS#12 (DER), with an empty passphrase, as `match import` can
  store a user-supplied file.
- `extra/pkcs12/v2/`: the same PKCS#12 file, encrypted in v2.
- `make-fixtures.sh`: regenerates all of the above.

The files are base64 text with fastlane's line breaks, every 60 characters.

## Regenerating

    Tests/SwiftCISigningTests/Fixtures/Match/make-fixtures.sh

The script builds everything in a new temporary directory, and then replaces `plain/`, `v1/`, `v2/` and `extra/`. It
needs three tools, and each has an environment variable to override it:

- `OPENSSL`: an openssl binary. The default is `/opt/homebrew/bin/openssl` (OpenSSL 4.1). `/usr/bin/openssl` is
  LibreSSL, and it is not used.
- `RUBY`: the Ruby that runs fastlane. The default is `/opt/homebrew/opt/ruby/bin/ruby`.
- `FASTLANE_DIR`: the fastlane gem directory. The default is `/opt/homebrew/lib/ruby/gems/4.0.0/gems/fastlane-2.232.2`.

If a tool is missing, the script says which variable to set.

The encryption is fastlane 2.232.2's own code, `Match::Encryption::MatchDataEncryption` and `EncryptionV1`, called from
the gem at `FASTLANE_DIR`. The SHA-256 file calls `EncryptionV1` with `hash_algorithm: "SHA256"`, and wraps the result
as `MatchDataEncryption` does. The salts are random, so the encrypted bytes change on each regeneration. The decrypted
content does not.

## Keys and passwords

- The password of all encrypted fixtures is `fixture-password`.
- The private key is a test key that signs nothing real. Its certificate is self-signed, with the subject
  `CN=SwiftCI Test Distribution (TEAMID1234)`, and it is not trusted by any Apple service.
- The certificate and the valid profiles were generated on 2026-11-04, and they expire on 2046-10-30, 7300 days later.
  The expired profile (`AdHoc_com.example.expired`) expired on 2020-01-01 by design. The decryption does not check
  expiry, so the test still decrypts it.
- `AdHoc_com.example.otherteam` has the team `OTHERTEAM1`, for the team mismatch cases.

## Tests

`MatchDecryptionTests` decrypts every encrypted file of `v1/` and `v2/` and compares it with `plain/`. The unpadding
password `wrong-532` is a fixed value: its MD5 decrypt of the app1 profile unpads, so only the content check rejects it.
It was found with fastlane's own `EncryptionV1` by trying `wrong-0`, `wrong-1` and so on, and `wrong-532` was the 533rd
try. If the fixtures are regenerated, that password must be found again, because the salts change.

## Real repository check

`MatchDecryptionManualCheck` decrypts a real match repository in memory and writes nothing. See the command in
`AGENTS.md`, "Building and testing".

Not run yet.
