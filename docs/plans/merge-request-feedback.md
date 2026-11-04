# Merge request feedback

Status: **planned**. Phase 2 of the
[implementation plan](implementation-plan.md#phase-2-replace-danger): the
generic pieces that replace Danger.

## Progress

- [x] (2026-11-03) R1, first part: the model, `Report.failure/warning/message/markdown`
  and `Report.current`, findings logged when added, report failures fail the
  command.
- [x] (2026-11-03) R1, second part: `onReport`, the outcome, and rule 4.
- [x] (2026-11-03) R2, first part: the Markdown renderer `MarkdownReport`.
- [x] (2026-11-03) R2, second part: the console summary and `report-<command>.md`.
- [x] (2026-11-03) R4: `Git.reportUncommittedChanges` and `Git.reportLines`.
- [x] (2026-11-04) R3, first part: `Xcode.reportTestFailures`.
- [ ] R3, second part: `Xcode.reportBuildIssues`. Waits for the
  `build-results` recording, which `xcodebuild` cannot make inside the agent
  sandbox; `sample/record.sh` is prepared for it.
- [ ] R5 and R6.

## Goal

A script can replace a typical Danger setup with SwiftCI calls. Its steps add
findings (failures, warnings and messages, optionally with a file and line)
and Markdown sections to a **run report**: one report per command run. At the
end of the command, SwiftCI:

1. prints the report on the console,
2. writes it as Markdown to the artifacts directory, and
3. hands it to report handlers that the script registered, such as the GitLab
   merge request comment.

A failure in the report fails the command, as Danger's `failure` does with
`--fail-on-errors`. The checks that a typical iOS Dangerfile does become
reusable steps that add to the report:

- test failures and build errors from the `.xcresult` result bundle (instead
  of JUnit plus `danger-junit`, and `xcpretty-json-formatter` plus
  `danger-xcodebuild`)
- "the build left uncommitted changes", with ignore patterns
- a line pattern check over tracked files, such as the `YYYY` date format
  pitfall

The first adopter is the merge request test job of an iOS project on Jenkins
with the GitLab plugin. Each of its two test commands posts up to three Danger
comments today (main checks, SwiftLint gate, compiler warning gate). Both
commands use the same Danger IDs, so the second command overwrites the
comments of the first. With SwiftCI each command posts one comment with all
its findings.

## Non-goals

- Inline comments on the changed lines in the merge request diff (GitLab's
  "Changes" tab). Findings with a file and line are listed in the comment.
  Inline comments only reach lines that the merge request changed, so the
  overview comment is needed anyway. Add them when a project asks.
- GitHub pull request comments, step summaries and annotations. They follow
  the same shape later (README, extension ideas).
- A report merged across several `./ci` invocations (Phase 4, inside-out
  adoption).
- Lint and warning gate steps in SwiftCI. They stay project code for now and
  add their findings to the report with the public API.
- Moving `SwiftCISlack` to the new HTTP client. It can follow separately.

## R1: Run report (core)

Changes in `Sources/SwiftCI`:

1. **Model.** A plain value, so renderers and tests can build it:

       public enum ReportSeverity: Hashable, Sendable { case failure, warning, message }

       public struct ReportFinding: Equatable, Sendable {
           public var severity: ReportSeverity
           /// Markdown inline text, one paragraph.
           public var text: String
           /// Repository-relative path, if the finding has a location.
           public var file: String?
           public var line: Int?
       }

       public struct ReportSection: Equatable, Sendable {
           public var title: String?
           /// Markdown block content, such as a table or <details>.
           public var markdown: String
       }

       public struct RunReport: Equatable, Sendable {
           public var commandName: String
           public var findings: [ReportFinding]
           public var sections: [ReportSection]
           /// nil while running; set when the command ends.
           public var outcome: CommandOutcome?
           public var failures, warnings, messages: [ReportFinding] { get }
           /// No failures and no warnings, and the command succeeded.
           public var isClean: Bool { get }
       }

       public enum CommandOutcome: Equatable, Sendable {
           case succeeded
           case failed(message: String)
       }

2. **Adding to the report.** Free functions, like `step`, that add to the
   report of the running command:

       public enum Report {
           public static func failure(_ text: String, file: String? = nil, line: Int? = nil)
           public static func warning(_ text: String, file: String? = nil, line: Int? = nil)
           public static func message(_ text: String, file: String? = nil, line: Int? = nil)
           public static func markdown(_ markdown: String, title: String? = nil)
           /// A copy of the report so far.
           public static var current: RunReport { get }
       }

   The report lives in the `RunContext` of the command. Calling these outside
   a running command, or from a report handler, stops the process with a
   `preconditionFailure`, as `step` does. Each added finding is also logged
   when it is added (a failure as an error line, a warning as a warning line,
   a message as a completion line), so the console shows it in its step.
   Secrets are masked in the text, as in every log line.

3. **Failures fail the command.** When the command body and its handlers
   succeeded but the report has failures, the command fails with
   `BuildError(message: "The run report has N failure(s).")` and the normal
   failure exit code. All checks therefore run and report before the command
   fails, as with Danger.

4. **A failed command is never reported as clean.** When the command fails
   and the report has no failures, the core adds a failure with the command's
   error message ("The command failed: …"). A renderer never has to look at
   the outcome to avoid saying "all checks passed".

5. **Report handlers.**

       public func onReport(failure: FailureMode? = nil, _ body: @escaping (RunReport) async throws -> Void)

   Registered like `cleanup`. When the command ends, the order is: body,
   `cleanup` handlers, `onFailure` handlers, then the report is finished
   (outcome set, rule 4 applied), printed and written (R2), and the
   `onReport` handlers run in registration order with the finished report.
   A handler is logged as a step named "Report". A failing handler fails the
   command unless `failure: .allowed`, like the other handlers. Cleanup and
   failure handlers may still add findings; report handlers may not.

## R2: Console summary and Markdown

1. **Console.** When the report has findings or sections, the core prints it
   after the step summary: failures, then warnings, then messages, each as
   `path:line: text` when a location is set. Sections are printed as their
   raw Markdown. An empty report prints nothing.
2. **Markdown renderer**, public, so the GitLab module and later a GitHub
   module share it:

       public struct MarkdownReport {
           public init(title: String, footer: String? = nil, maximumLength: Int = 100_000)
           public func render(_ report: RunReport) -> String
       }

   Layout: a `## <title>` heading with "failed" or "passed"; a failures and a
   warnings table (`Location | Message`, the location as inline code, pipes
   and line breaks in cells escaped); messages as a list; then each section
   under its `### title`. When the text is longer than `maximumLength`,
   sections are dropped from the end and replaced by a note that the full
   report is in the artifacts. The tables are cut last.
3. **Artifacts.** The core writes `report-<command>.md` to the artifacts
   directory (rendered with the command name as title) when the report is not
   empty, so a CI job can archive it and a dry run can be read later.

Tests: model counts and `isClean`; adding outside a command is not unit
tested (precondition); a failure fails the command with the message above
while the body succeeded; a thrown error adds the failure of rule 4 only when
the report has none; handler order with cleanup, onFailure and onReport;
`Report.current` inside a cleanup handler sees findings of the body; a failing
report handler with and without `.allowed`; Markdown escaping of `|` and line
breaks; truncation keeps the tables; the artifact file name and content; the
console lines.

## R3: Result bundle checks (`SwiftCIXcode`)

1. **Test failures.**

       public static func reportTestFailures(resultBundleURL: URL, step name: String? = nil) async throws

   on `Xcode`. Opens a step "Report test results". It reads the tests with the
   existing `testReport(resultBundleURL:)` mapping. Each failed test case adds
   one failure: ``"`Suite.testName()` failed: <first message>"``, with the
   file and line of its first failure location, and the further messages in
   the same text. A message adds the totals: "N tests, M failed, K skipped".
   When the bundle is missing or cannot be read, it adds the failure "Test
   results were not found in <path>." and does not throw, so a missing bundle
   is reported on the merge request instead of only in the log. To keep the
   location, the mapping keeps the file and line of a failure message as
   separate values internally. The JUnit output does not change.
2. **Build issues.**

       public static func reportBuildIssues(resultBundleURL: URL, includeWarnings: Bool = false, step name: String? = nil) async throws

   Runs `xcrun xcresulttool get build-results --path <bundle> --format json`
   (Xcode 16 and later). Each entry of `errors` adds a failure with its
   `message`; with `includeWarnings`, each entry of `warnings` adds a warning.
   The location comes from `sourceURL` (`file://…#…StartingLineNumber=…`),
   made relative to the working directory when it is inside it. The line
   number in the URL is zero-based in some Xcode versions; the recording
   decides (Fixtures). Warnings are off by default, because projects usually
   gate warnings with their own allowlist and would see them twice.

Tests use the mock runner with recorded JSON: failures with and without a
location, Swift Testing and XCTest, the totals message, a missing bundle; build
errors with and without `sourceURL`, warnings on and off.

## R4: Repository checks (core)

1. **Uncommitted changes.**

       public static func reportUncommittedChanges(ignoring patterns: [String] = [], message: String, step name: String? = nil) async throws

   on `Git`. Runs `git diff HEAD --name-only -z`: changes to tracked files
   compared with `HEAD`, staged or not. Untracked files are not included, as
   in Danger's `git.diff('HEAD')` check. Paths matching one of `patterns`
   (`fnmatch` globs such as `*.png`, matched against the whole path) are
   dropped. If any path remains, it adds one failure with `message` and a
   section listing the paths.
2. **Line pattern check.**

       public static func reportLines(matching pattern: String, in pathspecs: [String], message: String, severity: ReportSeverity = .failure, step name: String? = nil) async throws

   on `Git`. Lists tracked files with `git ls-files -z -- <pathspecs>`, reads
   them as UTF-8 (other files are skipped with a warning in the log), and adds
   one finding per matching line with the file and line. `pattern` is a Swift
   `Regex` in string form; an invalid pattern throws. The doc comment points
   out that a pattern written as a literal in a checked file matches itself,
   so `Y{4}` is safer than `YYYY` in a Swift script that checks `*.swift`.

Tests with the mock runner and a temporary directory for file contents:
ignore patterns, untracked files not listed, the section text; matches with
line numbers, several files, no match, invalid pattern.

## R5: HTTP client (core)

The GitLab module needs requests that unit tests can replace, as
`ProcessRunner` is replaced for processes.

    public struct HTTPRequest: Sendable {
        public var method: String
        public var url: URL
        public var headers: [String: String]
        /// Header values sent but never logged, such as tokens.
        public var secretHeaders: [String: Secret]
        public var body: Data?
    }

    public struct HTTPResponse: Sendable {
        public var statusCode: Int
        public var headers: [String: String]
        public var body: Data
    }

    public protocol HTTPClient {
        func send(_ request: HTTPRequest) async throws -> HTTPResponse
    }

The core registers a `URLSession` implementation (with `FoundationNetworking`
on Linux). `SwiftCITesting` gets `HTTPClientMock`, which returns queued
responses per method and URL and records the requests, with secret headers
masked. Sending does not open a step and does not log the body; callers log
what they need. A transport error is rethrown as a `BuildError` that names the
method and URL without the query.

## R6: `SwiftCIGitLab`

A new first-party module and product, `SwiftCIGitLab`, macOS and Linux,
public API only (it uses no `@_spi`). It depends on the core.

1. **Connection.**

       public struct GitLab {
           public init(apiURL: URL, token: Secret)
       }

   `apiURL` is the API base, such as `https://gitlab.example.com/api/v4`.
   Requests send the token in the `PRIVATE-TOKEN` header as a secret header.
   A non-2xx response throws a `BuildError` with the method, the path, the
   status code and GitLab's `message` or `error` field.

2. **The merge request of the run.**

       public struct GitLabMergeRequest: Equatable, Sendable {
           /// Numeric ID, or the URL-encoded path such as `group%2Fproject`.
           public var project: String
           public var iid: Int
       }

       public static func mergeRequest(from environment: [String: String] = …) -> GitLabMergeRequest?

   The IID is the core's `CI.environment.mergeRequest?.number`. The project is
   the first of: `CI_PROJECT_ID` (GitLab CI), `gitlabMergeRequestTargetProjectId`
   (Jenkins GitLab plugin), or the path taken from
   `gitlabTargetRepoHttpUrl`, `gitlabTargetRepoSshUrl` or `GIT_URL` (host and
   `.git` removed). `nil` when there is no merge request or no project.

   Core fix with this milestone: the Jenkins adapter treats a GitLab plugin
   build as a merge request only for `gitlabActionType == "MERGE"`. A build
   started by a merge request comment (such as a "rerun tests" comment) has
   `gitlabActionType == "NOTE"` and the same merge request variables, and
   Danger comments on it today. The adapter accepts `NOTE` when
   `gitlabMergeRequestIid` is set. Verify the variables on a real comment
   build in the dry run.

3. **One comment per report ID.**

       public enum CleanRunBehavior: Sendable {
           /// Delete the comment. Nothing stays on the merge request.
           case deleteComment
           /// Keep the comment and replace its text with the passed report.
           case updateComment
           /// The comment is a resolvable thread. Replace its text with the
           /// passed report and resolve the thread; reopen it on a new failure.
           case resolveThread
       }

       public enum CommentMode: Sendable { case post, log }

       public func updateComment(
           for report: RunReport,
           id: String,
           title: String,
           on mergeRequest: GitLabMergeRequest,
           whenClean: CleanRunBehavior = .deleteComment,
           mode: CommentMode = .post,
           step name: String? = nil
       ) async throws

   It opens a step "Update merge request comment <id>". The body is
   `MarkdownReport(title:footer:)` output, with a footer linking the CI build
   and the commit when known, and the hidden marker
   `<!-- swiftci-report-id: <id> -->` on its last line. `id` is limited to
   letters, digits, `-`, `_` and `.`.

   Finding the existing comment: `GET /user` gives the token's user. `GET
   /projects/:project/merge_requests/:iid/discussions?per_page=100`, following
   the `X-Next-Page` header, gives all threads. The comment is the first note
   written by that user whose body contains the marker. Notes of other users
   are never changed, even if they quote the marker.

   What it does:

   - Report not clean, no comment: create it. With `resolveThread`, as a new
     thread (`POST …/discussions`); otherwise as a plain note
     (`POST …/notes`).
   - Report not clean, comment exists: replace its body
     (`PUT …/notes/:note_id`). With `resolveThread` and a resolved thread,
     also reopen it (`PUT …/discussions/:id?resolved=false`).
   - Report clean, no comment: nothing.
   - Report clean, comment exists: `deleteComment` deletes it
     (`DELETE …/notes/:note_id`); `updateComment` replaces the body;
     `resolveThread` replaces the body and resolves the thread
     (`resolved=true`).

   A comment created as a plain note cannot be resolved later. When the
   behaviour changes to `resolveThread` and the existing comment is a plain
   note, it is deleted and the report is posted as a new thread.

   In `log` mode, the rendered body and the action it would take ("would
   create", "would update", "would delete", "nothing to do") are logged, and
   only the `GET` requests are sent. This is the dry run.

   When `on` is `nil` because the run is not for a merge request, the caller
   skips the step; the convenience below does it for the script.

4. **Convenience** for scripts, registered in a command body:

       public func postReportToMergeRequest(
           gitLab: GitLab,
           id: String,
           title: String,
           whenClean: CleanRunBehavior = .deleteComment,
           mode: CommentMode = .post
       )

   It registers an `onReport` handler that calls `updateComment` with the
   merge request of the run, or logs the step as skipped with "not a merge
   request" when there is none.

Tests with `HTTPClientMock` and fixture responses: the four cases for each
behaviour; pagination; another user's note with the marker is ignored; the
switch from a plain note to a thread; `log` mode sends no writes; a 401 and a
404 produce readable errors without the token; the token never appears in
the recorded log; the merge request lookup for each variable source; the
Jenkins `NOTE` action.

## Fixtures

- `xcresulttool get build-results` output from the sample package in
  `Tests/SwiftCIXcodeTests/Fixtures/XcodebuildTest/sample`: one run with a
  compile error, and the existing failing run (it has a warning in
  `SampleKit`). Record them with an extended `record.sh`, with the same
  replacements of the home directory and simulator ID. Note in the README
  whether line numbers in `sourceURL` are zero-based.
- GitLab responses for `GET /user`, `GET …/discussions` (two pages, plain
  notes and threads, another user's note), and the created or updated note.
  They are written from the GitLab REST API v4 shapes, trimmed to the fields
  used, and checked against the adopter's server in the dry run.

## Order

R1 and R2 first, since everything adds to the report. R3 and R4 next; with
them an adopter can print the full report on the console and in the
artifacts while Danger still posts. Then R5 and R6, and the dry run. Each
milestone is a separate change with its own tests and README updates
(roadmap rows for the run report, the checks and `SwiftCIGitLab`).

## Risks

- The `build-results` JSON is newer than `test-results`, and its location
  format is not documented. The recording fixes the format for Xcode 27; the
  previous major version needs its own recording before it is supported.
- GitLab instances can be old. Discussions and resolvable threads exist in
  every supported GitLab version, but the dry run is the real check.
- A large report hits the note size limit (1,000,000 characters on
  GitLab.com). The renderer's default limit of 100,000 is well below it.
- Report handlers run after cleanup. A cleanup that deletes the result bundle
  would break a check that runs in a handler. Checks run in the body or in
  cleanup, not in report handlers.

## Decisions

- **One comment per report ID, and the ID is chosen by the script**
  (2026-11-03). A command usually posts one comment that holds every check.
  Two commands in one job with different IDs no longer overwrite each other.
- **The clean-run behaviour is a parameter** (2026-11-03): delete, update or
  resolve. The default is `deleteComment`, which is what Danger mostly does.
  Projects that want a visible "passed" or that block merging on unresolved
  threads choose the other two.
- **Report failures fail the command at its end, not when added**
  (2026-11-03), so all checks report before the run fails, as with Danger.
- **No inline diff comments for now** (2026-11-03). See Non-goals.
- **Checks read the result bundle, not the console log** (2026-11-03).
  The bundle is structured and survives a custom console filter.

- **The report check runs after the `cleanup` handlers and before the
  `onFailure` handlers** (2026-11-03). Cleanup handlers may still add
  failures that count, and `onFailure` handlers, such as a "build failed"
  notification, also run when only the report failed the command.
- **`ReportFinding.file` is a `String`** (2026-11-03), not a `URL`: it is a
  repository-relative location for display and for links, not a path that
  SwiftCI opens.
- **Findings are logged to the console only when added** (2026-11-03), like
  other error and warning lines; they do not go to the full log. The printed
  report of R2 decides whether the full log gets the report.

- **A failing `onReport` handler does not change the outcome** (2026-11-03).
  The outcome is set once, before the report handlers run, so they all see
  the same report. A failing handler can still decide the exit code, and it
  does not run the `onFailure` handlers.
- **The stored report is not masked** (2026-11-03). Findings and the outcome
  message keep their text; console lines are masked as always. Everything
  that renders the report for output (R2's console summary and Markdown file,
  R6's comment) must mask secrets in the rendered text.

- **Markdown layout details** (2026-11-03). The heading says "failed" when
  the report has failures or the command failed, otherwise "passed", also
  with only warnings. The tables have a `**Failures**` or `**Warnings**`
  line above them; messages have none. A path with backticks gets a longer
  code fence. The renderer masks secrets itself, before measuring the
  length. When the text is too long, a note is added whenever anything is
  cut, and each cut list ends with "N more left out". The footer is kept,
  without leading and trailing blank lines. Whether GitLab renders `\|`
  inside a code span in a table cell is checked in the dry run.

- **The summary also goes to the full log** (2026-11-03), without colour,
  so the full log has every finding. It is printed, and the file written,
  after the outcome is set and before the `onReport` handlers. A failed write
  of the file fails an otherwise successful command with exit code 3, like a
  failed full log write; it does not change the outcome or run the
  `onFailure` handlers, which have already run.

- **The repository checks take an optional `repository` URL** (2026-11-03),
  the working directory of `git` and the base of the files that
  `reportLines` reads, so tests use a temporary directory. A file that cannot
  be read as UTF-8 is skipped with a warning in the log, not a finding.

- **Test failure findings** (2026-11-04). A failure is named with the JUnit
  suite and test name, such as `` `MyAppTests.LoginTests.testLogin()` ``; a
  parameterized Swift Testing test is one case, so the failing argument is
  not shown. Each further message adds its first line to the same finding,
  whose location is that of the first message with one. An expected failure
  counts as passed and a disabled test as skipped, as in the JUnit report.
  Any `BuildError` from reading the bundle becomes the "Test results were not
  found" failure.

## Open questions

None at the moment.
