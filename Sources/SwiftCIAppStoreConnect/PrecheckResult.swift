#if os(macOS)
import Foundation

/// The outcome of ``AppStoreConnect/precheck(appID:step:)``: the findings of the App Store metadata check.
public struct PrecheckResult: Sendable, Equatable {
    /// The findings, in the order of the rules and then of the items. Empty when the check found no potential
    /// problems.
    public let findings: [PrecheckFinding]
}

/// A potential problem in App Store metadata that App Review may reject, found by
/// ``AppStoreConnect/precheck(appID:step:)``.
public struct PrecheckFinding: Sendable, Equatable {
    /// The name of the rule that found the problem, as fastlane precheck names it, such as
    /// `No future functionality promises`.
    public let rule: String

    /// The field that has the problem, as fastlane precheck names it, such as `what's new: (en-US)`. A field without a
    /// locale, such as `copyright`, has no locale in its name.
    public let field: String

    /// Why the field was found, as fastlane precheck words it, such as `found: coming soon`, `missing copyright year`
    /// or `HTTP 404: https://example.com/support`.
    public let reason: String
}
#endif
