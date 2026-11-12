# Commands, steps and failures

How a CI script is structured, how it is run from the command line, and how
failures become exit codes.

## Concepts

| Concept | Description |
|---|---|
| **Command** | A named entry point invoked from the command line, e.g. `./ci test`. Several commands can be given and run in order. Inside the body, `cleanup { }` and `onFailure { }` register handlers that run when the command ends. `cleanup(when: .onCI) { }` registers a handler only when the condition is met, and logs it as skipped otherwise. A command reads inputs with `try input("track", default: "beta")`, from `--track=production` on the command line, then from the environment variable `TRACK`, then from the default. |
| **Step** | A named, timed unit of work inside a command, written `try await step("Name") { … }`. Steps run sequentially and return the value of their body. A step that throws is logged as failed. An error that escapes the command body fails the command, but a script can catch a step's error with `do`/`catch` and continue. A step started inside another step is shown in the outer step's group. A step that may fail is written `await step("Name", failure: .allowed) { … }`. It returns `nil` if it failed, logs the error as a warning, and the command continues. When a flag of the run decides whether the failure is allowed, `try await step("Name", allowsFailure: flag) { … }` throws if the flag is false, and behaves as `failure: .allowed` if it is true. A step that runs only under a condition is written `try await step("Name", when: condition, skipReason: "not on CI") { … }`; when the condition is false, the log shows the step as skipped, with the reason. `when: .onCI` runs a step only on CI and skips it with "not running on CI" elsewhere. A failure that must still fail the command, but must not stop the commands after it, is wrapped as `let passed = await deferringFailure { … }`. It returns `false` if the body threw, and the command continues. When the command body ends, it fails with the first deferred error, as if that error had escaped the body. |
| **Tool** | A child process (`xcodebuild`, `git`, a shell script). `run()` streams stdout and stderr to the console and the full log, and throws on a non-zero exit. `output()` returns stdout, and `result()` returns stdout, stderr and the exit code. A tool can set environment variables, a working directory, input, a timeout, filters and an output file (a copy of its unfiltered output). A program name is looked up in `PATH`. `Tool(shellCommand:)` runs `/bin/sh -c` for shell scripts. |
| **Integration** | Typed Swift API for a tool or service: `Xcode`, `Keychain`, `Signing`, `AppStoreConnect`, `Slack`, `Git`, … A call that does work, such as `xcode.archiveAndExport(…)`, is a step itself, with a default name. `step: "Name"` renames it. A query, such as `Git().commitHash()`, is not a step. A call made inside a step is part of that step. |
| **Extension** | A Swift library that adds integrations, ready-made steps, filters or report writers on top of the core. |
| **Filter** | A function that hides, rewrites or highlights a line of tool output. Every integration ships a default. |
| **Secret** | A value, usually from an environment variable, declared with `Secret("NAME")`. Every writer masks it as `••••••`: the console, the full log, error messages and `Environment.writeToLog()`. A secret is passed to a `Tool` through its environment or input, never as an argument. `revealedValue()` returns the raw value where an API needs it. |

## Command line

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
or a raw-value type. For a raw-value type that is also `CaseIterable`, a missing value or a value that is not a case
lists the valid raw values in the usage error. It reads `--device=…`, then the environment variable with
the upper-case name (`build-number` reads `BUILD_NUMBER`; an empty variable
counts as not set), then the default. A missing input without a default, or a
value that does not convert, is a usage error (exit code 2) that names the
option and the environment variable. An input name consists of letters, digits,
`-` and `_`, and does not start with `-`; any other name is a usage error. The
value of an input is written to the full log, and secrets are never inputs:
declare them with `Secret`.

`--list`, `--help` and `--verbose` are reserved flags. They never take a value,
and `input` refuses those names with a usage error. Each option may be given only once. A malformed
argument stops the run with exit code 2 before any command runs.

When commands ran, SwiftCI logs a warning at the end of the run, whether it
succeeded or failed, that lists each option no `input` call read, such as a
mistyped `--trak=beta`. The warning does not change the exit code.

SwiftCI parses its arguments itself. No argument-parsing dependency is required
for this small set of options.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | All requested commands succeeded. |
| 1 | A step, command body, deferred failure or handler failed (any error without an explicit code). |
| 2 | Usage or configuration error from the runner (unknown command, missing input, invalid value). |
| 3 | Internal SwiftCI error outside the script (for example, the full log cannot be opened). |
| 4 | A tool was ended because its timeout passed. |

A `BuildError` with an explicit code exits with that code. The run stops at the
first failed command and exits with its code. CI systems rely on these codes.
A failure must never exit with 0.
