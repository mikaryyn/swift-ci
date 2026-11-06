#if os(macOS)
import Foundation
import SwiftCI

extension AppStoreConnect {
    /// Reads the App Store metadata of the app `appID` and returns the items that the metadata check examines, in
    /// fastlane's order: the app info items of each localization, then the copyright of the newest App Store version and
    /// the version items of each localization.
    ///
    /// The newest App Store version is the one with the latest `createdDate`, in any state. When the app has no version,
    /// or no app info, a warning is logged and the items of that part are left out. Every page of the localization lists
    /// is read. The version and localization lists ask only for the attributes that the check uses; the app info list needs
    /// only its IDs.
    ///
    /// The method is a query, so it opens no step.
    ///
    /// - Parameter appID: The ID of the app in App Store Connect, such as `1234567890`.
    /// - Returns: The items to check, in order.
    func precheckItems(appID: String) async throws -> [PrecheckItem] {
        @Use var log: Log
        let version = try await newestVersion(appID: appID)
        let appInfo = try await firstAppInfo(appID: appID)
        var items: [PrecheckItem] = []
        if let appInfo {
            items += try await appInfoItems(appInfoID: appInfo.id)
        } else {
            log.warning("No app info of app \(appID) to check.")
        }
        if let version {
            items.append(PrecheckItem(field: .copyright, locale: nil, value: version.attributes.copyright))
            items += try await versionItems(versionID: version.id)
        } else {
            log.warning("No App Store version of app \(appID) to check.")
        }
        return items
    }

    /// The App Store version of `appID` with the latest `createdDate`, or nil when the app has no version for iOS.
    /// Throws when a `createdDate` is not an ISO 8601 timestamp.
    private func newestVersion(appID: String) async throws -> Resource<AppStoreVersionAttributes>? {
        let versions: [Resource<AppStoreVersionAttributes>] = try await getAll(
            "/v1/apps/\(appID)/appStoreVersions",
            query: [
                URLQueryItem(name: "filter[platform]", value: "IOS"),
                URLQueryItem(name: "fields[appStoreVersions]", value: "createdDate,copyright"),
            ]
        )
        var dated: [(version: Resource<AppStoreVersionAttributes>, date: Date)] = []
        for version in versions {
            guard let date = Self.date(fromISO8601: version.attributes.createdDate) else {
                throw BuildError(
                    message: "The App Store Connect version \(version.id) of app \(appID) has a createdDate that is not an ISO 8601 timestamp. Report this with the log."
                )
            }
            dated.append((version, date))
        }
        return dated.max { $0.date < $1.date }?.version
    }

    /// The first app info of `appID`, or nil when the app has none.
    private func firstAppInfo(appID: String) async throws -> Resource<EmptyAttributes>? {
        let list = try await get("/v1/apps/\(appID)/appInfos", as: DataList<Resource<EmptyAttributes>>.self)
        return list.data.first
    }

    /// The app info items of the app info `appInfoID`, for each of its localizations in API order.
    private func appInfoItems(appInfoID: String) async throws -> [PrecheckItem] {
        let localizations: [Resource<AppInfoLocalizationAttributes>] = try await getAll(
            "/v1/appInfos/\(appInfoID)/appInfoLocalizations",
            query: [
                URLQueryItem(
                    name: "fields[appInfoLocalizations]",
                    value: "locale,name,subtitle,privacyPolicyText,privacyPolicyUrl"
                ),
            ]
        )
        return localizations.flatMap { localization -> [PrecheckItem] in
            let attributes = localization.attributes
            return [
                PrecheckItem(field: .appName, locale: attributes.locale, value: attributes.name),
                PrecheckItem(field: .appSubtitle, locale: attributes.locale, value: attributes.subtitle, isOptional: true),
                PrecheckItem(field: .privacyPolicyText, locale: attributes.locale, value: attributes.privacyPolicyText),
                PrecheckItem(
                    field: .privacyPolicyURL, locale: attributes.locale, value: attributes.privacyPolicyUrl, isOptional: true
                ),
            ]
        }
    }

    /// The version items of the App Store version `versionID`, for each of its localizations in API order.
    private func versionItems(versionID: String) async throws -> [PrecheckItem] {
        let localizations: [Resource<AppStoreVersionLocalizationAttributes>] = try await getAll(
            "/v1/appStoreVersions/\(versionID)/appStoreVersionLocalizations",
            query: [
                URLQueryItem(
                    name: "fields[appStoreVersionLocalizations]",
                    value: "locale,keywords,description,whatsNew,supportUrl,marketingUrl"
                ),
            ]
        )
        return localizations.flatMap { localization -> [PrecheckItem] in
            let attributes = localization.attributes
            return [
                PrecheckItem(field: .keywords, locale: attributes.locale, value: attributes.keywords),
                PrecheckItem(field: .description, locale: attributes.locale, value: attributes.description),
                PrecheckItem(field: .releaseNotes, locale: attributes.locale, value: attributes.whatsNew),
                PrecheckItem(field: .supportURL, locale: attributes.locale, value: attributes.supportUrl),
                PrecheckItem(field: .marketingURL, locale: attributes.locale, value: attributes.marketingUrl, isOptional: true),
            ]
        }
    }

    /// The ISO 8601 timestamp `text` as a date. Fractional seconds are optional.
    private static func date(fromISO8601 text: String) -> Date? {
        let withFractionalSeconds = ISO8601DateFormatter()
        withFractionalSeconds.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFractionalSeconds.date(from: text) {
            return date
        }
        let withoutFractionalSeconds = ISO8601DateFormatter()
        withoutFractionalSeconds.formatOptions = [.withInternetDateTime]
        return withoutFractionalSeconds.date(from: text)
    }
}

/// The attributes of an App Store version that the check reads. `createdDate` is the ISO 8601 text of the response.
private struct AppStoreVersionAttributes: Decodable {
    let createdDate: String
    let copyright: String?
}

/// The attributes of an app info localization that the check reads.
private struct AppInfoLocalizationAttributes: Decodable {
    let locale: String
    let name: String?
    let subtitle: String?
    let privacyPolicyText: String?
    let privacyPolicyUrl: String?
}

/// The attributes of an App Store version localization that the check reads.
private struct AppStoreVersionLocalizationAttributes: Decodable {
    let locale: String
    let keywords: String?
    let description: String?
    let whatsNew: String?
    let supportUrl: String?
    let marketingUrl: String?
}

/// A resource of a JSON:API response: its ID and its attributes.
private struct Resource<Attributes: Decodable>: Decodable {
    let id: String
    let attributes: Attributes
}

/// The attributes of a resource that the check does not read. Only the ID is decoded.
private struct EmptyAttributes: Decodable {}

/// The `data` of a JSON:API response that holds one list.
private struct DataList<Item: Decodable>: Decodable {
    let data: [Item]
}
#endif
