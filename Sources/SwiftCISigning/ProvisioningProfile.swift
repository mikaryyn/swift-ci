import Foundation
import SwiftCI
#if canImport(Security)
import Security
#endif

/// The fields of a provisioning profile that the install needs.
struct ProvisioningProfile: Equatable, Sendable {
    var uuid: String
    var name: String
    var teamIdentifiers: [String]
    var teamName: String?
    /// `Entitlements["application-identifier"]`.
    var applicationIdentifier: String?
    /// `CreationDate`, if the profile has one. A missing or mistyped date is `nil`, not an error.
    var creationDate: Date?
    var expirationDate: Date
    /// The DER certificates that the profile was made for.
    var developerCertificates: [Data]

    /// Decodes the CMS-signed profile data in memory with the Security framework's CMS decoder, without a keychain, and
    /// reads its property list. `file` names the file in errors.
    ///
    /// Throws a ``BuildError`` that names `file`. A key that is missing or has the wrong type is named in the error. Data
    /// that is not a CMS message with a property list dictionary cannot be read.
    init(data: Data, file: String) throws {
        let unreadable = BuildError(
            message: "The provisioning profile \(file) can't be read. Check that it is a provisioning profile of Xcode "
                + "or fastlane match, and that it was not edited. Run fastlane match to create it again if it is not."
        )
        guard let content = Self.cmsContent(data) else { throw unreadable }
        let plist = try? PropertyListSerialization.propertyList(from: content, options: [], format: nil)
        guard let dictionary = plist as? [String: Any] else { throw unreadable }
        try self.init(propertyList: dictionary, file: file)
    }

    /// Reads the fields of the property list dictionary of a profile. Throws the missing-key error of ``init(data:file:)``
    /// for a key that is absent or has the wrong type.
    init(propertyList dictionary: [String: Any], file: String) throws {
        uuid = try Self.value(dictionary, key: "UUID", file: file, as: String.self)
        name = try Self.value(dictionary, key: "Name", file: file, as: String.self)
        teamIdentifiers = try Self.value(dictionary, key: "TeamIdentifier", file: file, as: [String].self)
        guard !teamIdentifiers.isEmpty else { throw Self.missingKey("TeamIdentifier", file: file) }
        teamName = dictionary["TeamName"] as? String
        let entitlements = dictionary["Entitlements"] as? [String: Any]
        applicationIdentifier = entitlements?["application-identifier"] as? String
        creationDate = dictionary["CreationDate"] as? Date
        expirationDate = try Self.value(dictionary, key: "ExpirationDate", file: file, as: Date.self)
        developerCertificates = try Self.value(dictionary, key: "DeveloperCertificates", file: file, as: [Data].self)
    }

    /// The content of a CMS message, when the data is one. Nil when the data is not a CMS message, or when the message
    /// has no content. Shared with ``MatchDecryption``, which checks that a decrypted profile is a property list.
    static func cmsContent(_ data: Data) -> Data? {
        #if canImport(Security)
        var decoder: CMSDecoder?
        guard CMSDecoderCreate(&decoder) == errSecSuccess, let decoder else { return nil }
        let updated = data.withUnsafeBytes { buffer -> OSStatus in
            guard let base = buffer.baseAddress else { return errSecParam }
            return CMSDecoderUpdateMessage(decoder, base, buffer.count)
        }
        guard updated == errSecSuccess, CMSDecoderFinalizeMessage(decoder) == errSecSuccess else { return nil }
        var content: CFData?
        guard CMSDecoderCopyContent(decoder, &content) == errSecSuccess, let content else { return nil }
        return content as Data
        #else
        return nil
        #endif
    }

    /// The value of `key` as `T`. Throws the missing-key error when the key is absent or has another type.
    private static func value<T>(_ dictionary: [String: Any], key: String, file: String, as type: T.Type) throws -> T {
        guard let value = dictionary[key] as? T else { throw missingKey(key, file: file) }
        return value
    }

    /// The error for a key that is missing or has the wrong type.
    private static func missingKey(_ key: String, file: String) -> BuildError {
        BuildError(
            message: "The provisioning profile \(file) has no valid \(key). Check that it is a provisioning profile of Xcode or fastlane match. Run fastlane match to create it again if it is not."
        )
    }
}
