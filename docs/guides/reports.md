# Reports for CI systems

CI systems can render a few standard report formats themselves. That is more
useful than scrolling through logs. SwiftCI writes reports to the artifacts
directory, and the CI configuration publishes them.

**Run report.** A command records its findings with `Report.failure(_:file:line:)`,
`Report.warning(…)` and `Report.message(…)`, and adds sections with
`Report.markdown(_:title:)`. When the command ends, SwiftCI prints a summary of
the findings and writes `report-<command>.md` to the artifacts directory. An
`onReport { report in … }` handler receives the finished report. A failure in
the report fails the command, so every check runs before the run ends. A report that must run after a
failed step is wrapped with `deferringFailure`, so that the command fails at the end with the first deferred error:

```swift
let testsPassed = await deferringFailure {
    try await xcode.test(destination: destination, resultBundleURL: bundle)
}
// Runs also when the tests failed.
try await Xcode.reportTestFailures(resultBundleURL: bundle)
```
The repository checks `Git.reportUncommittedChanges(ignoring:message:)` and
`Git.reportLines(matching:in:message:)`, methods of a `Git(repository:)` value, add their findings to the report in the
same way, `Xcode.reportTestFailures(resultBundleURL:)` adds the failed tests of a
result bundle, and `Xcode.reportBuildIssues(resultBundleURL:includeWarnings:)` adds
its build errors, and its warnings when asked.

```swift
let lint = Command("lint") {
    onReport { report in
        try await notifier.send(text: "\(report.failures.count) finding(s)")
    }
    try await step("Check files") {
        Report.failure("Force unwrap.", file: "Sources/App/View.swift", line: 12)
    }
}
```

`postReportToMergeRequest` (`SwiftCIGitLab`) posts the report as one comment on
the merge request of a merge request build, and skips the step elsewhere. The
comment is found by its report ID, so a command that runs again updates its
comment instead of adding one. The `whenClean:` argument says what a clean run
does with it: delete (the default), update, or resolve the thread. With
`mode: .log` it only logs what it would do, and a failing request does not fail
the command.

```swift
let tests = Command("tests") {
    postReportToMergeRequest(
        gitLab: GitLab(apiURL: URL(string: "https://gitlab.example.com/api/v4")!, token: Secret("GITLAB_TOKEN")),
        id: "tests",
        title: "Unit tests"
    )
    // The checks of the command add their findings to the report.
}
```

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

Coverage reports, annotations and a machine-readable run summary are planned; see [status.md](../status.md#planned-reports).
