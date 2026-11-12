import Foundation
import SwiftCI

/// Writes the files of an over-the-air (OTA) install of an ad-hoc IPA: the `manifest.plist` and an HTML install page
/// whose link installs the IPA on a registered device.
///
/// Only the output locations (`url`) are file URLs. `ipaURL` and `manifestURL` are web URLs where the files are served,
/// for example by the CI system. Callers usually write the files to ``Artifacts/url(_:)``, so the CI system archives them.
/// iOS installs only over HTTPS. A URL that is not `https` is logged as a warning, not treated as an error, because a
/// local test run often has no HTTPS URL.
public enum OverTheAirInstall {
    @Use private static var log: Log

    /// Writes the `manifest.plist` of an ad-hoc IPA to `url`. The property list is written in XML format, so its values
    /// are escaped.
    ///
    /// The manifest has one item with a `software-package` asset at `ipaURL`, and the metadata `bundle-identifier`,
    /// `bundle-version`, `kind` (`software`) and `title`. The parent directory of `url` must exist.
    ///
    /// Opens a step named "Write over-the-air manifest" when called at the top level of a command. `step` renames it.
    ///
    /// - Parameters:
    ///   - url: The file to write, for example `Artifacts.url("manifest.plist")`.
    ///   - ipaURL: The web URL where the IPA is served.
    ///   - bundleIdentifier: The bundle identifier of the app.
    ///   - bundleVersion: The bundle version in the metadata.
    ///   - title: The title shown by the install prompt.
    ///   - name: The name of the step, if it is not the default.
    public static func writeManifest(
        to url: URL,
        ipaURL: URL,
        bundleIdentifier: String,
        bundleVersion: String,
        title: String,
        step name: String? = nil
    ) async throws {
        try await step(default: "Write over-the-air manifest", name: name) {
            warnIfNotHTTPS(ipaURL, description: "The IPA")

            let contents: [String: Any] = [
                "items": [
                    [
                        "assets": [
                            [
                                "kind": "software-package",
                                "url": ipaURL.absoluteString
                            ]
                        ],
                        "metadata": [
                            "bundle-identifier": bundleIdentifier,
                            "bundle-version": bundleVersion,
                            "kind": "software",
                            "title": title
                        ]
                    ]
                ]
            ]
            let lines = try Plist.save(to: url, contents: contents)
            log.lines(title: "Contents of generated '\(url.filePath)' file:", lines: lines)
        }
    }

    /// Writes an HTML install page to `url`. The page redirects to
    /// `itms-services://?action=download-manifest&url=<manifestURL>` with a `meta refresh`, and shows the same link with
    /// `title` as its text, for browsers that block the redirect.
    ///
    /// `manifestURL` is percent-encoded as a query value, and the text and attributes of the page are HTML-escaped.
    /// The parent directory of `url` must exist.
    ///
    /// Opens a step named "Write over-the-air install page" when called at the top level of a command. `step` renames it.
    ///
    /// - Parameters:
    ///   - url: The file to write, for example `Artifacts.url("index.html")`.
    ///   - manifestURL: The web URL where the `manifest.plist` is served.
    ///   - title: The title of the page, and the text of the link.
    ///   - name: The name of the step, if it is not the default.
    public static func writeInstallPage(
        to url: URL,
        manifestURL: URL,
        title: String,
        step name: String? = nil
    ) async throws {
        try await step(default: "Write over-the-air install page", name: name) {
            warnIfNotHTTPS(manifestURL, description: "The manifest")

            let encodedManifestURL = try percentEncodedQueryValue(manifestURL.absoluteString)
            let escapedLink = escapeHTML("itms-services://?action=download-manifest&url=\(encodedManifestURL)")
            let escapedTitle = escapeHTML(title)
            let html = """
            <!DOCTYPE html>
            <html>
            <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <meta http-equiv="refresh" content="0; url=\(escapedLink)">
            <title>\(escapedTitle)</title>
            </head>
            <body>
            <p><a href="\(escapedLink)">\(escapedTitle)</a></p>
            </body>
            </html>

            """
            do {
                try html.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                throw BuildError(message: "Failed to write file '\(url.filePath)'. Details: \(error)")
            }
        }
    }

    /// Logs a warning if `url` does not use HTTPS, because iOS does not install from any other scheme.
    private static func warnIfNotHTTPS(_ url: URL, description: String) {
        guard url.scheme?.lowercased() != "https" else { return }
        log.warning("\(description) URL '\(url.absoluteString)' is not https. The install will not work on a device, "
            + "because iOS installs only over HTTPS.")
    }

    /// The URL-encoded form of `value` for a query value. Only ASCII letters, digits and `-._~` are kept, so `&`, `=`,
    /// `/`, `:` and `?` cannot end the value.
    private static func percentEncodedQueryValue(_ value: String) throws -> String {
        let allowed = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
        )
        guard let encoded = value.addingPercentEncoding(withAllowedCharacters: allowed) else {
            throw BuildError(message: "Failed to percent-encode the URL '\(value)' for the install page.")
        }
        return encoded
    }

    /// Escapes the characters that have a meaning in HTML text and in quoted attribute values.
    private static func escapeHTML(_ text: String) -> String {
        text.reduce(into: "") { result, character in
            switch character {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "'": result += "&#39;"
            default: result.append(character)
            }
        }
    }
}
