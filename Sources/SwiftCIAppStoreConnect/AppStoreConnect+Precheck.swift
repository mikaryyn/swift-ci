#if os(macOS)
import Foundation
import SwiftCI

extension AppStoreConnect {
    /// Checks the App Store metadata of an app for text and links that App Review often rejects. The check is the one
    /// of fastlane precheck: placeholder text, mentions of other platforms, promises of future features, test wording,
    /// curse words, the copyright year and unreachable URLs.
    ///
    /// The check reads the app info localizations, the copyright and the localizations of the newest App Store version.
    /// Then it runs each rule on every item that the rule handles. The console shows one line per rule, `Passed:` or
    /// `Failed:`. Each finding is added to the run report as a warning, so the summary of the run lists it.
    ///
    /// Findings never throw, and they do not fail the step or the command. Only an error that stops the check throws,
    /// such as an App Store Connect error or a `createdDate` that cannot be read.
    ///
    /// Opens a step named "Check App Store metadata" when called at the top level of a command. `step` renames it.
    ///
    /// - Parameters:
    ///   - appID: The ID of the app in App Store Connect, such as `1234567890`.
    ///   - name: The name of the step, if it is not the default.
    /// - Returns: The findings, in the order of the rules and then of the items. Empty when the check found no
    ///   potential problems.
    @discardableResult
    public func precheck(appID: String, step name: String? = nil) async throws -> PrecheckResult {
        try await step(default: "Check App Store metadata", name: name) {
            try await checkMetadata(appID: appID)
        }
    }

    /// Runs every rule on the items of the app, logs the outcome and returns the findings. Does not open a step.
    private func checkMetadata(appID: String) async throws -> PrecheckResult {
        @Use var log: Log
        let items = try await precheckItems(appID: appID)
        var findings: [PrecheckFinding] = []
        for rule in PrecheckRules.all {
            var ruleFindings: [PrecheckFinding] = []
            for item in items {
                if let reason = await rule.failure(for: item) {
                    ruleFindings.append(PrecheckFinding(rule: rule.name, field: item.friendlyName, reason: reason))
                }
            }
            if ruleFindings.isEmpty {
                log("Passed: \(rule.name)")
            } else {
                log.warning("Failed: \(rule.name) -> \(rule.description)")
            }
            findings += ruleFindings
        }

        if findings.isEmpty {
            log("App Store metadata check found no potential problems.")
        } else {
            for finding in findings {
                Report.warning("App Store metadata: \(finding.field): \(finding.reason)")
            }
            log("App Store metadata check found potential problems. They do not fail the build.")
        }
        return PrecheckResult(findings: findings)
    }
}
#endif
