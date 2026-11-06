// Contains rules, word lists and hashes ported from fastlane precheck.
//
// The MIT License (MIT)
//
// Copyright (c) 2015-2022 The Fastlane Authors
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

#if os(macOS)
import CryptoKit
import Foundation

/// The rules of the App Store metadata check, ported from fastlane precheck with their names, descriptions and word lists.
/// Every rule is a warning.
enum PrecheckRules {
    /// The rules for the current year of the machine's calendar.
    static let all = rules(currentYear: Calendar.current.component(.year, from: Date()))

    /// The rules in fastlane's order.
    ///
    /// - Parameter currentYear: The year that a copyright year may not be after.
    static func rules(currentYear: Int) -> [PrecheckRule] {
        [
            wordRule(
                name: "No negative  sentiment",
                description: "mentioning  in a way that could be considered negative",
                phrases: [
                    "ios bug", "macos bug", "safari bug", "webkit bug", "uikit bug", "apple store bug",
                    "slow iphone", "slow ipad", "old iphone",
                ]
            ),
            wordRule(
                name: "No placeholder text",
                description: "using placeholder text (e.g.:\"lorem ipsum\", \"text here\", etc...)",
                phrases: ["hipster ipsum", "bacon ipsum", "lorem ipsum", "placeholder", "text here"]
            ),
            wordRule(
                name: "No mentioning  competitors",
                description: "mentioning other platforms, like Android or Blackberry",
                phrases: [
                    "android", "google", "compuserve", "windows phone", "windows 10 mobile", "sailfish os",
                    "windows universal app", "blackberry", "palm os", "symbian",
                ],
                allowed: ["google analytics", "google drive"]
            ),
            wordRule(
                name: "No future functionality promises",
                description: "mentioning features or content that is not currently available in your app",
                phrases: [
                    "coming soon", "coming shortly", "in the next release", "arriving soon", "arriving shortly",
                    "here soon", "here shortly",
                ]
            ),
            wordRule(
                name: "No words indicating test content",
                description: "using text indicating this release is a test",
                phrases: ["testing", "just a test", "alpha test", "beta test"]
            ),
            PrecheckRule(
                name: "No curse words",
                description: "including words that might be considered objectionable",
                kind: .text,
                fields: textFields,
                check: { curseWordFailure($0, hashes: curseWordHashes) }
            ),
            PrecheckRule(
                name: "No incorrect or missing copyright date",
                description: "using a copyright year in the future, or missing a copyright year",
                kind: .text,
                fields: [.copyright],
                check: { copyrightFailure($0, currentYear: currentYear) }
            ),
        ]
    }

    /// The fields whose values are text.
    private static let textFields = Set(PrecheckItem.Field.allCases.filter { $0.kind == .text })

    /// A text rule that fails on the phrases of any text field.
    private static func wordRule(
        name: String, description: String, phrases: [String], allowed: [String] = []
    ) -> PrecheckRule {
        PrecheckRule(
            name: name,
            description: description,
            kind: .text,
            fields: textFields,
            check: { textMatch($0, phrases: phrases, allowed: allowed) }
        )
    }

    /// The curse words of `text` that have a hash in `hashes`, as fastlane's curse-word rule finds them.
    ///
    /// The candidate words are the whitespace-separated words of the lower-cased text, followed by the words of the text
    /// in which every character that is not an ASCII letter, digit or underscore is a space. Only ASCII whitespace
    /// separates words, and each distinct word is hashed as its UTF-8 bytes with SHA-256.
    ///
    /// - Parameters:
    ///   - text: The value to check.
    ///   - hashes: The lowercase hex SHA-256 digests of the curse words.
    /// - Returns: `found: ` followed by the curse words in order of first appearance, joined by `, `, or nil when none
    ///   is a curse word.
    nonisolated static func curseWordFailure(_ text: String, hashes: Set<String>) -> String? {
        let lowercased = text.lowercased()
        let withoutPunctuation = String(String.UnicodeScalarView(
            lowercased.unicodeScalars.map { isASCIIWordScalar($0) ? $0 : " " }
        ))
        var seen = Set<String>()
        let words = (asciiWords(lowercased) + asciiWords(withoutPunctuation)).filter { seen.insert($0).inserted }
        let found = words.filter { hashes.contains(sha256Hex($0)) }
        guard !found.isEmpty else { return nil }
        return "found: " + found.joined(separator: ", ")
    }

    /// The failure text of a copyright value. The first year in the text, a `19xx` or `20xx` number that is a whole
    /// word, must not be after `currentYear`.
    ///
    /// - Parameters:
    ///   - text: The copyright value. It is not trimmed or lower-cased.
    ///   - currentYear: The latest year that the copyright may name.
    /// - Returns: `missing copyright year`, `copyright year is in the future: <year>`, or nil when the year is fine.
    nonisolated static func copyrightFailure(_ text: String, currentYear: Int) -> String? {
        guard
            let match = text.firstMatch(of: /\b(?:19|20)\d{2}\b/.asciiOnlyDigits().wordBoundaryKind(.simple)),
            let year = Int(text[match.range])
        else {
            return "missing copyright year"
        }
        return year > currentYear ? "copyright year is in the future: \(year)" : nil
    }

    /// The whitespace-separated words of `text`, split on ASCII whitespace only, as Ruby splits them.
    nonisolated private static func asciiWords(_ text: String) -> [String] {
        let whitespace: Set<Unicode.Scalar> = [" ", "\t", "\n", "\r", "\u{0B}", "\u{0C}"]
        return text.unicodeScalars
            .split { whitespace.contains($0) }
            .map { String(String.UnicodeScalarView($0)) }
    }

    /// Whether `scalar` is an ASCII letter, digit or underscore.
    nonisolated private static func isASCIIWordScalar(_ scalar: Unicode.Scalar) -> Bool {
        scalar == "_" || ("0"..."9").contains(scalar) || ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar)
    }

    /// The lowercase hex SHA-256 digest of the UTF-8 bytes of `word`.
    nonisolated private static func sha256Hex(_ word: String) -> String {
        SHA256.hash(data: Data(word.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
#endif
