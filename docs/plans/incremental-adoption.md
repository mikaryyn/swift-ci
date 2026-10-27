# Incremental adoption

Status: **accepted**. Part of the
[implementation plan](implementation-plan.md).

Projects rarely replace a working CI setup in one go. SwiftCI should support
moving one step at a time from an existing workflow runner (Bitrise CLI,
fastlane lanes, shell scripts), in either direction. In inside-out adoption,
the existing runner calls SwiftCI for individual steps. In outside-in
adoption, SwiftCI is the entry point and calls the existing runner for parts
that are not yet ported.

## Inside-out: the existing runner calls SwiftCI

The contents of individual script steps are replaced with SwiftCI commands,
for example `./ci lint-gate` or `./ci junit`. The runner keeps orchestrating.
Its configuration gets thinner until it mostly consists of `./ci` calls, and
then the configuration is removed.

This approach suits projects where the runner is also the platform and stays,
such as Bitrise.io or another hosted CI. SwiftCI replaces script steps without
taking over the run.

The drawbacks are that the runner keeps control of failure handling,
conditions (`is_always_run`, `is_skippable`) and logs until the end, and that
the runner's configuration changes many times. The CI system's job definitions
change once more, at the end.

## Outside-in: SwiftCI calls the existing runner

CI jobs call `./ci <command>` from the start. At first, the command does
little more than run the old workflow, for example with
`bitrise --ci run <workflow>`. Work then moves out of the runner from the
edges inward:

1. Wrap the whole workflow. The entry point, keychain unlock, failure
   notifications, exit codes, logs, secret redaction and the step summary are
   native from day one.
2. Replace the workflows that run before and after the core work (setup,
   signing assets, naming, manifests, notifications) one at a time. SwiftCI
   then calls only the remaining core workflow, for example the archive.
3. Replace the core workflow and delete it from the runner's configuration.

This approach suits projects where another system (Jenkins, GitLab CI, GitHub
Actions) orchestrates the jobs and the end state is `./ci <command>`. Job
definitions change only once, and each job compiles the CI package only once.

### Things to watch out for

- **State does not flow back.** Values the runner shares between its own
  steps (Bitrise `envman`, fastlane lane context) are lost when the runner
  exits. Split work only at points where the state lives in files (artifacts
  directory, export options plist), or compute the values (version, artifact
  name, bundle ID) in SwiftCI.
- **Passing values in.** SwiftCI passes inputs as process environment
  variables. Variables declared in the runner's own configuration may take
  precedence over the process environment (to verify for Bitrise
  `app: envs:`). Use names the configuration does not define.
- **Shared directories.** Point the runner's output directory (for example
  `BITRISE_DEPLOY_DIR`) at SwiftCI's artifacts directory, so both write to the
  same place.
- **Splitting large workflows.** Runner configurations built from small,
  reusable workflows (`before_run` / `after_run` chains) are easy to migrate
  step by step. A monolithic workflow may need to be split inside the runner
  first.

## What SwiftCI needs

Generic capabilities that make both directions work. Most are useful beyond
migration.

| Capability | Needed for | Notes |
|---|---|---|
| Granular commands with explicit inputs | Inside-out | Project commands sized like single steps; inputs from arguments or environment variables (`@Env`) so runner outputs such as `BITRISE_XCRESULT_PATH` can be read. |
| Output export adapters | Inside-out | Export values to later steps: `envman add` (Bitrise), `$GITHUB_OUTPUT` / `$GITHUB_ENV` (GitHub Actions), dotenv report (GitLab CI). Selected by CI environment detection. Core, see [Decisions](#decisions). |
| Configurable artifacts directory | Both | Can be set to the runner's output directory, e.g. `BITRISE_DEPLOY_DIR`. |
| Build once, run the binary | Inside-out | Repeated `swift run` costs seconds per step. A first step builds; later steps run `.build/debug/ci` directly. Documented in the CI package template. |
| Report persisted across invocations | Inside-out | Each `./ci` run writes its findings to the artifacts directory; a final `./ci report` merges them into the summary or merge request comment. |
| Interim tool wrappers | Outside-in | Small wrappers with default output filters for running the existing tools: `bitrise --ci run`, `danger`, `fastlane`. Explicit, never automatic fallbacks. |

The interim tool wrappers are temporary by nature. The fastlane wrapper is
already part of the signing module's explicit fallback. The Bitrise wrapper
is temporary core API (see [Decisions](#decisions)). The Danger wrapper is
project glue, and `SwiftCIGitLab` replaces it in Phase 2.

## Strategy for the reference project

The reference project from the [implementation plan](implementation-plan.md)
is orchestrated by Jenkins, so Phase 1 uses **outside-in** adoption:

1. Each Jenkinsfile (and each job defined in the Jenkins UI) switches to a
   `./ci <command>` that wraps the matching Bitrise workflow.
2. Its `before_run` / `after_run` workflows are replaced natively one at a
   time, starting with keychain unlock, setup, naming and notifications.
3. The core workflow (archive and export, test) is replaced last, after a
   parity run (see [Parity checks](implementation-plan.md#parity-checks)).

Danger and `fastlane match` keep running as interim tools, called explicitly
from SwiftCI, until Phases 2 and 3.

## Decisions

- **CI environment detection and output export are in the core.** Each CI
  system gets one small adapter behind a public protocol. The adapters need no
  dependencies and work on Linux. Other parts of the core and modules use them
  for the artifacts location, report rendering, merge request lookup in
  `SwiftCIGitLab`, and log groups. The built-in adapters cover Jenkins
  (including GitLab plugin variables), GitLab CI, GitHub Actions, Bitrise
  (including the `envman` output adapter) and local runs. Extensions can
  register adapters for other systems.
- **The Bitrise wrapper is in the core, as temporary API.** It runs
  `bitrise --ci run <workflow>` with a default output filter. It exists only
  to support outside-in migration. It will be removed once the reference
  project has left Bitrise, and in any case before 1.0. Its doc comments, the
  README capability table and this document all say that it is temporary.
  The Bitrise CI environment adapter (detection and `envman` output export) is
  permanent and not affected.

## Open questions

None at the moment.
