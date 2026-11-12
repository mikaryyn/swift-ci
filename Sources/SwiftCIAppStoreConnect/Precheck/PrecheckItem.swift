#if os(macOS)
import Foundation

/// One piece of App Store metadata that the metadata check examines: the value, the field it comes from and the name
/// that the findings print for it.
struct PrecheckItem: Equatable {
    /// Whether the value is text, which the word rules check, or a URL, which the URL rule checks.
    enum Kind: Equatable {
        case text
        case url
    }

    /// The fields of App Store metadata that the check reads.
    enum Field: CaseIterable {
        case appName
        case appSubtitle
        case privacyPolicyText
        case privacyPolicyURL
        case copyright
        case keywords
        case description
        case releaseNotes
        case supportURL
        case marketingURL

        /// The kind of value of the field.
        var kind: Kind {
            switch self {
            case .privacyPolicyURL, .supportURL, .marketingURL:
                return .url
            default:
                return .text
            }
        }

        /// The name of the field as fastlane prints it, without the locale. `U+F8FF` is the Apple logo of fastlane's text,
        /// shown by Apple's fonts; other fonts may show it as a blank or a box.
        var label: String {
            switch self {
            case .appName: return "app name"
            case .appSubtitle: return "app name subtitle"
            case .privacyPolicyText: return "\u{F8FF} tv privacy policy"
            case .privacyPolicyURL: return "privacy URL"
            case .copyright: return "copyright"
            case .keywords: return "keywords"
            case .description: return "description"
            case .releaseNotes: return "what's new"
            case .supportURL: return "support URL"
            case .marketingURL: return "marketing URL"
            }
        }
    }

    /// The field that the value comes from.
    let field: Field

    /// The name that the findings print for the item, such as `description: (en-US)`, or only the field name when the
    /// item has no locale, as the copyright has.
    let friendlyName: String

    /// The value, or nil when App Store Connect has none.
    let value: String?

    /// Whether an empty or missing value is fine. An optional item with no value passes every rule without being
    /// checked.
    let isOptional: Bool

    /// Creates an item.
    ///
    /// - Parameters:
    ///   - field: The field that the value comes from.
    ///   - locale: The locale of the localized value, such as `en-US`, or nil for a value without a locale.
    ///   - value: The value, or nil when App Store Connect has none.
    ///   - isOptional: Whether an empty or missing value is fine.
    init(field: Field, locale: String?, value: String?, isOptional: Bool = false) {
        self.field = field
        self.friendlyName = locale.map { "\(field.label): (\($0))" } ?? field.label
        self.value = value
        self.isOptional = isOptional
    }
}
#endif
