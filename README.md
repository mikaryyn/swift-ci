# SwiftCI

A Swift library for writing continuous integration scripts in Swift.

SwiftCI lets a project describe its CI work, such as building, testing,
signing, uploading and notifying, as a small Swift package. The package runs
the same way on a CI machine and on a developer's Mac. SwiftCI is meant as a
lightweight, Swift-native alternative to tools such as
[fastlane](https://fastlane.tools) and the [Bitrise](https://bitrise.io)
workflow runner. It keeps external dependencies to a minimum.

> **Status: early prototype, in planning.** The core (commands, steps,
> process execution, logging) and several Xcode helpers work and are used in
> real projects, but APIs are not stable and there are known correctness issues
> (see [Known issues](#known-issues)). This README describes both what exists
> today and how SwiftCI is intended to work. Planned features are marked
> **(planned)**.

## Contents

- [Why SwiftCI](#why-swiftci)
- [Goals](#goals)
- [Non-goals](#non-goals)
- [Why a library and not a scripting tool](#why-a-library-and-not-a-scripting-tool)
- [How it works](#how-it-works)
- [Extensions](#extensions)
- [Platforms](#platforms)
- [Capabilities](#capabilities)
- [Native implementations and explicit fallbacks](#native-implementations-and-explicit-fallbacks)
- [Output, filtering and secrets](#output-filtering-and-secrets)
- [Reports for CI systems](#reports-for-ci-systems)
- [Running in CI and locally](#running-in-ci-and-locally)
- [Testing CI scripts and extensions](#testing-ci-scripts-and-extensions)
- [Migrating from Bitrise and fastlane](#migrating-from-bitrise-and-fastlane)
- [Prior art and alternatives](#prior-art-and-alternatives)
- [Is this a good idea?](#is-this-a-good-idea)
- [Roadmap](#roadmap)
- [Known issues](#known-issues)
- [Open questions](#open-questions)

## Why SwiftCI

### The problem

CI for an Apple platform project tends to grow into a stack of layers, each
with its own language and runtime:

- a CI server (Jenkins, GitLab CI, GitHub Actions) with job definitions in
  Groovy or YAML
- a workflow runner (Bitrise CLI, fastlane lanes) configured in YAML or Ruby
- steps and actions that are themselves Ruby, Go or Python programs
- shell scripts embedded in YAML strings that glue the steps together and pass
  values between them
- helper tools for the gaps: `xcpretty` for logs, `trainer` for test reports,
  Danger for merge request comments, ImageMagick for icon badges, Python
  for HTML reports

Each layer works, but together they cost a lot:

- **Runtimes to maintain.** Ruby version managers, Bundler, native gem
  extensions, Python packages and Homebrew tools must be kept working on every
  CI machine. They break on macOS and Xcode upgrades, which are exactly when CI
  is needed most.
- **Logic in the wrong places.** Build logic is spread over YAML, Groovy,
  inline shell and Ruby. Nothing type-checks it, nothing tests it, and editors
  cannot navigate it. Mistakes show up 20 minutes into a CI run.
- **Hard to run locally.** Reproducing a CI failure means installing the whole
  stack and recreating CI-only environment variables and files.
- **Unreadable output.** Raw `xcodebuild` logs and runner banners bury the one
  error that matters.
- **Leaky secrets.** Passwords end up on command lines and in debug output
  printed by `set -x`, and from there in logs.
- **Lock-in.** Workflows are written in a runner's YAML dialect and depend on
  its step library and its way of passing state between steps.

The people who maintain this are usually the app developers, and they write
Swift every day.

### The idea

Most of the actual work is calling Apple's command-line tools in the right
order: `xcodebuild`, `xcrun`, `security`, `simctl`, `git`. That needs a thin,
typed layer with good defaults, not a separate ecosystem. SwiftCI provides that
layer as a Swift library. CI logic is an ordinary Swift package. It compiles
with the same toolchain as the app, runs the same way on CI and on a developer's
machine, and needs nothing else installed.

### Why not just shell scripts?

Shell is the obvious alternative. It is already installed, and every CI system
can run it. For short, linear tasks it is the right tool, and SwiftCI keeps it
as an escape hatch (`Tool(shellCommand:)`). It does not scale to a full CI
setup:

- **Failures pass silently.** `set -e` does not cover pipelines without
  `pipefail`, commands in conditions or subshells. A pipeline such as
  `xcodebuild … | xcpretty` reports the formatter's exit status. CI scripts
  routinely add `|| true` and `set +e` to make cleanup and reporting work, and
  then miss real failures. In SwiftCI an error that escapes a step or command
  body fails the run. A script may catch a step's error with `do`/`catch` and
  continue. Cleanup and failure notifications are `cleanup` and `onFailure`
  handlers.
- **Quoting and word splitting.** Paths with spaces, lists of bundle
  identifiers and arguments built from variables are easy to get wrong.
  Building command lines from strings invites injection. SwiftCI runs processes
  with argument arrays.
- **Secrets.** Shell makes it natural to pass a password as an argument
  (`security unlock-keychain -p "$PASSWORD"`). There, the password is visible in
  the process list and printed by `set -x`. Redacting secrets from all output
  requires wrapping every command. SwiftCI registers secrets once and redacts
  them everywhere.
- **Structured data.** CI work increasingly means JSON, property lists and XML:
  `xcresulttool` output, export options, App Store Connect API responses, JUnit
  reports, JWT signing, match decryption. In shell that means `jq`,
  `PlistBuddy`, `openssl`, `sed` and often Python or Ruby, so the extra runtimes
  come back. Swift has `Codable`, `PropertyListSerialization`, `CryptoKit` and
  `URLSession` built in.
- **Portability.** macOS ships Bash 3.2 and BSD tools. Linux has GNU tools. For
  example, `sed -i ''` on macOS is `sed -i` on Linux, and `date`, `stat` and
  `readlink` differ as well. A script that works on a Mac fails on a Linux
  runner, and the reverse.
- **No reuse or versioning.** Sharing shell scripts between projects means
  copying them. SwiftCI integrations are versioned packages with a public API,
  pinned and upgraded like any dependency.
- **No types, tests or tooling.** Shell has no compiler to catch a misspelt
  variable, no unit tests in practice, and limited editor support. A 1,000-line
  YAML file with embedded shell is the usual end state.
- **Clean output is work.** Step headers, timing, filtered tool output, a full
  log next to a short console log, and a summary at the end all have to be
  built by hand in every script. In SwiftCI they are the default.

The trade-off is a compile step before the first run, discussed in
[Why a library and not a scripting tool](#why-a-library-and-not-a-scripting-tool)
and [Is this a good idea?](#is-this-a-good-idea).

## Goals

- **CI scripts in Swift.** Workflows are typed, compiled Swift code. They can
  be edited, navigated and debugged in Xcode or any SourceKit-LSP editor, and
  they can be unit tested like any other Swift code.
- **Minimal dependencies.** SwiftCI needs a Swift toolchain and Apple's own
  command-line tools (`xcodebuild`, `xcrun`, `security`, `git`, …). It needs no
  Ruby, Node.js, Python or Go runtime. Third-party Swift packages are considered
  case by case and avoided by default.
- **Native first, explicit fallback.** Common Apple CI tasks are implemented in
  Swift. Where a native implementation is missing or not yet trustworthy, a
  command can explicitly choose an external implementation such as fastlane.
  SwiftCI never switches implementations silently.
- **Clean output by default.** Every tool SwiftCI runs has a default output
  filter, in the spirit of [xcbeautify](https://github.com/cpisciotta/xcbeautify).
  Console logs show what matters: progress, warnings, errors and test results.
  The complete raw output is always kept in a log file.
- **Secrets never leak.** Registered secrets are redacted from all output and
  log files. They are not passed to child processes on the command line.
- **Generic.** SwiftCI contains no knowledge of any specific project, team,
  bundle identifier, server or account. Everything project-specific lives in
  the project's own CI package.
- **Same script everywhere.** The primary target is CI machines: self-hosted or
  hosted Macs and Linux runners driven by Jenkins, GitLab CI, GitHub Actions and
  similar systems. Every command must also be runnable on a developer's machine.
- **Every kind of Swift project.** First-class support for Xcode projects and
  workspaces, Swift packages, Apple platforms (iOS, macOS, tvOS, watchOS,
  visionOS) and server-side Swift. Generic shell commands are always available
  as an escape hatch.
- **Linux-compatible core.** The core runs on macOS and Linux. Apple-specific
  integrations are separate modules that are only available on macOS.
- **Extensible.** Integrations and ready-made steps are delivered as extensions:
  small Swift packages built on SwiftCI's public API. First-party integrations
  use the same API as everyone else.

## Non-goals

- **Not a CI server.** SwiftCI does not schedule jobs, provision machines, store
  secrets or host logs. Jenkins, GitLab CI, GitHub Actions, Bitrise or Xcode
  Cloud keep doing that. SwiftCI is what they invoke.
- **Not a YAML workflow engine.** Workflows are Swift code, not configuration.
  Scripts are ordinary async Swift: no result builders and no macros (which
  would need swift-syntax), and commands are registered explicitly with
  `command(…)`. Reusable groups of steps are plain `async throws` functions.
- **Not parallel.** Steps and commands run one after another.
- **Not a build system.** It drives `xcodebuild` and `swift build`. It does not
  replace them, and it does not generate projects (see Tuist, XcodeGen).
- **Not a large step library.** SwiftCI itself will not ship integrations for
  every ecosystem. Non-Swift work is done with plain shell commands. Anything
  else can be an independent [extension](#extensions).
- **Not a drop-in fastlane replacement.** SwiftCI covers the common CI path:
  build, test, archive, install signing assets and upload. Long-tail features
  such as App Store metadata and screenshot management, or creating and renewing
  certificates in the developer portal, are out of scope initially. They remain
  available through the fastlane fallback.

## Why a library and not a scripting tool

An alternative design would be a standalone `swiftci` executable that reads a
`ci.swift` file and runs it, the way `fastlane` reads a `Fastfile`. SwiftCI is
deliberately a library, used from a regular Swift Package Manager executable,
for these reasons:

- **Swift scripting is limited.** Swift can run single-file scripts
  (`#!/usr/bin/env swift`), but such scripts cannot import package dependencies
  or span multiple files. They are type-checked from scratch on every run.
  Lifting those limits requires extra tooling such as
  [swift-sh](https://github.com/mxcl/swift-sh) or the now-deprecated
  [Marathon](https://github.com/JohnSundell/Marathon). That means reimplementing
  what SwiftPM already does.
- **SwiftPM already solves the hard parts.** Dependency resolution, version
  pinning (`Package.resolved`), incremental compilation and build caching come
  for free. So does editor support (Xcode, SourceKit-LSP) with autocompletion
  and jump-to-definition.
- **Scripts are testable.** CI logic lives in normal Swift targets, so it can be
  split into files and modules and covered by unit tests.
- **Versioned like any dependency.** A project pins a SwiftCI release in its CI
  package and upgrades deliberately.

The cost is a compile step. The first run of a CI package takes tens of seconds
to build, and later runs are incremental. CI machines should cache the CI
package's `.build` directory. A thin wrapper script (see below) hides
`swift run` from users.

## How it works

### Project layout

A project adds a small Swift package next to its app code. The package is kept
separate, so CI-only dependencies never reach the app's package graph:

```text
MyApp/
├── MyApp.xcodeproj
├── ci                      # wrapper script: ./ci <command> [<command> ...]
└── CI/
    ├── Package.swift       # depends on SwiftCI and extensions, pinned to release tags
    └── Sources/ci/
        ├── main.swift      # registers commands
        ├── Test.swift
        └── Release.swift
```

`CI/Package.swift`:

```swift
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ci",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/example/swift-ci.git", from: "0.1.0"),
        // A third-party extension (hypothetical)
        .package(url: "https://github.com/example/swift-ci-swiftlint.git", from: "1.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "ci",
            dependencies: [
                .product(name: "SwiftCI", package: "swift-ci"),
                .product(name: "SwiftCIXcode", package: "swift-ci"),
                .product(name: "SwiftCISwiftLint", package: "swift-ci-swiftlint"),
            ]
        ),
    ]
)
```

Module names follow the [module layout](#module-layout).

The `ci` wrapper script lives at the repository root. It changes to its own
directory, so the working directory is always the project root:

```sh
#!/bin/sh
set -e
cd "$(dirname "$0")"
exec swift run --package-path CI -c release ci "$@"
```

### Concepts

| Concept | Description |
|---|---|
| **Command** | A named entry point invoked from the command line, e.g. `./ci test`. Several commands can be given and run in order. Inside the body, `cleanup { }` and `onFailure { }` register handlers that run when the command ends. A command reads inputs with `try input("track", default: "beta")`, from `--track=production` on the command line, then from the environment variable `TRACK`, then from the default. |
| **Step** | A named, timed unit of work inside a command, written `try await step("Name") { … }`. Steps run sequentially and return the value of their body. A step that throws is logged as failed. An error that escapes the command body fails the command, but a script can catch a step's error with `do`/`catch` and continue. A step started inside another step is shown in the outer step's group. A step that may fail is written `await step("Name", failure: .allowed) { … }`. It returns `nil` if it failed, logs the error as a warning, and the command continues. A step that runs only under a condition is written `try await step("Name", when: condition, skipReason: "not on CI") { … }`; when the condition is false, the log shows the step as skipped, with the reason. |
| **Tool** | A child process (`xcodebuild`, `git`, a shell script). `run()` streams stdout and stderr to the console and the full log, and throws on a non-zero exit. `output()` returns stdout, and `result()` returns stdout, stderr and the exit code. A tool can set environment variables, a working directory, input, a timeout, filters and an output file (a copy of its unfiltered output). A program name is looked up in `PATH`. `Tool(shellCommand:)` runs `/bin/sh -c` for shell scripts. |
| **Integration** | Typed Swift API for a tool or service: `Xcode`, `Keychain`, `Signing`, `AppStoreConnect`, `Slack`, `Git`, … A call that does work, such as `xcode.archiveAndExport(…)`, is a step itself, with a default name. `step: "Name"` renames it. A query, such as `Git.getCommitHash()`, is not a step. A call made inside a step is part of that step. |
| **Extension** | A Swift library that adds integrations, ready-made steps, filters or report writers on top of the core. |
| **Filter** | A function that hides, rewrites or highlights a line of tool output. Every integration ships a default. |
| **Secret** | A value, usually from an environment variable, declared with `Secret("NAME")`. Every writer masks it as `••••••`: the console, the full log, error messages and `Environment.writeToLog()`. A secret is passed to a `Tool` through its environment or input, never as an argument. `revealedValue()` returns the raw value where an API needs it. |

### Example

*Illustrative. Commands, throwing steps, allowed failures, inline `cleanup` /
`onFailure` handlers and inputs are implemented. Integration calls as steps are
implemented for `Xcode`, `Keychain`, `Slack`, `Fastlane`, `Icon` and
`Simulator` (shutdown only). The other integration calls (`Signing`,
`AppStoreConnect`) are planned; see the [roadmap](#roadmap) and the
[capabilities](#capabilities).*

```swift
import SwiftCI
import SwiftCIXcode
import SwiftCISigning
import SwiftCIAppStoreConnect
import SwiftCISlack

let xcode = Xcode(workspace: URL(filePath: "MyApp.xcworkspace"), scheme: "MyApp")

let test = Command("test", description: "Run the unit tests") {
    let device: String = try input("device", default: "iPhone 17")
    cleanup { try await Simulator.shutdownAll() }

    try await xcode.resolvePackages()
    try await xcode.test(
        destination: "platform=iOS Simulator,name=\(device),OS=latest",
        resultBundleURL: try Artifacts.url("MyApp.xcresult")
    )
}

let release = Command("release", description: "Build and upload to TestFlight") {
    let matchPassword = Secret("MATCH_PASSWORD")
    let slackWebhook = Secret("SLACK_WEBHOOK_URL")

    onFailure {
        try await Slack(webhookURL: slackWebhook).send(text: "Release build failed")
    }

    try await Signing.installMatchAssets(
        type: .appStore,
        bundleIdentifiers: ["com.example.myapp"],
        password: matchPassword,
        using: .native            // or .fastlane
    )
    // Copies the IPA and the dSYM zip to the artifacts directory: artifacts/MyApp.ipa and artifacts/MyApp.dSYM.zip.
    try await xcode.archiveAndExport(ipaFileName: "MyApp")
    try await AppStoreConnect(apiKey: .fromEnvironment()).upload(ipa: Artifacts.url("MyApp.ipa"))
}

await SwiftCI {
    command(test)
    command(release)
}
```

### Command line

```text
./ci <command> [<command> ...] [--name=value ...]   Run commands in order; stop at the first failed command.
./ci --list                                          List available commands.
./ci --verbose <command>                             Show unfiltered tool output on the console.
./ci --help                                          Show the usage and the command list.
```

`--list` prints each command with the `description:` given to `Command`. A
missing or unknown command name prints the same list after the error. `--help`
prints the usage and the same list, and runs no command. If `--help` and
`--list` are both given, `--help` wins.

`--verbose` shows every line of tool output on the console, without the
filters of the integrations. Secrets stay masked, and the full log is the same
as without it.

**Options and inputs.** An option is always written `--name=value`, with the
value after `=`. Bool values are written too, as `--skip-tests=true`. An empty
value (`--device=`) is a valid value, and the value may contain `=`. There is no
`--name value` form and no bare `--name`. Both are usage errors, and the message
shows the `--name=value` form. Options are global: every command of the run sees
them.

A script reads an option with `input`, which uses the same name as the option:

```swift
let device: String = try input("device", default: "iPhone 17")
let track: Track = try input("track")   // a raw-value enum
```

`input` takes any `LosslessStringConvertible` type (`String`, `Int`, `Bool`, …)
or a raw-value type. It reads `--device=…`, then the environment variable with
the upper-case name (`build-number` reads `BUILD_NUMBER`; an empty variable
counts as not set), then the default. A missing input without a default, or a
value that does not convert, is a usage error (exit code 2) that names the
option and the environment variable. Secrets are never inputs; declare them
with `Secret`.

`--list`, `--help` and `--verbose` are reserved flags. They never take a value,
and `input` refuses those names. Each option may be given only once. A malformed
argument stops the run with exit code 2 before any command runs.

When commands ran, SwiftCI logs a warning at the end of the run, whether it
succeeded or failed, that lists each option no `input` call read, such as a
mistyped `--trak=beta`. The warning does not change the exit code.

SwiftCI parses its arguments itself. No argument-parsing dependency is required
for this small set of options.

### Exit codes

| Code | Meaning |
|---|---|
| 0 | All requested commands succeeded. |
| 1 | A step, command body or handler failed (any error without an explicit code). |
| 2 | Usage or configuration error from the runner (unknown command, missing input, invalid value). |
| 3 | Internal SwiftCI error outside the script (for example, the full log cannot be opened). |

A `BuildError` with an explicit code exits with that code. The run stops at the
first failed command and exits with its code. CI systems rely on these codes.
A failure must never exit with 0.

## Extensions

The core is deliberately small. Integrations and ready-made steps come as
**extensions**. In this document, the word means plugins in the general sense,
not SwiftPM package plugins. An extension is a Swift library that depends on the
core and uses only its public API. It is usually a small, independent Swift
package. First-party integrations (Xcode, signing, App Store Connect, …) are
built the same way, so SwiftCI's own code exercises the extension API.

### What an extension provides

- **Integrations.** Typed APIs for a tool or service.
- **Ready-made steps.** Well-named steps with sensible defaults that a project
  can drop into its commands.
- **Default filters.** Filters for the tools the extension runs.
- **Report writers.** For example, converting a tool's results to JUnit XML.
- **Fallbacks.** Where the extension offers more than one implementation, it
  follows the [explicit fallback rules](#native-implementations-and-explicit-fallbacks).

*Illustrative, for a hypothetical SwiftLint extension:*

```swift
import SwiftCI

public struct SwiftLint {
    public init(executable: String = "swiftlint", strict: Bool = false) { … }

    /// Runs `swiftlint lint` with SwiftCI's process runner and default filter.
    ///
    /// Opens a step named "SwiftLint" when called at the top level of a command. `step` renames it.
    public func lint(step name: String? = nil) async throws {
        try await step(default: "SwiftLint", name: name) {
            try await Tool(
                command: executable,
                arguments: ["lint", "--quiet"] + (strict ? ["--strict"] : []),
                filters: Self.defaultFilters
            ).run()
        }
    }

    public static let defaultFilters: [Filter] = [ … ]
}
```

`lint` opens its own step, so a script calls it directly: `try await SwiftLint().lint()`.

### Extension API (planned)

The core's public API is the contract for extensions. It is versioned with that
in mind:

- `Command`, `step`, `cleanup`, `onFailure`
- `step(default:name:)`, for integration steps (see [Extensions](#extensions))
- Process execution: `Tool` with `run()`, `output()` and `result()`: arguments,
  environment, working directory, input, timeouts, output streaming and capture,
  filters
- `ProcessRunner`, the protocol that starts a tool's process. Tests replace it
  with a mock
- Logging (`Log`), full log and step headers
- `Filter` and filter helpers
- Secret declaration (`Secret`) and redaction of every writer
- Environment access (`@Env`, `@EnvOpt`)
- `BuildError` and exit codes
- Paths: Foundation `URL` (file URLs) throughout, with small SwiftCI helpers
  (URL extensions or a thin wrapper) for common operations such as resolving
  paths relative to the project root, checking existence, creating
  directories, and temporary and artifacts locations
- Artifacts directory: `Artifacts.directory` and `Artifacts.url(_:)`
- CI environment: detection of the CI system (branch, commit, merge request,
  build URL, local run) and output export to later steps, through a public
  adapter protocol. Built-in adapters cover Jenkins (including GitLab plugin
  variables), GitLab CI, GitHub Actions, Bitrise and local runs. Extensions
  can register more.
- Report model (`TestReport`, `TestSuite`, `TestCase`) and JUnit writer (`JUnit.write`)
- `SwiftCITesting`: mocks and helpers (log, shell/process, environment) for
  testing CI scripts and extensions

### Module layout

This repository ships the core and the first-party modules as separate library
products. Keeping them together lets changes to the core and its modules land in
one commit and one version while the extension API is still evolving. Projects
then need only one package dependency. Because modules use only the public API,
any of them can later move to its own repository, for example if it needs its
own release pace.

| Product | Platforms | Contents |
|---|---|---|
| `SwiftCI` | macOS, Linux | Core: commands, steps, processes, logging, filters, secrets, environment, artifacts, reports, Git, SwiftPM (`swift build` / `swift test`) |
| `SwiftCIXcode` | macOS | `xcodebuild`, xcresult test reports (`Xcode.testReport`, `Xcode.writeJUnitReport`), simulators, Xcode selection, version and build numbers, app icon overlay |
| `SwiftCISigning` | macOS | Keychains, match-compatible signing asset install, provisioning profiles, fastlane `match` fallback |
| `SwiftCIAppStoreConnect` | macOS (core of the client may later run on Linux) | Minimal native App Store Connect client: API key auth, build upload, build processing status; notarization; fastlane fallbacks |
| `SwiftCISlack` | macOS, Linux | Slack incoming webhooks |
| `SwiftCIGitLab` | macOS, Linux | GitLab merge request feedback: find the merge request from CI variables, render the run report as one comment per report ID (create, update, resolve) |
| `SwiftCITesting` | macOS, Linux | Test support for CI scripts and extensions: process runner and log mocks, and scoped setup of the environment and the mocks (prototype, see [Testing CI scripts and extensions](#testing-ci-scripts-and-extensions)) |

Today the package has the products `SwiftCI`, `SwiftCIXcode`, `SwiftCISigning`,
`SwiftCISlack` and `SwiftCITesting`. `SwiftCIAppStoreConnect` and `SwiftCIGitLab` have no code yet, so they
become products when their first code lands. The modules are built and tested on macOS.
Linux verification is tracked separately in the
[Linux verification plan](docs/plans/linux-verification.md).

### Conventions for independent extensions

- Package name `swift-ci-<name>`, library product `SwiftCI<Name>`.
- Depend on the core with a semantic version range (`from: "x.y.z"`).
- Follow the same principles as the core: generic, minimal dependencies, default
  filters, secret safety, explicit fallbacks, and clearly declared platform
  support.
- There is no central registry. Known extensions may be listed in this README.

### App Store Connect client

`SwiftCIAppStoreConnect` contains a minimal native client that covers only what
CI needs: ES256 API key tokens (CryptoKit), the Build Upload API, build
processing status and, if needed, TestFlight group assignment. A full client
such as [AppStoreConnect-Swift-SDK](https://github.com/AvdLee/appstoreconnect-swift-sdk)
is generated from Apple's complete OpenAPI specification. It would add a
third-party dependency and noticeable compile time to every CI package, and CI
would use only a small part of it.

Projects that need more of the API (metadata, testers and groups, users,
reviews) can use an independent extension built on that SDK. See
[Extension ideas](#extension-ideas).

### Known extensions

None yet.

### Extension ideas

Ideas, not commitments. Each could be an independent `swift-ci-<name>` package,
or a first-party module if it proves broadly useful. All of them follow the same
rules: generic, minimal dependencies, default filters, secret safety.

**Apple distribution**

- **Full App Store Connect API.** An extension that wraps
  AppStoreConnect-Swift-SDK for metadata, TestFlight testers and groups, users
  and review submission. It suits projects that need more than the minimal
  first-party client.
- **Publishing over-the-air install files.** Upload the IPA, `manifest.plist`
  and install page to a web server or object storage.
- **Other distribution services.** Firebase App Distribution and similar
  services, through their HTTP APIs.
- **Screenshots.** Run UI tests that capture App Store screenshots and collect
  them from the `.xcresult` bundle. This is an alternative to
  `fastlane snapshot`.

**Code quality**

- **SwiftLint and swift-format.** Run them with default filters, and emit JUnit
  or annotation reports.
- **Compiler warning gate.** Fail a build on new compiler warnings. An allowlist
  file records accepted warnings, and each entry needs a reason.
- **SonarQube.** Produce Sonar's generic test execution and coverage formats,
  and run the scanner.
- **GitHub pull request feedback.** Render the run report as a pull request
  comment, step summary and annotations. This mirrors the first-party
  `SwiftCIGitLab` module and is a lightweight alternative to parts of Danger.

**Build support**

- **Code generation.** SwiftGen, Sourcery and similar generators, with filters
  and up-to-date checks.
- **Project generation.** Run XcodeGen or Tuist before building.
- **Caches.** Save and restore SwiftPM and DerivedData caches on local disk or in
  object storage.
- **DocC publishing.** Build documentation archives for several modules, merge
  them, and publish a static site.
- **UI test diagnostics.** Record simulator video, and collect crash logs and
  attachments when UI tests fail.

**Notifications and project tracking**

- **Chat services.** Microsoft Teams, Google Chat, Mattermost and Discord
  webhooks, alongside the first-party Slack module.
- **Release notes.** Generate notes from Git history and tags, optionally
  linking issue tracker keys.
- **Issue trackers.** Comment on or transition Jira, GitLab or GitHub issues
  that a build references.

**Secrets**

- **Secret providers.** Load secrets from 1Password, HashiCorp Vault or the macOS
  keychain, and register them for redaction automatically.

The core follows semantic versioning. Before 1.0, minor releases may break the
extension API. After 1.0, breaking changes only happen in major releases.

## Platforms

- **Core (`SwiftCI`).** macOS and Linux. It is built and tested on macOS; Linux verification is planned (see [Known issues](#known-issues)).
  Linux CI will use the official Swift Docker images **(planned)**.
- **Apple modules.** macOS only. They should still compile on Linux, with their
  APIs unavailable, so that one CI package can contain both Linux and macOS
  commands. A project gates its Apple-only commands with `#if os(macOS)`.
- **Rules for the core.** Use only APIs available in Foundation on Linux. Do not
  use `AppKit`, `Security`, `CryptoKit` or `CommonCrypto`. Use `URLSession`
  through `FoundationNetworking` on Linux. Represent paths as Foundation `URL`,
  not `System.FilePath`, so no `swift-system` dependency is needed.
- **Windows.** Not a goal.

### Toolchain and Xcode versions

- **Swift.** Building a CI package requires Swift 6.2 or later. The package uses
  `swift-tools-version: 6.2`. On macOS, this means Xcode 26 or later.
- **Xcode driven by SwiftCI.** Xcode 26 or later. SwiftCI supports the two latest
  major Xcode versions (currently 26 and 27). Output filters, `.xcresult` parsing
  and export options are tested with fixtures from each. Support for the oldest
  is dropped when a new major version ships. The Xcode used for builds may differ
  from the one that compiled the CI package. Select it with `DEVELOPER_DIR` or
  `xcode-select`.
- **Result bundles.** SwiftCI parses them only with the current `xcresulttool`
  JSON API (`get test-results`, `get build-results`), never the legacy mode.

## Capabilities

**Prototype** means the feature exists and at least one project uses it, but it
is not yet fully tested or stable. **Planned** means it is designed here but not
implemented.

| Area | Capability | Status |
|---|---|---|
| Core | Commands, throwing and allowed-failure steps with nesting, integration calls as steps, `cleanup` / `onFailure` handlers | Prototype |
| Core | Process execution with streamed output and filters; `--verbose` shows the output unfiltered | Prototype |
| Core | Console log with colours, per-command full log file (`logs/<command>.log` in the artifacts directory) | Prototype |
| Core | Artifacts directory: `SWIFTCI_ARTIFACTS_DIR`, `SwiftCI(artifactsDirectory:)`, `Artifacts.directory` and `Artifacts.url(_:)` | Prototype |
| Core | Environment variables (`@Env`, `@EnvOpt`) | Prototype |
| Core | Secret declaration (`Secret("NAME")`), redaction in all writers, secrets in `Tool` environment and input | Prototype |
| Core | Exit codes (failed steps exit 1, usage errors 2, internal errors 3) | Prototype |
| Core | `--list`, `--help`, and the command list after a missing or unknown command | Prototype |
| Core | Options `--name=value` and inputs (`input(…)`) from the command line, then the environment, then the default; a warning for options that no input read | Prototype |
| Core | Builds and runs on Linux | Planned |
| Core | Public, versioned extension API | Planned |
| Core | Split into core and first-party modules (`SwiftCI`, `SwiftCIXcode`, `SwiftCISigning`, `SwiftCISlack`; macOS verified, Linux not yet) | Prototype |
| Testing | `SwiftCITesting`: `ProcessRunnerMock`, `LogMock`, `SwiftCITest.run` and scoped environment and mocks, for scripts and extensions (macOS verified) | Prototype |
| Core | Step summary at end of run (status and duration per step) | Planned |
| Core | CI environment detection (`CI.environment`: Jenkins, GitLab CI, GitHub Actions, Bitrise, generic CI, local) | Prototype |
| Core | CI output export to later steps (`CI.export`): `envman`, `$GITHUB_ENV` and `artifacts/outputs.env` | Prototype |
| Xcode | clean, build, archive and export (IPA and dSYM zip to the artifacts directory by default), resolve packages, build settings, docbuild | Prototype |
| Xcode | test, with result bundle, code coverage, test plan, timeout and raw log file; xcresult summary of failures and coverage is planned | Prototype |
| Reports | JUnit XML test reports from `.xcresult`: `Xcode.testReport` (model) and `Xcode.writeJUnitReport` (file, in a step); the writer is in the core | Prototype |
| Reports | Coverage reports (Cobertura XML) from `.xcresult` | Planned (later) |
| Reports | Warning and error annotations (GitLab Code Quality, GitHub workflow commands) | Planned (optional, later) |
| Xcode | Default `xcodebuild` console filter: errors, warnings and the result line; for `test`, also the failing tests, the summaries, and the simulator and test runner failures (lost connection, restart, crash, hang, early exit) | Prototype |
| Xcode | `xcodebuild` output formatter with progress (xcbeautify-style) | Planned |
| Xcode | Xcode selection and preflight checks (version, SDKs, simulators) | Planned |
| Xcode | Version and build number setting | Prototype |
| Xcode | Over-the-air install files (`manifest.plist` and install page) | Prototype |
| Simulators | Shut down all simulators via `simctl` (`Simulator.shutdownAll`) | Prototype |
| Simulators | Boot and erase via `simctl` | Planned |
| SwiftPM | `swift build`, `swift test`, with output formatting | Planned |
| Signing | Keychain unlock; the password goes to `security -i` on standard input, never as an argument | Prototype |
| Signing | Temporary keychain create / import / partition list / delete | Planned |
| Signing | Install signing assets from a fastlane `match` Git repository (read-only, native); Git credentials and keychain passwords are not arguments | Prototype |
| Signing | Same via fastlane `match` (fallback) | Prototype |
| App Store Connect | API key auth (ES256 JWT with CryptoKit) | Planned |
| App Store Connect | Upload builds (Build Upload API; `iTMSTransporter` interim) | Planned |
| App Store Connect | Upload via fastlane `pilot` / `deliver` (fallback) | Planned |
| macOS | Notarization via `notarytool`, stapling | Planned |
| Notifications | Slack incoming webhooks, as Block Kit (`Slack.send`) or legacy attachment (`Slack.sendAttachment`) messages, with optional sender name and icon; the webhook URL is a `Secret` | Prototype |
| Merge requests | GitLab merge request comment from the run report (`SwiftCIGitLab`) | Planned |
| Git | Commit hash, tag | Prototype |
| Misc | App icon text overlay (e.g. build number or environment badge) | Prototype |
| Generic | Arbitrary shell commands and scripts | Prototype |
| Migration | Run Bitrise CLI workflows (`bitrise --ci run`) with an output filter. **Temporary.** Removed once it is no longer needed for migration, and at the latest before 1.0 ([details](docs/plans/incremental-adoption.md#decisions)) | Prototype |

## Native implementations and explicit fallbacks

Some integrations have both a native Swift implementation and an external one.
For now, the external one is always fastlane. These are the rules:

1. **The caller chooses.** Integrations that have more than one implementation
   take an explicit parameter such as `using: .native` or `using: .fastlane`.
2. **No automatic switching.** If the chosen implementation fails, the step
   fails. Silently retrying with another implementation would make CI results
   impossible to reason about.
3. **The log says which ran.** Every step records the implementation and tool
   version it used.
4. **SwiftCI does not install fallbacks.** If a project uses the fastlane
   fallback, the project provides fastlane, typically through its own `Gemfile`
   and Bundler. SwiftCI only invokes it. The project chooses how: `.direct` runs
   `fastlane` from `PATH`, and `.bundler(gemfile:)` runs `bundle exec fastlane`,
   with `BUNDLE_GEMFILE` set when a Gemfile path is given. SwiftCI never looks
   for a Gemfile by itself.
5. **Native must earn its place.** A native implementation becomes the
   recommended choice only once it has automated tests against realistic
   fixtures and has been used in real CI runs.

| Task | Native | Fallback |
|---|---|---|
| Install signing assets from a match repository | Swift: Git clone, decrypt v1/v2 match files, `security import`, install profiles | `fastlane match --readonly` |
| Create or renew certificates and profiles | Not planned initially | `fastlane match` (non-readonly) |
| Upload to TestFlight / App Store | App Store Connect Build Upload API; `xcrun iTMSTransporter` first | `fastlane pilot` / `deliver` |
| App Store metadata and screenshots | Out of scope | `fastlane deliver` |
| JUnit test reports | Swift, from `xcrun xcresulttool` output | `fastlane trainer` |
| Coverage reports | Swift, from `xcrun xccov` output | None planned |

## Output, filtering and secrets

SwiftCI writes each tool's output to two places:

- **Console.** Filtered, coloured and compact. Each integration has a default
  filter that keeps progress (e.g. "Compiling Foo.swift"), warnings, errors and
  test results, and drops noise. `--verbose` skips the filters, so every line
  reaches the console; secrets are still masked. Colours follow
  terminal detection and the `NO_COLOR` convention **(planned)**.
- **Full log.** The complete output of every tool, unfiltered but with secrets
  redacted. It has one file per command, with step headers. The log is saved as
  `logs/<command>.log` in the artifacts directory, so that CI can archive it. A
  second run of the same command overwrites it. See
  [Running in CI and locally](#running-in-ci-and-locally).

A `Tool` can also copy its unfiltered output to a file of its own with
`outputFile:`. The copy is written as the lines arrive, without the `[stderr] `
prefix, with secrets masked, and `--verbose` does not change it.

Filters are plain Swift functions of type `(String) -> String?`. A filter returns
the line, a rewritten line, or `nil` to hide it. Projects can replace or extend
the default filters of any tool.

A line whose meaning depends on the lines around it is decided by a
`BlockFilter`, which may show several lines for one or hold a line back. The
helper `tableFilter(keeping:otherLines:)` shows or hides each table of the output
as a whole, by its title, and passes the other lines on to a plain filter.

Secret handling follows these rules:

- A secret is declared with `Secret("NAME")`. The value is read from that
  environment variable when the secret is declared, and the declaration does
  not throw. `Secret(value:)` registers a value derived at runtime. Its value is
  replaced with `••••••` in console output, full logs and error messages.
- The value is checked at first use. A missing or empty variable, or a value
  shorter than 4 characters, is a usage error (exit code 2). The message names
  the variable and never shows the value.
- Each secret value is masked, and so are its percent-encoded forms (RFC 3986,
  in upper and lower case hex) and each of its lines. Longer values are masked
  first, so a secret that contains another one is masked as a whole. Form
  encoding and base64 are not masked.
- Redaction is applied after all filters, so a custom filter cannot bypass it.
- `Secret` prints as `••••••` in string interpolation, `print`, `String(reflecting:)`
  and `dump`. `revealedValue()` returns the raw value, for APIs that need it.
- A `Tool` takes secrets through its environment and its input. The child
  process receives the raw value. Captured output, such as the value of
  `output()`, is not masked, because programs parse it. The logs still mask it.
- Integrations pass secrets to child processes through environment variables or
  standard input, never as command-line arguments. Command-line arguments are
  visible in `ps` and are written to the full log.
- `Environment.writeToLog()` prints every variable and masks values that look
  secret: names with a part such as `PASSWORD`, `TOKEN`, `SECRET` or `KEY` (but
  not `KEY_ID` or `KEY_PATH`), and values in a well-known secret format (GitHub,
  GitLab and Slack tokens, AWS key IDs, private keys, JWTs). A URL with a
  password keeps the URL and masks the password. `reveal:` shows named variables
  for false positives. These guesses only affect the dump; to mask a value
  everywhere, declare it with `Secret`.

## Reports for CI systems

CI systems can render a few standard report formats themselves. That is more
useful than scrolling through logs. SwiftCI writes reports to the artifacts
directory, and the CI configuration publishes them.

**JUnit XML test reports.** `Xcode.writeJUnitReport` writes a JUnit XML file
converted from the `.xcresult` bundle of `Xcode.test` (`swift test` is
planned).

- Jenkins (`junit` step) shows failed tests per build, test trends and
  durations, and can mark builds with only test failures as unstable.
- GitLab (`artifacts:reports:junit`) shows failed tests, including newly failing
  ones, directly in the merge request.
- Other consumers, such as Danger, read the same file.
- It replaces `fastlane trainer`, which is commonly used only for this
  conversion.

The converter reads `xcrun xcresulttool` output. Apple changes that output
between Xcode versions, so the converter needs fixtures from each supported
Xcode version.

**Coverage reports (planned, later).** The converter writes Cobertura XML from
the `.xcresult` bundle (`xcrun xccov`). GitLab's coverage visualisation,
SonarQube and similar tools read that file.

**Annotations (planned, optional, later).** Annotations attach compiler
warnings, errors and lint findings to the changed lines in a merge or pull
request. They use GitLab Code Quality reports or GitHub workflow commands
(`::warning file=…,line=…`). Each CI system needs its own small formatter, and
the value overlaps with Danger and log-parsing CI plugins. So these come after
the core reports.

**Machine-readable run summary (deferred).** A JSON file with step status,
durations and artifact paths could feed notifications or dashboards without
scraping logs. It will be added when something needs it.

## Running in CI and locally

The same command runs everywhere:

```sh
./ci test
```

- Jenkins calls `sh './ci test'`.
- GitLab CI uses `script: ["./ci test"]`.
- GitHub Actions uses `run: ./ci test`.
- Bitrise runs a single script step with `./ci test` as an intermediate
  migration stage.
- On a developer Mac, `./ci test` runs the same way. Commands should not
  assume CI-only state.
  Where a command needs CI-only resources (signing secrets, upload keys), it
  fails early with a clear message that names the missing environment variable.

### Artifacts

Each run keeps its files in one artifacts directory: the full log of each
command (`logs/<command>.log`), and the files that commands write with
`Artifacts.url(_:)` or that integrations keep. CI archives this directory.

- By default it is `artifacts/` in the working directory when the run starts.
- A script can choose another default with `SwiftCI(artifactsDirectory:)`.
- The environment variable `SWIFTCI_ARTIFACTS_DIR` wins over both, so a job
  can redirect the output without a code change, for example on Bitrise:
  `SWIFTCI_ARTIFACTS_DIR="$BITRISE_DEPLOY_DIR" ./ci test`.
- SwiftCI creates the directory when the first command starts. A path that
  exists and is not a directory fails the run with exit code 2, and the message
  names the setting.
- SwiftCI never deletes anything in it. Clean the CI workspace between builds,
  and delete the directory by hand locally.

Archive `artifacts/` in the CI system, even when the build fails, so that the
logs of a failed run are kept:

- Jenkins: `archiveArtifacts artifacts: 'artifacts/**', allowEmptyArchive: true`
- GitLab CI: `artifacts: { when: always, paths: [artifacts/] }`
- GitHub Actions: `actions/upload-artifact@v4` with `path: artifacts/` and
  `if: always()`

On a developer machine, add `artifacts/` to `.gitignore`, so that the full logs
do not show up in `git status`.

Test and coverage reports for the CI system are described in
[Reports for CI systems](#reports-for-ci-systems).

### CI environment

`CI.environment` tells a script which CI system runs it and what it builds:
the branch, commit, tag, merge request, build number, build URL and job name.
SwiftCI detects it once, when `SwiftCI { }` starts, from the environment of the
run. A local run has `isCI` set to `false` and no build information.

```swift
let release = Command("release") {
    let ci = CI.environment
    if ci.isCI, let number = ci.buildNumber {
        log("Build \(number) of \(ci.branch ?? "?")")
    }
}
```

- Built-in detection covers GitHub Actions, GitLab CI, Bitrise, Jenkins
  (including the GitLab plugin and multibranch pipelines), other systems that
  set `CI=true`, and local runs.
- `SwiftCI(ciAdapters:)` adds adapters for other systems. They are asked before
  the built-in ones.
- The full log of each command records the result in one line, for example
  `CI: Jenkins, build 123, branch main`.
- A field-by-field reference of the variables and precedence used by each
  adapter is tracked in the
  [end-user documentation plan](docs/plans/end-user-documentation.md#d6-ci-environment-and-output-export-reference).

### Output export

`CI.export` passes a value to later steps of the CI job. It uses the mechanism
of the runner that the command runs in:

```swift
let archive = try await xcode.archiveAndExport(ipaFileName: "MyApp")
try await CI.export("MYAPP_IPA_PATH", archive.ipaURL.filePath)
```

| Runner | How the value is passed |
|---|---|
| Bitrise CLI (`ENVMAN_ENVSTORE_PATH` is set), on a Mac or on bitrise.io | `envman add`. Later steps of the Bitrise workflow see the value. This also applies to the Bitrise CLI inside another CI system, such as a Jenkins job. |
| GitHub Actions (`GITHUB_ENV` is set) | `NAME=value` is appended to `$GITHUB_ENV`, and to `$GITHUB_OUTPUT` when that is set too. Later steps see the variable, and a step with an `id` reads `steps.<id>.outputs.NAME`. |
| Anything else, such as GitLab CI, Jenkins or a local run | `NAME=value` is written to `artifacts/outputs.env`, one line per name. |

- Names must match `[A-Za-z_][A-Za-z0-9_]*`. Values are one line. To pass a
  text with line breaks, write it to a file with `Artifacts.url(_:)` and export
  the path of the file.
- Secrets cannot be exported. A value that contains a registered secret is a
  usage error (exit code 2), and the message does not show the value.
- `CI.export` is not a step. It logs `Exported NAME` in the current step. An
  export does not change the environment of the SwiftCI process, so use a Swift
  variable for the same script.
- A failing `envman` or an unwritable file fails the command.
- The dotenv file is kept between runs. A reused workspace may hold names from
  an earlier build, so clean the workspace before the build. A name that is
  exported again replaces its line.

GitLab CI reads the dotenv file as a report, so that later jobs see its
variables. GitLab limits dotenv reports to 5 KB and, by default, 20 variables on
self-managed instances:

```yaml
build:
  script: ["./ci build"]
  artifacts:
    reports:
      dotenv: artifacts/outputs.env

deploy:
  needs: ["build"]
  script: ['echo "$MYAPP_IPA_PATH"']
```

Jenkins has no native mechanism. A Jenkinsfile reads the file with the
`readProperties` step of the Pipeline Utility Steps plugin:

```groovy
sh './ci build'
def outputs = readProperties file: 'artifacts/outputs.env'
env.MYAPP_IPA_PATH = outputs.MYAPP_IPA_PATH
```

## Testing CI scripts and extensions

A CI script or an extension can be tested without running real tools. Add the
`SwiftCITesting` product to the test target of the CI package, or of the
extension, and use only its public API:

```swift
import SwiftCI
import SwiftCITesting
import Testing

@Suite(.serialized) struct BuildTests {
    @Test func buildCompilesTheScheme() async {
        let runner = ProcessRunnerMock()
        let result = await SwiftCITest.run(
            ["build"],
            environment: ["MYAPP_SCHEME": "MyApp"],
            runner: runner
        ) {
            command(Command("build") {
                let scheme = try Environment.required("MYAPP_SCHEME")
                try await step("Compile") {
                    try await Tool(command: "mytool", arguments: ["build", scheme]).run()
                }
            })
        }

        #expect(result.exitCode == 0)
        #expect(result.plainLog.contains("Entering step [Compile]"))
        #expect(runner.tools.map(\.arguments) == [["build", "MyApp"]])
    }
}
```

- `SwiftCITest.run` runs the commands of a script as `./ci <command>` does, with
  the mocks in place, and returns the exit code and the log. It does not exit the
  process.
- `ProcessRunnerMock` records every `Tool` that runs: its command, arguments,
  environment (secret values stay secrets), input and working directory. Set the
  result of a program with `respond(to:with:)`, a queue of responses, or a
  `handler`. A response can stream lines to the log, or throw.
- `LogMock` records each console line and the arguments of each log method.
- `SwiftCITest.withMocks` does the same setup for code that is not a command, such
  as a call of a module's function. The environment is set only inside it.
- Each `run` and `withMocks` call has its own artifacts directory. Without an
  `artifactsDirectory:`, it is a temporary directory that is removed afterwards,
  so the files of a test are gone when it returns. A test that checks files passes
  its own directory. The result of `run` reports the directory it used. Nothing is
  written to the working directory.
- Only `Environment`, `@Env` and `Secret` read the variables that the test sets. The
  real environment of the shell that runs the tests is not read.

**Tests that use `SwiftCITesting` must not run at the same time.** SwiftCI keeps
its state in globals, such as the registrations, the secrets and the environment.
Put the tests in a suite marked `.serialized` (Swift Testing), or leave XCTest at its
default of one test at a time. Do not run them with `--parallel`.

Recommended practice:

- Cache `CI/.build` between runs.
- Pin SwiftCI to a release tag, not a branch.
- Keep secrets in the CI system's credential store and pass them as environment
  variables.

## Migrating from Bitrise and fastlane

Typical Bitrise steps and fastlane actions, and their SwiftCI counterparts:

| Bitrise step / fastlane action | SwiftCI |
|---|---|
| `script` | `step(name) { … }` with Swift code, or `Tool(shellCommand:)` for shell |
| `xcode-test` / `scan` | `Xcode.test` (result bundle, coverage and test plan) |
| `xcode-archive` / `gym` | `Xcode.archiveAndExport`, a step itself. No `step` wrapper needed |
| `xcode-project-info` | `Xcode.getBuildSettings(target:)` and `Xcode.getVersion` |
| `set-xcode-build-number` / `increment_build_number` | `Xcode.setBuildNumber`; read the current value with `Xcode.getVersion` |
| `fastlane match` (readonly) | `Signing.installMatchAssets(using: .native)` |
| `deploy-to-itunesconnect-deliver` / `pilot` | `AppStoreConnect.upload` **(planned)**, or the fastlane fallback |
| `slack` | `Slack.sendAttachment` for the same attachment format with a colored bar, or `Slack.send` for Block Kit; both are steps themselves |
| `trainer` | `Xcode.writeJUnitReport` from the result bundle |
| `before_run` / `after_run` workflows | Reusable `async throws` functions, and `cleanup { }` / `onFailure { }` handlers |
| `is_always_run` | `cleanup { … }` |
| `is_skippable` | `step(name, failure: .allowed) { … }` |
| `envman add` (pass values between steps) | `CI.export`, which passes a value to later steps. Inside one script, use Swift variables |
| `run_if` | `step(name, when: condition, skipReason: …) { … }`, which logs the skipped step, or an ordinary Swift `if` |

Migration can be gradual. Keep the existing CI server, replace one Bitrise
workflow or fastlane lane at a time with a SwiftCI command, and call that
command from the old configuration until nothing else remains.

While a Bitrise workflow still does part of the work, a SwiftCI command can
wrap it. `Bitrise.run` is temporary, and it is removed before 1.0:

```swift
let release = Command("release") {
    try await xcode.archiveAndExport(ipaFileName: "MyApp")

    // Temporary: the upload workflow is not ported yet.
    try await Bitrise.run(workflow: "upload")
}
```

Values that the workflow exports with `envman` are lost when it exits, so pass
values in with `environment:`, using names that the workflow does not define.

## Prior art and alternatives

This section is a summary. Sources and details are in
[docs/prior-art.md](docs/prior-art.md).

| Tool | What it is | Relation to SwiftCI |
|---|---|---|
| fastlane (Ruby) | The established iOS/Android automation suite: gym, scan, match, pilot, deliver, plugins | Compatibility target and explicit fallback |
| Fastlane.swift | Fastlane lanes written in Swift; still beta, still needs Ruby | Shows that Swift syntax alone, without removing the Ruby runtime, isn't enough |
| Bitrise | Hosted CI + `bitrise.yml` runner + versioned step library | SwiftCI replaces the local workflow runner and steps, not the hosted CI |
| Codemagic CLI tools (Python) | Signing, build and publishing helpers for Codemagic | Similar scope, different language |
| Xcode Cloud | Apple-hosted CI | Alternative for teams happy with Apple's hosted model |
| GitHub Actions / GitLab CI / Jenkins | Orchestration and runners | What invokes SwiftCI |
| Swiftlane / Puma | Earlier Swift fastlane alternatives; inactive or archived | Cautionary: keeping up with Apple is the main cost |
| Tuist, XcodeGen | Swift project generation | Adjacent; can be used alongside |
| xcbeautify, xcpretty | `xcodebuild` output formatters | Inspiration for default filters |
| Sake, swift-sh | Swift task runners and scripting | Adjacent; general scripting, not CI integrations |
| AppStoreConnect-Swift-SDK | Swift client for the full App Store Connect API | Reference; not used by the first-party minimal client, candidate basis for an [extension](#extension-ideas) |
| Danger Swift | Pull request review automation in Swift | Complementary |

## Is this a good idea?

A candid assessment, revisited as the project evolves.

**Why it can work**

- The common path of Apple CI is small: select Xcode, resolve, build, test,
  archive, export, install signing assets, upload, notify. Most of it is thin
  wrappers over stable Apple tools.
- One language for app and CI code removes a whole class of problems. Examples
  are Ruby version managers, Bundler, native gem extensions and OpenSSL breakage
  on macOS upgrades.
- Typed, compiled scripts catch mistakes before a 20-minute CI run does. They can
  be debugged locally in Xcode.
- YAML-based workflow runners push logic into embedded shell scripts. In Swift,
  the logic is ordinary code.

**Risks**

- **Apple churn.** Xcode output formats, `xcodebuild` options, signing and App
  Store Connect workflows change every year. Earlier Swift fastlane alternatives
  (Puma, Swiftlane) stalled for exactly this reason. Maintenance is a recurring
  cost, not a one-off.
- **Signing is unforgiving.** Keychains, partition lists, certificate and
  profile matching and match repository compatibility have many edge cases.
  Failures are hard to diagnose on remote machines.
- **Reinventing fastlane.** Every native reimplementation of a fastlane feature
  competes with a mature, widely used implementation.
- **Compile time.** Swift scripts must be built before they run. Caching
  mitigates this, but a cold machine is slower than a shell script.
- **Bus factor.** A small project depends on a few maintainers.

**How the design limits the risks**

- Thin, typed wrappers over Apple tools rather than reimplementations of them.
- An explicit fastlane fallback for every native implementation that could fail
  on edge cases, so a broken native path never blocks a release.
- Strict scope: only the common path is native, and the rest is shell or the
  fallback.
- Compatibility fixtures and tests for anything security- or format-sensitive
  (match decryption, JWT signing).
- No hidden state: plain Swift, plain processes, and logs that show exactly what
  ran.

**When not to use SwiftCI.** Skip it if Xcode Cloud covers your needs, if you
depend on fastlane's metadata and screenshot tooling or its plugin ecosystem, or
if nobody on the team wants to maintain CI code in Swift.

## Roadmap

The order of work follows from adopting SwiftCI in a real project. See the
[implementation plan](docs/plans/implementation-plan.md).

1. **Correctness of the core.** Fix exit codes and add secret redaction. Extend
   the process API with separate stdout and stderr, output capture, timeouts,
   a working directory and an environment. The fastlane fallback now runs
   `fastlane` by name, and it needs tests for all of it.
2. **Core and modules.** Split the package into the core and first-party
   modules and `SwiftCITesting` (done on macOS). Make the extension API public,
   and build and test the core on Linux.
3. **Clean output.** Add a default `xcodebuild` formatter and a step summary.
   The artifacts directory is in the core; the
   integrations that write files into it follow.
4. **Xcode test path.** Add `Xcode.test`, xcresult summaries, JUnit reports,
   simulator management, Xcode preflight checks, and SwiftPM build and test
   support.
5. **Signing.** Add temporary keychains, a native match install with v1 and v2
   fixtures, and the fastlane fallback.
6. **Distribution.** Add the App Store Connect JWT. Upload through Transporter
   first, then through the Build Upload API. Add notarization for macOS.
7. **More reports.** Add coverage reports, then optional annotations for GitLab
   and GitHub.
8. **Stabilise.** Publish semantically versioned releases, complete the
   [end-user documentation plan](docs/plans/end-user-documentation.md), and
   provide an example CI package and an example extension.

## Known issues

- On macOS 26, `set-key-partition-list -k` rejects keychain passwords that contain
  non-ASCII characters, even when they are passed correctly. `unlock-keychain`
  still accepts them. The native match install then logs a warning and continues
  without the partition list.
- Linux is not verified since the module split. The
  [Linux verification plan](docs/plans/linux-verification.md) tracks the work.
  The core does not build on Linux yet, and the blockers are: `Slack` uses `URLSession` without
  `FoundationNetworking`, and the Apple modules are not yet gated with
  `#if os(macOS)`. `SwiftCIXcode` imports `AppKit` (icon overlay), and
  `SwiftCISigning` imports `Security`, `CryptoKit` and `CommonCrypto` (match). The
  `ProcessRunner` Linux branches are also unverified. Paths are Foundation `URL`s,
  so `System` is not imported and no `swift-system` package is needed.

## Open questions

Decisions still to be made are tracked here until they are resolved:

- None at the moment.

## License

See [LICENSE](LICENSE).
