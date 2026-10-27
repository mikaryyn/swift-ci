# AGENTS.md

Guidance for coding agents working in this repository. Read
[README.md](README.md) first. It is the source of truth for goals, design and
the status of each capability.

## What this project is

SwiftCI is a Swift **library** for writing CI scripts in Swift. Projects
consume it from their own small SwiftPM executable package (`./ci <command>`).
It is a Swift-native alternative to fastlane and the Bitrise workflow runner.
It consists of thin, typed wrappers over Apple's command-line tools. Where a
native implementation is missing, it offers explicit fallbacks to fastlane. The
core runs on macOS and Linux. Integrations and ready-made steps are extensions,
either separate library products or small external packages, built on the
core's public API.

The project is in an early **planning** phase. Do not implement features unless
asked. When asked, follow the design in README.md. If a request conflicts with
that design, raise the conflict instead of diverging from it silently.

## Hard rules

1. **Stay generic.** Never add project-specific data: app or company names,
   bundle identifiers, team IDs, server URLs, repository URLs, account names,
   scheme names, keychain names or CI job names. Use parameters instead. In
   examples, use placeholders such as `com.example.myapp` and `MyApp`.
2. **No new dependencies without approval.** You may use these without asking:
   the Swift standard library, Foundation, Apple system frameworks (`System`,
   `CryptoKit`, `Security`, `CommonCrypto`, `AppKit` where already used) and
   Apple command-line tools (`xcodebuild`, `xcrun`, `security`, `plutil`, `git`,
   …). Third-party Swift packages, Ruby gems, Homebrew tools and other runtimes
   need an explicit decision from the maintainer.
3. **Fallbacks are explicit.** An integration with both a native and an external
   implementation takes an explicit choice, such as `using: .native` or
   `using: .fastlane`. Never fall back automatically on failure. Never install
   fallback tools from SwiftCI.
4. **Secrets never leak.** Do not log secret values or include them in error
   messages. Do not pass them to child processes as command-line arguments.
   Prefer environment variables or standard input.
5. **Failures must fail.** An error that escapes a step or command body fails
   the command, and the command must exit with a non-zero code. A script may
   catch a step's error with ordinary `do`/`catch`. The step is still logged as
   failed, and the command continues. Do not swallow errors that escape, and do
   not hide a failure from the exit code.
6. **Clean output is a feature.** Every new tool integration ships a default
   output filter. The filter keeps progress, warnings, errors and results, and
   hides noise. The full raw output still goes to the full log.
7. **Keep the core Linux-compatible.** Code in the core (`SwiftCI` product) may
   use only APIs that Foundation provides on Linux. Put `AppKit`, `Security`,
   `CryptoKit`, `CommonCrypto` and Darwin-only Foundation APIs (such as
   `FileHandle.bytes`) in macOS modules. Use `FoundationNetworking` for
   `URLSession` on Linux. Apple modules must still compile on Linux, so gate
   their APIs with `#if os(macOS)`.
8. **Build integrations as extensions.** First-party modules use only the core's
   public API, as an independent extension package would. If an integration
   needs something internal, add a deliberate public extension API instead of
   a workaround.
9. **Keep README.md current.** When a capability's status changes, or a design
   decision is made or reversed, update the capability table, roadmap, known
   issues or open questions to match.

## Repository layout

The package has five library products, `SwiftCI` (core), `SwiftCIXcode`,
`SwiftCISigning`, `SwiftCISlack` and `SwiftCITesting`, one target each. Each module
depends only on `SwiftCI` and uses its public API. The core depends on no module.
README.md ("Module layout") describes the planned products. `SwiftCITesting` is
the test support for scripts and extensions.
`SwiftCIAppStoreConnect` and `SwiftCIGitLab` become products when their first
code lands.

```text
Package.swift                 Swift tools 6.2, macOS 13+, no dependencies,
                              default actor isolation = MainActor
Sources/SwiftCI/              Core
  SwiftCI.swift               Entry point `SwiftCI { … }`, command dispatch, exit codes
  Command.swift               Command and step (throwing and allowed-failure steps, nesting)
  Handlers.swift              cleanup / onFailure registration and running
  RunContext.swift            State of the running command: step depth, handlers, pending internal error
  Tools/
    Tool.swift                Process values (Tool): run, output, result; output filters
    ProcessRunner.swift       The runner that starts a Tool's process: spawn, pipes, timeouts
    Git.swift                 Commit hash and tag
    Bitrise.swift             Temporary Bitrise CLI wrapper (`bitrise --ci run`) with its output filter
  Other/
    Log.swift, FullLog.swift  Console log protocol, per-command full log file
    Redaction.swift           Secret registry, masking function, RedactingLog
    Secret.swift              Secret type and its environment source
    Filters.swift             Filter type and helpers
    Environment.swift         @Env / @EnvOpt and Environment helpers; the environment source that tests replace
    BuildError.swift          Error type and exit codes
    Artifacts.swift           Artifacts directory: resolution, creation, `Artifacts.directory`, `Artifacts.url(_:)`
    CI.swift                  CI environment types (`CI`, `CIEnvironment`, `MergeRequest`, `CISystem`), `CIAdapter`, `CIExporter`
    CIDetection.swift         Detection of the CI environment and the built-in adapters, in order; the full log's CI line
    CIExport.swift            `CI.export`, its name, line-break and secret checks, and the envman, GitHub Actions and dotenv exporters
    Plist.swift               Property list read and write (URL paths)
    TemporaryDirectory.swift  Temporary directory, child URLs
    URL+Extension.swift, String+Extension.swift
    Use.swift                 Minimal dependency registry (`register`, `@Use`)
    ColorizeSwift.swift       Vendored terminal colour helpers
    TestingSupport.swift      Test hooks for SwiftCITesting, `@_spi(Testing)` only: install mocks, isolate and restore global state
Sources/SwiftCIXcode/         Module (macOS): xcodebuild wrappers, app icon overlay
  Icon.swift                  App icon text overlay (AppKit)
  Xcode/                      xcodebuild wrappers (build, archive/export, settings, docbuild)
Sources/SwiftCISigning/       Module (macOS): keychains, match-compatible signing install, fastlane fallback
  Keychain.swift              Keychain unlock: a plain type with static methods
  SecurityInteractive.swift   Builds the one-line input of `security -i`
  GitCredentials.swift        Git credentials for the native match install (E11)
  Fastlane.swift              fastlane match invocation + native match install (v1/v2 decryption)
Sources/SwiftCISlack/         Module: Slack incoming webhooks
  Slack.swift
Sources/SwiftCITesting/       Module: test support for scripts and extensions. Imports no test framework.
                              Uses `@_spi(Testing) import SwiftCI` only for the hooks in TestingSupport.swift
  SwiftCITest.swift           run(_:environment:artifactsDirectory:ciAdapters:runner:script:), withMocks(_:runner:log:artifactsDirectory:ciAdapters:_:), SwiftCITestResult
  ProcessRunnerMock.swift     Records each Tool it runs and returns prepared responses
  LogMock.swift               Records console lines and the arguments of each Log method
Tests/SwiftCITestSupport/     Not a product. Helpers shared by this repository's test targets: GlobalStateTests,
                              registerToolMocks, secretsSetUp (SPI), thrownError, stripANSI, temporaryArtifactsDirectory
Tests/SwiftCITests/           Core tests (Swift Testing)
  Fixtures/                   Recordings of real tool runs, bundled as test resources (Bitrise)
Tests/SwiftCIXcodeTests/      Xcode tests
Tests/SwiftCISigningTests/    Keychain, match, Git credential and `security -i` tests
Tests/SwiftCISlackTests/      Slack tests
Tests/SwiftCITestingTests/    Tests of SwiftCITesting as an extension author sees it: `import SwiftCI`,
                              `import SwiftCITesting` and `import Testing` only (no `@testable`, no SPI)
docs/prior-art.md             Research on fastlane, Bitrise and alternatives
```

## Building and testing

```sh
swift build
swift test
```

Each test target is a separate test bundle. `swift test` runs the bundles one
after another, each in its own process. Suites that touch global state (the
registry, the running command, the full log, secrets) are nested in the
`GlobalStateTests` suite of `SwiftCITestSupport`, which is serialized. Every
test target extends it with its own suites. Keep that rule when you add a
suite that touches global state.

The release check builds the products without `-enable-testing`, so a module
that uses internal core API fails:

```sh
swift build -c release --product SwiftCI --product SwiftCIXcode --product SwiftCISigning --product SwiftCISlack --product SwiftCITesting
```

Plain `swift build -c release` builds every non-test target, including
`SwiftCITestSupport`. That target uses only the core's SPI, not
`@testable import`, so this check also works and is the one to run:

```sh
swift build -c release
```

The manual keychain check runs SwiftCI's real unlock and partition-list code
against a throwaway keychain. It is skipped by default. Run it once, on a Mac,
with:

```sh
SWIFTCI_MANUAL_KEYCHAIN_CHECK=1 swift test --disable-sandbox --filter KeychainManualCheck
```

If SwiftPM fails with `sandbox-exec: sandbox_apply: Operation not permitted`
(for example when the agent itself runs sandboxed), add `--disable-sandbox`.

The core does not build on Linux yet (see README.md "Known issues"). Once it
does, verify Linux compatibility of core changes with the official Swift Docker
image, for example
`docker run --rm -v "$PWD":/src -w /src swift:6.2 swift test`.

Tests must not write into the working directory. `SwiftCITest.run` and `withMocks` use a
temporary artifacts directory. A test that calls `runSwiftCI` directly passes `artifactsDirectory:`
(`temporaryArtifactsDirectory()` from `SwiftCITestSupport`), or the run writes `artifacts/` into the repository.

Tests must not touch the real keychain, network, developer portal, App Store
Connect, simulators or `~/Library`. The one exception is `KeychainManualCheck`,
which runs only when `SWIFTCI_MANUAL_KEYCHAIN_CHECK=1` is set (see below). Replace the process runner with
`SwiftCITest.run` or `SwiftCITest.withMocks` from `SwiftCITesting`. The repository's
tests that keep their own scope use `registerToolMocks()` from `SwiftCITestSupport`.
See `Tests/SwiftCISigningTests/Tools/KeychainTest.swift` for an example. For
format-sensitive code, such as match decryption or JWT signing, use fixture
files.

Tests that use `SwiftCITesting` change global state, so they must run one at a
time. The repository's suites nest in `GlobalStateTests`. `SwiftCITestingTests`
marks its suite `.serialized` itself, because it may not import `SwiftCITestSupport`.

## Code conventions

- Use Swift 6.2 language mode with `MainActor` default isolation. Steps run
  sequentially. Do not introduce concurrency without a reason.
- Module sources (`Sources/SwiftCIXcode`, `SwiftCISigning`, `SwiftCISlack`)
  use `import SwiftCI` only. No `@testable import` and no internal core API. If a
  module needs core internals, stop and make a deliberate public API decision.
- `SwiftCITesting` may use the core's test hooks, but only as `@_spi(Testing)`
  declarations in `Other/TestingSupport.swift` and `SwiftCI.swift`. Do not make a
  hook ordinary public API, and do not make `register` public.
- Integrations are plain types with static or instance methods. Tests replace
  the `ProcessRunner`, which every integration runs its processes through. Add a
  protocol and a registration only for an integration that cannot be tested
  through the runner, for example an HTTP client, and then add a public
  registration API first.
- Run processes with argument arrays (`Tool(command:arguments:)`). Use
  `Tool(shellCommand:)` only for user-supplied shell scripts. Never build
  command lines by string interpolation.
- Represent paths as Foundation file `URL`s in public API. Pass a URL to a tool
  argument or a message as `url.filePath` (`Other/URL+Extension.swift`), never as
  `url.absoluteString` or by interpolating the URL, so `file://` and percent-encoding
  do not leak. Add helpers there rather than writing ad hoc path code. Do not
  add `System.FilePath` or plain `String` path parameters.
- Report expected failures as `BuildError`. Write each message so it tells the
  user what to do, for example which environment variable is missing.
- Start the doc comment of temporary API (such as the Bitrise wrapper for
  migration) with `Temporary:`. Say when the API will be removed, and link to
  the plan that tracks it. Do not build permanent features on temporary API.
- Add doc comments to all public API. Examples in doc comments and README must
  follow the generic-only rule.
- Public integration calls that do work open a step with
  `step(default:name:)` and take a final `step: String? = nil` parameter.
  Queries do not open a step. The doc comment says which one a method is.
- Match the surrounding code style. Write commits in Conventional Commits form
  (`feat:`, `fix:`, `refactor:`, `docs:`, `test:`).

## Decisions recorded in README.md

Do not reopen these without the maintainer:

- Library-first: projects write CI scripts as SwiftPM executable packages.
- Explicit fallbacks only.
- Linux-compatible core; Apple modules macOS-only.
- First-party modules live in this repository as separate products.
- Paths are Foundation `URL`s.
- App Store Connect: minimal native client, no AppStoreConnect-Swift-SDK in
  first-party modules. A full-API extension based on the SDK is an
  [extension idea](README.md#extension-ideas).
- GitLab merge request feedback is a first-party module (`SwiftCIGitLab`).
- CI environment detection and output export adapters are core. The Bitrise
  workflow wrapper is temporary core API, to be removed before 1.0.
- Minimum Xcode 26 (Swift 6.2). Support the two latest major Xcode versions.
  Parse `.xcresult` only with the current `xcresulttool` JSON API.
- CI reports: JUnit is core; coverage later; annotations optional; JSON run
  summary deferred.

Record new extension ideas in README.md under "Extension ideas". When an idea
gets built, move it to the list of known extensions.

## Reference material

- Design, capability status, roadmap, known issues and open questions:
  [README.md](README.md)
- Phased implementation plan and open decisions:
  [docs/plans/implementation-plan.md](docs/plans/implementation-plan.md)
- End-user documentation work:
  [docs/plans/end-user-documentation.md](docs/plans/end-user-documentation.md)
- Linux verification:
  [docs/plans/linux-verification.md](docs/plans/linux-verification.md)
- Prior art, Apple tooling risks (match formats, ES256 JWT, upload APIs):
  [docs/prior-art.md](docs/prior-art.md)
- fastlane match encryption (compatibility reference):
  <https://github.com/fastlane/fastlane/blob/master/match/lib/match/encryption/encryption.rb>
- App Store Connect API token generation:
  <https://developer.apple.com/documentation/AppStoreConnectAPI/generating-tokens-for-api-requests>
