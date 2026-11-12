# SwiftCI

A Swift library for writing continuous integration scripts in Swift.

SwiftCI lets a project describe its CI work, such as building, testing,
signing, uploading and notifying, as a small Swift package. The package runs
the same way on a CI machine and on a developer's Mac. SwiftCI is meant as a
lightweight, Swift-native alternative to tools such as
[fastlane](https://fastlane.tools) and the [Bitrise](https://bitrise.io)
workflow runner. It keeps external dependencies to a minimum.

> **Status: early prototype.** The core (commands, steps, process execution,
> logging) and several Xcode helpers work and are used in real projects, but
> APIs are not stable and there are known correctness issues. See
> [docs/status.md](docs/status.md).

## Why SwiftCI

CI for an Apple platform project tends to grow into a stack of layers, each
with its own language and runtime: CI server job definitions in Groovy or
YAML, a workflow runner configured in YAML or Ruby, steps written in Ruby, Go
or Python, shell glued in between, and helper tools for the gaps. Together they
cost a lot:

- **Runtimes to maintain.** Ruby, Bundler, Python packages and Homebrew tools
  break on macOS and Xcode upgrades, exactly when CI is needed most.
- **Logic in the wrong places.** Build logic spread over YAML, Groovy, shell
  and Ruby is not type-checked, tested or navigable.
- **Hard to run locally.** Reproducing a CI failure means installing the whole
  stack.
- **Unreadable output.** Raw `xcodebuild` logs bury the one error that matters.
- **Leaky secrets.** Passwords end up on command lines and in logs.
- **Lock-in.** Workflows depend on a runner's YAML dialect and step library.

Most of the actual work is calling Apple's command-line tools in the right
order: `xcodebuild`, `xcrun`, `security`, `simctl`, `git`. That needs a thin,
typed layer with good defaults, not a separate ecosystem. SwiftCI provides that
layer as a Swift library. CI logic is an ordinary Swift package. It compiles
with the same toolchain as the app, runs the same way on CI and on a developer's
machine, and needs nothing else installed.

The full reasoning, including why not shell scripts and why a library rather
than a scripting tool, is in [docs/design.md](docs/design.md). How SwiftCI
relates to fastlane, Bitrise and other tools is in
[docs/prior-art.md](docs/prior-art.md).

## Goals

- **CI scripts in Swift.** Typed, compiled workflows that can be edited,
  debugged and unit tested like any other Swift code.
- **Minimal dependencies.** A Swift toolchain and Apple's command-line tools.
  No Ruby, Node.js, Python or Go runtime. Third-party Swift packages are
  avoided by default.
- **Native first, explicit fallback.** Common Apple CI tasks are implemented in
  Swift. A command can explicitly choose an external implementation such as
  fastlane. SwiftCI never switches implementations silently.
- **Clean output by default.** Every tool has a default output filter, in the
  spirit of [xcbeautify](https://github.com/cpisciotta/xcbeautify). The
  complete raw output is always kept in a log file.
- **Secrets never leak.** Registered secrets are redacted from all output and
  are never passed to child processes on the command line.
- **Generic.** No knowledge of any specific project, team or account.
- **Same script everywhere.** On CI machines driven by Jenkins, GitLab CI,
  GitHub Actions and similar systems, and on a developer's machine.
- **Every kind of Swift project.** Xcode projects and workspaces, Swift
  packages, all Apple platforms and server-side Swift, with shell commands as an
  escape hatch.
- **Linux-compatible core.** Apple-specific integrations are separate modules.
- **Extensible.** Integrations are extensions on SwiftCI's public API.
  First-party integrations use the same API as everyone else.

## Non-goals

- **Not a CI server.** Jenkins, GitLab CI, GitHub Actions, Bitrise or Xcode
  Cloud schedule jobs, store secrets and host logs. SwiftCI is what they invoke.
- **Not a YAML workflow engine.** Workflows are plain Swift code.
- **Not parallel.** Steps and commands run one after another.
- **Not a build system.** It drives `xcodebuild` and `swift build`, and does
  not generate projects.
- **Not a large step library.** Non-Swift work is done with shell commands, or
  with an independent [extension](docs/guides/extensions.md).
- **Not a drop-in fastlane replacement.** SwiftCI covers the common CI path:
  build, test, archive, install signing assets, upload and check the App Store
  metadata. Long-tail features such as editing metadata and screenshots, or
  managing certificates in the developer portal, remain available through the
  fastlane fallback.

**When not to use SwiftCI.** Skip it if Xcode Cloud covers your needs, if you
depend on fastlane's metadata and screenshot tooling or its plugin ecosystem, or
if nobody on the team wants to maintain CI code in Swift.

## Quick start

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
    ],
    targets: [
        .executableTarget(
            name: "ci",
            dependencies: [
                .product(name: "SwiftCI", package: "swift-ci"),
                .product(name: "SwiftCIXcode", package: "swift-ci"),
            ]
        ),
    ]
)
```

The products are listed under [Modules](#modules).

The `ci` wrapper script lives at the repository root. It changes to its own
directory, so the working directory is always the project root. `--quiet`
hides SwiftPM's build progress lines, so the console starts with the CI
output; build errors are still shown:

```sh
#!/bin/sh
set -e
cd "$(dirname "$0")"
exec swift run --quiet --package-path CI -c release ci "$@"
```

The first run builds the CI package, which takes tens of seconds. Later runs
are incremental.

### Example

*Illustrative. Which integration calls exist today is listed in
[docs/status.md](docs/status.md).*

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
        destination: Simulator.destination(device: device, os: "latest"),
        resultBundleURL: try Artifacts.url("MyApp.xcresult")
    )
}

let release = Command("release", description: "Build and upload to TestFlight") {
    let matchPassword = Secret("MATCH_PASSWORD")
    let slackWebhook = Secret("SLACK_WEBHOOK_URL")

    onFailure {
        try await Slack(webhookURL: slackWebhook).send(text: "Release build failed")
    }

    // The keychain must exist and be unlocked first, for example with Keychain.unlock(name:password:).
    try await Signing.installMatchAssets(
        type: .appstore,
        bundleIdentifiers: ["com.example.myapp"],
        teamId: "TEAMID1234",
        repository: MatchRepository(url: "git@git.example.com:ios/certificates.git"),
        matchPassword: matchPassword,
        keychain: .existing(name: "ci.keychain", password: Secret("KEYCHAIN_PASSWORD")),
        using: .native                          // or .fastlane(invocation: .bundler())
    )
    // Copies the IPA and the dSYM zip to the artifacts directory: artifacts/MyApp.ipa and artifacts/MyApp.dSYM.zip.
    try await xcode.archiveAndExport(ipaFileName: "MyApp")
    let apiKey = try AppStoreConnectAPIKey.environment(
        keyID: "ABC123DEFG", keyFileVariable: "ASC_KEY_PATH", issuerVariable: "ASC_ISSUER_ID"
    )
    try await AppStoreConnect(apiKey: apiKey).uploadBuild(ipa: Artifacts.url("MyApp.ipa"), appID: "1234567890")
}

await SwiftCI {
    command(test)
    command(release)
}
```

### Concepts

| Concept | Description |
|---|---|
| **Command** | A named entry point invoked from the command line, e.g. `./ci test`. Several commands can be given and run in order. `cleanup { }` and `onFailure { }` register handlers that run when the command ends. |
| **Step** | A named, timed unit of work inside a command, written `try await step("Name") { … }`. An error that escapes a step fails the command, unless the script catches it or marks the step `failure: .allowed`. Steps can be conditional and nested. |
| **Tool** | A child process (`xcodebuild`, `git`, a shell script) run with an argument array. Its output is streamed, filtered on the console and kept in full in the log. A non-zero exit throws. |
| **Integration** | Typed Swift API for a tool or service: `Xcode`, `Keychain`, `Signing`, `AppStoreConnect`, `Slack`, `Git`, … A call that does work is a step itself. A query is not. |
| **Extension** | A Swift library that adds integrations, ready-made steps, filters or report writers on top of the core. |
| **Filter** | A function that hides, rewrites or highlights a line of tool output. Every integration ships a default. |
| **Secret** | A value, usually from an environment variable, declared with `Secret("NAME")`. It is masked as `••••••` everywhere SwiftCI writes, and passed to tools through the environment or standard input, never as an argument. |

The details are in [Commands, steps and failures](docs/guides/commands-and-steps.md)
and [Output, filtering and secrets](docs/guides/output-and-secrets.md).

### Command line

```text
./ci <command> [<command> ...] [--name=value ...]   Run commands in order; stop at the first failed command.
./ci --list                                          List available commands.
./ci --verbose <command>                             Show unfiltered tool output on the console.
./ci --help                                          Show the usage and the command list.
```

A script reads an option with `try input("device", default: "iPhone 17")`,
from `--device=…`, then the environment variable `DEVICE`, then the default.
Any failure exits with a non-zero code. The options, inputs and exit codes are
described in [Commands, steps and failures](docs/guides/commands-and-steps.md).

### Run it in CI

The same command runs everywhere:

- Jenkins calls `sh './ci test'`.
- GitLab CI uses `script: ["./ci test"]`.
- GitHub Actions uses `run: ./ci test`.
- On a developer Mac, `./ci test` runs the same way. A command that needs
  CI-only resources (signing secrets, upload keys) fails early with a message
  that names the missing environment variable.

Each run writes its logs and files to `artifacts/`. Archive that directory in
the CI system even when the build fails, and add it to `.gitignore`.

Recommended practice:

- Cache `CI/.build` between runs.
- Pin SwiftCI to a release tag, not a branch.
- Keep secrets in the CI system's credential store and pass them as environment
  variables.

The artifacts directory, the CI environment and passing values to later CI
steps are described in [Running in CI and locally](docs/guides/running-in-ci.md).

## Modules

This repository ships the core and the first-party modules as separate library
products of one package. Each module depends only on the core's public API.

| Product | Platforms | Contents |
|---|---|---|
| `SwiftCI` | macOS, Linux | Core: commands, steps, processes, logging, filters, secrets, environment, artifacts, reports, Git |
| `SwiftCIXcode` | macOS | `xcodebuild`, xcresult test reports, simulators, version and build numbers, app icon overlay |
| `SwiftCISigning` | macOS | Keychains, match-compatible signing asset install, fastlane `match` fallback |
| `SwiftCIAppStoreConnect` | macOS | Minimal App Store Connect client: API key auth, build upload, metadata check |
| `SwiftCISlack` | macOS, Linux | Slack incoming webhooks |
| `SwiftCIGitLab` | macOS, Linux | GitLab merge request feedback from the run report |
| `SwiftCITesting` | macOS, Linux | Test support for CI scripts and extensions: process runner and log mocks, scoped environment |

CI scripts are testable with `SwiftCITesting`; see
[Testing CI scripts and extensions](docs/guides/testing.md). Integrations
beyond these modules come as [extensions](docs/guides/extensions.md).

## Platforms and requirements

- **Core (`SwiftCI`).** macOS and Linux. It is built and tested on macOS; Linux
  is not yet verified (see [docs/status.md](docs/status.md#known-issues)).
- **Apple modules.** macOS only. A project gates its Apple-only commands with
  `#if os(macOS)`.
- **Windows.** Not a goal.
- **Swift.** Building a CI package requires Swift 6.2 or later
  (`swift-tools-version: 6.2`). On macOS, this means Xcode 26 or later.
- **Xcode driven by SwiftCI.** The two latest major Xcode versions (currently
  26 and 27). The Xcode used for builds may differ from the one that compiled
  the CI package. Select it with `DEVELOPER_DIR` or `xcode-select`.

## Documentation

Guides:

- [Commands, steps and failures](docs/guides/commands-and-steps.md): concepts, command line, inputs and exit codes
- [Output, filtering and secrets](docs/guides/output-and-secrets.md)
- [Running in CI and locally](docs/guides/running-in-ci.md): artifacts, CI environment and output export
- [Reports for CI systems](docs/guides/reports.md): run report, merge request comments and JUnit XML
- [Testing CI scripts and extensions](docs/guides/testing.md)
- [Extensions](docs/guides/extensions.md): writing extensions, the extension API and extension ideas
- [App Store Connect](docs/guides/app-store-connect.md)
- [Migrating from Bitrise and fastlane](docs/guides/migration.md)

Project:

- [Status](docs/status.md): capabilities, roadmap, known issues and open questions
- [Design](docs/design.md): the reasoning behind the design
- [Prior art](docs/prior-art.md): related tools and Apple tooling risks
- [Repository layout](docs/repository-layout.md): files and folders of the package
- Plans: [end-user documentation](docs/plans/end-user-documentation.md), [Linux verification](docs/plans/linux-verification.md)

## License

See [LICENSE](LICENSE).
