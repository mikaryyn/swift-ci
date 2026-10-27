# Implementation plan

Status: **accepted**. Decisions are listed at the end.

## Goal

Make SwiftCI good enough to run the complete CI of a real iOS project, and
use that migration to drive and order SwiftCI's work. The first adopting
project (called *the reference project* below) currently uses:

- Jenkins on a self-hosted Mac agent, with GitLab merge requests
- the Bitrise CLI as the workflow runner, called from Jenkinsfiles
- Danger (Ruby) for merge request feedback
- fastlane for signing (match), test result conversion (trainer) and App
  Store upload (deliver)
- assorted Ruby, Python and shell helpers

The tools are replaced in this order. Bitrise goes first, then Danger, then
fastlane, then the remaining helpers. Developer task runners such as `just`
stay as developer tooling. Their recipes may call `./ci` where work overlaps.

## Principles

- **Generic in SwiftCI, glue in the project.** Anything another project could
  use goes into SwiftCI (core, first-party module or extension). Project
  names, identifiers, deployment tables and URLs stay in the project's CI
  package.
- **One workflow at a time.** Each Bitrise workflow gets a `./ci <command>`
  equivalent. The new command runs alongside the old workflow on the same
  commit, and replaces it only after the results match (see
  [Parity checks](#parity-checks)). Migration can go inside-out or
  outside-in. See [Incremental adoption](incremental-adoption.md).
- **Interim tools are explicit.** While a native implementation is missing,
  SwiftCI calls the existing tool (Danger, `fastlane match`) as an explicit
  external step. It never calls the tool as an automatic fallback.
- **Every phase ends with passing checks and removes something.** Each phase
  removes at least one tool or runtime from the CI machine.

## Starting point

The reference project's workflows fall into these groups:

| Workflow | Started by | What it does |
|---|---|---|
| Merge request tests (one per app scheme) | Jenkins job per merge request | SwiftLint gate, `xcodebuild test` with coverage, compiler warning gate, JUnit via `fastlane trainer`, Danger comment |
| Internal ad-hoc deploy (one per app) | Jenkinsfile on merge, nightly and on request | Set build number in Info.plist, stamp version on app icon, `match adhoc`, archive and ad-hoc export, IPA naming from version, tag and commit, OTA `manifest.plist` and install page, Slack |
| App Store deploy | Parameterised Jenkinsfile | Deployment name selects one or more build configurations; for each: `match appstore`, archive, App Store export, upload with `deliver`, Slack |
| UI tests (full and smoke test plan) | Nightly Jenkins job | Simulator preparation (hardware keyboard off), UI tests, JUnit and HTML report, Slack |
| Static analysis | Disabled | Tests with coverage, Cobertura XML, SwiftLint report, `sonar-scanner`; not migrated (see [Decisions](#decisions)) |
| Documentation | Nightly | Already migrated to a SwiftCI command (DocC); the old Jazzy workflow is unused |

Two quality gates are already Swift scripts. One runs SwiftLint with a pinned
version, and the other checks compiler warnings against an allowlist file.
Both write JSON reports, and a second Dangerfile turns those reports into
merge request comments.

### Tools to retire

- Bitrise CLI and `bitrise.yml`
- Ruby, rbenv, Bundler and all gems: `danger` and its GitLab, JUnit and
  xcodebuild plugins, `fastlane`, `xcpretty`, `xcpretty-json-formatter`,
  `jazzy`, `slather`, `bundler-audit`
- Python `junit2html`
- The Bitrise icon stamper step and its ImageMagick/Ghostscript dependency
- Groovy logic in Jenkinsfiles beyond checkout, credentials and artifact
  archiving

### Tools that stay

- `just`, SwiftLint, SwiftGen and xcbeautify as developer tools
- Jenkins-side tasks implemented as Jenkins plugins (for example SBOM
  generation and Dependency-Track upload)

## Adopting project setup

These issues affect any project that consumes SwiftCI from CI.

- **Pin SwiftCI.** Depend on a tagged version, not a branch, so CI runs are
  reproducible. This requires SwiftCI to publish 0.x tags.
- **Avoid recompiling on every run.** If the CI workspace is wiped before each
  build, the CI package and SwiftCI are compiled from scratch every time. Use
  a persistent `--scratch-path` outside the workspace on self-hosted agents,
  or a cache on hosted runners. Also use a debug build. It compiles faster,
  and runtime speed does not matter for a CI script.
- **One CI package.** Move standalone check scripts into the CI package as
  commands or steps, instead of running them with `swift script.swift`.
- **Swift tools version.** The CI package must declare a tools version at
  least as new as SwiftCI's.

## Phases

### Phase 0: SwiftCI foundations

This is SwiftCI work that must happen before a project depends on more of
it. It covers roadmap items 1 and 2 in [README.md](../../README.md#roadmap),
plus parts of item 3.

- Correct exit codes. A failed step fails the run.
- New script syntax, milestones M0 to M5 of
  [Script syntax](script-syntax.md): a testable runner, throwing steps, allowed failures,
  inline cleanup and failure handlers, integration calls as steps (before
  the module split) and removal of `Workflow`. These are breaking
  changes, so they land before 0.1.0.
- Process API, secret registration and redaction, and the fastlane fallback
  invocation fix. These are implemented; the user-facing overview is in
  [Output, filtering and secrets](../../README.md#output-filtering-and-secrets),
  and the remaining reference work is tracked in
  [End-user documentation](end-user-documentation.md).
- Split into core and first-party modules, make the extension API public, and
  add `SwiftCITesting`. The macOS split is complete; see the
  [module layout](../../README.md#module-layout). Verification of the core on
  Linux is tracked in [Linux verification](linux-verification.md).
- A configurable artifacts directory, for example one that points at an
  existing runner's output directory. This is implemented; see
  [Artifacts](../../README.md#artifacts).
- A temporary Bitrise workflow wrapper in the core supports outside-in
  migration. It is removed before 1.0 (see
  [Incremental adoption](incremental-adoption.md#decisions)).
- CI environment detection and output export in the core, through a public
  adapter protocol. Adapters cover Jenkins (including GitLab plugin
  variables), GitLab CI, GitHub Actions, Bitrise and local runs. These and the
  Bitrise wrapper are implemented; see
  [CI environment](../../README.md#ci-environment),
  [Output export](../../README.md#output-export) and
  [Incremental adoption](incremental-adoption.md).
- Release 0.1.0.

**Exit criteria.** The reference project's existing SwiftCI command runs on a
pinned tag, and its tests pass on macOS. Linux verification of the core is
deferred (see [Linux verification](linux-verification.md)).

### Phase 1: replace Bitrise

Phase 1 uses **outside-in** adoption (see
[Incremental adoption](incremental-adoption.md)). First, jobs switch to
`./ci <command>`, which wraps the Bitrise workflow. Next, the workflows that
run before and after the core work are replaced natively. The core work is
replaced last. Danger and `fastlane match` still run, called explicitly from
SwiftCI.

Command descriptions and inputs (milestone M6 of
[Script syntax](script-syntax.md)) land when the first ported workflow needs
an input.

Workflows are ported in this order:

1. **Internal ad-hoc deploy.** This workflow exercises most of the existing
   prototype code (plist, icon overlay, archive and export, Git, Slack). It
   does not involve Danger and carries low risk. Its new generic pieces are:
   - version and build number setting (Info.plist or build settings)
   - reading marketing version and build number
   - artifact naming helpers
   - OTA distribution: `manifest.plist` and install page for an exported IPA
   - `match` via fastlane (`using: .fastlane`)
2. **App Store deploy.**
   - Archive, then upload with `xcodebuild -exportArchive` using method
     `app-store-connect`, the `upload` destination and App Store Connect API
     key authentication (`-authenticationKeyPath`, `-authenticationKeyID`,
     `-authenticationKeyIssuerID`). This uses Apple's own tool, replaces
     `deliver`, and needs no JWT code yet. See
     [App Store upload](#app-store-upload) for the settings that keep parity
     with the current `deliver` step.
   - A second `-exportArchive` pass with the `export` destination produces
     the IPA artifact, because `upload` does not write one locally.
   - The deployment table (deployment name to build configurations) moves
     from Groovy into the project's CI package, for example
     `./ci appstore --deployment=<name>`. Options use the `--name=value`
     form (see [Script syntax](script-syntax.md#rules)).
   - The API key reaches the tool as a file path taken from a secret, never
     as an argument value.
3. **Merge request tests.**
   - SwiftLint and compiler warning gates ported from the existing scripts
     into reusable steps (see [Extension ideas](../../README.md#extension-ideas)).
   - `Xcode.test` with an explicit result bundle path.
   - JUnit XML from the `.xcresult` with `xcresulttool`, replacing
     `fastlane trainer`.
   - Simulator shutdown with `simctl`.
   - Danger still runs, reading the JUnit file and gate reports produced by
     SwiftCI.
4. **UI tests.**
   - Simulator preparation (preferences such as the hardware keyboard,
     shutdown before and after).
   - Test plans.
   - JUnit published with the CI system's own test report support (for
     example the Jenkins `junit` step) instead of generating HTML.

Finally, delete `bitrise.yml` (including the disabled static analysis
workflow), the Bitrise secrets template and the unused Jazzy workflow, and
update the project's documentation.

**Exit criteria.** No Jenkinsfile or job calls `bitrise`, and the Bitrise CLI
is uninstalled from the CI machine.

### Phase 2: replace Danger

- **Run report in the core.** Steps add messages, warnings, failures and
  Markdown to a run-level report. Renderers: console summary (core), merge
  request comment (GitLab module), later GitHub step summary and annotations.
- **GitLab merge request client** (`SwiftCIGitLab`, Linux-compatible, public
  API only):
  - find the project and merge request from CI environment variables
  - token from a registered secret
  - one comment per report ID, created or updated on each run, and resolved
    or removed when the run is clean (the equivalent of Danger's
    `danger_id`)
- **Port the checks** as reusable steps:
  - test failures from the `.xcresult` (instead of JUnit plus a Danger
    plugin)
  - build errors and warnings from the `.xcresult` (replacing
    `xcpretty-json-formatter` and the Danger xcodebuild plugin)
  - quality gate findings rendered directly into the report, without JSON
    files passed between tools
  - "build left uncommitted changes" check, with ignore patterns
  - pattern checks over source files (e.g. the `YYYY` date format pitfall)
- **Dry run first.** Print the rendered comment to the log for a while, then
  post for real.

**Exit criteria.** No Dangerfiles, and the Danger gems are removed.

### Phase 3: replace fastlane

By now only `match` is left. `trainer` and `deliver` were replaced in
Phase 1.

- **Read-only match.** Switch from `using: .fastlane` to `using: .native`
  after the native install is tested with v1 and v2 encrypted fixtures.
  Decide between temporary keychains per run and a persistent CI keychain.
- **Certificate and profile renewal** (`match --force`). Keep using fastlane
  locally for these rare, manual runs at first. A native implementation needs
  the App Store Connect certificates, profiles and bundle ID endpoints. It is
  a later step.
- **App Store Connect client.** The minimal native client (JWT, build
  processing status, optionally TestFlight groups) is added when a workflow
  needs more than the upload in Phase 1.

**Exit criteria.** CI never runs fastlane, and Ruby, rbenv and the `Gemfile`
are removed from the CI machine.

### Phase 4: remaining tooling

- Keep Jenkinsfiles thin. Keychain unlock, DerivedData and module cache
  cleanup move into `./ci` commands.
- Move job definitions that live only in the Jenkins UI into Jenkinsfiles in
  the repository.
- Optionally, make developer task runner recipes call `./ci` where they
  duplicate CI work (signing asset download, localisation download and code
  generation).
- Inside-out adoption support for projects that keep their runner: output
  export adapters, a report merged across `./ci` invocations, and
  documentation for building once and running the binary (see
  [Incremental adoption](incremental-adoption.md)).
- Harden existing commands. For example, replace shell-interpolated `rsync`
  calls with argument arrays and file operations, and remove patches that
  depend on generated file names.

**Exit criteria.** CI depends only on Xcode, the Swift toolchain, Jenkins and
the explicitly retained tools.

## Parity checks

Before switching a workflow, run the old and new implementation on the same
commit and compare:

| Workflow | Compare |
|---|---|
| Deploys | IPA name; bundle ID, version and build number; signing identity and profile (`codesign -dv`, embedded profile); entitlements; `manifest.plist`; icon overlay; dSYM archive |
| App Store deploy | Build appears in App Store Connect with the expected version and build number |
| Tests | Test, failure and skip counts; JUnit content; gate results on a branch with a known lint violation and a known warning |
| Merge request feedback | Rendered comment against the Danger comment for the same merge request |
| All | Exit code on success and on a forced failure; no secrets in console or full log |

## Testing SwiftCI

- Unit tests use mocks registered through the dependency registry. They never
  touch the real keychain, network, simulators or `~/Library`.
- Fixtures cover format-sensitive code. They include small `.xcresult` bundles
  and `xcodebuild` output for each supported Xcode major version, match
  repositories with v1 and v2 encryption, JUnit output, and GitLab API
  responses.
- The core runs its tests on Linux in the official Swift Docker image.

## Decisions

- **Interim tools in Phase 1.** Danger and `fastlane match` keep running as
  explicit external steps called from SwiftCI until they are replaced in
  Phases 2 and 3. Each switch then changes one thing at a time, which keeps
  parity checks meaningful.

- **App Store upload.** Phase 1 uploads with `xcodebuild -exportArchive`
  (`upload` destination), provided that no functionality of the current
  workflow is lost. The native App Store Connect client is added later, only
  for what `xcodebuild` cannot do (processing status, TestFlight groups).
  Details below.

- **GitLab merge request client.** The first-party module `SwiftCIGitLab`
  lives in this repository (see [module layout](../../README.md#module-layout)).
  It is versioned together with the run report API it renders. GitHub support
  later follows the same shape, as a sibling module or extension.

- **Static analysis.** The disabled SonarQube workflow is not migrated.
  SonarQube support stays an [extension idea](../../README.md#extension-ideas),
  built on the core's coverage export (a "later" capability) if needed.

- **Xcode versions.** The minimum is Xcode 26, matching the Swift 6.2
  toolchain requirement. SwiftCI supports the two latest major Xcode versions,
  with `.xcresult` and output fixtures for each, and parses result bundles
  only with the current `xcresulttool` JSON API. See
  [Toolchain and Xcode versions](../../README.md#toolchain-and-xcode-versions).

- **Project-side plan.** The project-specific migration (workflow mapping,
  identifiers, Jenkins changes, parity run notes) lives as an ExecPlan in the
  adopting project's repository and follows the phases here. SwiftCI gaps
  found during migration come back to this repository as generic roadmap
  items or issues.

### App Store upload

The current Bitrise `deploy-to-itunesconnect-deliver` step (with an app ID,
`skip_app_version_update` and an API key) effectively runs:

```sh
fastlane deliver --api_key_path <key.json> --app <app ID> --team_id <team> \
  --ipa <ipa> --skip_screenshots --skip_metadata --skip_app_version_update \
  --force --platform ios --precheck_include_in_app_purchases false
```

| `deliver` behaviour in this configuration | `xcodebuild` upload |
|---|---|
| Binary upload | Same. Upload signs an IPA from the archive and sends it. |
| Metadata, screenshots, version creation, review submission, waiting for processing | Off in `deliver` too; nothing to replace. |
| App selected by app ID | Not needed: the build is matched by bundle ID. The app record must already exist, as today. |
| Symbols for crash reports | Same: `uploadSymbols` defaults to true. |
| Build number set by CI | Set `manageAppVersionAndBuildNumber` to false, otherwise Xcode may change the build number on upload. |
| IPA kept as a CI artifact | Upload writes no local IPA: export separately with the `export` destination. |
| Signing | Manual signing with the installed profiles; do not pass `-allowProvisioningUpdates`, so CI never creates or changes certificates and profiles. |
| fastlane precheck (metadata guideline check) | Runs after upload, but its result only gates review submission, which is off; it does not affect the upload. Not replaced. If wanted later, it belongs to a full App Store Connect extension. |
| API key permissions | Same key and role (Developer or higher can upload). |

To verify during the parity run, check two things. First, confirm the export
option names and defaults in the installed Xcode (`xcodebuild -help`). Second,
confirm that precheck failures do not fail the current workflow.

Later, the Build Upload API in the native client can upload the exported IPA
itself, so the uploaded binary and the archived artifact are the same file.

## Open decisions

None at the moment. Open questions about incremental adoption are tracked in
[Incremental adoption](incremental-adoption.md#open-questions).
