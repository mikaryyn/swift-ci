import Foundation
import SwiftCI
import Testing

/// ``tableFilter(keeping:otherLines:)``: a table is shown or hidden as a whole, by its title, and the lines outside
/// tables go to the other filter.
@Suite struct TableFilterTests {
    /// Runs the lines through a new block filter, and returns the lines it shows.
    private func shown(
        _ lines: [String],
        keeping keepTable: @escaping (String) -> Bool = { $0 == "Keep" },
        otherLines: @escaping Filter = { _ in nil }
    ) -> [String] {
        let filter = tableFilter(keeping: keepTable, otherLines: otherLines)
        return lines.flatMap { filter($0) }
    }

    @Test func keptTableIsShownWithItsBordersAndRows() {
        let table = ["+----+", "| Keep |", "+----+", "| a | b |", "+----+"]

        #expect(shown(table) == table)
    }

    @Test func hiddenTableIsHiddenWithItsBordersAndRows() {
        #expect(shown(["+----+", "| Hide |", "+----+", "| a |", "+----+"]) == [])
    }

    @Test func linesOutsideTablesGoToTheOtherFilter() {
        let lines = ["keep me", "drop me", "+----+", "| Keep |", "+----+", "keep me too"]
        let other: Filter = { $0.hasPrefix("keep") ? $0 : nil }

        #expect(shown(lines, otherLines: other) == ["keep me", "+----+", "| Keep |", "+----+", "keep me too"])
    }

    /// A row without a top border is not part of a table.
    @Test func aRowWithoutATopBorderIsNotATable() {
        #expect(shown(["| Keep |", "+----+"], otherLines: { $0 }) == ["| Keep |"])
    }

    /// A table ends at the first line that is not a table line. A row after that line starts no table.
    @Test func aTableEndsAtTheFirstLineThatIsNotPartOfIt() {
        let lines = ["+----+", "| Keep |", "+----+", "text", "| Hide |", "+----+", "| x |", "+----+"]

        #expect(shown(lines, otherLines: { $0 }) == ["+----+", "| Keep |", "+----+", "text", "| Hide |"])
    }

    @Test func consecutiveTablesAreDecidedSeparately() {
        let lines = ["+--+", "| Keep |", "+--+", "", "+--+", "| Hide |", "+--+"]

        #expect(shown(lines, otherLines: { $0 }) == ["+--+", "| Keep |", "+--+", ""])
    }

    /// A table with no title row, where the second border comes first, is hidden as a whole.
    @Test func aTableWithoutATitleRowIsHidden() {
        #expect(shown(["+--+", "+--+", "| Keep |", "+--+"]) == [])
    }

    /// A kept table is shown at its title, so it does not need its last lines to be shown.
    @Test func keptTableIsShownFromItsTitleOnward() {
        #expect(shown(["+--+", "| Keep |"]) == ["+--+", "| Keep |"])
    }

    /// A table that ends before its title is not shown.
    @Test func tableWithOnlyABorderIsNotShown() {
        #expect(shown(["+--+"]) == [])
    }

    /// The title is compared without colour codes, and the lines keep them.
    @Test func titleIsComparedWithoutColourCodes() {
        let table = ["+--+", "|  \u{1B}[32mKeep\u{1B}[0m  |", "+--+"]

        #expect(shown(table) == table)
    }

    /// `keepTable` gets the plain title of each table, in order.
    @Test func keepTableGetsThePlainTitleOfEachTable() {
        var titles: [String] = []
        let lines = ["+--+", "| \u{1B}[32mKeep\u{1B}[0m |", "+--+", "", "+--+", "|   Other   |", "+--+"]

        _ = shown(lines, keeping: { titles.append($0); return false })

        #expect(titles == ["Keep", "Other"])
    }
}
