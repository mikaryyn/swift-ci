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
  result bundle. Used by the JUnit report (T2).

Swift Testing prefixes some lines with a zero-width space (U+200B).
