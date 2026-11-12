# Output, filtering and secrets

SwiftCI writes each tool's output to two places:

- **Console.** Filtered, coloured and compact. Each integration has a default
  filter that keeps progress (e.g. "Compiling Foo.swift"), warnings, errors and
  test results, and drops noise. `--verbose` skips the filters, so every line
  reaches the console; secrets are still masked. Colours follow
  terminal detection and the `NO_COLOR` convention **(planned)**.
- **Full log.** One file per command, with step headers. It has every console
  line as plain text, without colour codes, the unfiltered output of every tool,
  the exit code of each tool, the arguments of the run, each input read and the
  failures, with secrets redacted. Integrations can write lines that are not on
  the console with the public `FullLog.write`. The log is saved as
  `logs/<command>.log` in the artifacts directory, so that CI can archive it. If
  a command runs again in the same run, its log is `logs/<command>-2.log`, and
  so on. A later run with the same artifacts directory overwrites the log. See
  [Running in CI](running-in-ci.md).

A `Tool` can also copy its unfiltered output to a file of its own with
`outputFile:`. The copy is written as the lines arrive, without the `[stderr] `
prefix, with secrets masked, and `--verbose` does not change it.

Filters are plain Swift functions of type `(String) -> String?`. A filter returns
the line, a rewritten line, or `nil` to hide it. `hideAllLines` hides every
line. Projects can replace or extend the default filters of any tool.

A filter is a closure, so it can keep state and decide a line by the lines
before it. It can hold lines back and return them together later, as one string
with line breaks, which the console shows as separate lines. Nothing is flushed
at the end of the output. The helper `tableFilter(keeping:otherLines:)` shows or
hides each table of the output as a whole, by its title, and passes the other
lines on to another filter. `String.withoutTerminalCodes` removes the terminal
codes of a line, such as colors, before a filter checks it.

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
