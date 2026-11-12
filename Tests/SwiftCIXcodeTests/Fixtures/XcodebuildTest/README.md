# xcodebuild test recordings

Recorded on 2026-10-30 with Xcode 27.2 on an iPhone 17 simulator (iOS 27), from
the sample package in `sample/` with `sample/record.sh`. The home directory is
replaced with `/Users/ci` and the simulator ID with a placeholder.

- `xcodebuild-test-failing.log`: the console output of `xcodebuild test`
  (exit code 65). XCTest: 1 passed, 2 failed (one with two assertions), 1
  skipped. Swift Testing: 1 passed, 2 failed, 1 disabled, and a parameterized
  test over 1, 2 and 3 that fails for 2. A build warning in `SampleKit`.
- `test-results-tests.json` and `test-results-summary.json`: the output of
  `xcrun xcresulttool get test-results tests` and `… summary` for the same
  result bundle. Used by the JUnit report.

Swift Testing prefixes some lines with a zero-width space (U+200B).

Recorded on 2026-11-04 with Xcode 27.2 on an iPhone 17 simulator (iOS 27.2), with
`sample/record.sh`. The home directory is replaced with `/Users/ci` and the
simulator ID with `00000000-0000-4000-8000-000000000001`.

- `build-results-warning.json`: the output of `xcrun xcresulttool get build-results
  --path <bundle> --format json` for the sample package as it is. One warning:
  `unused` in `SampleKit.swift`, which is on line 10. Its `sourceURL` has
  `StartingLineNumber=9`, so the line numbers in `sourceURL` are zero-based.
- `build-results-compile-error.json`: the same output for a copy of the sample
  in `/private/tmp/sci-sample-compile-error` with a file that does not compile.
  Two errors: "Testing cancelled because the build failed.", which has no
  `sourceURL`, and the compile error at `Broken.swift` line 2 (`StartingLineNumber=1`).

Both are read by `Xcode.reportBuildIssues`.
