# Repository layout

The package has seven library products, `SwiftCI` (core), `SwiftCIXcode`,
`SwiftCISigning`, `SwiftCISlack`, `SwiftCIGitLab`, `SwiftCIAppStoreConnect` and `SwiftCITesting`, one target each. Each module
depends only on `SwiftCI` and uses its public API. The core depends on no module.
README.md ("Modules") describes the products. `SwiftCITesting` is
the test support for scripts and extensions.

```text
Package.swift                 Swift tools 6.2, macOS 13+, no dependencies,
                              default actor isolation = MainActor
Sources/SwiftCI/              Core
  SwiftCI.swift               Entry point `SwiftCI { … }`, the run's scope, command dispatch, usage
  CommandRun.swift            The life cycle of one command: body, handlers, report, full log, exit code
  Command.swift               `Command`
  Step.swift                  Steps (throwing, allowed-failure, skipped, nested), `StepCondition`, `step(default:name:)`, `deferringFailure`
  Handlers.swift              cleanup / onFailure / onReport registration and running
  RunContext.swift            State of the running command: step depth, handlers, run report, pending internal error
  Arguments.swift             Command-line parsing (`RunArguments`: command names, `--name=value` options, reserved flags) and the run's options state (`RunOptions`)
  Input.swift                 `input(_:default:)` and `input(_:)` for `LosslessStringConvertible` and raw-value types
  BuildError.swift            Error type and exit codes
  Use.swift                   Minimal dependency registry (`register`, `@Use`)
  TestingSupport.swift        Test hooks for SwiftCITesting, `@_spi(Testing)` only: install mocks, isolate and restore global state
  Tools/
    Tool.swift                Process values (Tool): run, output, result
    ToolTypes.swift           ToolResult, ToolOutputLine, ToolEnvironmentValue, ToolInput
    ToolOutputFile.swift      The file that a Tool writes its raw output to
    ProcessRunner.swift       The `ProcessRunner` protocol and the runner of a Tool's process: the run itself
    ProcessSpawn.swift        Finding the program and starting it with `posix_spawn`
    ProcessWorkers.swift      The reader, writer and supervisor threads of a run
    ProcessRunState.swift     The outcome of a run, its events and the line splitter
    Git.swift                 `Git(repository:)`: commit hash and tag, temporary worktree
    Git+Report.swift          The repository checks of the run report: uncommitted changes, lines that match a pattern
  HTTP/
    HTTPClient.swift          `HTTPRequest`, `HTTPResponse` and the `HTTPClient` protocol
    URLSessionHTTPClient.swift  The `URLSession` client, registered in `registerDependencies()`
  Environment/
    Environment.swift         `Environment` helpers; the environment source that tests replace
    EnvironmentMasking.swift  Which environment variables are masked when the environment is logged
    Secret.swift              Secret type and its environment source
    Redaction.swift           Secret registry, masking function, RedactingLog
  Logging/
    Log.swift                 Console log protocol, `LogSymbol`
    FullLog.swift             Per-command full log file
    Filters.swift             Filter type and helpers
    TerminalStyle.swift       Terminal styles and colours: `String.bold()`, `.red()`, `.onRed()`, …
  Reports/
    RunReport.swift           Run report model: `RunReport`, findings, severities, sections, outcome
    Report.swift              `Report`: adds findings and sections to the report of the running command
    RunReportOutput.swift     The run report summary on the console and in the full log, and `report-<command>.md`
    MarkdownReport.swift      `MarkdownReport`: the run report as Markdown, masked and truncated to a length limit
    TestReport.swift          `TestReport`: the model of test results
    JUnit.swift               `JUnit.write`: a test report as JUnit XML, secrets masked
  CI/
    CI.swift                  CI environment types (`CI`, `CIEnvironment`, `MergeRequest`, `CISystem`), `CIAdapter`, `CIExporter`
    CIDetection.swift         Detection of the CI environment and the built-in adapters, in order; the full log's CI line
    CIExport.swift            `CI.export`, its name, line-break and secret checks, and the envman, GitHub Actions and dotenv exporters
  Files/
    Artifacts.swift           Artifacts directory: resolution, creation, `Artifacts.directory`, `Artifacts.url(_:)`
    TemporaryDirectory.swift  Temporary directory, child URLs
    Plist.swift               Property list read and write (URL paths)
    RepositoryPath.swift      `repositoryRelativePath`
    URL+Extension.swift       `URL.filePath`
Sources/SwiftCIXcode/         Module (macOS): xcodebuild wrappers, app icon overlay
  Icon.swift                  App icon text overlay (AppKit)
  Xcode/                      xcodebuild wrappers (build, archive/export, settings, docbuild)
Sources/SwiftCISigning/       Module (macOS): keychains, match-compatible signing install, fastlane fallback
  Keychain.swift              Keychain unlock: a plain type with static methods
  Signing.swift               Public match API: `Signing.installMatchAssets`, `MatchRepository`, `MatchKeychain`,
                              `MatchImplementation`, `InstalledProfile`; the step and the internal test seams
  MatchType.swift             `MatchType`, the distribution type of a match install, and its profile names
  SecurityInteractive.swift   Builds the one-line input of `security -i`
  GitCredentials.swift        Git credentials for the match install
  Fastlane.swift              fastlane match invocation (`Fastlane.match`, `matchUpdate`) and its console filter
  MatchDecryption.swift       Decryption of fastlane match files (v1, v2) in memory, with a content check
  ProvisioningProfile.swift   The fields of a provisioning profile, decoded in memory (internal)
  CertificateInfo.swift       Facts of a certificate of a match repository: common name, SHA-1, expiry (internal)
  MatchSelection.swift        Selection of the profile and certificate of each bundle identifier from a match checkout (internal)
  MatchCheckout.swift         The temporary shallow clone of the match repository, with its console filter (internal)
  MatchKeychainPath.swift     The keychain file of a match install, found by name or path (internal)
  MatchInstallation.swift     Install of the selected assets (imports, partition list, profiles, identity check) (internal)
  TemporaryDirectory+Removal.swift  `TemporaryDirectory.withDirectory`: a body in a temporary directory that is removed afterwards (internal)
  MatchNativeInstall.swift    The native match install after the caller resolves the keychain and credentials: clone, selection, install (internal)
  MatchFastlaneInstall.swift  The fastlane match install: runs `fastlane match --readonly`, reads the profiles back (internal)
Sources/SwiftCISlack/         Module: Slack incoming webhooks
  Slack.swift
Sources/SwiftCIGitLab/        Module: GitLab API connection and the merge request of the run
  GitLab.swift                Connection, requests, error messages, JSON decoding and pagination (internal)
  GitLabMergeRequest.swift    `GitLabMergeRequest` and its lookup from the CI variables
  GitLabDiscussions.swift     Wire types of users, discussions and notes, the lookup of the comment and its writes (internal)
  MergeRequestComment.swift   `CleanRunBehavior`, `CommentMode`, `updateComment` (the body, the footer and the dry run) and `postReportToMergeRequest`, the convenience of a command's report handler
  MergeRequestCommentPlan.swift  The changes that a run makes to the comment, as one pure decision (internal)
Sources/SwiftCIAppStoreConnect/  Module (macOS): App Store Connect API key, client, build upload and metadata check
  AppStoreConnectAPIKey.swift  `AppStoreConnectAPIKey`: key ID, issuer ID and private key, from a `.p8` file or the environment
  AppStoreConnectToken.swift  ES256 JSON Web Token of an API key, cached until it nearly expires (internal)
  AppStoreConnect.swift       `AppStoreConnect`: the client, its requests, retries and pagination (internal)
  AppStoreConnect+Errors.swift  The error messages of the client: statuses, Apple's details, decoding problems (internal)
  AppStoreConnect+BuildUpload.swift  `AppStoreConnect.uploadBuild`: the step that checks and uploads an IPA
  AppStoreConnect+Precheck.swift  `AppStoreConnect.precheck`: the step that checks the App Store metadata and logs and reports its findings
  PrecheckResult.swift        `PrecheckResult` and `PrecheckFinding`, the findings of the metadata check
  BuildUpload.swift           `BuildUpload` and `BuildUploadState`, the result of an upload
  BuildUploadParts.swift      Sends the parts of the IPA to their pre-signed URLs and computes the MD5 (internal)
  BuildUploadResources.swift  JSON:API request and response types of the Build Upload API (internal)
  IPAInfo.swift               Reads the bundle identifier, version, build and platform from an IPA (internal)
  Precheck/                   The metadata check (internal)
    PrecheckMetadata.swift    Reads the items to check from App Store Connect, with the newest version and the pages of each list
    PrecheckItem.swift        One value to check: its field, its friendly name as fastlane prints it, and whether it is optional
    PrecheckRule.swift        One rule: its name, description, the fields it checks and its check
    PrecheckRules.swift       The eight rules in fastlane's order, with their word lists, the phrase matcher and the URL check
    CurseWordHashes.swift     The SHA-256 hashes of the curse words, ported from fastlane precheck (MIT notice in the file)
Sources/SwiftCITesting/       Module: test support for scripts and extensions. Imports no test framework.
                              Uses `@_spi(Testing) import SwiftCI` only for the hooks in TestingSupport.swift
  SwiftCITest.swift           run(_:environment:artifactsDirectory:ciAdapters:runner:httpClient:script:), withMocks(_:runner:httpClient:log:artifactsDirectory:ciAdapters:_:), SwiftCITestResult
  ProcessRunnerMock.swift     Records each Tool it runs and returns prepared responses
  HTTPClientMock.swift        Returns queued responses per method and URL, and records the requests with secrets masked
  LogMock.swift               Records console lines and the arguments of each Log method
Tests/SwiftCITestSupport/     Not a product. Helpers shared by this repository's test targets: GlobalStateTests,
                              registerToolMocks, isolatedGlobalState (SPI), thrownError, stripANSI, temporaryArtifactsDirectory,
                              withTemporaryArtifactsDirectory
Tests/SwiftCITests/           Core tests (Swift Testing), in the same folders as the sources they test
Tests/SwiftCIXcodeTests/      Xcode tests
Tests/SwiftCISigningTests/    Keychain, match, Git credential and `security -i` tests
Tests/SwiftCISlackTests/      Slack tests
Tests/SwiftCIGitLabTests/     GitLab connection, merge request and merge request comment tests
Tests/SwiftCIAppStoreConnectTests/  API key, token, client, IPA reading, build upload and metadata check tests, and the manual metadata check
  Fixtures/                   Tiny IPAs for the IPA reading tests: a valid app, and ones with no app, two apps, a missing build version, a Mac platform and an app name with glob characters; `precheck/` holds the JSON responses of the metadata check
Tests/SwiftCITestingTests/    Tests of SwiftCITesting as an extension author sees it: `import SwiftCI`,
                              `import SwiftCITesting` and `import Testing` only (no `@testable`, no SPI)
docs/prior-art.md             Research on fastlane, Bitrise and alternatives
```
