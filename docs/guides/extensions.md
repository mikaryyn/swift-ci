# Extensions

The core is deliberately small. Integrations and ready-made steps come as
**extensions**. In this document, the word means plugins in the general sense,
not SwiftPM package plugins. An extension is a Swift library that depends on the
core and uses only its public API. It is usually a small, independent Swift
package. First-party integrations (Xcode, signing, App Store Connect, …) are
built the same way, so SwiftCI's own code exercises the extension API.

## What an extension provides

- **Integrations.** Typed APIs for a tool or service.
- **Ready-made steps.** Well-named steps with sensible defaults that a project
  can drop into its commands.
- **Default filters.** Filters for the tools the extension runs.
- **Report writers.** For example, converting a tool's results to JUnit XML.
- **Fallbacks.** Where the extension offers more than one implementation, it
  follows the [explicit fallback rules](../design.md#native-implementations-and-explicit-fallbacks).

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

A CI package adds an independent extension as a package dependency, next to
SwiftCI, and uses its product in the executable target:

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

## Extension API (planned)

The core's public API is the contract for extensions. It is versioned with that
in mind:

- `Command`, `step`, `cleanup` (including `cleanup(when:)`), `onFailure`, `deferringFailure`
- `step(default:name:)`, for integration steps
- Process execution: `Tool` with `run()`, `output()` and `result()`: arguments,
  environment, working directory, input, timeouts, output streaming and capture,
  filters
- `ProcessRunner`, the protocol that starts a tool's process. Tests replace it
  with a mock
- Logging (`Log`), full log and step headers
- `Filter` and filter helpers
- Secret declaration (`Secret`) and redaction of every writer
- Environment access (`Environment`)
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

## Conventions for independent extensions

- Package name `swift-ci-<name>`, library product `SwiftCI<Name>`.
- Depend on the core with a semantic version range (`from: "x.y.z"`).
- Follow the same principles as the core: generic, minimal dependencies, default
  filters, secret safety, explicit fallbacks, and clearly declared platform
  support.
- There is no central registry. Known extensions are listed below.

## Known extensions

None yet.

## Extension ideas

Ideas, not commitments. Each could be an independent `swift-ci-<name>` package,
or a first-party module if it proves broadly useful. All of them follow the same
rules: generic, minimal dependencies, default filters, secret safety.

**Apple distribution**

- **Full App Store Connect API.** An extension that wraps
  AppStoreConnect-Swift-SDK for editing metadata, TestFlight testers and groups, users
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

## Versioning

The core follows semantic versioning. Before 1.0, minor releases may break the
extension API. After 1.0, breaking changes only happen in major releases.
