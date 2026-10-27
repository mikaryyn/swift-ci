import AppKit
import SwiftCI

public struct Color {
    public init(red: Double, green: Double, blue: Double, alpha: Double) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    fileprivate var nsColor: NSColor {
        NSColor(red: red, green: green, blue: blue, alpha: alpha)
    }

    let red: Double
    let green: Double
    let blue: Double
    let alpha: Double
}

public struct Icon {
    /// Draws a text banner on every PNG image in the directory `iconURL`, and saves the images in place.
    ///
    /// Opens a step named "Add text to app icon" when called at the top level of a command. `step` renames it.
    public static func addText(
        iconURL: URL,
        text: String,
        foregroundColor: Color = Color(red: 1, green: 1, blue: 1, alpha: 1),
        backgroundColor: Color = Color(red: 0, green: 0, blue: 0, alpha: 0.5),
        step name: String? = nil
    ) async throws {
        try await step(default: "Add text to app icon", name: name) {
            for file in try findImageFiles(in: iconURL) {
                let fileURL = iconURL.appending(path: file)
                let image = try load(imageAt: fileURL)

                let w = image.representations[0].pixelsWide
                let h = image.representations[0].pixelsHigh

                let i = NSImage(size: NSSize(width: w, height: h), flipped: false) { _ in
                    image.draw(in: NSRect(origin: .zero, size: NSSize(width: w, height: h)))
                    backgroundColor.nsColor.set()
                    let bannerRect = NSRect(origin: .zero, size: NSSize(width: w, height: Int(ceil(Double(h) * 0.3))))
                    bannerRect.fill(using: .sourceOver)
                    draw(text: text, in: bannerRect, color: foregroundColor.nsColor)
                    return true
                }
                try save(image: i, to: fileURL)
            }
        }
    }

    private static func findImageFiles(in directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.filePath)
            .filter { $0.hasSuffix(".png") }
    }

    private static func load(imageAt url: URL) throws -> NSImage {
        guard let image = NSImage(contentsOf: url) else {
            throw BuildError(message: "Failed to load image '\(url.filePath)'")
        }
        return image
    }

    private static func draw(text: String, in rect: NSRect, color: NSColor) {
        let (pointSize, size) = fit(text: text, in: rect)
        let textRect = NSRect(x: (rect.size.width - size.width) / 2, y: (rect.size.height - size.height) / 2, width: size.width, height: size.height)

        text.draw(in: textRect, withAttributes: [
            .foregroundColor: color,
            .font: NSFont.systemFont(ofSize: pointSize)
        ])
    }

    private static func fit(text: String, in rect: NSRect) -> (Double, NSSize) {
        let knownPointSize = 100.0
        let matchingSize = text.size(withAttributes: [.font: NSFont.systemFont(ofSize: knownPointSize)])
        let multiplier = matchingSize.height / knownPointSize

        var correctPointSize = rect.height / multiplier

        var size = text.size(withAttributes: [.font: NSFont.systemFont(ofSize: correctPointSize)])
        let maxWidth = rect.width * 0.9
        if size.width > maxWidth {
            correctPointSize *= maxWidth / size.width
            size = text.size(withAttributes: [.font: NSFont.systemFont(ofSize: correctPointSize)])
        }
        return (correctPointSize, size)
    }

    private static func save(image: NSImage, to url: URL) throws {
        let tiff = image.tiffRepresentation!
        let imageRep = NSBitmapImageRep(data: tiff)!
        let pngData = imageRep.representation(using: .png, properties: [:])!
        try pngData.write(to: url)
    }
}
