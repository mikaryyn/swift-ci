# fastlane match fixtures

Test fixtures for `MatchDecryption` (`Sources/SwiftCISigning/MatchDecryption.swift`) and for match selection
(`Sources/SwiftCISigning/MatchSelection.swift`). They are a generic match repository for the team `TEAMID1234`, with
three certificates and seven profiles (six ad hoc and one App Store), in the layout that fastlane match uses.

## Layout

- `plain/`: the repository unencrypted: the certificates (`.cer`, DER), their private keys (`.p12`, PEM RSA keys, as
  fastlane's `cert` writes them), the signed profiles (`.mobileprovision`, CMS, DER), `README.md` and
  `match_version.txt`. The files that the selection tests use are:
  - `certs/distribution/CERTID1234.cer` and `.p12`: the certificate that signs the profiles, and its key. Its common
    name is `SwiftCI Test Distribution (TEAMID1234)`.
  - `certs/distribution/CERTID9999.cer` and `.p12`: a second valid certificate and its key, with the common name
    `SwiftCI Test Distribution 2 (TEAMID1234)`. No profile uses it. It sorts after `CERTID1234`, so a selection that
    takes the last certificate by name would pick it. Selection must pick the certificate that the profile lists.
  - `certs/distribution/CERTIDEXPD.cer` and `.p12`: an expired certificate and its key, valid from 2019-01-01 to
    2020-01-01. Only `AdHoc_com.example.expiredcert` uses it.
  - `profiles/adhoc/AdHoc_com.example.app1` and `app2`: valid profiles of the team, made with `CERTID1234`.
  - `profiles/adhoc/AdHoc_com.example.otherteam`: a valid profile of the team `OTHERTEAM1`.
  - `profiles/adhoc/AdHoc_com.example.expired`: a profile that expired on 2020-01-01.
  - `profiles/adhoc/AdHoc_com.example.expiredcert`: a valid profile whose certificate is `CERTIDEXPD`.
  - `profiles/adhoc/AdHoc_com.example.nocert`: a valid profile whose certificate is not in the repository. The
    certificate is generated for this file and not stored.
  - `profiles/appstore/AppStore_com.example.app1`: a valid App Store profile, so that the mapping of two types to their
    folders is tested.
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
- Each certificate has its own test key that signs nothing real. The certificates are self-signed, with the subjects
  `CN=SwiftCI Test Distribution (TEAMID1234)`, `CN=SwiftCI Test Distribution 2 (TEAMID1234)` and
  `CN=SwiftCI Test Distribution Expired (TEAMID1234)`, and no Apple service trusts them. All the profiles are signed
  with the key of `CERTID1234`.
- The certificates `CERTID1234` and `CERTID9999` and the valid profiles were generated on 2026-11-04, and they expire on
  2046-10-30, 7300 days later. The expired certificate (`CERTIDEXPD`) and the expired profile
  (`AdHoc_com.example.expired`) expired on 2020-01-01 by design. The decryption does not check expiry, so the decryption
  tests still decrypt them. The selection tests check the expiry at a fixed date, 2030-01-01.
- `AdHoc_com.example.otherteam` has the team `OTHERTEAM1`, for the team mismatch cases.

## Tests

`MatchDecryptionTests` decrypts every encrypted file of `v1/` and `v2/` and compares it with `plain/`. The unpadding
password `wrong-216` is a fixed value: its MD5 decrypt of the app1 profile unpads, so only the content check rejects it.
It was found with fastlane's own `EncryptionV1` by trying `wrong-0`, `wrong-1` and so on, and `wrong-216` was the 217th
try. If the fixtures are regenerated, that password must be found again, because the salts change.

`MatchSelectionTests` runs the selection on `v2/` and `v1/` with the fixture password and a fixed date, so the tests do
not depend on the clock. `ProvisioningProfileTests` reads the plain profile and certificate, and checks the missing and
mistyped keys on property list dictionaries, because a CMS message without a signer cannot be made in a test.

## Real repository check

`MatchDecryptionManualCheck` decrypts a real match repository in memory and writes nothing. See the command in
`AGENTS.md`, "Building and testing".

Run on 2026-11-04 by the maintainer of the first adopting project, on a developer Mac, against that project's match
repository: 62 encrypted files, all decrypted, 0 failed. Formats: 61 v2 and 1 v1 (MD5 or SHA-256 was not recorded).
Content: 1 certificate, 1 private key as PEM (`pemPrivateKey`), no PKCS#12, and 60 profiles (ad hoc, App Store and
development). The fastlane version that wrote the files was not recorded.
