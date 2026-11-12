#if os(macOS)
import Foundation

/// One rule of the App Store metadata check, with the names that its findings print and the fields it checks.
struct PrecheckRule: Sendable {
    /// The name of the rule as fastlane prints it, such as `No curse words`.
    let name: String

    /// The description of the rule as fastlane prints it, which says what a failure means.
    let description: String

    /// The fields that the rule checks. All of them hold the same kind of value, text or URL, which `check` expects.
    let fields: Set<PrecheckItem.Field>

    /// Returns the failure text of a value, such as `found: coming soon`, or nil when the value passes.
    let check: @Sendable (String) async -> String?

    /// Whether the rule checks `item`. A rule does not check an item from another field.
    func handles(_ item: PrecheckItem) -> Bool {
        fields.contains(item.field)
    }

    /// The failure text of `item`, or nil when the item passes or the rule does not handle it.
    ///
    /// An optional item with a missing or empty value passes without `check` being called. A required item with a
    /// missing value is checked as an empty string.
    func failure(for item: PrecheckItem) async -> String? {
        guard handles(item) else { return nil }
        let value = item.value ?? ""
        if item.isOptional && value.isEmpty {
            return nil
        }
        return await check(value)
    }
}
#endif
