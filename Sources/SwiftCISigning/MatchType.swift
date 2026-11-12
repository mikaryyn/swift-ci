/// Distribution types of fastlane match. The raw value is the type argument of `fastlane match`. The folders of the
/// certificates and profiles in the match repository are derived from the type.
public enum MatchType: String {
    /// Signing for the App Store and TestFlight.
    case appstore
    /// Signing for ad-hoc distribution to the registered devices of the team.
    case adhoc
    /// Signing for in-house distribution with an Apple Developer Enterprise Program account.
    case enterprise
    /// Signing for development builds on the registered devices of the team.
    case development

    /// The name of the provisioning profile that fastlane match gives the app `bundleIdentifier`, such as
    /// `match AdHoc com.example.myapp`. It is the name to pass as `provisioningProfile` to `Xcode.archiveAndExport`:
    /// `provisioningProfile: MatchType.adhoc.profileName(for:)`.
    ///
    /// This is not a step. It builds a name and does not read or change anything.
    ///
    /// - Parameter bundleIdentifier: The bundle identifier of the app, for example `com.example.myapp`.
    /// - Returns: The profile name that fastlane match gives the profile of this type and identifier.
    public func profileName(for bundleIdentifier: String) -> String {
        "match \(profileTypeName) \(bundleIdentifier)"
    }
}
