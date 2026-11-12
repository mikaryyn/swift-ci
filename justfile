# Common commands. Run `just` to list them.
#
# Set SWIFT_FLAGS=--disable-sandbox when SwiftPM fails with
# `sandbox-exec: sandbox_apply: Operation not permitted`, for example when the caller is itself sandboxed.

swift_flags := env("SWIFT_FLAGS", "")

[private]
default:
    @just --list

# Build all targets, including tests.
build:
    swift build {{swift_flags}}

# Run all test bundles.
test:
    swift test {{swift_flags}}

# Run the tests that match a filter, for example `just test-filter RunnerTests`.
test-filter filter:
    swift test {{swift_flags}} --filter {{filter}}

# Build without `-enable-testing`, so a module that uses internal core API fails. Run before a commit that changes API.
release-check:
    swift build {{swift_flags}} -c release

# Run the core tests on Linux in the official Swift image. The core does not build on Linux yet.
test-linux:
    docker run --rm -v "$PWD":/src -w /src swift:6.2 swift test

# Manual check: unlock and partition-list code against a throwaway keychain. Run once on a Mac after changing keychain code.
manual-keychain:
    SWIFTCI_MANUAL_KEYCHAIN_CHECK=1 swift test --disable-sandbox --filter KeychainManualCheck

# Manual check: decrypt every file of a local match repository in memory. Needs SWIFTCI_MANUAL_MATCH_REPOSITORY and MATCH_PASSWORD. Writes nothing.
manual-match-decryption:
    @: "${SWIFTCI_MANUAL_MATCH_REPOSITORY:?set the path of a local match clone}" "${MATCH_PASSWORD:?set the match password}"
    swift test --disable-sandbox --filter MatchDecryptionManualCheck

# Manual check: native match install from a local Git repository of the fixture, with a throwaway keychain.
manual-match-install:
    SWIFTCI_MANUAL_MATCH_CHECK=1 swift test --disable-sandbox --filter MatchInstallManualCheck

# Manual check: App Store metadata check against the real API for one app. Needs SWIFTCI_MANUAL_PRECHECK_APP_ID, ASC_KEY_ID, ASC_ISSUER_ID and ASC_KEY_FILE. Only reads.
manual-precheck:
    @: "${SWIFTCI_MANUAL_PRECHECK_APP_ID:?set the app id}" "${ASC_KEY_ID:?set the key id}" "${ASC_ISSUER_ID:?set the issuer id}" "${ASC_KEY_FILE:?set the path of the .p8 file}"
    swift test --disable-sandbox --filter PrecheckManualCheck
