# Status

What SwiftCI can do today, what is planned, and what is known to be broken or
undecided.

## Capabilities

**Prototype** means the feature exists and at least one project uses it, but it
is not yet fully tested or stable. **Planned** means it is designed here but not
implemented.

| Area | Capability | Status |
|---|---|---|
| Core | Commands, throwing and allowed-failure steps with nesting, integration calls as steps, `cleanup` (also `cleanup(when:)`) / `onFailure` handlers, `deferringFailure` | Prototype |
| Core | Process execution with streamed output and filters; `--verbose` shows the output unfiltered | Prototype |
| Core | HTTP client: `HTTPRequest`, `HTTPResponse` and `HTTPClient`, with a `URLSession` client registered as `@Use var client: HTTPClient`, and `HTTPClientMock` for tests | Prototype |
| Core | Console log with colours, per-command full log file (`logs/<command>.log` in the artifacts directory) | Prototype |
| Core | Artifacts directory: `SWIFTCI_ARTIFACTS_DIR`, `SwiftCI(artifactsDirectory:)`, `Artifacts.directory` and `Artifacts.url(_:)` | Prototype |
| Core | Environment variables (`Environment.required`, `Environment.optional`) | Prototype |
| Core | Secret declaration (`Secret("NAME")`), redaction in all writers, secrets in `Tool` environment and input | Prototype |
| Core | Exit codes (failed steps exit 1, usage errors 2, internal errors 3, timeouts 4) | Prototype |
| Core | `--list`, `--help`, and the command list after a missing or unknown command | Prototype |
| Core | Options `--name=value` and inputs (`input(…)`) from the command line, then the environment, then the default; a warning for options that no input read | Prototype |
| Core | Builds and runs on Linux | Planned |
| Core | Public, versioned extension API | Planned |
| Core | Split into core and first-party modules (`SwiftCI`, `SwiftCIXcode`, `SwiftCISigning`, `SwiftCIAppStoreConnect`, `SwiftCISlack`, `SwiftCIGitLab`; macOS verified, Linux not yet) | Prototype |
| Testing | `SwiftCITesting`: `ProcessRunnerMock`, `HTTPClientMock`, `LogMock`, `SwiftCITest.run` and scoped environment and mocks, for scripts and extensions (macOS verified) | Prototype |
| Core | Step summary at end of run (status and duration per step) | Planned |
| Core | Run report: `Report` findings and sections, `onReport` handlers that receive the final report, a console and full log summary, and `report-<command>.md` in the artifacts directory; a report failure fails the command. `MarkdownReport` renders a report as Markdown. It is posted to a merge request by `SwiftCIGitLab` | Prototype |
| Core | Repository checks for the run report: uncommitted changes compared with `HEAD` (`Git.reportUncommittedChanges(…)`) and lines of tracked files that match a Swift `Regex` (`Git.reportLines(…)`) | Prototype |
| Xcode | Test failures and build issues from the `.xcresult` bundle for the run report: `Xcode.reportTestFailures`, with the totals, and `Xcode.reportBuildIssues` (build errors as failures; warnings only with `includeWarnings`) | Prototype |
| Core | CI environment detection (`CI.environment`: Jenkins, GitLab CI, GitHub Actions, Bitrise, generic CI, local) | Prototype |
| Core | CI output export to later steps (`CI.export`): `envman`, `$GITHUB_ENV` and `artifacts/outputs.env` | Prototype |
| Xcode | clean, build, archive and export (ad-hoc or App Store; IPA and dSYM zip to the artifacts directory by default; App Store export writes the IPA only, upload is separate; the archive is removed unless `archiveURL:` keeps it), resolve packages, build settings (`Xcode.getBuildSettings`, cached for the run: one `xcodebuild -showBuildSettings` per workspace or project, scheme, configuration, destination and build settings), version and build number (`Xcode.getVersion` reads the Info.plist on each call and the cached build settings only when a value refers to one), docbuild, DocC archive merge (`Xcode.mergeDocumentation`) | Prototype |
| Xcode | Delete the DerivedData folder of the user (`Xcode.deleteDerivedData`), and its location (`Xcode.derivedDataURL`) | Prototype |
| Xcode | test, with result bundle, code coverage, test plan, timeout and raw log file; xcresult summary of failures and coverage is planned | Prototype |
| Reports | JUnit XML test reports from `.xcresult`: `Xcode.testReport` (model) and `Xcode.writeJUnitReport` (file, in a step); the writer is in the core | Prototype |
| Reports | Coverage reports (Cobertura XML) from `.xcresult` | Planned (later) |
| Reports | Warning and error annotations (GitLab Code Quality, GitHub workflow commands) | Planned (optional, later) |
| Xcode | Default `xcodebuild` console filter: errors, warnings and the result line; for `test`, also the failing tests, the summaries, and the simulator and test runner failures (lost connection, restart, crash, hang, early exit) | Prototype |
| Xcode | `xcodebuild` output formatter with progress (xcbeautify-style) | Planned |
| Xcode | Xcode selection and preflight checks (version, SDKs, simulators) | Planned |
| Xcode | Version and build number setting | Prototype |
| Xcode | Over-the-air install files (`manifest.plist` and install page) | Prototype |
| Simulators | Shut down all simulators via `simctl` (`Simulator.shutdownAll`) | Prototype |
| Simulators | Quit the Simulator app (`Simulator.quitApp`; not running is not an error) | Prototype |
| Simulators | Hardware keyboard turned off in the Simulator preferences, so typed text in UI tests reaches the software keyboard (`Simulator.disableHardwareKeyboard`) | Prototype |
| Simulators | `xcodebuild` destination of an iOS simulator by device name and OS (`Simulator.destination`) | Prototype |
| Simulators | Boot and erase via `simctl` | Planned |
| SwiftPM | `swift build`, `swift test`, with output formatting | Planned |
| Signing | Keychain unlock; the password goes to `security -i` on standard input, never as an argument | Prototype |
| Signing | Temporary keychain create / import / partition list / delete | Planned |
| Signing | `Signing.installMatchAssets(using: .native)`: install signing assets from a fastlane `match` Git repository (read-only, native). The certificate of each profile is chosen by the profiles. The imported identity is checked with `security find-identity`. Profiles go to the Xcode 16+ folder. Git credentials and keychain passwords are not arguments. `MatchType.profileName(for:)` gives the profile name to pass to `Xcode.archiveAndExport` | Prototype |
| Signing | `Signing.installMatchAssets(using: .fastlane(…))`: the same install through `fastlane match --readonly` (fallback), then the profiles are read back. The explicit values (`--git_url`, `--git_branch`, `--team_id`, `--keychain_name`) override a `Matchfile`; the secrets go in the environment | Prototype |
| App Store Connect | API key auth (ES256 JWT with CryptoKit) | Prototype |
| App Store Connect | Upload builds (Build Upload API, `AppStoreConnect.uploadBuild`; iOS IPAs) | Prototype |
| App Store Connect | Metadata check (port of fastlane precheck) | Prototype |
| App Store Connect | Upload via fastlane `pilot` / `deliver` (fallback) | Planned |
| macOS | Notarization via `notarytool`, stapling | Planned |
| Notifications | Slack incoming webhooks, as Block Kit (`Slack.send`) or legacy attachment (`Slack.sendAttachment`) messages, with optional sender name and icon; the webhook URL is a `Secret`. A message Slack does not accept fails the step with Slack's reason; run it as an allowed failure to make it optional. The message goes to the full log only | Prototype |
| Merge requests | `SwiftCIGitLab`: GitLab connection (`GitLab`, with the token sent as a secret header) and the merge request of the run from the CI variables (`GitLabMergeRequest.mergeRequest()`). The run report as one merge request comment per report ID (`postReportToMergeRequest`, `GitLab.updateComment`): created, updated, resolved or deleted, with a `log` mode that only shows what it would do. A request is retried after a 429 response, and after a 5xx response or a lost connection except for a `POST` | Prototype |
| Git | Commit hash, tag | Prototype |
| Misc | App icon text overlay (e.g. build number or environment badge) | Prototype |
| Generic | Arbitrary shell commands and scripts | Prototype |

## Native implementations and fallbacks

Integrations with more than one implementation follow the
[explicit fallback rules](design.md#native-implementations-and-explicit-fallbacks).

| Task | Native | Fallback |
|---|---|---|
| Install signing assets from a match repository | Swift: Git clone, decrypt v1/v2 match files, `security import`, install profiles | `fastlane match --readonly` |
| Create or renew certificates and profiles | Not planned initially | `fastlane match` (non-readonly) |
| Upload to TestFlight / App Store | App Store Connect Build Upload API | `fastlane pilot` / `deliver` |
| Editing App Store metadata and screenshots | Out of scope | `fastlane deliver` |
| App Store metadata check | App Store Connect API, `AppStoreConnect.precheck` | None |
| JUnit test reports | Swift, from `xcrun xcresulttool` output | `fastlane trainer` |
| Coverage reports | Swift, from `xcrun xccov` output | None planned |

## Planned reports

**Coverage reports (planned, later).** The converter writes Cobertura XML from
the `.xcresult` bundle (`xcrun xccov`). GitLab's coverage visualisation
and similar tools read that file.

**Annotations (planned, optional, later).** Annotations attach compiler
warnings, errors and lint findings to the changed lines in a merge or pull
request. They use GitLab Code Quality reports or GitHub workflow commands
(`::warning file=…,line=…`). Each CI system needs its own small formatter, and
the value overlaps with Danger and log-parsing CI plugins. So these come after
the core reports.

**Machine-readable run summary (deferred).** A JSON file with step status,
durations and artifact paths could feed notifications or dashboards without
scraping logs. It will be added when something needs it.

## Roadmap

The order of work follows from adopting SwiftCI in a real project.

1. **Correctness of the core.** Fix exit codes and add secret redaction. Extend
   the process API with separate stdout and stderr, output capture, timeouts,
   a working directory and an environment. The fastlane fallback now runs
   `fastlane` by name, and it needs tests for all of it.
2. **Core and modules.** Split the package into the core and first-party
   modules and `SwiftCITesting` (done on macOS). Make the extension API public,
   and build and test the core on Linux.
3. **Clean output.** Add a default `xcodebuild` formatter and a step summary.
   The artifacts directory is in the core; the
   integrations that write files into it follow.
4. **Xcode test path.** Add `Xcode.test`, xcresult summaries, JUnit reports,
   simulator management, Xcode preflight checks, and SwiftPM build and test
   support.
5. **Signing.** Add temporary keychains, a native match install with v1 and v2
   fixtures, and the fastlane fallback.
6. **Distribution.** Add the App Store Connect JWT and upload through the Build
   Upload API. Add notarization for macOS.
7. **More reports.** Add coverage reports, then optional annotations for GitLab
   and GitHub.
8. **Stabilise.** Publish semantically versioned releases, complete the
   [end-user documentation plan](plans/end-user-documentation.md), and
   provide an example CI package and an example extension.

## Known issues

- On macOS 26, `set-key-partition-list -k` rejects keychain passwords that contain
  non-ASCII characters, even when they are passed correctly. `unlock-keychain`
  still accepts them. The native match install then logs a warning and continues
  without the partition list.
- Linux is not verified since the module split. The
  [Linux verification plan](plans/linux-verification.md) tracks the work.
  The core does not build on Linux yet, and the blocker is that the Apple
  modules are not yet gated with `#if os(macOS)`. `SwiftCIXcode` imports `AppKit` (icon overlay), and
  `SwiftCISigning` imports `Security`, `CryptoKit` and `CommonCrypto` (match). The
  `ProcessRunner` Linux branches are also unverified. Paths are Foundation `URL`s,
  so `System` is not imported and no `swift-system` package is needed.
- The native match install is tested with fixtures that fastlane 2.232's own
  encryption code wrote. Its decryption was verified against a real match
  repository (`MatchDecryptionManualCheck`), and its install (import, partition
  list, profiles and the `find-identity` check) was verified with a throwaway
  keychain (`MatchInstallManualCheck`). It is not yet used in CI, and it has not
  yet run against a real certificate. Profiles are written to
  `~/Library/Developer/Xcode/UserData/Provisioning Profiles`, which Xcode 16 and
  later read.
- The fastlane path takes `keychain_password` from a `Matchfile` before
  `MATCH_KEYCHAIN_PASSWORD`. A project that sets it there should set the same value,
  or leave it out. The fastlane path finds the profiles only under fastlane's
  default names (`match <Type> <identifier>`). A custom `profile_name` is not supported.

- A timeout or cancellation ends only the program a `Tool` started, not the
  processes that program started. On a runner that is not reset between jobs, a
  descendant such as a simulator or a compiler process can keep running.

## Open questions

Decisions still to be made are tracked here until they are resolved:

- **Ending descendants of a tool.** The usual fix is a process group of its own
  for each program, with the signals sent to the group. That needs signal
  handling in SwiftCI first, because Ctrl-C at the terminal would stop reaching
  the program, and a decision about the terminal, because the new group is a
  background group, where a tool that reads from `/dev/tty` (such as `git`
  asking for a password) is stopped. It could start as an opt-in parameter of
  `Tool`.
  The same signal handling must make an allowed step and `deferringFailure` stop
  on cancellation, because they absorb it today.
- **Unfinished build uploads.** `uploadBuild` refuses to start when the app has a build upload of the same version
  and build number that has not failed, and a run that fails halfway leaves such an upload in the state
  `AWAITING_UPLOAD`. The step then asks for a new build number. It is not known whether App Store Connect really
  blocks the number while the upload waits for its file, or lets a new upload through. To be checked against the real
  API. If it lets one through, the check should ignore uploads that wait for their file.
