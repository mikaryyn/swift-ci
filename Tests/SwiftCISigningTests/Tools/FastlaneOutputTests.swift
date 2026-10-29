@testable import SwiftCI
@testable import SwiftCISigning
@testable import SwiftCITestSupport
import Foundation
import SwiftCITesting
import Testing

extension GlobalStateTests {
    /// The console filter of `Fastlane.match`, against two recordings of real `fastlane match --readonly` runs
    /// (`Fixtures/Fastlane`). The full log keeps every line of them.
    @Suite(.serialized) struct FastlaneOutputTests {
        /// The run installs three apps. The console keeps the warning about the Matchfile, the installed certificate table
        /// and the final result. The profile tables, the per-profile warnings, the git and decryption output and the update
        /// notice are hidden.
        @Test func successfulRunShowsOnlyTheWarningTheCertificateAndTheResult() async throws {
            let (log, runner) = registerToolMocks()
            runner.responses = [.init(lines: try recordingLines("match-readonly"))]

            try await Fastlane.match(type: .adhoc, appIdentifiers: threeAppIdentifiers, teamId: "TEAMID1234", verbose: true)

            #expect(log.loggedLines.map(stripANSI) == successfulConsoleLines)
        }

        /// A wrong password stops the run. The console keeps the errors, the bundler failure and the `[!]` line, and hides
        /// the Ruby backtrace and the other exception lines.
        @Test func failedRunShowsTheErrorsAndTheFailureOnly() async throws {
            let (log, runner) = registerToolMocks()
            runner.responses = [.init(
                lines: try recordingLines("match-readonly-wrong-password"),
                result: ToolResult(stdout: "", stderr: "", exitCode: 1)
            )]

            let error = await thrownError {
                try await Fastlane.match(
                    type: .adhoc, appIdentifiers: threeAppIdentifiers, teamId: "TEAMID1234", invocation: .bundler()
                )
            }

            #expect(error?.message == "bundle exited with code 1.")
            #expect(log.loggedLines.map(stripANSI) == failedConsoleLines)
        }

        /// The filter is the same for `matchUpdate`, so it is checked on the same recording.
        @Test func matchUpdateUsesTheSameConsoleFilter() async throws {
            let (log, runner) = registerToolMocks()
            runner.responses = [.init(lines: try recordingLines("match-readonly"))]

            try await Fastlane.matchUpdate(type: .adhoc, appIdentifiers: threeAppIdentifiers, teamId: "TEAMID1234")

            #expect(log.loggedLines.map(stripANSI) == successfulConsoleLines)
        }

        /// The full log has every line of the recording, the hidden ones too.
        @Test func fullLogKeepsEveryLineOfTheRecording() async throws {
            let runner = ProcessRunnerMock()
            let lines = try recordingLines("match-readonly")
            runner.responses = [.init(lines: lines)]
            var fullLog = ""

            let result = await SwiftCITest.run(["match"]) {
                register(ProcessRunner.self, runner)
                command(Command("match") {
                    try await Fastlane.match(
                        type: .adhoc, appIdentifiers: threeAppIdentifiers, teamId: "TEAMID1234", verbose: true
                    )
                    fullLog = try String(contentsOfFile: FullLog.path?.filePath ?? "", encoding: .utf8)
                })
            }

            #expect(result.exitCode == 0)
            #expect(lines.filter { !$0.text.isEmpty }.allSatisfy { fullLog.contains($0.text) })
            #expect(fullLog.contains("Installed Provisioning Profile"))
            #expect(fullLog.contains("Setting environment variable 'sigh_com.example.app1_adhoc'"))
        }
    }
}

/// The app identifiers of the recordings.
private let threeAppIdentifiers = ["com.example.app1", "com.example.app2", "com.example.app3"]

/// The console lines of the successful recording, without colour codes.
private let successfulConsoleLines = [
    "WARN [2026-10-29 14:06:26.52]: In the config file './Matchfile' you have the line keychain_password, but didn't provide any value. Make sure to append a value right after the option name. Make sure to check the docs for more information",
    "+------------------------------------------------------------------+",
    "|                      Installed Certificate                       |",
    "+-------------------+----------------------------------------------+",
    "| User ID           | TEAMID1234                                   |",
    "| Common Name       | Apple Distribution: Example Org (TEAMID1234) |",
    "| Organisation Unit | TEAMID1234                                   |",
    "| Organisation      | Example Org                                  |",
    "| Country           | US                                           |",
    "| Start Datetime    | 2026-06-15 08:02:59 UTC                      |",
    "| End Datetime      | 2027-06-15 08:02:58 UTC                      |",
    "+-------------------+----------------------------------------------+",
    "INFO [2026-10-29 14:06:32.19]: All required keys, certificates and provisioning profiles are installed 🙌",
]

/// The console lines of the failed recording, without colour codes.
private let failedConsoleLines = [
    "WARN [2026-10-29 14:13:25.24]: In the config file './Matchfile' you have the line keychain_password, but didn't provide any value. Make sure to append a value right after the option name. Make sure to check the docs for more information",
    "ERROR [2026-10-29 14:13:27.10]: bad decrypt",
    "ERROR [2026-10-29 14:13:27.10]: Couldn't decrypt the repo, please make sure you enter the right password!",
    "bundler: failed to load command: fastlane (/Users/ci/.rbenv/versions/3.3.13/bin/fastlane)",
    "/Users/ci/.rbenv/versions/3.3.13/lib/ruby/gems/3.3.0/gems/fastlane-2.232.2/fastlane_core/lib/fastlane_core/ui/interface.rb:141:in `user_error!': [!] Invalid password passed via 'MATCH_PASSWORD' (FastlaneCore::Interface::FastlaneError)",
]

/// The lines of a recording in `Fixtures/Fastlane`, as the runner would deliver them: stdout, one line per entry.
private func recordingLines(_ name: String) throws -> [ToolOutputLine] {
    let url = try #require(Bundle.module.resourceURL?.appending(path: "Fixtures/Fastlane/\(name).txt"))
    let text = try String(contentsOf: url, encoding: .utf8)
    return text.components(separatedBy: "\n").map(stdoutLine)
}
