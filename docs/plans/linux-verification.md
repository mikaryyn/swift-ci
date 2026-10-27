# Linux verification

Status: **accepted**, deferred until after the current macOS work. Part of the
[implementation plan](implementation-plan.md#phase-0-swiftci-foundations).

## Goal

Make the `SwiftCI` core and the products intended for cross-platform use build
and pass their tests on Linux, while keeping Apple-specific products usable in
a single package whose Linux commands do not import their macOS-only APIs.

The module split and Foundation `URL` path migration are complete on macOS.
Linux has not been verified since that work, and the README's
[Known issues](../../README.md#known-issues) lists the currently known
blockers.

## Scope

Linux support covers:

- `SwiftCI`
- `SwiftCISlack`
- `SwiftCITesting`
- `SwiftCITestSupport` as a build and repository-test dependency

`SwiftCIXcode` and `SwiftCISigning` remain macOS integrations. They must still
compile as package products on Linux with their unavailable API gated by
`#if os(macOS)`, so one CI package can contain both Linux and macOS commands.

## Work

### L0: Verify the core in the minimum toolchain

1. Build and test with the official Swift 6.2 Linux image. Prefer Apple's
   `container` tool for the local verification, for example:

   ```sh
   container run --rm -v "$PWD":/src -w /src swift:6.2 swift test
   ```

2. Verify the release build as well as the debug test build:

   ```sh
   container run --rm -v "$PWD":/src -w /src swift:6.2 swift build -c release
   ```

3. Record every compile or test failure before changing code. Do not assume
   that a macOS-only error is the only blocker.

### L1: Foundation networking

- In `SwiftCISlack`, import `FoundationNetworking` when available so
  `URLSession` builds on Linux.
- Keep the public Slack API and behavior the same on both platforms.
- Run Slack tests without real network access.

### L2: Process runner

Verify every Linux branch of `ProcessRunner`, including:

- Availability and behavior of `posix_spawn_file_actions_addchdir_np` in the
  Swift 6.2 image's glibc.
- Program lookup and executable checks.
- Working-directory handling for program names and relative command paths.
- Concurrent standard input, stdout and stderr without deadlock.
- Line splitting, invalid UTF-8 replacement and final lines without LF.
- Timeout termination, forced termination, cancellation and child reaping.
- Signal exit-code mapping.
- The requirement that the host process does not ignore `SIGCHLD` or set
  `SA_NOCLDWAIT`.

Use harmless temporary executables and shell processes as the existing macOS
tests do. Do not weaken behavior on either platform merely to make a test
portable.

### L3: Logging and strict concurrency

- Verify `fflush(stdout)` and the rest of `Log` under Swift 6.2 strict
  concurrency on Linux.
- Keep console and full-log output behavior identical to macOS where terminal
  capabilities allow it.

### L4: Gate Apple products

- Gate AppKit, Security, CryptoKit, CommonCrypto and other macOS-only imports
  and declarations with `#if os(macOS)`.
- Ensure `SwiftCIXcode` and `SwiftCISigning` products compile on Linux without
  exposing unusable declarations.
- Document that scripts gate commands importing or using these modules with
  `#if os(macOS)`.
- Do not move Apple functionality into the core or add a dependency to solve
  compilation.

### L5: Repository guidance and CI

After local verification passes:

- Update `AGENTS.md` with the exact Linux build and test commands that were
  verified.
- Update the README platform section and remove the resolved Linux known
  issue.
- Update the end-user platform documentation tracked by
  [End-user documentation](end-user-documentation.md).
- Add a Linux CI job using the official Swift 6.2 image. It runs tests and a
  release build so internal cross-module access cannot hide behind testability.

## Completion criteria

Linux verification is complete when:

1. `swift test` passes in the official Swift 6.2 Linux image.
2. `swift build -c release` passes for the full package.
3. Core process-runner behavior has equivalent Linux test coverage for
   execution, streams, input, timeouts, cancellation and signals.
4. Apple products compile on Linux with their APIs unavailable there.
5. No test touches the network, a real keychain, simulators or user-library
   state.
6. A Linux CI job guards both debug tests and the release build.
7. README and end-user platform documentation accurately describe the
   verified support and no longer call Linux unverified.

## Risks

- **glibc and spawn APIs.** The minimum Swift image may expose different spawn
  extensions than macOS. Keep the behavior but use a Linux-appropriate
  implementation behind conditional compilation.
- **Signal behavior.** Tests involving timeouts and cancellation can become
  flaky if they depend on scheduling. Keep bounded deadlines and assert
  observable outcomes rather than exact timing.
- **Testability hiding access errors.** A debug test build can allow access
  that a consumer release build cannot. The release build is mandatory.
- **Apple module leakage.** A transitive macOS import can make the whole
  package fail before conditional declarations are considered. Gate imports
  at the file boundary.
- **Toolchain drift.** Local newer Swift versions do not prove support for the
  declared Swift 6.2 minimum. The official 6.2 image is authoritative.

## Decisions

- Linux compatibility is required for the core; it is not a separate fork or
  reduced feature set.
- Apple integrations stay in separate products and remain macOS-only API.
- Paths remain Foundation `URL`s; no Linux-only path dependency is added.
- Verification uses the official Swift 6.2 image. macOS work was allowed to
  land first, but Linux CI becomes mandatory once this plan is completed.
- No new third-party dependency is introduced for Linux support without an
  explicit maintainer decision.

## Open questions

None at the moment.
