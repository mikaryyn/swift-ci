import Foundation

/// One of the 16 standard terminal colors. The raw value is the index in the ANSI palette.
public enum TerminalColor: Int, CaseIterable, Sendable {
    case black, red, green, yellow, blue, magenta, cyan, lightGray
    case darkGray, lightRed, lightGreen, lightYellow, lightBlue, lightMagenta, lightCyan, white

    /// The parameter of the escape sequence that sets this color as the text color.
    fileprivate var foregroundParameter: Int {
        rawValue < 8 ? 30 + rawValue : 90 + rawValue - 8
    }

    /// The parameter of the escape sequence that sets this color as the background color.
    fileprivate var backgroundParameter: Int {
        foregroundParameter + 10
    }
}

extension String {
    /// The string without terminal control sequences: the style and color codes that the functions below write, and any
    /// other sequence of `ESC [`, digits and semicolons, and a letter. Use it in a ``Filter`` to check a line that a tool
    /// colored.
    public var withoutTerminalCodes: String {
        replacingOccurrences(of: "\u{1B}\\[[0-9;]*[A-Za-z]", with: "", options: .regularExpression)
    }
}

/// ANSI styles and colors for console lines. Each function wraps the string in a style code and ends it with a reset.
/// A style inside an already styled string is kept: the outer style is opened again after the inner reset.
extension String {
    public func bold() -> String { styled(1) }
    public func dim() -> String { styled(2) }
    public func italic() -> String { styled(3) }
    public func underline() -> String { styled(4) }
    public func blink() -> String { styled(5) }
    public func reverse() -> String { styled(7) }
    public func hidden() -> String { styled(8) }
    public func strikethrough() -> String { styled(9) }

    public func foregroundColor(_ color: TerminalColor) -> String { styled(color.foregroundParameter) }

    public func backgroundColor(_ color: TerminalColor) -> String { styled(color.backgroundParameter) }

    /// The string in the color at `paletteIndex` of the 256-color palette.
    public func foregroundColor(paletteIndex: UInt8) -> String { styled(38, 5, Int(paletteIndex)) }

    /// The string on a background of the color at `paletteIndex` of the 256-color palette.
    public func backgroundColor(paletteIndex: UInt8) -> String { styled(48, 5, Int(paletteIndex)) }

    /// The string in `foreground` on a background of `background`.
    public func colorize(_ foreground: TerminalColor, background: TerminalColor) -> String {
        foregroundColor(foreground).backgroundColor(background)
    }

    public func black() -> String { foregroundColor(.black) }
    public func red() -> String { foregroundColor(.red) }
    public func green() -> String { foregroundColor(.green) }
    public func yellow() -> String { foregroundColor(.yellow) }
    public func blue() -> String { foregroundColor(.blue) }
    public func magenta() -> String { foregroundColor(.magenta) }
    public func cyan() -> String { foregroundColor(.cyan) }
    public func lightGray() -> String { foregroundColor(.lightGray) }
    public func darkGray() -> String { foregroundColor(.darkGray) }
    public func lightRed() -> String { foregroundColor(.lightRed) }
    public func lightGreen() -> String { foregroundColor(.lightGreen) }
    public func lightYellow() -> String { foregroundColor(.lightYellow) }
    public func lightBlue() -> String { foregroundColor(.lightBlue) }
    public func lightMagenta() -> String { foregroundColor(.lightMagenta) }
    public func lightCyan() -> String { foregroundColor(.lightCyan) }
    public func white() -> String { foregroundColor(.white) }

    public func onBlack() -> String { backgroundColor(.black) }
    public func onRed() -> String { backgroundColor(.red) }
    public func onGreen() -> String { backgroundColor(.green) }
    public func onYellow() -> String { backgroundColor(.yellow) }
    public func onBlue() -> String { backgroundColor(.blue) }
    public func onMagenta() -> String { backgroundColor(.magenta) }
    public func onCyan() -> String { backgroundColor(.cyan) }
    public func onLightGray() -> String { backgroundColor(.lightGray) }
    public func onDarkGray() -> String { backgroundColor(.darkGray) }
    public func onLightRed() -> String { backgroundColor(.lightRed) }
    public func onLightGreen() -> String { backgroundColor(.lightGreen) }
    public func onLightYellow() -> String { backgroundColor(.lightYellow) }
    public func onLightBlue() -> String { backgroundColor(.lightBlue) }
    public func onLightMagenta() -> String { backgroundColor(.lightMagenta) }
    public func onLightCyan() -> String { backgroundColor(.lightCyan) }
    public func onWhite() -> String { backgroundColor(.white) }

    private func styled(_ parameters: Int...) -> String {
        let open = "\u{1B}[" + parameters.map(String.init).joined(separator: ";") + "m"
        let reset = "\u{1B}[0m"
        return open + replacingOccurrences(of: reset, with: reset + open) + reset
    }
}
