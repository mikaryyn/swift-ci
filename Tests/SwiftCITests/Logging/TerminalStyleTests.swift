@testable import SwiftCI
import Testing

@Suite struct TerminalStyleTests {
    @Test func aStyleWrapsTheTextInItsCodeAndAReset() {
        #expect("x".bold() == "\u{1B}[1mx\u{1B}[0m")
        #expect("x".dim() == "\u{1B}[2mx\u{1B}[0m")
        #expect("x".italic() == "\u{1B}[3mx\u{1B}[0m")
        #expect("x".underline() == "\u{1B}[4mx\u{1B}[0m")
        #expect("x".blink() == "\u{1B}[5mx\u{1B}[0m")
        #expect("x".reverse() == "\u{1B}[7mx\u{1B}[0m")
        #expect("x".hidden() == "\u{1B}[8mx\u{1B}[0m")
        #expect("x".strikethrough() == "\u{1B}[9mx\u{1B}[0m")
    }

    @Test func colorsUseTheStandardCodes() {
        #expect("x".black() == "\u{1B}[30mx\u{1B}[0m")
        #expect("x".red() == "\u{1B}[31mx\u{1B}[0m")
        #expect("x".lightGray() == "\u{1B}[37mx\u{1B}[0m")
        #expect("x".darkGray() == "\u{1B}[90mx\u{1B}[0m")
        #expect("x".lightRed() == "\u{1B}[91mx\u{1B}[0m")
        #expect("x".white() == "\u{1B}[97mx\u{1B}[0m")
        #expect("x".onBlack() == "\u{1B}[40mx\u{1B}[0m")
        #expect("x".onRed() == "\u{1B}[41mx\u{1B}[0m")
        #expect("x".onDarkGray() == "\u{1B}[100mx\u{1B}[0m")
        #expect("x".onWhite() == "\u{1B}[107mx\u{1B}[0m")
    }

    @Test func everyColorHasADistinctForegroundAndBackgroundCode() {
        let foregrounds = TerminalColor.allCases.map { "x".foregroundColor($0) }
        let backgrounds = TerminalColor.allCases.map { "x".backgroundColor($0) }

        #expect(Set(foregrounds).count == 16)
        #expect(Set(backgrounds).count == 16)
        #expect(foregrounds.allSatisfy { $0.wholeMatch(of: /\u{1B}\[(3[0-7]|9[0-7])mx\u{1B}\[0m/) != nil })
        #expect(backgrounds.allSatisfy { $0.wholeMatch(of: /\u{1B}\[(4[0-7]|10[0-7])mx\u{1B}\[0m/) != nil })
    }

    @Test func aPaletteIndexUsesThe256ColorCodes() {
        #expect("x".foregroundColor(paletteIndex: 202) == "\u{1B}[38;5;202mx\u{1B}[0m")
        #expect("x".backgroundColor(paletteIndex: 17) == "\u{1B}[48;5;17mx\u{1B}[0m")
    }

    @Test func colorizeSetsTheTextAndTheBackground() {
        #expect("x".colorize(.red, background: .white) == "x".red().onWhite())
    }

    @Test func aNestedStyleOpensTheOuterStyleAgainAfterTheReset() {
        let text = "x".red().bold()

        #expect(text == "\u{1B}[1m\u{1B}[31mx\u{1B}[0m\u{1B}[1m\u{1B}[0m")
    }

    @Test func theFullLogRemovesTheCodes() {
        #expect("[\("name".cyan().bold())] ✔︎".yellow().withoutTerminalCodes == "[name] ✔︎")
        #expect("x".foregroundColor(paletteIndex: 202).onLightBlue().withoutTerminalCodes == "x")
    }
}
