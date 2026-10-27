# Prior art: a Swift-native iOS/macOS CI toolkit

*Research snapshot, October 2026. Status and GitHub star counts are approximate.
They come from project pages and release sources checked during 2025 and 2026.
Stars do not measure adoption. Check release pages before you choose
dependencies.*

## Bottom line

A pure-Swift toolkit is plausible as a thin, composable automation layer over
Apple's existing tools. It is a much less convincing prospect as a full,
drop-in replacement for fastlane's signing, portal management, metadata
delivery, upload, and plugin ecosystem. The best opportunity is a small typed
toolkit that runs `xcodebuild`/`xcrun`, produces useful diagnostics, supports a
few stable integrations, and can delegate gaps to fastlane or Transporter.

## Comparison

| Project | Approach and current signal |
|---|---|
| [fastlane](https://github.com/fastlane/fastlane) (Ruby, ~42k stars) | The broad, established automation suite (2.228.0 in Dec. 2025). `gym` builds/archives/exports, `scan` runs tests, `match` synchronizes signing assets, `pilot` handles TestFlight, `deliver` handles App Store delivery and metadata. The main compatibility target. [Docs](https://docs.fastlane.tools/actions/) |
| [Fastlane.swift](https://docs.fastlane.tools/getting-started/ios/fastlane-swift/) | Still labeled beta. Lanes are written in Swift, but the Ruby runtime, plugins and maintenance footprint remain. Changing the lane language alone gave little reason to migrate. |
| [Bitrise](https://github.com/bitrise-io/bitrise) (CLI, ~900 stars) | Hosted mobile CI with `bitrise.yml`, a local CLI runner and a versioned Step library (often Go, not exclusively). Useful model for composable, versioned actions; adopting it means adopting its workflow model. [StepLib](https://github.com/bitrise-io/bitrise-steplib) |
| [Xcode Cloud](https://developer.apple.com/xcode-cloud/) | Apple-hosted CI integrated with Xcode and App Store Connect (build, test, analyze, archive, TestFlight). Lowest-friction Apple option, but not a reusable toolkit or general runner. |
| [GitHub Actions](https://docs.github.com/en/actions) | Hosted/self-hosted runners with YAML workflows. Supplies orchestration, not an Apple build/release abstraction: teams still manage Xcode versions, secrets, signing and logs. |
| [Codemagic](https://codemagic.io/) + [CLI tools](https://github.com/codemagic-ci-cd/cli-tools) (~500 stars) | Hosted mobile CI; its open-source CLI tools (Python) cover signing, building and publishing. Shows that even a mobile CI vendor pairs a workflow service with platform-specific helpers. |
| [Tuist](https://github.com/tuist/tuist) (~5.8k stars) and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (~8.9k stars) | Swift tooling for project generation and project workflows. These tools are adjacent, not fastlane replacements. They show demand for typed, declarative Apple tooling. |
| [Mint](https://github.com/yonaskolb/Mint), [mise](https://github.com/jdx/mise), [xcodes](https://github.com/XcodesOrg/xcodes) | Tool bootstrap, version pinning and Xcode selection. Solve reproducibility around a toolkit rather than the workflow itself. |
| [xcbeautify](https://github.com/cpisciotta/xcbeautify) (Swift), [xcpretty](https://github.com/xcpretty/xcpretty) (Ruby) | Build-log formatters. Log presentation is a bounded, useful component. Prefer integrating over writing a second parser of Xcode's evolving output. |
| [Swiftlane](https://github.com/onmyway133/Swiftlane) / Puma (~700 stars) | Earlier Swift fastlane alternative wrapping `xcodebuild`, signing and App Store Connect. Last release ~4 years old; Puma archived. It shows the cost of keeping pace with Xcode and Apple service changes. |
| [Sake](https://github.com/kattouf/Sake), [swift-sh](https://github.com/mxcl/swift-sh), [Marathon](https://github.com/JohnSundell/Marathon) | Swift task runners / scripting. Sake is active (1.0.3, Nov. 2025); Marathon is deprecated. Scripting convenience does not replace reliable signing, uploads or CI integration. |
| SwiftPM command plugins, [ArgumentParser](https://github.com/apple/swift-argument-parser), [swift-subprocess](https://github.com/swiftlang/swift-subprocess) | Plugins run sandboxed and need declared write/network permissions. That makes them a poor default home for signing and upload, but fine as a thin dispatcher. ArgumentParser is mature; swift-subprocess reached 1.0 beta in July 2025. [Plugin permissions](https://developer.apple.com/documentation/packagedescription/pluginpermission) |
| [AppStoreConnect-Swift-SDK](https://github.com/AvdLee/appstoreconnect-swift-sdk) (~1.7k stars), community `asc` CLIs | Swift access to App Store Connect API resources. Reduces API-model work; does not solve signing or every upload/release workflow. |
| [Danger Swift](https://github.com/danger/swift), [Rugby](https://github.com/swiftyfinch/Rugby) | Adjacent tools (PR review automation, CocoaPods caching), not evidence of a mature Swift-native fastlane ecosystem. |

## Apple tooling and implementation risks

**Signing is the hardest part to replace safely.** In Git mode, `match` stores
encrypted certificates, keys and profiles. Current fastlane distinguishes two
formats. **v2** (default) uses AES-256-GCM with PBKDF2-HMAC-SHA256. Legacy
**v1** uses AES-256-CBC with OpenSSL's `EVP_BytesToKey` (MD5, SHA-256
fallback).
[Implementation](https://github.com/fastlane/fastlane/blob/master/match/lib/match/encryption/encryption.rb) ·
[docs](https://docs.fastlane.tools/actions/match/). A native implementation must
stay compatible with existing repositories, be tested against fixtures of both
formats, report wrong passwords with a clear message, and handle keychain
creation and unlock, partition lists, profile placement, multiple targets and
certificate validity. Never invent a new "match-compatible" format.

**JWT signing is tractable but easy to get wrong.** App Store Connect API tokens
use ES256 with a `.p8` key, `kid`, `iss`, `iat`, `exp` (max 20 minutes) and
audience `appstoreconnect-v1`. CryptoKit's P-256 signature must be emitted as raw
`r || s` (`rawRepresentation`), not DER. Test encoding, clock skew, expiry and
token redaction. [Apple docs](https://developer.apple.com/documentation/AppStoreConnectAPI/generating-tokens-for-api-requests)

**Uploading is changing.** Apple introduced the App Store Connect Build Upload
API at WWDC25 (API 4.1). A smaller first step is wrapping `xcrun iTMSTransporter`
(or `altool`, still listed for App Store uploads) with API-key auth. `altool`'s
*notarization* was retired in Nov. 2023 in favor of `xcrun notarytool`, which is
not an App Store upload tool.
[WWDC25](https://developer.apple.com/videos/play/wwdc2025/324/) ·
[Build uploads](https://developer.apple.com/documentation/appstoreconnectapi/build-uploads) ·
[upload guidance](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds/) ·
[TN3147](https://developer.apple.com/documentation/technotes/tn3147-migrating-to-the-latest-notarization-tool)

## Implications for SwiftCI

A generic, macOS-focused Swift toolkit is sound. It makes Apple's own tools
safer and easier to compose, with typed inputs, no shell-string interpolation,
streamed logs, correct exit codes and structured summaries.

Start with stable, bounded capabilities: build, test, archive and export; Xcode
selection and preflight checks; xcresult handling; version and build numbers;
Slack; and a Transporter wrapper.

For signing and App Store Connect, integrate before reimplementing. Keep the
fastlane fallback optional, visible and explicit. Add native versions only with
compatibility fixtures and real-world integration tests.

Prefer an executable over a plugin. A normal executable is the better building
block for CI, and a SwiftPM plugin may delegate to it.

A toolkit is not a CI service. Jenkins, GitHub Actions, GitLab CI, Bitrise,
Codemagic and Xcode Cloud still own runners, secrets, scheduling and log
storage.

Do not promise a drop-in fastlane replacement until the long tail (account
behavior, metadata, retries, Apple changes) is covered.
