@testable import SwiftCI
import Foundation
import Testing

@Suite struct LogTests {
    @Test(arguments: [
        (0.0, "0s"),
        (0.2, "1s"),
        (59.0, "59s"),
        (60.0, "1m 0s"),
        (185.4, "3m 6s"),
    ])
    func elapsedTimeUsesMinutesAndSeconds(interval: TimeInterval, expected: String) {
        #expect(LogImpl.formatElapsed(interval) == expected)
    }
}
