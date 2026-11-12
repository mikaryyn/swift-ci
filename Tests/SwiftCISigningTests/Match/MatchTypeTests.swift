import SwiftCISigning
import Testing

@Suite struct MatchTypeTests {
    /// The profile names are the ones that fastlane match gives, and that the fastlane install looks up.
    @Test func profileNameUsesTheProfileTypeOfEachMatchType() {
        let identifier = "com.example.myapp"

        #expect(MatchType.appstore.profileName(for: identifier) == "match AppStore com.example.myapp")
        #expect(MatchType.adhoc.profileName(for: identifier) == "match AdHoc com.example.myapp")
        #expect(MatchType.enterprise.profileName(for: identifier) == "match InHouse com.example.myapp")
        #expect(MatchType.development.profileName(for: identifier) == "match Development com.example.myapp")
    }

    @Test func profileNameCanBeUsedAsAFunctionReference() {
        let profileName: (String) -> String = MatchType.adhoc.profileName(for:)

        #expect(profileName("com.example.myapp") == "match AdHoc com.example.myapp")
    }
}
