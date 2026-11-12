# Running in CI and locally

The same command runs everywhere:

```sh
./ci test
```

- Jenkins calls `sh './ci test'`.
- GitLab CI uses `script: ["./ci test"]`.
- GitHub Actions uses `run: ./ci test`.
- Bitrise runs a single script step with `./ci test` as an intermediate
  migration stage.
- On a developer Mac, `./ci test` runs the same way. Commands should not
  assume CI-only state.
  Where a command needs CI-only resources (signing secrets, upload keys), it
  fails early with a clear message that names the missing environment variable.

## Artifacts

Each run keeps its files in one artifacts directory: the full log of each
command (`logs/<command>.log`), and the files that commands write with
`Artifacts.url(_:)` or that integrations keep. CI archives this directory.

- By default it is `artifacts/` in the working directory when the run starts.
- A script can choose another default with `SwiftCI(artifactsDirectory:)`.
- The environment variable `SWIFTCI_ARTIFACTS_DIR` wins over both, so a job
  can redirect the output without a code change, for example on Bitrise:
  `SWIFTCI_ARTIFACTS_DIR="$BITRISE_DEPLOY_DIR" ./ci test`.
- SwiftCI creates the directory when the first command starts. A path that
  exists and is not a directory fails the run with exit code 2, and the message
  names the setting.
- SwiftCI never deletes anything in it. Clean the CI workspace between builds,
  and delete the directory by hand locally.

Archive `artifacts/` in the CI system, even when the build fails, so that the
logs of a failed run are kept:

- Jenkins: `archiveArtifacts artifacts: 'artifacts/**', allowEmptyArchive: true`
- GitLab CI: `artifacts: { when: always, paths: [artifacts/] }`
- GitHub Actions: `actions/upload-artifact@v4` with `path: artifacts/` and
  `if: always()`

On a developer machine, add `artifacts/` to `.gitignore`, so that the full logs
do not show up in `git status`.

Test and coverage reports for the CI system are described in
[Reports for CI systems](reports.md).

## CI environment

`CI.environment` tells a script which CI system runs it and what it builds:
the branch, commit, tag, merge request, build number, build URL and job name.
SwiftCI detects it once, when `SwiftCI { }` starts, from the environment of the
run. A local run has `isCI` set to `false` and no build information.

```swift
let release = Command("release") {
    let ci = CI.environment
    if ci.isCI, let number = ci.buildNumber {
        log("Build \(number) of \(ci.branch ?? "?")")
    }
}
```

- Built-in detection covers GitHub Actions, GitLab CI, Bitrise, Jenkins
  (including the GitLab plugin and multibranch pipelines), other systems that
  set `CI=true`, and local runs.
- `SwiftCI(ciAdapters:)` adds adapters for other systems. They are asked before
  the built-in ones.
- The full log of each command records the result in one line, for example
  `CI: Jenkins, build 123, branch main`.
- A field-by-field reference of the variables and precedence used by each
  adapter is tracked in the
  [end-user documentation plan](../plans/end-user-documentation.md#d6-ci-environment-and-output-export-reference).

## Output export

`CI.export` passes a value to later steps of the CI job. It uses the mechanism
of the runner that the command runs in:

```swift
let archive = try await xcode.archiveAndExport(ipaFileName: "MyApp")
try await CI.export("MYAPP_IPA_PATH", archive.ipaURL.filePath)
```

| Runner | How the value is passed |
|---|---|
| Bitrise CLI (`ENVMAN_ENVSTORE_PATH` is set), on a Mac or on bitrise.io | `envman add`. Later steps of the Bitrise workflow see the value. This also applies to the Bitrise CLI inside another CI system, such as a Jenkins job. |
| GitHub Actions (`GITHUB_ENV` is set) | `NAME=value` is appended to `$GITHUB_ENV`, and to `$GITHUB_OUTPUT` when that is set too. Later steps see the variable, and a step with an `id` reads `steps.<id>.outputs.NAME`. |
| Anything else, such as GitLab CI, Jenkins or a local run | `NAME=value` is written to `artifacts/outputs.env`, one line per name. |

- Names must match `[A-Za-z_][A-Za-z0-9_]*`. Values are one line. To pass a
  text with line breaks, write it to a file with `Artifacts.url(_:)` and export
  the path of the file.
- Secrets cannot be exported. A value that contains a registered secret is a
  usage error (exit code 2), and the message does not show the value.
- `CI.export` is not a step. It logs `Exported NAME` in the current step. An
  export does not change the environment of the SwiftCI process, so use a Swift
  variable for the same script.
- A failing `envman` or an unwritable file fails the command.
- The dotenv file is kept between runs. A reused workspace may hold names from
  an earlier build, so clean the workspace before the build. A name that is
  exported again replaces its line.

GitLab CI reads the dotenv file as a report, so that later jobs see its
variables. GitLab limits dotenv reports to 5 KB and, by default, 20 variables on
self-managed instances:

```yaml
build:
  script: ["./ci build"]
  artifacts:
    reports:
      dotenv: artifacts/outputs.env

deploy:
  needs: ["build"]
  script: ['echo "$MYAPP_IPA_PATH"']
```

Jenkins has no native mechanism. A Jenkinsfile reads the file with the
`readProperties` step of the Pipeline Utility Steps plugin:

```groovy
sh './ci build'
def outputs = readProperties file: 'artifacts/outputs.env'
env.MYAPP_IPA_PATH = outputs.MYAPP_IPA_PATH
```
