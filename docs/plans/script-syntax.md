# Script syntax

Status: **accepted**. M0 to M5 are implemented. Part of the
[implementation plan](implementation-plan.md).

## Goal

Make SwiftCI scripts read like ordinary async Swift, with as little
boilerplate as possible. The main audience is iOS developers.

Today a failed step does not throw. It marks the command as failed, and
later steps check that mark and skip themselves. Code between steps keeps
running after a failure, steps cannot return values, and cleanup is expressed
as steps with `.always` or `.onFailure`.

After this plan:

- A failed step throws, and the command stops like any Swift code that
  throws. Code between steps is safe, and steps return values.
- A step can be explicitly allowed to fail.
- Cleanup and failure handlers are registered inline, where the resource they
  clean up is created, and run at the end of the command: cleanup handlers
  first, then failure handlers, each in reverse order of registration.
- Integration calls such as `xcode.archiveAndExport(…)` are steps
  themselves. `step { }` is only needed for custom code and for grouping.
- Reusable groups of steps are plain `async throws` functions. The `Workflow`
  type is removed.
- Commands have descriptions and can read inputs from command-line options or
  environment variables.

## Target API

*All names are placeholders, following the generic-only rule. Some calls in
the example (`xcode.test`, `Keychain.createTemporary`, `keychain.delete`,
`Signing.installMatchAssets`, `AppStoreConnect.upload`) do not exist yet.
They come from later [roadmap](../../README.md#roadmap) work and are built on
the step API from M4. This plan does not add them.*

```swift
import SwiftCI
import SwiftCIXcode
import SwiftCISigning
import SwiftCIAppStoreConnect
import SwiftCISlack

let xcode = Xcode(workspace: "MyApp.xcworkspace", scheme: "MyApp")
let slack = Slack(webhookURL: Secret("SLACK_WEBHOOK_URL"))

let test = Command("test", description: "Run the unit tests") {
    let device: String = try input("device", default: "iPhone 17")
    try await xcode.test(destination: .iOSSimulator(name: device))
}

let release = Command("release", description: "Build and upload to TestFlight") {
    onFailure { try await slack.send(text: "Release failed") }

    await step("Notify start", failure: .allowed) {
        try await slack.send(text: "Release started")
    }

    let keychain = try await Keychain.createTemporary()
    cleanup { try await keychain.delete() }

    try await installSigning(into: keychain)
    let ipa = try await xcode.archiveAndExport(method: .appStore)
    try await AppStoreConnect(apiKey: .fromEnvironment()).upload(ipa: ipa)
}

/// A reusable group of steps is a plain function.
func installSigning(into keychain: Keychain) async throws {
    try await step("Install signing") {
        try await Signing.installMatchAssets(
            type: .appStore,
            bundleIdentifiers: ["com.example.myapp"],
            keychain: keychain,
            using: .native
        )
    }
}

await SwiftCI {
    command(test)
    command(release)
}
```

Run it with `./ci release`, `./ci test --device="iPhone 17 Pro"`, or
`DEVICE="iPhone 17 Pro" ./ci test`.

### Rules

**Commands**

- A command is created with `Command(name, description:) { … }` and
  registered explicitly with `command(…)` inside `SwiftCI { }`.
- The command body is an `async throws` closure. If it throws, the command
  fails.

**Steps**

- `step(name) { … }` runs its body as a named, timed step and returns the
  body's value. If the body throws, the step is logged as failed and the
  error is rethrown, so the rest of the command does not run.
- Steps rethrow the original error unchanged, so ordinary Swift `catch`
  clauses and typed error handling keep working.
- Each error message is logged once, where the error is finally handled: by
  the runner as an error, or by an allowed step as a warning. Steps on the way
  only log their own status line ("failed").
- A step inside another step is shown as part of the outer step's group in
  the log. If the inner step fails, the outer step fails too.
- An error thrown outside any step also fails the command, and is logged by
  the runner as a command error.
- `step` may only be called while a command runs. Calling it elsewhere is a
  programming error and stops the run with a message that says so.
- Only an error that escapes a body fails it. If the script catches a step's
  error with `do`/`catch`, the step is still logged as "failed", but the
  command continues, `onFailure` handlers do not run because of it, and
  SwiftCI does not log the error message. Handling it is up to the script.

**Allowed failures**

- `step(name, failure: .allowed) { … }` does not throw, so it needs no
  `try`. It returns an optional: `nil` if the body failed.
- Integration calls have no `failure:` parameter. To allow one to fail,
  wrap it in `step(name, failure: .allowed) { … }`, as in the Target API.
- `failure:` takes a type whose only value is `.allowed`. There is no
  "not allowed" value, because a step that may not fail is the ordinary
  throwing `step(name) { … }`.
- The log shows the step as "failed (allowed)" and the error message as a
  warning, and the command continues. This also applies when the error came
  from a step nested inside the allowed step.

**Cleanup and failure handlers**

- `cleanup { … }` registers a handler that runs when the command ends,
  whether it succeeded or failed.
- `onFailure { … }` registers a handler that runs when the command ends only
  if it failed.
- Handlers run only if their registration was reached. Register `onFailure`
  at the top of the command so that it covers every step.
- At the end of the command, all `cleanup` handlers run first, in reverse
  order of registration, like Swift's `defer`. Then the `onFailure` handlers
  run, also in reverse order, if the command failed. A failure in a cleanup
  handler therefore also triggers the `onFailure` handlers.
- Every handler runs, even if an earlier one failed. A failed handler fails
  the command. `cleanup(failure: .allowed) { … }` and
  `onFailure(failure: .allowed) { … }` mark a handler that may fail.
- A failed allowed handler is logged like an allowed step: "failed
  (allowed)" and its error message once as a warning, also when the body has
  already failed. It does not fail the command, so a failed allowed cleanup
  handler does not trigger the `onFailure` handlers.
- If the body failed, its error decides the exit code. Otherwise the first
  failed handler that is not allowed, in the order the handlers ran, decides
  it. Every error message is logged.
- Registering a handler does not throw. Registering one outside a running
  command, or inside another handler, is a programming error and stops the
  run with a message that says so.
- Handlers registered inside a step still run at the end of the command, not
  at the end of the step.

**Integration calls as steps**

- A public integration call that does work or changes something, such as
  `xcode.archiveAndExport(…)`, opens its own step with a default name. A
  `step:` parameter renames it.
- A query that only reads information, such as `Git.getCommitHash()` or
  `xcode.getBuildSettings()`, does not open a step. Its tool output still
  goes to the full log, and its errors still stop the command. Each
  integration method's doc comment says whether it is a step.
- An integration call made inside another step does not open a new step. It
  becomes part of the outer step.
- Extensions use the same public API as first-party modules to open steps.
- An integration call made outside a running command (for example in a
  test, or before `SwiftCI { }`) runs without opening a step.

**Reusable groups**

- A reusable group is an `async throws` function. To show it as one group in
  the log, wrap its body in `step(name) { … }`.

**Inputs**

- `input(name, default:)` reads the option `--name=value` from the command
  line. If the option is not given, it reads
  the environment variable with the upper-case name (`--build-number` reads
  `BUILD_NUMBER`). If neither is set, it returns the default.
- The value can be any `LosslessStringConvertible` type (`String`, `Int`,
  `Bool`, …) or any `RawRepresentable` type whose raw value is
  `LosslessStringConvertible`, such as `enum Track: String { case beta,
  production }`.
- An input without a default that has no value stops the run with a usage
  error (exit code 2). The message names both the option and the environment
  variable.
- Options are always written as `--name=value`, including Bool values
  (`--skip-tests=true`). There is no `--name value` form and no bare flag,
  so a command name is never mistaken for an option value. A bare `--name`
  other than the reserved `--list`, `--verbose` and `--help` is a usage
  error.
- Secrets are never inputs. A secret must not be passed as a command-line
  argument, so secrets keep using `Secret`.
- Options are global. With several commands
  (`./ci test release --track=beta`), every command sees the same options.
- At the end of the run, whether it succeeded or failed, SwiftCI logs a
  warning that lists every option no `input(…)` call read, for example a
  mistyped `--trak=beta`. The warning does not change the exit code.

**Several commands**

- `./ci test release` runs the commands in order. If a command fails, its
  handlers run, the later commands do not run, and the process exits with
  the failed command's exit code.

### Exit codes

| Error | Exit code |
|---|---|
| None | 0 |
| `BuildError` with an explicit code, from a step, the command body or a handler | That code (for example 2 for a usage error) |
| Any other error from a step, the command body or a handler | 1 |
| Usage error from the runner (unknown command, missing input, invalid value) | 2 |
| Internal SwiftCI error outside the script (for example the full log cannot be opened) | 3 |

No failure maps to 0. When several errors occur in one command, the body's
error decides the code, otherwise the first failed handler that is not
allowed (see [Cleanup and failure handlers](#rules)).

## Milestones

Each milestone lists what changes, the tests, the README sections to update
and the observable result. File paths refer to the current single-target
layout. After the module split, the same changes apply to the files'
new locations.

### M0: Testable runner

*Done.*

Preparation for M1 to M3. It changes no behavior and no public API.

Changes:

1. `SwiftCI.swift`: move the runner into an internal function that takes
   the command-line arguments and returns an exit code. The public
   `SwiftCI { }` entry point registers the dependencies, calls it with
   `CommandLine.arguments`, and calls `exit()` once, at the end. No other
   code calls `exit()`.
2. The internal runner resets the registered commands at the start of each
   run, so separate runs in one process do not see each other's commands.
3. Tests: a helper that registers a `LogMock`, runs a script through the
   internal runner with given arguments, and returns the exit code and the
   logged lines.

Tests (characterization of today's behavior, changed on purpose by M1):

- A successful command exits with today's success code.
- An unknown command name and no command name exit with today's codes.
- A failing step exits with today's code (0, the known issue that M1
  fixes).

Result: M1 to M3 can test exit codes and log output without ending the test
process.

### M1: Throwing steps

*Done.*

Changes:

1. `Other/BuildError.swift`: give `ErrorCode` explicit raw values that match
   the [Exit codes](#exit-codes) table: 1 for a failure, 2 for a usage or
   configuration error, 3 for an internal error. Rename the cases to match
   their meaning (for example `.failure`, `.usage`, `.internal`). No case has
   raw value 0. Phase 0 of the implementation plan contains the same fix.
2. `Command.swift`: the command body becomes
   `@MainActor () async throws -> Void`. Add an optional
   `description: String?` parameter (used in M6). Remove the initializer that
   passes the `Command` to the body, and remove `hasFailed` and
   `_hasFailed`.
3. `Command.swift`: replace `Command.current` with an internal run context
   for the running command. It tracks the step depth (for nesting and for
   M4) and the handler stack (for M3). The runner creates it when a command
   starts and clears it when the command ends, with `defer`, also after a
   thrown error. It holds lifecycle state (whether a command or handler is
   running, the step depth) and the registered handlers. It must never be
   used to skip ordinary command or step code because of an earlier failure.
4. `Command.swift`: replace `step(_:_:_:)` with
   `step<T>(_ name: String, _ body: () async throws -> T) async throws -> T`.
   It logs entering, finished (with duration) or failed, and rethrows the
   original error unchanged. It does not log the error message. Without a
   run context, it stops with `preconditionFailure` and a message saying that
   `step` may only be called inside a command.
5. Nested steps: a step started inside another step logs as part of the outer
   step's group (indented on the console, with a nested header in the full
   log).
6. Remove `StepWhen` and `Log.skippedStep(name:)`.
7. `SwiftCI.swift`: `run(command:)` returns a result instead of calling
   `exit()`. Only the `SwiftCI { }` entry point calls `exit()`. The runner
   logs the error message of a failed command once, and maps errors to exit
   codes as in the [Exit codes](#exit-codes) table.
8. `SwiftCI.swift`: with several commands, stop at the first failed command
   and exit with its code.

Tests (Swift Testing, with `LogMock`):

- A step returns its body's value.
- A failed step throws, and nothing after it in the command body runs.
- A failure in a nested step fails the outer step, and its message is logged
  once.
- A caller can catch the original error type thrown inside a step.
- An error thrown outside any step fails the command and is logged as a
  command error.
- The exit code rows that M1 can produce: success (0), an ordinary error
  (1), a `BuildError` with code 2 thrown inside a step, an unknown command
  name (2) and an internal error (3). Handler rows are tested in M3, input
  rows in M6.
- A script that catches a step's error with `do`/`catch` continues, the step
  is logged as "failed", the error message is not logged by SwiftCI, and
  the command succeeds.
- The run context is cleared after a command fails: run a failing command
  through the runner, then run a second command through a separate runner
  call, and check that it starts at step depth 0 with no handlers.
- With `./ci a b c`, a failure in `b` exits with `b`'s code, and `c` does
  not run.

README.md: the Concepts table (Step row), the Example, the capability table
(Core row), the Exit codes section and Known issues (exit code bullet).

Result: when a step's error escapes the command, `./ci <command>` exits with
the code from the [Exit codes](#exit-codes) table (normally 1), the error
message appears once, and no later code in the command runs. A caught error
leaves the command running.

### M2: Allowed failures

*Done.*

Changes:

1. `Command.swift`: add a public type with a single value, for example
   `public enum FailureMode { case allowed }`, and
   `step<T>(_ name: String, failure: FailureMode, _ body: () async throws -> T) async -> T?`.
   It does not throw. On failure, including a failure in a nested step, it
   logs the error message as a warning, logs the step as "failed (allowed)"
   and returns `nil`.
2. `Other/Log.swift`: add `allowedFailedStep(name:)` to `Log`, with a console
   line and a full log line.

Tests:

- A failed allowed step returns `nil`, and the command continues and
  succeeds.
- A successful allowed step returns its value.
- The log shows "failed (allowed)" and the error message as a warning.
- A failing step nested inside an allowed step: the inner step logs
  "failed", the outer logs "failed (allowed)", the message appears once as a
  warning and never as an error, and the command succeeds.
- Overload resolution: `step(name) { … }` and
  `step(name, failure: .allowed) { … }` with single- and multi-statement
  bodies, returning a value and returning `Void`, compile without type
  annotations.

README.md: the Concepts table (Step row) and the Bitrise migration table
(`is_skippable`).

Result: a step that posts a Slack notification can fail without failing the
build, and the log says so.

### M3: Cleanup and failure handlers

*Done.*

Changes:

1. `Command.swift`: add
   `cleanup(failure: FailureMode? = nil, _ body: @escaping () async throws -> Void)`
   and `onFailure(failure: FailureMode? = nil, _ body: @escaping () async throws -> Void)`.
   Both are non-throwing and append a handler to the run context. Called
   outside a running command, or inside another handler, they stop with
   `preconditionFailure` and a message that says where they may be called.
2. `SwiftCI.swift`: after the command body returns or throws, the runner
   runs all `cleanup` handlers in reverse order of registration. Then, if the
   command has failed (in its body or in a cleanup handler), it runs the
   `onFailure` handlers in reverse order of registration.
3. Each handler is logged like a step ("Cleanup", "On failure"). Its errors
   are caught, and the remaining handlers still run. A failed handler fails
   the command (exit code from the [Exit codes](#exit-codes) table) unless it
   was registered with `failure: .allowed`. If the body already failed, the
   body's error decides the exit code. Otherwise the first failed handler
   that is not allowed, in the order the handlers ran, decides it. Errors of
   handlers that are not allowed are logged as errors. A failed allowed
   handler is logged as "failed (allowed)" with its message once as a
   warning, and does not count as a command failure.
4. Handlers registered inside a step are still run at the end of the
   command, not at the end of the step.

Tests:

- Cleanup handlers run in reverse order of registration, then `onFailure`
  handlers in reverse order of registration.
- A handler whose registration was not reached does not run.
- `onFailure` handlers run only after a failure, including a failure in a
  cleanup handler that was registered before the `onFailure` handler.
- A failed handler fails a command that otherwise succeeded, and all other
  handlers still run.
- `failure: .allowed` on a handler keeps the command successful.
- A body failure and a handler failure: the exit code comes from the body's
  error, and both messages are logged.
- No body failure and two failed handlers with different `BuildError`
  codes: the exit code comes from the handler that ran first, and both
  messages are logged.
- A failed allowed handler logs "failed (allowed)" and one warning, both
  after a successful body and after a failed body.
- A failed allowed cleanup handler does not trigger `onFailure` handlers,
  and the command succeeds.
- The [Exit codes](#exit-codes) rows for handler failures.
- (Registration outside a command stops the process, so it is not unit
  tested. Document it in the doc comment.)

README.md: the Concepts table (Step row: remove `.onFailure` and `.always`),
the Example, and the Bitrise migration table (`before_run` / `after_run`,
`is_always_run`).

Result: a temporary keychain created in a step is deleted at the end of the
command, whether the command succeeded or failed, and a failure notification
is sent only when it failed.

### M4: Integration calls as steps

*Done.*

Changes:

1. `Command.swift`: add a public overload of `step` for integrations:
   `step<T>(default defaultName: String, name: String?, _ body: () async throws -> T) async throws -> T`.
   If a command is running and no step is running, it opens a step called
   `name ?? defaultName`. If a step is already running, or no command is
   running, it runs the body directly. Its doc comment says that it is meant
   for integration and extension authors, and that scripts should use
   `step(name) { … }`. Example:

   ```swift
   public func archiveAndExport(method: ExportMethod, step name: String? = nil) async throws -> URL {
       try await step(default: "Archive and export \(scheme)", name: name) { … }
   }
   ```
2. Add a `step: String? = nil` parameter to each public integration call that
   becomes a step, and wrap its body in the new API. Proposed list: in
   `Xcode`, `clean`, `build`, `archiveAndExport`, `resolvePackages` and the
   docbuild call; in `KeychainImpl`, `unlock`; in `Slack`, `send`; in
   `Fastlane`, `match`, `matchUpdate` and `matchUpdateBuiltin`; in `Icon`,
   `addText`. Queries such as `Git.getCommitHash`, `Git.getCommitTag` and
   `Xcode.getBuildSettings` stay as they are and do not open steps.
3. Add a line to the doc comment of every public integration method saying
   whether it opens a step.
4. Default names say what is done and to what, using the integration's own
   parameters, for example "Archive and export MyApp".

Tests:

- A top-level integration call opens one step with its default name.
- `step:` renames it.
- An integration call inside a `step { }` does not open a step of its own.
- An integration call that calls another integration internally (for
  example `archiveAndExport` calling `getBuildSettings`) produces one step.
- An integration call outside a running command opens no step and does not
  stop the process.

README.md: the Concepts table (Integration row), the Example, the Bitrise
migration table, the Extension API list and the SwiftLint extension example.

Result: a command built only from the integration calls in the list above
produces a log with one step per call, without any `step { }` wrappers.
Integrations added later (see [Target API](#target-api)) follow the same
pattern.

### M5: Remove `Workflow`

*Done.*

Changes:

1. Delete `Workflow.swift`.

Tests: none. The package builds without `Workflow`.

README.md: remove the Workflow row from the Concepts table; change "Ready-made
steps and workflows" in "What an extension provides" to ready-made steps;
change the SwiftLint extension example to a public `async throws` function;
remove `Workflow` from the Extension API list; change the `before_run` /
`after_run` row of the Bitrise migration table to "functions and
`cleanup` / `onFailure` handlers".

Result: reusable groups are plain functions everywhere in the code and
documentation.

### M6: Descriptions and inputs

Done ahead of M6: `Command` stores its `description`, `--list` prints the
commands with their descriptions and exits with 0 without running any
command, and a missing or unknown command name prints the same list after the
error (exit code 2). The rest of M6 is still open.

Changes:

1. `Command.swift`: store `description` and make it readable for `--list`
   (planned in README roadmap item 3).
2. `SwiftCI.swift`: split the arguments into command names and options.
   Every argument of the form `--name=value` is an option. `--list`,
   `--verbose` and `--help` are reserved flags and never take a value;
   `--help=x` is a usage error. Any other argument starting with `--` and
   without `=` is a usage error whose message shows the `--name=value` form.
   An option given twice is a usage error. Every other argument is a command
   name, and unknown command names stay a usage error.
   - `--list` prints the commands with their descriptions and exits with 0
     without running any command.
   - `--help` prints usage and exits with 0 without running any command. If
     both `--help` and `--list` are given, `--help` wins.
   - `--verbose` is combined with the given commands and shows unfiltered
     tool output on the console.
3. Add `input<T: LosslessStringConvertible>(_ name: String, default: T) throws -> T`
   and `input<T: LosslessStringConvertible>(_ name: String) throws -> T`, plus
   the same two overloads for `T: RawRepresentable` where
   `T.RawValue: LosslessStringConvertible`.
   They read the option, then the environment variable (upper case, hyphens
   to underscores), then the default. A missing value or one that does not
   convert to `T` throws a usage error (exit 2) that names the option, the
   environment variable and the expected type.
4. `Other/Environment.swift`: read the environment through an injectable
   source, registered in `registerDependencies()`, so that tests do not
   depend on the real process environment.
5. `SwiftCI.swift`: record which options `input(…)` read, and after the
   last command (or the failed one) log a warning listing the options that
   were never read.

Tests:

- An option wins over the environment variable, and the environment
  variable wins over the default.
- `--name=value` works, including an empty value and a value that contains
  `=`.
- `--name value` and a bare `--name` give exit code 2 with a message that
  shows `--name=value`.
- A Bool input accepts `--name=true` and `--name=false`.
- Command names and options can be mixed in any order.
- A missing required input and a value that does not convert give exit
  code 2 and a message naming the option and the environment variable.
- Options apply to every command in `./ci test release --track=beta`.
- An option that no command read is listed in a warning at the end of a
  successful run and of a failed run, and the exit code is unchanged.
- A `String`-backed enum input converts from its raw value, and an unknown
  value gives exit code 2.
- An option given twice gives exit code 2.
- `--list` and `--help` exit with 0 and run no command, even when command
  names are also given. `--help=x` gives exit code 2.
- `--verbose` with a command runs the command.
- The [Exit codes](#exit-codes) rows for missing and invalid inputs.

README.md: the Command line section (options and `input`), the Concepts table
(Command row), the Bitrise migration table (workflow inputs) and the
capability table.

Result: `./ci release --track=beta` and `TRACK=beta ./ci release` behave the
same.

## Dependencies and order

- M1 to M5 belong to Phase 0 of the
  [implementation plan](implementation-plan.md#phase-0-swiftci-foundations)
  and land before release 0.1.0. They are the breaking changes, so the
  reference project rewrites its script once, before it pins 0.1.0.
- M6 adds API and breaks nothing. It belongs to Phase 1 and lands when the
  first ported workflow needs an input.
- M1 to M3 ship together in one release. M1 removes `.always` and
  `.onFailure` steps, and M3 adds their replacement, so a release with only
  M1 would leave scripts without cleanup.
- M1's exit code fix is the same as the Phase 0 item in the
  [implementation plan](implementation-plan.md#phase-0-swiftci-foundations).
  Whichever lands first does it.
- M4 lands before the Phase 0 module split, in the single-target layout.
  The API that M4 adds is public from the start, because first-party modules
  use only the core's public API. The split then moves the wrapped
  integrations into their modules without changing them.
- M5 depends on M3, because handlers replace the `before_run` / `after_run`
  role of workflows.
- M6 depends on M1 for the usage exit code.
- M0 comes first. It changes no behavior and can land on its own.
- Order: M0, then M1, M2, M3 (together), then M5 and M4, then the module
  split, all before 0.1.0. M6 follows in Phase 1.

## Risks

- **Overloads of `step`.** The throwing generic `step`, the non-throwing
  `failure: .allowed` overload and the integration overload
  `step(default:name:)` must not be ambiguous, and multi-statement closures
  must infer `T` (including `Void`) without annotations. Write the tests for
  type inference first.
- **Hidden run context.** The run context is internal global state on the
  main actor. It must stay limited to lifecycle state, nesting and handler
  dispatch. If it starts to skip ordinary command or step code after a
  failure, the old problem returns.
- **Breaking changes.** Existing scripts that use `.always`, `.onFailure`,
  `Workflow` or the `Command` initializer that passes the command must be
  changed. The first adopting project changes its script once, at 0.1.0,
  after M1 to M5 have landed.
- **Log readability.** Nested groups must stay readable in CI log viewers.
  The CI environment adapters (Phase 0) may later map groups to native log
  sections.

## Decisions

- D1 Parallelism is a non-goal.
- D2 Commands are registered explicitly with `command(…)`. Automatic
  registration would be hidden magic, and a missing command is noticed
  quickly.
- D3 The main audience is iOS developers. The API should feel like ordinary
  async Swift.
- D4 No macros, so no swift-syntax dependency.
- D5 A failed step throws and stops the command.
- D6 `step(…, failure: .allowed)` marks a step that may fail. It does not
  throw, returns an optional, and is logged as "failed (allowed)". (First
  decided as `allowFailure: true`. Changed because a Bool would also accept
  `false`, which a non-throwing step cannot honour.)
- D7 `cleanup { }` and `onFailure { }` are registered inline, like `defer`.
  At the end of the command, cleanup handlers run first and then failure
  handlers, each in reverse order. A failed handler fails the command, and
  the other handlers still run. (First decided as one reverse-order stack.
  Changed so that failure handlers always see failures in cleanup.)
- D8 Integration calls that do work or change something are steps
  themselves. Queries that only read information are not (D15).
- D9 The `Workflow` type is removed. Reusable groups are functions.
- D10 `input(…)` reads a command-line option first and an environment
  variable second.
- D11 Inputs accept any `LosslessStringConvertible` type and raw-value
  enums, a missing required input is a usage error, inputs are never
  secrets, and options are global.
- D12 Steps rethrow the original error. Each error message is logged once,
  where it is finally handled.
- D13 `step` and handler registration outside a running command are
  programming errors. Integration calls outside a command run without a
  step.
- D14 With several commands, the run stops at the first failed command and
  exits with its code.
- D15 Read-only integration queries do not open steps. The log's step list
  shows the work, not every question asked along the way.
- D16 Integration calls do not take a `failure:` parameter. To allow an
  integration call to fail, wrap it in `step(…, failure: .allowed) { … }`.
  This keeps one mechanism and avoids a non-throwing overload of every
  integration method. A generic helper such as
  `allowFailure { try await slack.send(…) }` can be added later if the
  wrapper proves tedious.
- D17 Integrations open their steps with an overload of `step`:
  `step(default:name:) { … }`. Step stays the single concept, and the
  distinct labels keep the overloads unambiguous.
- D18 Options are written only as `--name=value`, Bool values included. No
  `--name value` form and no bare flags, so parsing never needs to know an
  input's type and a command name is never read as a value.
- D19 Options that no command read are listed in a warning at the end of the
  run. Declaring inputs up front would catch typos before the run, but it
  repeats every input name.
- D20 M1 to M5 are part of Phase 0 and land before 0.1.0. M6 is part of
  Phase 1. (First decided with M4 done together with the module split.
  Changed so that M4 lands before the split, in the single-target layout,
  because the split is not planned yet and its step API is public anyway.)
- D21 Only an error that escapes a body fails it. A caught error leaves the
  command running, and SwiftCI does not log its message.
- D22 The body's error decides the exit code, otherwise the first failed
  handler that is not allowed. A failed allowed handler is logged like an
  allowed step and does not trigger `onFailure`.
- D23 An option given twice is a usage error. `--list` and `--help` print and
  exit with 0 without running commands, `--verbose` combines with commands,
  and reserved flags never take a value.
- D24 Errors of the full log (opening, writing, closing) are internal errors
  with exit code 3. They are never dropped: a failed write of a status line
  in an allowed step or a handler is recorded and fails the command with 3,
  also inside an allowed handler, because it is SwiftCI's failure and not the
  handler's.
- D25 A handler's body always runs, even if its status line cannot be
  written. Handlers therefore do not use the throwing `step`, but log the
  same lines.
- D26 If closing the full log is the command's only failure, the `onFailure`
  handlers run once after the close. Their output goes to the console only.
- D27 Tests that touch SwiftCI's global state run one at a time, under one
  serialized parent suite. This is intended to stay.
- D28 The first adopting project keeps its current SwiftCI revision until
  0.1.0, and `main` stays unchanged until then. The work happens on `dev`.

Rejected alternatives:

- **Keep the current model and document "no code between steps".** Failures
  stay hidden from ordinary Swift code, and steps still cannot return values.
- **A result builder (SwiftUI style).** It would prevent code between steps,
  but passing values between steps becomes awkward, and result builder
  errors are hard to read.
- **Macros such as `@Command`.** They could remove registration and generate
  argument parsing, but they need swift-syntax (D4) and cannot remove
  `try await`.
- **Cleanup blocks at the end of the command.** An `always` block also runs
  when the resource it cleans up was never created.
- **Cleanup failures as warnings only.** A leftover keychain or similar state
  on a CI machine must not pass silently.
- **`try? await step(…)` for allowed failures.** The step cannot know it was
  allowed to fail, so the log shows an ordinary failure for a passing build.
- **Explicit steps for every integration call.** Two `try await`s and a
  closure per line.
- **Wrapping step errors in an internal type** to avoid logging them twice.
  Callers could no longer catch the original error type.
- **One reverse-order stack for all handlers.** An `onFailure` handler
  registered after a `cleanup` handler would run before it and miss a
  failure in it.

## Open questions

None at the moment.
