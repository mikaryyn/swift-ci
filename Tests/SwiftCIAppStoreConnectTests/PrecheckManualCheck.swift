#if os(macOS)
@testable import SwiftCI
@testable import SwiftCIAppStoreConnect
@testable import SwiftCITestSupport
@_spi(Testing) import SwiftCI
import Foundation
import Testing

extension GlobalStateTests {
    /// Runs the App Store metadata check against the real App Store Connect API, for the app in
    /// `SWIFTCI_MANUAL_PRECHECK_APP_ID`. It is skipped unless that variable is not empty:
    ///
    ///     SWIFTCI_MANUAL_PRECHECK_APP_ID=<app id> ASC_KEY_ID=<key id> ASC_ISSUER_ID=<issuer> ASC_KEY_FILE=<path to .p8> \
    ///         swift test --disable-sandbox --filter PrecheckManualCheck
    ///
    /// The key is read as the deploy reads it: the key ID from `ASC_KEY_ID`, and the issuer ID and the path of the `.p8`
    /// file from `ASC_ISSUER_ID` and `ASC_KEY_FILE`. The check only reads from App Store Connect and sends HEAD requests to
    /// the URLs of the app. Its console lines are printed as in a deploy. The test fails if the check throws; findings do
    /// not fail it.
    @Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["SWIFTCI_MANUAL_PRECHECK_APP_ID"]?.isEmpty == false))
    struct PrecheckManualCheck {
        @Test func precheckReadsTheAppFromAppStoreConnect() async throws {
            let restore = isolatedGlobalState()
            defer { restore() }
            registerDependencies()
            let environment = ProcessInfo.processInfo.environment
            let appID = try #require(environment["SWIFTCI_MANUAL_PRECHECK_APP_ID"])
            let keyID = environment["ASC_KEY_ID"] ?? ""
            guard !keyID.isEmpty else {
                Issue.record("Set ASC_KEY_ID to the key ID of the App Store Connect API key.")
                return
            }
            let key = try AppStoreConnectAPIKey.environment(
                keyID: keyID, keyFileVariable: "ASC_KEY_FILE", issuerVariable: "ASC_ISSUER_ID"
            )

            let exitCode = await runSwiftCI(arguments: ["precheck"], artifactsDirectory: temporaryArtifactsDirectory()) {
                command(Command("precheck") {
                    try await AppStoreConnect(apiKey: key).precheck(appID: appID)
                })
            }

            #expect(exitCode == 0, "The check threw. The console shows the error above.")
        }
    }
}
#endif
