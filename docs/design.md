# Design

The reasoning behind SwiftCI's design. [README.md](../README.md) gives the
overview, and [status.md](status.md) tracks what is implemented.

## The problem

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

## Why not just shell scripts?

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

[Why a library and not a scripting tool](#why-a-library-and-not-a-scripting-tool)
and [Is this a good idea?](#is-this-a-good-idea).

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

## Scripts are plain Swift

Workflows are Swift code, not configuration. Scripts are ordinary async Swift:
no result builders and no macros (which would need swift-syntax), and commands
are registered explicitly with `command(…)`. Reusable groups of steps are plain
`async throws` functions.

## One package for the first-party modules

This repository ships the core and the first-party modules as separate library
products. Keeping them together lets changes to the core and its modules land in
one commit and one version while the extension API is still evolving. Projects
then need only one package dependency. Because modules use only the public API,
any of them can later move to its own repository, for example if it needs its
own release pace.

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

The native and fallback implementation of each task is listed in
[status.md](status.md#native-implementations-and-fallbacks).

## A minimal App Store Connect client

`SwiftCIAppStoreConnect` contains a minimal native client that covers only what
CI needs: ES256 API key tokens (CryptoKit), the Build Upload API, the App Store
metadata check, build processing status and, if needed, TestFlight group assignment. A full client
such as [AppStoreConnect-Swift-SDK](https://github.com/AvdLee/appstoreconnect-swift-sdk)
is generated from Apple's complete OpenAPI specification. It would add a
third-party dependency and noticeable compile time to every CI package, and CI
would use only a small part of it. The core of the client may later run on Linux.


Projects that need more of the API (editing metadata, testers and groups, users,
reviews) can use an independent extension built on that SDK. See
[Extension ideas](guides/extensions.md#extension-ideas). The client itself is
described in the [App Store Connect guide](guides/app-store-connect.md).

## Platform rules

- **Rules for the core.** Use only APIs available in Foundation on Linux. Do not
  use `AppKit`, `Security`, `CryptoKit` or `CommonCrypto`. Use `URLSession`
  through `FoundationNetworking` on Linux. Represent paths as Foundation `URL`,
  not `System.FilePath`, so no `swift-system` dependency is needed.
- **Apple modules.** They should still compile on Linux, with their APIs
  unavailable, so that one CI package can contain both Linux and macOS
  commands.
- **Linux CI** will use the official Swift Docker images **(planned)**.

## Xcode support policy

- SwiftCI supports the two latest major Xcode versions. Output filters,
  `.xcresult` parsing and export options are tested with fixtures from each.
  Support for the oldest is dropped when a new major version ships.
- **Result bundles.** SwiftCI parses them only with the current `xcresulttool`
  JSON API (`get test-results`, `get build-results`), never the legacy mode.

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

## References

- [Prior art](prior-art.md): Apple tooling risks (match formats, ES256 JWT, upload APIs)
- [fastlane match encryption](https://github.com/fastlane/fastlane/blob/master/match/lib/match/encryption/encryption.rb): compatibility reference
- [App Store Connect API token generation](https://developer.apple.com/documentation/AppStoreConnectAPI/generating-tokens-for-api-requests)
