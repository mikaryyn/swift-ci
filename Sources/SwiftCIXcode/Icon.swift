import AppKit
import SwiftCI

/// Stamps text, such as the version and build number, on the PNG images of an app icon.
public enum Icon {
    /// A colour in the sRGB colour space.
    public struct Color {
        /// Creates a colour. Each component is from 0 to 1. `alpha` 0 is transparent and 1 is opaque.
        public init(red: Double, green: Double, blue: Double, alpha: Double) {
            self.red = red
            self.green = green
            self.blue = blue
            self.alpha = alpha
        }

        fileprivate var nsColor: NSColor {
            NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
        }

        let red: Double
        let green: Double
        let blue: Double
        let alpha: Double
    }

    /// Draws a text banner along the bottom of every PNG image in the directory `iconURL`, and saves the images in
    /// place. Only the PNG files directly in the directory are changed, and the files are overwritten, so a checkout is
    /// modified. Each image keeps its size in pixels.
    ///
    /// The banner covers the bottom 30 % of the image. The text is as large as fits the banner and 90 % of its width, and
    /// centred. A directory that cannot be read, a directory without PNG files and a file that is not a readable PNG fail
    /// the step.
    ///
    /// Opens a step named "Add text to app icon" when called at the top level of a command. `step` renames it.
    ///
    /// - Parameters:
    ///   - iconURL: The directory with the icon images, for example an `AppIcon.appiconset` folder.
    ///   - text: The text to draw.
    ///   - foregroundColor: The colour of the text. Defaults to white.
    ///   - backgroundColor: The colour of the banner. Defaults to black with an alpha of 0.5.
    ///   - name: The name of the step, if it is not the default.
    public static func addText(
        iconURL: URL,
        text: String,
        foregroundColor: Color = Color(red: 1, green: 1, blue: 1, alpha: 1),
        backgroundColor: Color = Color(red: 0, green: 0, blue: 0, alpha: 0.5),
        step name: String? = nil
    ) async throws {
        @Use var log: Log

        try await step(default: "Add text to app icon", name: name) {
            for fileURL in try findImageFiles(in: iconURL) {
                let png = try stamp(
                    imageAt: fileURL,
                    text: text,
                    foregroundColor: foregroundColor.nsColor,
                    backgroundColor: backgroundColor.nsColor
                )
                do {
                    try png.write(to: fileURL)
                } catch {
                    throw BuildError(message: "Failed to write file '\(fileURL.filePath)'. Details: \(error)")
                }
                log("Added text to \(fileURL.filePath)")
            }
        }
    }

    /// The PNG files directly in `directory`, sorted by name.
    private static func findImageFiles(in directory: URL) throws -> [URL] {
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: directory.filePath)
        } catch {
            throw BuildError(message: "Failed to read the icon directory '\(directory.filePath)'. Details: \(error)")
        }
        let files = names
            .filter { $0.lowercased().hasSuffix(".png") }
            .sorted()
            .map { directory.appending(path: $0) }
        guard !files.isEmpty else {
            throw BuildError(
                message: "Found no PNG files in the icon directory '\(directory.filePath)'. Check the path of the icon set."
            )
        }
        return files
    }

    /// The PNG data of the image at `url` with the banner and the text drawn on it. The context has the pixel size of the
    /// image, so the result does not depend on the screen that the Mac has.
    private static func stamp(imageAt url: URL, text: String, foregroundColor: NSColor, backgroundColor: NSColor) throws -> Data {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw BuildError(message: "Failed to read file '\(url.filePath)'. Details: \(error)")
        }
        guard let source = NSBitmapImageRep(data: data)?.cgImage else {
            throw BuildError(message: "Failed to load image '\(url.filePath)'. Check that it is a valid PNG file.")
        }
        let width = source.width
        let height = source.height
        guard
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else {
            throw BuildError(message: "Failed to create a \(width) x \(height) pixel drawing context for '\(url.filePath)'.")
        }

        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        let bannerRect = NSRect(x: 0, y: 0, width: width, height: Int(ceil(Double(height) * 0.3)))
        backgroundColor.set()
        bannerRect.fill(using: .sourceOver)
        draw(text: text, in: bannerRect, color: foregroundColor)
        NSGraphicsContext.restoreGraphicsState()

        guard
            let result = context.makeImage(),
            let png = NSBitmapImageRep(cgImage: result).representation(using: .png, properties: [:])
        else {
            throw BuildError(message: "Failed to encode the image '\(url.filePath)' as PNG.")
        }
        return png
    }

    private static func draw(text: String, in rect: NSRect, color: NSColor) {
        let (pointSize, size) = fit(text: text, in: rect)
        let textRect = NSRect(
            x: (rect.width - size.width) / 2,
            y: (rect.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
        text.draw(in: textRect, withAttributes: [
            .foregroundColor: color,
            .font: NSFont.systemFont(ofSize: pointSize)
        ])
    }

    /// The font size at which `text` is as high as `rect`, reduced so that it is not wider than 90 % of `rect`, and the
    /// size that the text takes then.
    private static func fit(text: String, in rect: NSRect) -> (pointSize: Double, size: NSSize) {
        let referencePointSize = 100.0
        let referenceSize = text.size(withAttributes: [.font: NSFont.systemFont(ofSize: referencePointSize)])
        var pointSize = rect.height / (referenceSize.height / referencePointSize)

        var size = text.size(withAttributes: [.font: NSFont.systemFont(ofSize: pointSize)])
        let maxWidth = rect.width * 0.9
        if size.width > maxWidth {
            pointSize *= maxWidth / size.width
            size = text.size(withAttributes: [.font: NSFont.systemFont(ofSize: pointSize)])
        }
        return (pointSize, size)
    }
}
