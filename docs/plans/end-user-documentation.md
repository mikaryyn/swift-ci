# End-user documentation

Status: **accepted**. Tracks the documentation part of
[roadmap item 8](../../README.md#roadmap) and the documentation work that
accompanies earlier roadmap items.

## Goal

Give script authors and extension authors enough documentation to adopt
SwiftCI without reading its source, tests or implementation plans. The README
remains the overview and source of truth for the design and capability status.
Focused guides and generated API documentation provide the detail that would
make the README too long.

This plan tracks documentation only. A capability is documented as it exists;
the documentation must not promise planned API as current API.

## Audiences

- **Script authors** who create a SwiftPM executable package and write commands
  for their project.
- **CI maintainers** who invoke the script from Jenkins, GitLab CI, GitHub
  Actions, Bitrise or a local machine, archive its output and provide secrets.
- **Extension authors** who build integrations, filters, report writers or
  ready-made steps on the public core API.
- **Contributors** who need to know which user-facing documents must change
  with an API or behavior change.

## Documentation rules

- Examples use generic placeholders such as `MyApp` and
  `com.example.myapp`. They contain no real account, team, server or project
  data.
- Every public declaration has a useful doc comment. A method that performs
  work says whether it opens a step; a query says that it does not.
- Guides use public API only. Extension examples import `SwiftCI`, not SPI or
  `@testable` API.
- Examples do not pass secrets as command-line arguments or print revealed
  values.
- Platform and version requirements are stated next to instructions that
  depend on them.
- The README capability table and roadmap are updated in the same change that
  makes a capability current, changes its scope or defers it.
- Until a focused guide is published, the corresponding README section stays
  self-contained. Moving material out of the README must not leave a gap.

## Existing coverage

The following completed work is already described in Markdown and does not
need a duplicate backlog item:

- The README's [Artifacts](../../README.md#artifacts) section documents the
  default directory, configuration precedence, creation, full-log location,
  CI archiving and the persistent-directory warning.
- The README's [CI environment](../../README.md#ci-environment) and
  [Output export](../../README.md#output-export) sections document the public
  model, built-in systems, custom-adapter entry point, exporter mechanisms,
  validation, secret prohibition, and GitLab and Jenkins configuration.
- The README's [Concepts](../../README.md#concepts),
  [Extension API](../../README.md#extension-api-planned),
  [Output, filtering and secrets](../../README.md#output-filtering-and-secrets)
  and [Testing CI scripts and extensions](../../README.md#testing-ci-scripts-and-extensions)
  sections document the main `Tool`, `ProcessRunner`, `Secret`, filtering,
  redaction and testing behavior.
- The README's [Module layout](../../README.md#module-layout) and
  [Testing CI scripts and extensions](../../README.md#testing-ci-scripts-and-extensions)
  sections document the product split, product selection and public testing
  support. Contributor-only module boundaries remain in `AGENTS.md`.
- Public source doc comments document the individual APIs, their parameters,
  errors and step behavior.

The completed artifacts-directory, CI-environment, processes-and-secrets and
module-split implementation plans were removed after their remaining
end-user documentation work was recorded below. Deferred Linux work moved to
[Linux verification](linux-verification.md).

## Deliverables

### D0: Documentation structure and publishing

- Add a `Documentation.docc` catalog for each public library product when the
  public API is stable enough to publish.
- Publish generated DocC for released versions and link it from the README.
- Keep conceptual guides in one discoverable location, either DocC articles or
  `docs/`. Do not maintain two independent copies of the same guide.
- Add a documentation check to the release process: build DocC, check Markdown
  links and verify that examples compile where practical.

### D1: Getting started

Write a short path from an empty project to a working `./ci` command:

- Create the separate SwiftPM executable package.
- Add and pin the SwiftCI dependency, choose the required products, and explain
  which module to import for core, Xcode, signing, Slack and testing APIs.
- Add the repository-root wrapper script.
- Register and run one command locally.
- Add one CI invocation and archive `artifacts/` even on failure.
- Explain build caching and the supported Swift/Xcode versions.
- Explain that public path parameters are Foundation file `URL`s, show
  `URL(filePath:)`, and warn against passing `absoluteString` to tools.
- Link to the example CI package required by roadmap item 8.

The guide must have one minimal example before showing signing, notifications
or other optional integrations.

### D2: Commands, steps and failures

Write a conceptual guide that covers:

- Command registration, descriptions, listing and running several commands.
- Throwing steps, return values, nesting and allowed failures.
- Integration calls as steps and the `step:` name override.
- `cleanup` and `onFailure` registration, ordering and failure behavior.
- Catching a step error with ordinary Swift and how that affects the command.
- Exit codes and which failure wins when a body and handlers both fail.
- Command-line inputs, `--help` and `--verbose` when milestone M6 of
  [Script syntax](script-syntax.md#m6-descriptions-and-inputs) is completed.

### D3: Tools, process output and filters

Write the detailed process reference that is not appropriate for the README's
single `Tool` row:

- Prefer `Tool(command:arguments:)`; reserve `Tool(shellCommand:)` for
  user-supplied shell scripts.
- Explain program lookup in `PATH`, command paths, working directories,
  inherited and overridden environment variables, standard input and
  per-tool timeouts.
- Compare `run()`, `output()` and `result()`, including non-zero exit behavior.
- Explain stdout/stderr handling, filtering, full logs, captured output and the
  last stderr lines included in failures.
- State that captured output is not redacted and must be handled as sensitive
  data when it may contain a secret.
- Document timeout and cancellation behavior, including termination followed
  by forced termination.
- Show how an extension supplies a default filter and how a script replaces or
  extends it.

### D4: Secrets and safe diagnostics

Turn the existing README rules into a task-oriented guide without changing
their meaning:

- Declare environment and runtime-derived secrets.
- Explain validation at first use and the minimum length rule.
- Pass secrets through a tool's environment or standard input, never its
  arguments.
- Describe global redaction, percent-encoded and multiline forms, and the
  deliberate limits such as base64 and form encoding.
- Explain `Environment.writeToLog()`, its name/value heuristics and `reveal:`
  for false positives.
- Explain that `revealedValue()` is an escape hatch for an API boundary, not a
  value to log or interpolate into an error.
- Add a troubleshooting checklist for suspected leakage and credential
  rotation.

### D5: Artifacts and generated files

The README already covers ordinary use. Add a focused reference when more
report and distribution outputs land. It must include:

- The resolution and precedence rules for `Artifacts.directory`.
- The containment and parent-creation rules of `Artifacts.url(_:)`.
- Which integrations write user-kept files there and which files remain
  temporary.
- `Xcode.archiveAndExport` output names, replacement behavior,
  `includeDSYMZip`, the layout of the dSYM zip, and the warning behavior when
  an archive has no dSYMs.
- The stale-file risk when a CI workspace or artifacts directory is reused.
- A table of reports and generated files, with the API that creates each one
  and the CI configuration needed to publish it.

Update this guide whenever a new integration starts producing a file that the
user keeps.

### D6: CI environment and output export reference

Write the detailed reference that was previously available only in the
completed CI-environment implementation plan:

- A field-by-field matrix of the variables read by the GitHub Actions, GitLab
  CI, Bitrise and Jenkins adapters, including merge-request and tag cases.
- Detection order, empty-value behavior, numeric parsing, generic CI and local
  fallback behavior.
- The distinction between the detected CI system and the exporter of the
  innermost runner.
- Exporter selection order, including why `ENVMAN_ENVSTORE_PATH` takes
  precedence inside another CI system.
- A complete custom `CIAdapter` and `CIExporter` example and how to test it
  with `SwiftCITesting`.
- GitHub pull-request event-file behavior and the meaning of the reported
  commit.
- Dotenv persistence, size/variable limits, stale values and safe cleanup.
- The temporary `Bitrise.run` API, its input/output limitations and removal
  before 1.0.

The matrix must be updated in the same change as any built-in adapter's
variable names or precedence.

### D7: Testing scripts and extensions

Expand the existing README example into a guide that covers:

- `SwiftCITest.run` versus `SwiftCITest.withMocks`.
- Preparing queued and handler-based `ProcessRunnerMock` responses.
- Inspecting tools without revealing secret values.
- Choosing and preserving a test artifacts directory.
- Installing custom CI adapters in a test.
- Global-state isolation and the requirement to serialize these tests.
- Testing an independent extension through public API only.
- The boundary between `SwiftCITesting`, its testing-only SPI, and ordinary
  public API; users import only `SwiftCI` and `SwiftCITesting`.

### D8: Integration guides

Add one focused guide or DocC article for each substantial integration when
its public API stabilizes:

- Xcode build, archive/export, build settings, DocC and later testing.
- Signing and keychains, including native match versus the explicit fastlane
  fallback and credential transport.
- Slack incoming webhooks.
- Future App Store Connect, GitLab feedback, report and simulator modules.

Each guide states prerequisites, opens with the common path, lists artifacts,
shows expected failure recovery and links to the relevant fallback rather than
silently switching implementations.

### D9: Migration and operations

Keep the README migration table concise and add operational guides for:

- Incremental migration from Bitrise and fastlane in either direction
  described by [Incremental adoption](incremental-adoption.md).
- Building once and running the compiled CI executable in several later
  runner steps.
- CI cache recommendations and workspace cleanup.
- Diagnosing failures from the console log, full log and exit code.
- Upgrading SwiftCI, including breaking changes before 1.0 and migration notes
  for stable releases.

## Documentation required with future work

- Milestone M6 of the script-syntax plan updates D2 and the README command-line
  section in the same change.
- Completion of [Linux verification](linux-verification.md) updates platform
  requirements, conditional-import examples and known issues in the same
  change.
- Every implementation-plan capability updates its integration guide,
  artifacts/report table, capability status and example before it is marked
  complete.
- Removing the temporary Bitrise wrapper removes it from every guide and
  migration example in the same release.

## Completion criteria

This plan is complete when:

1. The README gives a reliable overview and a first successful run without
   requiring another document.
2. Every public product has published API documentation.
3. D1 through D9 are covered by one maintained guide each, allowing closely
   related deliverables to share a guide.
4. The CI environment variable matrix and generated-file table are current.
5. The example CI package and example extension build against the latest
   release.
6. Documentation links and DocC build in the release check.

## Open questions

None at the moment.
