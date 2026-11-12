@testable import SwiftCIXcode
@testable import SwiftCITestSupport
import AppKit
import Foundation
@testable import SwiftCI
import SwiftCITesting
import Testing

extension GlobalStateTests {
    /// `Icon.addText` on generated PNG files in a temporary folder.
    @Suite(.serialized) struct IconTests {
        /// A temporary folder for one test. The test removes it.
        static func temporaryFolder() throws -> URL {
            let folder = FileManager.default.temporaryDirectory
                .appending(path: "swift-ci-tests/icon-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            return folder
        }

        /// PNG data of a `width` x `height` image in one opaque colour.
        static func pngData(width: Int, height: Int, red: Double, green: Double, blue: Double) throws -> Data {
            let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
            let context = try #require(CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.setFillColor(red: red, green: green, blue: blue, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            let image = try #require(context.makeImage())
            return try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        }

        /// The size in pixels of the PNG at `url`, and the colour of the pixel at `x`, `y` counted from the top left.
        static func decode(_ url: URL, x: Int, y: Int) throws -> (width: Int, height: Int, color: NSColor) {
            let representation = try #require(NSBitmapImageRep(data: try Data(contentsOf: url)))
            let color = try #require(representation.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
            return (representation.pixelsWide, representation.pixelsHigh, color)
        }

        /// The banner darkens the bottom of the image, the top stays as it was, and the size in pixels is kept. Only PNG
        /// files are changed.
        @Test func addTextDrawsTheBannerAndKeepsTheSize() async throws {
            let (log, _) = registerToolMocks()
            let folder = try Self.temporaryFolder()
            defer { try? FileManager.default.removeItem(at: folder) }
            let icon = folder.appending(path: "Icon.png")
            let json = folder.appending(path: "Contents.json")
            try Self.pngData(width: 100, height: 80, red: 1, green: 0, blue: 0).write(to: icon)
            try Data("{}".utf8).write(to: json)

            try await Icon.addText(iconURL: folder, text: "1.2 (3)")

            let result = try Self.decode(icon, x: 1, y: 79)
            let top = try Self.decode(icon, x: 1, y: 0)
            #expect(result.width == 100)
            #expect(result.height == 80)
            #expect(result.color.redComponent < 0.7)
            #expect(top.color.redComponent > 0.95)
            #expect(try String(contentsOf: json, encoding: .utf8) == "{}")
            #expect(log.loggedLines.contains { $0.contains("Added text to \(icon.filePath)") })
        }

        /// The images are changed in the order of their names, whatever the case of the extension.
        @Test func addTextChangesTheFilesInOrder() async throws {
            let (log, _) = registerToolMocks()
            let folder = try Self.temporaryFolder()
            defer { try? FileManager.default.removeItem(at: folder) }
            for name in ["b.png", "A.PNG", "c.png"] {
                try Self.pngData(width: 20, height: 20, red: 0, green: 0, blue: 1).write(to: folder.appending(path: name))
            }

            try await Icon.addText(iconURL: folder, text: "x")

            let names = log.loggedLines.compactMap { line in
                line.contains("Added text to") ? URL(filePath: String(line.split(separator: " ").last ?? "")).lastPathComponent : nil
            }
            #expect(names == ["A.PNG", "b.png", "c.png"])
        }

        /// A directory that does not exist fails the step and names the directory.
        @Test func missingDirectoryIsABuildError() async throws {
            _ = registerToolMocks()
            let parent = try Self.temporaryFolder()
            defer { try? FileManager.default.removeItem(at: parent) }
            let folder = parent.appending(path: "Missing")

            let error = await thrownError { try await Icon.addText(iconURL: folder, text: "x") }

            #expect(error?.message.hasPrefix("Failed to read the icon directory '\(folder.filePath)'.") == true)
        }

        /// A directory without PNG files fails the step, because nothing would be stamped.
        @Test func directoryWithoutPNGFilesIsABuildError() async throws {
            _ = registerToolMocks()
            let folder = try Self.temporaryFolder()
            defer { try? FileManager.default.removeItem(at: folder) }
            try Data("{}".utf8).write(to: folder.appending(path: "Contents.json"))

            let error = await thrownError { try await Icon.addText(iconURL: folder, text: "x") }

            #expect(error?.message == "Found no PNG files in the icon directory '\(folder.filePath)'. Check the path of the icon set.")
        }

        /// A file that is not a PNG fails the step and names the file.
        @Test func corruptPNGIsABuildError() async throws {
            _ = registerToolMocks()
            let folder = try Self.temporaryFolder()
            defer { try? FileManager.default.removeItem(at: folder) }
            let file = folder.appending(path: "Broken.png")
            try Data("not a png".utf8).write(to: file)

            let error = await thrownError { try await Icon.addText(iconURL: folder, text: "x") }

            #expect(error?.message == "Failed to load image '\(file.filePath)'. Check that it is a valid PNG file.")
        }
    }
}
