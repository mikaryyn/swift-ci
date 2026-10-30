import SampleKit
import XCTest

final class SampleXCTests: XCTestCase {
    func testPasses() {
        XCTAssertEqual(sum(1, 2), 3)
    }

    func testFailsOnMismatch() {
        XCTAssertEqual(sum(1, 1), 3, "addition is wrong")
    }

    func testSkipped() throws {
        throw XCTSkip("skipped on purpose")
    }

    func testFailsTwice() {
        XCTAssertEqual(greeting(name: "A"), "Hello, B", "first message")
        XCTAssertTrue(sum(0, 0) != 0, "second message")
    }
}
