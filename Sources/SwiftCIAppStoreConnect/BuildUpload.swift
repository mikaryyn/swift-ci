#if os(macOS)
import Foundation

/// A build of an app that was uploaded to App Store Connect.
///
/// `state` is the state that App Store Connect reported when it accepted the uploaded file, `processing` or `complete`.
/// Processing of the build continues in App Store Connect after the upload returns.
public struct BuildUpload: Sendable, Equatable {
    /// The ID of the build upload in App Store Connect.
    public let id: String
    /// The ID of the app that the build was uploaded to.
    public let appID: String
    /// The bundle identifier of the app in the IPA.
    public let bundleIdentifier: String
    /// The version of the build, `CFBundleShortVersionString`, such as `1.2.3`.
    public let version: String
    /// The build number, `CFBundleVersion`.
    public let build: String
    /// The state of the build upload when App Store Connect accepted the file: `processing` or `complete`.
    public let state: BuildUploadState
}

/// The state of a build upload in App Store Connect.
public enum BuildUploadState: Sendable, Equatable {
    /// App Store Connect is waiting for the uploaded file. The upload step waits past this state, so it never returns it.
    case awaitingUpload
    /// App Store Connect has accepted the file and is processing the build.
    case processing
    /// App Store Connect failed the upload. The upload step throws instead of returning it, with the errors in its
    /// error.
    case failed
    /// App Store Connect has finished processing the build.
    case complete
    /// A state that this version of SwiftCI does not know, with the value that App Store Connect sent. The upload step
    /// waits past it, so it never returns it.
    case unknown(String)

    /// The state of the value that App Store Connect sends.
    init(apiValue: String) {
        switch apiValue {
        case "AWAITING_UPLOAD": self = .awaitingUpload
        case "PROCESSING": self = .processing
        case "FAILED": self = .failed
        case "COMPLETE": self = .complete
        default: self = .unknown(apiValue)
        }
    }
}
#endif
