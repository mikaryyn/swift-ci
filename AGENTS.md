# AGENTS.md

Guidance for coding agents. Read [README.md](README.md) first. README.md and `docs/` are the source of truth: the README for goals and the overview, [docs/design.md](docs/design.md) for design decisions, [docs/status.md](docs/status.md) for capability status, and `docs/guides/` for the behavior of each area.

## What this project is

SwiftCI is a Swift library for writing CI scripts in Swift, a Swift-native alternative to fastlane and the Bitrise runner. It has thin, typed wrappers over Apple's command-line tools, and explicit fastlane fallbacks where there is no native implementation. The core runs on macOS and Linux. Integrations are extensions built on the core's public API.

The project is in an early planning phase and is prerelease: no API has been released, so any API may change. Update the packages that use the API in the same change. Don't implement features unless asked. If a request conflicts with the design in README.md or `docs/design.md`, raise the conflict instead of diverging from it.

## Hard rules

1. **Stay generic.** Never add project-specific data: app or company names, bundle identifiers, team IDs, server URLs, repository URLs, account names, scheme names, keychain names or CI job names. Use parameters instead. In examples, use placeholders such as `com.example.myapp` and `MyApp`.
2. **No new dependencies without approval.** You may use these without asking: the Swift standard library, Foundation, Apple system frameworks (`System`, `CryptoKit`, `Security`, `CommonCrypto`, `AppKit` where already used) and Apple command-line tools (`xcodebuild`, `xcrun`, `security`, `plutil`, `git`, …). Third-party Swift packages, Ruby gems, Homebrew tools and other runtimes need an explicit decision from the maintainer.
3. **Fallbacks are explicit.** An integration with both a native and an external implementation takes an explicit choice, such as `using: .native` or `using: .fastlane`. Never fall back automatically on failure. Never install fallback tools from SwiftCI.
4. **Secrets never leak.** Do not log secret values or include them in error messages. Do not pass them to child processes as command-line arguments. Prefer environment variables or standard input.
5. **Failures must fail.** An error that escapes a step or command body fails the command, and the command must exit with a non-zero code. A script may catch a step's error with ordinary `do`/`catch`. The step is still logged as failed, and the command continues. Do not swallow errors that escape, and do not hide a failure from the exit code.
6. **Clean output is a feature.** Every new tool integration ships a default output filter. The filter keeps progress, warnings, errors and results, and hides noise. The full raw output still goes to the full log.
7. **Keep the core Linux-compatible.** Code in the core (`SwiftCI` product) may use only APIs that Foundation provides on Linux. Put `AppKit`, `Security`, `CryptoKit`, `CommonCrypto` and Darwin-only Foundation APIs (such as `FileHandle.bytes`) in macOS modules. Use `FoundationNetworking` for `URLSession` on Linux. Apple modules must still compile on Linux, so gate their APIs with `#if os(macOS)`.
8. **Build integrations as extensions.** First-party modules use only the core's public API, as an independent extension package would. If an integration needs something internal, add a deliberate public extension API instead of a workaround.
9. **Keep the documentation current.** When a capability's status changes, update the capability table, roadmap, known issues or open questions in `docs/status.md`. When a design decision is made or reversed, update `docs/design.md`. When user-visible behavior changes, update the guide in `docs/guides/` that describes it. Keep README.md short: it is the overview.

## Repository layout

One Swift package with seven library products, each with one target. Each module depends only on `SwiftCI` and uses its public API. The core depends on no module. See [docs/repository-layout.md](docs/repository-layout.md) for the file-level layout.

- `SwiftCI`: the core. Commands, steps, process execution, logging, secrets, reports, CI environments. The run itself is in the root of the target. Folders `Tools/`, `HTTP/`, `Environment/`, `Logging/`, `Reports/`, `CI/` and `Files/`.
- `SwiftCIXcode`, `SwiftCISigning`, `SwiftCIAppStoreConnect`: macOS modules for `xcodebuild`, keychains and match signing, and App Store Connect.
- `SwiftCISlack`, `SwiftCIGitLab`: Slack webhooks, and GitLab merge request feedback.
- `SwiftCITesting`: test support for scripts and extensions.
- `Tests/<Module>Tests`: tests of each module. `Tests/SwiftCITestSupport` is shared helpers, not a product. `Fixtures/` holds recorded data.
- `docs/`: `design.md` (design decisions), `status.md` (capabilities, roadmap, known issues, open questions), `guides/` (user guides), `plans/` (implementation plans) and research. `README.md` is the overview.

## Building and testing

Commands are in the [justfile](justfile). Run `just` to list them. Set `SWIFT_FLAGS=--disable-sandbox` if SwiftPM fails with `sandbox-exec: sandbox_apply: Operation not permitted`.

- `just build`, `just test`, `just test-filter <filter>`: build, run all tests, run matching tests.
- `just release-check`: builds without `-enable-testing`, so a module that uses internal core API fails. Run it before committing API changes.
- `just test-linux`: runs the tests in the Swift Docker image. The core does not build on Linux yet (see "Known issues" in `docs/status.md`). Use it to verify Linux compatibility once it does.
- `just manual-keychain`, `manual-match-decryption`, `manual-match-install`, `manual-precheck`: manual checks against a throwaway keychain, a local match clone or the real App Store Connect API. Skipped by `just test`. Run one after changing the code it covers. The recipe comments list the variables they need.

Each test target is a separate test bundle. Suites that touch global state (the registry, the running command, the full log, secrets) are nested in the serialized `GlobalStateTests` suite of `SwiftCITestSupport`, and every test target extends it with its own suites. Keep that rule when you add such a suite. `SwiftCITestingTests` may not import `SwiftCITestSupport` and marks its suite `.serialized` itself.

Tests must not touch the real keychain, network, developer portal, App Store Connect, simulators or `~/Library`, except the manual checks. Replace the process runner with `SwiftCITest.run` or `SwiftCITest.withMocks` from `SwiftCITesting`, or `registerToolMocks()` from `SwiftCITestSupport` for tests with their own scope (example: `Tests/SwiftCISigningTests/Tools/KeychainTest.swift`). Use fixture files for format-sensitive code, such as match decryption or JWT signing.

Tests must not write into the working directory. `SwiftCITest.run` and `withMocks` use a temporary artifacts directory. A test that calls `runSwiftCI` directly passes `artifactsDirectory: temporaryArtifactsDirectory()`, or the run writes `artifacts/` into the repository.

## Code conventions

- Use Swift 6.2 language mode with `MainActor` default isolation. Steps run sequentially. Do not introduce concurrency without a reason.
- Module sources use `import SwiftCI` only. No `@testable import` and no internal core API. If a module needs core internals, stop and make a deliberate public API decision.
- `SwiftCITesting` may use the core's test hooks, but only as `@_spi(Testing)` declarations. Do not make a hook ordinary public API, and do not make `register` public.
- Integrations are plain types with static or instance methods. Tests replace the `ProcessRunner`, which every integration runs its processes through. Add a protocol and a registration only for an integration that cannot be tested through the runner, for example an HTTP client, and then add a public registration API first.
- Run processes with argument arrays (`Tool(command:arguments:)`). Use `Tool(shellCommand:)` only for user-supplied shell scripts. Never build command lines by string interpolation.
- Represent paths as Foundation file `URL`s in public API. Pass a URL to a tool argument or a message as `url.filePath`, never as `url.absoluteString` or by interpolating the URL, so `file://` and percent-encoding do not leak. Add helpers to the URL extension rather than writing ad hoc path code. Do not add `System.FilePath` or plain `String` path parameters.
- Report expected failures as `BuildError`. Write each message so it tells the user what to do, for example which environment variable is missing.
- Start the doc comment of temporary API with `Temporary:`. Say when the API will be removed. Do not build permanent features on temporary API.
- Do not refer to plans, plan milestones or decisions (such as `M4` or `decision E11`), tasks, or Markdown files (README.md, `docs/`) in code, comments or tests. State the fact or the reason in the comment itself.
- Add doc comments to all public API. Examples in doc comments, the README and the guides must follow the generic-only rule.
- Public integration calls that do work open a step with `step(default:name:)` and take a final `step: String? = nil` parameter. Queries do not open a step. The doc comment says which one a method is.
- Match the surrounding code style. Write commits in Conventional Commits form (`feat:`, `fix:`, `refactor:`, `docs:`, `test:`).
