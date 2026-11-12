# Migrating from Bitrise and fastlane

Typical Bitrise steps and fastlane actions, and their SwiftCI counterparts:

| Bitrise step / fastlane action | SwiftCI |
|---|---|
| `script` | `step(name) { … }` with Swift code, or `Tool(shellCommand:)` for shell |
| `xcode-test` / `scan` | `Xcode.test` (result bundle, coverage and test plan) |
| `xcode-archive` / `gym` | `Xcode.archiveAndExport`, a step itself. No `step` wrapper needed |
| `xcode-project-info` | `Xcode.getBuildSettings(target:)` and `Xcode.getVersion` |
| `set-xcode-build-number` / `increment_build_number` | `Xcode.setBuildNumber`; read the current value with `Xcode.getVersion` |
| `fastlane match` (readonly) | `Signing.installMatchAssets(using: .native)` |
| `deploy-to-itunesconnect-deliver` / `pilot` | `AppStoreConnect(apiKey:).uploadBuild(ipa:appID:)`, or the fastlane fallback **(planned)** |
| `slack` | `Slack.sendAttachment` for the same attachment format with a colored bar, or `Slack.send` for Block Kit; both are steps themselves |
| `trainer` | `Xcode.writeJUnitReport` from the result bundle |
| `before_run` / `after_run` workflows | Reusable `async throws` functions, and `cleanup { }` / `onFailure { }` handlers |
| `is_always_run` | `cleanup { … }` |
| `is_skippable` | `step(name, failure: .allowed) { … }`, or `step(name, allowsFailure: flag) { … }` when a flag of the run decides |
| `envman add` (pass values between steps) | `CI.export`, which passes a value to later steps. Inside one script, use Swift variables |
| `run_if` | `step(name, when: condition, skipReason: …) { … }` or `step(name, when: .onCI) { … }`, which log the skipped step, or an ordinary Swift `if` |

Migration can be gradual. Keep the existing CI server, replace one Bitrise
workflow or fastlane lane at a time with a SwiftCI command, and call that
command from the old configuration until nothing else remains.

While a Bitrise workflow still does part of the work, a SwiftCI command can
run it like any other tool, with a `Tool` and its own output filters. Values that
the workflow exports with `envman` are lost when it exits, so pass values in with
`environment:`, using names that the workflow does not define.

```swift
let release = Command("release") {
    try await xcode.archiveAndExport(ipaFileName: "MyApp")

    // The upload workflow is not ported yet.
    try await Tool(
        command: "bitrise",
        arguments: ["--ci", "run", "upload"],
        environment: ["BITRISE_DEPLOY_DIR": .text(Artifacts.directory.filePath)]
    ).run()
}
```
