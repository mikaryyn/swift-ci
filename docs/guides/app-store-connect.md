# App Store Connect

`SwiftCIAppStoreConnect` contains a minimal native client that covers only what
CI needs: ES256 API key tokens (CryptoKit), the Build Upload API, the App Store
metadata check, build processing status and, if needed, TestFlight group
assignment. Why it is not a full client is explained in
[design.md](../design.md#a-minimal-app-store-connect-client).

The build upload (`AppStoreConnect(apiKey:).uploadBuild(ipa:appID:)`) is a prototype and
supports iOS IPAs only. Its step reads the version and build number from the IPA. Before it
sends any bytes, it checks that the app has the IPA's bundle identifier and that the app has no
build upload of the same version and build number that has not failed. It ends when App Store Connect has
accepted the file, as `altool` does; processing continues in App Store Connect after the step.
The parts of the file are sent in parallel, `parallelUploads` at a time (default 6).
The client retries a request after a 429 response, and after a 5xx response or a lost connection except
for a `POST`, which could otherwise create a resource twice. A part is retried after a 5xx response or a lost
connection, and never after its pre-signed URL has expired.
The App Store metadata check (`AppStoreConnect(apiKey:).precheck(appID:)`) is a
prototype port of fastlane precheck. It reads the localizations of the app info that is being edited, the copyright and the
localizations of the newest App Store version, and checks them for text and links that App Review
often rejects: placeholder text, mentions of other platforms, promises of future features, test
wording, curse words, the copyright year and unreachable URLs. Its step logs each rule as passed or
failed, lists the findings and adds them to the run report as warnings. It only reads from App Store
Connect, so it needs read access only. A finding never fails the step; an App Store Connect error
throws.

```swift
let apiKey = try AppStoreConnectAPIKey.environment(
    keyID: "ABC123DEFG", keyFileVariable: "ASC_KEY_PATH", issuerVariable: "ASC_ISSUER_ID"
)
try await AppStoreConnect(apiKey: apiKey).uploadBuild(ipa: ipaURL, appID: "1234567890")
try await AppStoreConnect(apiKey: apiKey).precheck(appID: "1234567890")
```

Projects that need more of the API (editing metadata, testers and groups, users,
reviews) can use an independent extension built on that SDK. See
[Extension ideas](extensions.md#extension-ideas).
