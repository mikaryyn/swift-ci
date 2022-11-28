import Foundation
import SwiftCI

class LogMock: Log {
    func callAsFunction(_ line: String) {
        loggedLines.append(line)
    }

    var loggedLines = [String]()
}
