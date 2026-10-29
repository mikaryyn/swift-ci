# Xcode tests

Status: **proposed**. Part of Phase 1 of the
[implementation plan](implementation-plan.md#phase-1-replace-bitrise): the
generic pieces of the second ported workflow, merge request unit tests.

## Goal

A script can replace a typical merge request test workflow of a workflow
runner with SwiftCI calls:

1. Run a lint gate (a project script, run with `Tool`).
2. Run the unit tests of a scheme on a simulator, with code coverage, into a
   result bundle at a known path, and keep the raw `xcodebuild` output in a
   file for a compiler warning gate.
3. Run a compiler warning gate on that raw output (a project script).
4. Shut down the simulators.
5. Write a JUnit XML report from the result bundle, for Danger or the CI
   system.
6. Post merge request feedback (Danger, run with `Tool`, until SwiftCI has its
   own).

Steps 1, 3 and 6 need nothing new. This plan adds `Xcode.test` (T1), the JUnit
report (T2) and the simulator shutdown (T3). Each milestone is independent and
small, so that an adopting project can move its workflow over one step at a
time (see [Incremental adoption](incremental-adoption.md)).

The first adopter is the merge request test job of an iOS project with two
schemes, whose workflow runs `xcode-test` with code coverage, `fastlane
trainer` for JUnit, and Danger with `danger-junit`.

## Non-goals

- Test plans, test selection (`-only-testing`), retries and parallel
  destinations. Add them when a project needs them.
- Simulator preparation (creating devices, preferences such as the hardware
  keyboard, erase). UI tests need it; they are the next workflow.
- Coverage reports (Cobertura XML). The result bundle keeps the coverage, and
  `xcrun xccov` reads it. Cobertura stays a later report.
- A summary of failures and coverage on the console from the result bundle.
  The console filter of T1 shows failing tests as they happen; a summary
  follows when merge request feedback is native.
- Choosing a simulator automatically. The destination is the caller's.

## T1: `Xcode.test`

Changes, in the core and in `SwiftCIXcode`:

1. **Core: a copy of the output in a file.** `Tool` gets a parameter
   `outputFile: URL? = nil`. When it is set, every stdout and stderr line is
   also written to that file, unfiltered, without the `[stderr] ` prefix of
   the full log, and with secrets masked as in the full log. The file is
   created or truncated when the tool starts, and its directory is created if
   missing. This is generic: any tool whose raw output a later step parses
   needs it.
2. **`Xcode.test`**, an instance method:

       public func test(
           destination: String? = nil,
           resultBundleURL: URL,
           rawLogURL: URL? = nil,
           enableCodeCoverage: Bool = true,
           step name: String? = nil
       ) async throws

   It runs `xcodebuild test` with the workspace or project, scheme,
   configuration and xcconfig of the `Xcode` value (`makeArguments`), with
   `-destination` set to `destination` or, without it, to the value's own
   destination. A test run needs a concrete destination, such as
   `platform=iOS Simulator,name=iPhone 17,OS=latest`; the default
   `generic/platform=iOS` fails in `xcodebuild`, and the doc comment says so.
   It adds `-resultBundlePath <resultBundleURL>` and `-enableCodeCoverage YES`
   or `NO`. An existing bundle at `resultBundleURL` is removed first, because
   `xcodebuild` refuses to write over it; its parent directory is created.
   `rawLogURL` is passed to the tool as `outputFile`.
3. **Failure.** When `xcodebuild` exits with a non-zero code, `test` throws a
   `BuildError` that names the scheme and the exit code, and says where the
   result bundle is if it exists. The result bundle and the raw log are
   complete at that point, so the caller can catch the error, write the JUnit
   report and post feedback, and rethrow.
4. **Console filter.** The default `xcodebuild` filter (errors, warnings,
   result line) plus the lines of failing tests and the test summary, for
   XCTest and Swift Testing. The exact patterns are taken from a recording
   (see Tests). Passing tests are hidden. The full log keeps everything.
5. **Step.** It opens a step named "Test MyApp" by default; `step` renames
   it.

Tests:

- The arguments with a workspace and a project, with and without a
  destination, with coverage on and off, and with a configuration and an
  xcconfig.
- An existing result bundle is removed before the run; a missing parent
  directory is created.
- A failing run throws after the mock has written the bundle, and the error
  names the scheme and the exit code.
- `outputFile`: stdout and stderr lines arrive unfiltered and without prefix,
  a secret is masked, the file is truncated on a second run, and the console
  and the full log are unchanged.
- The console filter keeps the expected lines of a recorded `xcodebuild test`
  run with passing, failing and skipped tests in XCTest and Swift Testing, and
  hides the rest.

## T2: JUnit report

Changes:

1. **Core: report model and JUnit writer**, as the README lists for the core.
   A `TestReport` value holds test suites; a suite has a name and test cases;
   a case has a class name, a name, a duration, and a result: passed, failed
   with messages, or skipped with a message. `JUnit.write(_ report: TestReport,
   to url: URL) throws` writes JUnit XML: a `testsuites` element with the
   totals, one `testsuite` per suite with `tests`, `failures`, `skipped` and
   `time`, and one `testcase` per case with `classname`, `name` and `time`,
   containing `failure` elements (message attribute and text) or `skipped`.
   Text is XML-escaped. It does not open a step; it writes one file.
2. **`SwiftCIXcode`: the report from a result bundle.**

       public static func testReport(resultBundleURL: URL) async throws -> TestReport

   on `Xcode`. It runs `xcrun xcresulttool get test-results tests --path
   <bundle> --format json` (the test results API of Xcode 16 and later; the
   deprecated `get object` API is not used) and maps its `testNodes` tree:
   each "Test Suite" node becomes a suite, named with its bundle prefix
   (`MyAppTests.LoginTests`) so the class name is unique; each "Test Case"
   becomes a case with `durationInSeconds` and `result`; "Failure Message"
   children become the failure messages, with the source location when given;
   "Skip Message" becomes the skip message. "Expected Failure" counts as
   passed. Parameterized Swift Testing cases ("Arguments" children) and
   repetitions ("Repetition", "Test Case Run") are one case whose result is
   the test case node's result, with the messages of all runs. Device and
   configuration nodes are flattened; with more than one destination the
   suite name gets the device name appended. It is a query: it opens no step.
3. **Convenience**, the call a script makes:

       public static func writeJUnitReport(resultBundleURL: URL, to url: URL, step name: String? = nil) async throws

   It opens a step named "Write JUnit report", so a script can run it after
   failed tests and see it in the step summary.

The output must be readable by `danger-junit` (it reads `testcase` elements
and their `failure`, `error` and `skipped` children, with the `classname`,
`name` and `message` attributes) and by the Jenkins `junit` step. The
adopting project compares the Danger comment with the one from
`fastlane trainer` on a merge request with a failing test.

Tests:

- The writer: totals, escaping of `<`, `&` and quotes in names and messages,
  a failure with several messages, a skipped case, and an empty report.
- The mapping, from recorded `xcresulttool` JSON: XCTest and Swift Testing,
  passed, failed, skipped and expected-failure cases, a parameterized test,
  and two devices.
- `xcresulttool` failing (for example a path that is not a bundle) is a
  `BuildError` that names the bundle.

## T3: simulator shutdown

Changes, in `SwiftCIXcode`, a new `Simulator` type with
`public static func shutdownAll(step name: String? = nil) async throws`,
which runs `xcrun simctl shutdown all` in a step named "Shut down
simulators". It is meant for a `cleanup` handler, as in the README example.
The rest of the planned `Simulator` API (boot, erase) comes with the UI tests.

Tests: the arguments, and the step name.

## Fixtures

The tests need a recorded `xcodebuild test` console output and recorded
`xcresulttool get test-results tests` JSON, from the current Xcode (27). They
are made from a small throwaway project, created outside this repository,
with an app target, an XCTest bundle and a Swift Testing bundle containing a
passing, a failing, a skipped and a parameterized test. A project's own test
output is not committed: it contains project and developer names. The
maintainer records them, because the coding agent's sandbox cannot run
simulator tests, and the recordings are checked for paths that name a user
before they are committed (replace the home directory with `/Users/ci`).
The JSON of a second Xcode version is added when the README's supported
versions are tested. The sample project and the recordings are made when T1
is implemented, not before.

## Order

T1, T2 and T3 are independent. The adopting project needs T1 first, because
its tests can only leave the workflow runner together with the steps that read
the result bundle; until T2 lands it keeps `fastlane trainer` for JUnit. T3 is
small and can ship with T1. One release can contain all three if they are
ready together.

## Risks

- **`xcresulttool` output changes between Xcode versions.** The mapping
  decodes only the fields it uses, ignores unknown fields and node types, and
  is tested with recordings. A node type it does not know is skipped with a
  warning, not an error.
- **Exit code 65 without failing tests.** `xcodebuild test` also fails when
  the build fails or the simulator does not boot. Then the bundle has no test
  results, and the JUnit report is empty. The step still fails with the build
  error on the console, and Danger's "test results missing" check reports it,
  as with `fastlane trainer`.
- **Large raw logs.** The raw log of a full test run can be tens of
  megabytes. It is written as it streams, like the full log.

## Decisions

- The raw log is a generic `Tool` feature (`outputFile`), not something only
  `Xcode.test` does.
- The JUnit writer and the report model are in the core; reading a result
  bundle is in `SwiftCIXcode`.
- Only the `xcresulttool get test-results` API is used.
- `Xcode.test` throws after the bundle and the raw log are complete; it does
  not write the JUnit report itself, so the caller decides where and whether.

## Open questions

- Should `Xcode.test` write the JUnit report itself when given a
  `junitURL:`? It would save a call in scripts, but it ties two things that
  the first adopter wants to replace separately. Decide after the adopter's
  T2 step.
