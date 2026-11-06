#if os(macOS)
@testable import SwiftCI
@testable import SwiftCIAppStoreConnect
@testable import SwiftCITestSupport
import CryptoKit
import Foundation
import SwiftCITesting
import Testing

extension GlobalStateTests {
    /// The rules and the text matching of the App Store metadata check. They are pure functions, so the tests use no
    /// network and no mocks. The current year is passed in, so the copyright tests do not depend on the date.
    @Suite struct PrecheckRulesTests {
        /// The rule named `name` among the rules of `currentYear`.
        static func rule(_ name: String, currentYear: Int = 2026) throws -> PrecheckRule {
            try #require(PrecheckRules.rules(currentYear: currentYear).first { $0.name == name })
        }

        /// A text item of `field` in the locale `en-US`.
        static func text(_ field: PrecheckItem.Field, _ value: String?, optional: Bool = false) -> PrecheckItem {
            PrecheckItem(field: field, locale: "en-US", value: value, isOptional: optional)
        }

        /// The lowercase hex SHA-256 digest of the UTF-8 bytes of `word`.
        static func sha256Hex(_ word: String) -> String {
            SHA256.hash(data: Data(word.utf8)).map { String(format: "%02x", $0) }.joined()
        }

        /// A rule whose check reports `called` for every value, to show whether the dispatch called it.
        static func probe(kind: PrecheckItem.Kind, field: PrecheckItem.Field) -> PrecheckRule {
            PrecheckRule(name: "probe", description: "probe", kind: kind, fields: [field], check: { _ in "called" })
        }

        // MARK: Catalogue

        @Test func rulesAreTheSevenNonURLRulesInFastlaneOrderWithFastlaneNames() {
            let rules = PrecheckRules.rules(currentYear: 2026)

            #expect(rules.map { "\($0.name) -> \($0.description)" } == [
                "No negative  sentiment -> mentioning  in a way that could be considered negative",
                "No placeholder text -> using placeholder text (e.g.:\"lorem ipsum\", \"text here\", etc...)",
                "No mentioning  competitors -> mentioning other platforms, like Android or Blackberry",
                "No future functionality promises -> mentioning features or content that is not currently available in your app",
                "No words indicating test content -> using text indicating this release is a test",
                "No curse words -> including words that might be considered objectionable",
                "No incorrect or missing copyright date -> using a copyright year in the future, or missing a copyright year",
            ])
            #expect(PrecheckRules.all.map(\.name) == rules.map(\.name))
        }

        @Test func fieldsHaveTheKindsOfTheFastlaneItems() {
            #expect(PrecheckItem.Field.allCases.count == 10)
            #expect(Set(PrecheckItem.Field.allCases.filter { $0.kind == .url }) == [.privacyPolicyURL, .supportURL, .marketingURL])
        }

        @Test func friendlyNamesFollowFastlane() {
            #expect(Self.text(.description, "x").friendlyName == "description: (en-US)")
            #expect(PrecheckItem(field: .privacyPolicyText, locale: "en-US", value: nil).friendlyName == " tv privacy policy: (en-US)")
            #expect(PrecheckItem(field: .releaseNotes, locale: "fi", value: nil).friendlyName == "what's new: (fi)")
            #expect(PrecheckItem(field: .marketingURL, locale: "fi", value: nil).friendlyName == "marketing URL: (fi)")
            #expect(PrecheckItem(field: .copyright, locale: nil, value: "© 2026").friendlyName == "copyright")
        }

        // MARK: Word rules

        @Test func wordRuleFindsAPhraseAndPassesOtherText() async throws {
            let rule = try Self.rule("No future functionality promises")

            #expect(await rule.failure(for: Self.text(.description, "Dark mode is coming soon.")) == "found: coming soon")
            #expect(await rule.failure(for: Self.text(.description, "Available now.")) == nil)
        }

        @Test func wordRuleIgnoresCase() async throws {
            let rule = try Self.rule("No future functionality promises")

            #expect(await rule.failure(for: Self.text(.description, "ARRIVING SHORTLY")) == "found: arriving shortly")
        }

        @Test func wordRuleFindsAPhraseInsideALongerWord() async throws {
            let rule = try Self.rule("No words indicating test content")

            #expect(await rule.failure(for: Self.text(.description, "We are contesting the result")) == "found: testing")
        }

        @Test func foundPhrasesAreInListOrderNotTextOrder() {
            let found = textMatch(
                "beta test then alpha test", phrases: ["alpha test", "beta test"], allowed: []
            )

            #expect(found == "found: alpha test, beta test")
        }

        @Test func negativeSentimentFindsFastlaneWords() async throws {
            let rule = try Self.rule("No negative  sentiment")

            #expect(await rule.failure(for: Self.text(.description, "Slow iPad on launch")) == "found: slow ipad")
            #expect(await rule.failure(for: Self.text(.description, "This iOS bug is fixed")) == "found: ios bug")
            #expect(await rule.failure(for: Self.text(.description, "Works on iOS")) == nil)
        }

        @Test func placeholderTextFindsLoremIpsum() async throws {
            let rule = try Self.rule("No placeholder text")

            #expect(await rule.failure(for: Self.text(.description, "Lorem Ipsum dolor sit amet")) == "found: lorem ipsum")
        }

        @Test func competitorRuleAllowsGoogleAnalyticsAndDrive() async throws {
            let rule = try Self.rule("No mentioning  competitors")

            #expect(await rule.failure(for: Self.text(.description, "Google Analytics only")) == nil)
            #expect(await rule.failure(for: Self.text(.description, "Google Drive and Google Analytics")) == nil)
            #expect(await rule.failure(for: Self.text(.description, "Google Analytics and Google")) == "found: google")
            #expect(await rule.failure(for: Self.text(.description, "Google Drive, Android")) == "found: android")
        }

        @Test func testWordRuleFindsTestingButNotOtherWords() async throws {
            let rule = try Self.rule("No words indicating test content")

            #expect(await rule.failure(for: Self.text(.description, "This is just a test")) == "found: just a test")
            #expect(await rule.failure(for: Self.text(.description, "Release notes")) == nil)
        }

        @Test func emptyAndWhitespaceTextPassWordRules() {
            #expect(textMatch("", phrases: ["testing"], allowed: []) == nil)
            #expect(textMatch(" \n\t ", phrases: ["testing"], allowed: []) == nil)
        }

        // MARK: Curse words

        @Test func curseWordFromFastlaneReadmeIsFound() {
            let hashes: Set<String> = ["31be3624bc03aa68bc050cce316dc80cfe1ace3d0f58fa5f5b20c9e781c44a07"]

            #expect(PrecheckRules.curseWordFailure("oneword", hashes: hashes) == "found: oneword")
            #expect(PrecheckRules.curseWordFailure("oneword1", hashes: hashes) == nil)
        }

        @Test func punctuationIsRemovedForTheSecondWordList() {
            let hashes: Set<String> = [Self.sha256Hex("word,"), Self.sha256Hex("word")]

            #expect(PrecheckRules.curseWordFailure("word, word", hashes: hashes) == "found: word,, word")
        }

        @Test func nonASCIILettersSplitWordsAsInFastlane() {
            let hashes: Set<String> = [Self.sha256Hex("ber")]

            #expect(PrecheckRules.curseWordFailure("über", hashes: hashes) == "found: ber")
            #expect(PrecheckRules.curseWordFailure("café", hashes: [Self.sha256Hex("café"), Self.sha256Hex("caf")]) == "found: café, caf")
        }

        @Test func curseWordHashesAreTheFastlaneDigests() {
            // fastlane's en_us.txt has 350 digests, one per line.
            #expect(curseWordHashes.count == 350)
            #expect(curseWordHashes.allSatisfy { $0.count == 64 && $0.allSatisfy { "0123456789abcdef".contains($0) } })
        }

        @Test func cleanTextPassesCurseRule() {
            #expect(PrecheckRules.curseWordFailure("Track your tasks every day.", hashes: curseWordHashes) == nil)
        }

        // MARK: Copyright

        @Test func copyrightYearMustBeWholeAndNotInTheFuture() {
            #expect(PrecheckRules.copyrightFailure("© 2024 Example", currentYear: 2026) == nil)
            #expect(PrecheckRules.copyrightFailure("© 2026 Example", currentYear: 2026) == nil)
            #expect(PrecheckRules.copyrightFailure("© Example", currentYear: 2026) == "missing copyright year")
            #expect(PrecheckRules.copyrightFailure("© 2031", currentYear: 2026) == "copyright year is in the future: 2031")
            #expect(PrecheckRules.copyrightFailure("x2024", currentYear: 2026) == "missing copyright year")
            #expect(PrecheckRules.copyrightFailure("2031 - 2020", currentYear: 2026) == "copyright year is in the future: 2031")
        }

        @Test func lettersNextToTheYearAreNotABoundaryAsInFastlane() {
            #expect(PrecheckRules.copyrightFailure("Müller2024", currentYear: 2026) == "missing copyright year")
            #expect(PrecheckRules.copyrightFailure("日本2024", currentYear: 2026) == "missing copyright year")
            #expect(PrecheckRules.copyrightFailure("2024 Müller", currentYear: 2026) == nil)
        }

        // MARK: Dispatch

        @Test func optionalItemWithNoValueOrEmptyValuePassesWithoutCheck() async throws {
            let probe = Self.probe(kind: .text, field: .appSubtitle)

            #expect(await probe.failure(for: Self.text(.appSubtitle, nil, optional: true)) == nil)
            #expect(await probe.failure(for: Self.text(.appSubtitle, "", optional: true)) == nil)
        }

        @Test func optionalItemWithOnlySpacesIsChecked() async throws {
            let probe = Self.probe(kind: .text, field: .appSubtitle)

            #expect(await probe.failure(for: Self.text(.appSubtitle, "   ", optional: true)) == "called")
        }

        @Test func requiredItemWithNoValueIsCheckedAsEmpty() async throws {
            let rule = try Self.rule("No incorrect or missing copyright date")

            #expect(await rule.failure(for: PrecheckItem(field: .copyright, locale: nil, value: nil)) == "missing copyright year")
            #expect(await rule.failure(for: PrecheckItem(field: .copyright, locale: nil, value: "")) == "missing copyright year")
        }

        @Test func ruleDoesNotHandleOtherKindsOrFields() async throws {
            let copyright = try Self.rule("No incorrect or missing copyright date")
            let urlProbe = Self.probe(kind: .url, field: .supportURL)
            let textProbe = Self.probe(kind: .text, field: .keywords)

            // The copyright rule ignores other text fields, even when they have no year.
            #expect(copyright.handles(Self.text(.description, "© Example")) == false)
            #expect(await copyright.failure(for: Self.text(.description, "© Example")) == nil)
            #expect(await urlProbe.failure(for: Self.text(.keywords, "x")) == nil)
            #expect(await textProbe.failure(for: Self.text(.supportURL, "x")) == nil)
        }
    }
}
#endif
