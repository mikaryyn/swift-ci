#if os(macOS)
import Foundation

// The JSON:API documents of the Build Upload API. Only the fields that the upload reads or writes are declared. Apple's
// other fields are ignored when decoding.

/// A request document: `{"data": …}`.
struct RequestDocument<Resource: Encodable>: Encodable {
    let data: Resource
}

/// A response document: `{"data": …}`.
struct ResponseDocument<Attributes: Decodable>: Decodable {
    let data: ResponseResource<Attributes>
}

/// A resource in a response, with its ID and attributes.
struct ResponseResource<Attributes: Decodable>: Decodable {
    let id: String
    let attributes: Attributes
}

/// The identifier of a resource, as a relationship names it.
struct ResourceIdentifier: Encodable {
    let type: String
    let id: String
}

/// A to-one relationship: `{"data": {"type": …, "id": …}}`.
struct ToOneRelationship: Encodable {
    let data: ResourceIdentifier
}

/// The request that creates a build upload: `POST /v1/buildUploads`.
struct BuildUploadCreate: Encodable {
    let type = "buildUploads"
    let attributes: Attributes
    let relationships: Relationships

    struct Attributes: Encodable {
        let cfBundleShortVersionString: String
        let cfBundleVersion: String
        let platform: String
    }

    struct Relationships: Encodable {
        let app: ToOneRelationship
    }
}

/// The request that reserves the file of a build upload: `POST /v1/buildUploadFiles`.
struct BuildUploadFileCreate: Encodable {
    let type = "buildUploadFiles"
    let attributes: Attributes
    let relationships: Relationships

    struct Attributes: Encodable {
        let assetType: String
        let fileName: String
        let fileSize: Int
        let uti: String
    }

    struct Relationships: Encodable {
        let buildUpload: ToOneRelationship
    }
}

/// The request that commits the uploaded file: `PATCH /v1/buildUploadFiles/{id}`.
struct BuildUploadFileCommit: Encodable {
    let type = "buildUploadFiles"
    let id: String
    let attributes: Attributes

    struct Attributes: Encodable {
        let uploaded: Bool
        let sourceFileChecksums: SourceFileChecksums
    }

    struct SourceFileChecksums: Encodable {
        let file: Checksum
    }

    struct Checksum: Encodable {
        let algorithm: String
        let hash: String
    }
}

/// The attributes of an app that the upload reads: `GET /v1/apps/{id}?fields[apps]=bundleId`.
struct AppAttributes: Decodable {
    let bundleId: String
}

/// The attributes of a build upload. Every field is optional, because each response carries only some of them.
struct BuildUploadAttributes: Decodable {
    let cfBundleShortVersionString: String?
    let cfBundleVersion: String?
    let state: BuildUploadStateDetails?
}

/// The state of a build upload, with the errors, warnings and infos that App Store Connect reports for it.
struct BuildUploadStateDetails: Decodable {
    let state: String?
    let errors: [DeliveryIssue]?
    let warnings: [DeliveryIssue]?
    let infos: [DeliveryIssue]?
}

/// The attributes of the file of a build upload. `uploadOperations` comes with the reservation, and `assetDeliveryState`
/// with the reads of the state.
struct BuildUploadFileAttributes: Decodable {
    let uploadOperations: [UploadOperation]?
    let assetDeliveryState: AssetDeliveryStateDetails?
}

/// The delivery state of the uploaded file, with its errors and warnings.
struct AssetDeliveryStateDetails: Decodable {
    let state: String?
    let errors: [DeliveryIssue]?
    let warnings: [DeliveryIssue]?
}

/// An error, warning or info of App Store Connect, with its code and description.
struct DeliveryIssue: Decodable {
    let code: String?
    let description: String?
}

/// One request that sends a part of the file. Its `url` is pre-signed, so it carries credentials in its query.
struct UploadOperation: Decodable {
    let method: String
    let url: String
    let offset: Int
    let length: Int
    let partNumber: Int
    let requestHeaders: [RequestHeader]?
    /// An ISO 8601 date after which the part can no longer be sent. Absent when App Store Connect gives none.
    let expiration: String?
}

/// A header that the request of an upload operation must carry, exactly as given.
struct RequestHeader: Decodable {
    let name: String
    let value: String
}
#endif
