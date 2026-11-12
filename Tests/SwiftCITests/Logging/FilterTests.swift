import SwiftCI
import Testing

@Suite struct FilterTests {
    @Test func textFilterHidesOrReplacesTheWholeLine() {
        #expect(filter("noise")("some noise here") == nil)
        #expect(filter("noise", "quiet")("some noise here") == "quiet")
        #expect(filter("noise")("a useful line") == "a useful line")
    }

    @Test func regexFilterHidesTheLine() {
        #expect(filter(#/^\d+ files/#)("12 files compiled") == nil)
        #expect(filter(#/^\d+ files/#)("compiled 12 files") == "compiled 12 files")
    }

    @Test func regexFilterReplacesOnlyTheMatch() {
        #expect(filter(#/\d+/#, "N")("12 files and 3 folders") == "N files and N folders")
        #expect(filter(#/\d+/#, "N")("no digits") == "no digits")
    }

    @Test func regexFilterWithClosureReplacesEachMatch() {
        let hideValue = filter(#/token=(\w+)/#) { _ in "token=•" }
        #expect(hideValue("login token=abc123 ok") == "login token=• ok")
        #expect(hideValue("login ok") == "login ok")
    }

    @Test func hideAllLinesHidesEveryLine() {
        #expect(hideAllLines("anything") == nil)
        #expect(hideAllLines("") == nil)
    }
}
