@_spi(Testing) import SwiftCI
@testable import SwiftCI
@testable import SwiftCITestSupport
import SwiftCITesting
import Testing

/// A raw-value input type for the tests.
private enum Track: String, Equatable {
    case beta
    case production
}

extension GlobalStateTests {
    @Suite(.serialized) struct InputTests {
        @Test func optionWinsOverEnvironmentAndDefault() async {
            var values: [String] = []
            let result = await SwiftCITest.run(["test", "--device=iPad"], environment: ["DEVICE": "iPhone"]) {
                command(Command("test") {
                    let device: String = try input("device", default: "iPhone 17")
                    values.append(device)
                })
            }

            #expect(result.exitCode == 0)
            #expect(values == ["iPad"])
        }

        @Test func environmentWinsOverDefault() async {
            var values: [String] = []
            let result = await SwiftCITest.run(["test"], environment: ["DEVICE": "iPhone"]) {
                command(Command("test") {
                    let device: String = try input("device", default: "iPhone 17")
                    values.append(device)
                })
            }

            #expect(result.exitCode == 0)
            #expect(values == ["iPhone"])
        }

        @Test func defaultIsUsedWhenNothingIsGiven() async {
            var values: [String] = []
            let result = await SwiftCITest.run(["test"]) {
                command(Command("test") {
                    let device: String = try input("device", default: "iPhone 17")
                    values.append(device)
                })
            }

            #expect(result.exitCode == 0)
            #expect(values == ["iPhone 17"])
        }

        @Test func hyphenatedNameReadsUpperCaseEnvironmentVariableWithUnderscores() async {
            var values: [Int] = []
            let result = await SwiftCITest.run(["test"], environment: ["BUILD_NUMBER": "42"]) {
                command(Command("test") {
                    let number: Int = try input("build-number")
                    values.append(number)
                })
            }

            #expect(result.exitCode == 0)
            #expect(values == [42])
        }

        @Test func emptyEnvironmentVariableCountsAsNotSet() async {
            var values: [String] = []
            let result = await SwiftCITest.run(["test"], environment: ["DEVICE": ""]) {
                command(Command("test") {
                    let device: String = try input("device", default: "iPhone 17")
                    values.append(device)
                })
            }

            #expect(result.exitCode == 0)
            #expect(values == ["iPhone 17"])
        }

        @Test func emptyOptionValueIsAValidValue() async {
            var values: [String] = []
            let result = await SwiftCITest.run(["test", "--device="], environment: ["DEVICE": "iPhone"]) {
                command(Command("test") {
                    let device: String = try input("device", default: "iPhone 17")
                    values.append(device)
                })
            }

            #expect(result.exitCode == 0)
            #expect(values == [""])
        }

        @Test func optionValueMayContainEquals() async {
            var values: [String] = []
            let result = await SwiftCITest.run(["test", "--note=a=b"]) {
                command(Command("test") {
                    let note: String = try input("note", default: "")
                    values.append(note)
                })
            }

            #expect(result.exitCode == 0)
            #expect(values == ["a=b"])
        }

        @Test func spaceSeparatedOptionIsAUsageErrorNamingTheForm() async {
            var ran = false
            let result = await SwiftCITest.run(["test", "--device", "iPad"]) {
                command(Command("test") { ran = true })
            }

            let lines = result.log.map(stripANSI)
            #expect(result.exitCode == 2)
            #expect(!ran)
            #expect(lines.contains { $0.hasPrefix("<Error>") && $0.contains("--device=value") })
        }

        @Test func bareOptionIsAUsageErrorNamingTheForm() async {
            var ran = false
            let result = await SwiftCITest.run(["test", "--skip-tests"]) {
                command(Command("test") { ran = true })
            }

            let lines = result.log.map(stripANSI)
            #expect(result.exitCode == 2)
            #expect(!ran)
            #expect(lines.contains { $0.hasPrefix("<Error>") && $0.contains("--skip-tests=value") })
        }

        @Test func boolInputAcceptsTrueAndFalse() async {
            var values: [Bool] = []
            let result = await SwiftCITest.run(["test", "--skip-tests=true", "--run-ui=false"]) {
                command(Command("test") {
                    let skip: Bool = try input("skip-tests", default: false)
                    let ui: Bool = try input("run-ui", default: true)
                    values.append(contentsOf: [skip, ui])
                })
            }

            #expect(result.exitCode == 0)
            #expect(values == [true, false])
        }

        @Test func commandNamesAndOptionsCanBeMixed() async {
            var values: [String] = []
            var ran: [String] = []
            let result = await SwiftCITest.run(["--track=beta", "test", "--device=iPad", "release"]) {
                command(Command("test") {
                    ran.append("test")
                    let track: String = try input("track")
                    values.append(track)
                    let device: String = try input("device", default: "iPhone 17")
                    values.append(device)
                })
                command(Command("release") {
                    ran.append("release")
                    let track: String = try input("track")
                    values.append(track)
                })
            }

            #expect(result.exitCode == 0)
            #expect(ran == ["test", "release"])
            #expect(values == ["beta", "iPad", "beta"])
        }

        @Test func missingRequiredInputIsAUsageErrorNamingOptionAndEnvironmentVariable() async {
            var ran = false
            let result = await SwiftCITest.run(["test"]) {
                command(Command("test") {
                    ran = true
                    let track: String = try input("track")
                    _ = track
                })
            }

            let lines = result.log.map(stripANSI)
            #expect(result.exitCode == 2)
            #expect(ran)
            #expect(lines.contains("<Error> Missing input: pass --track=value or set the environment variable TRACK."))
        }

        @Test func inputInScriptClosureWorks() async {
            var values: [String] = []
            let result = await SwiftCITest.run(["test"], environment: ["TRACK": "beta"]) {
                let track: String = try input("track")
                command(Command("test") { values.append(track) })
            }

            #expect(result.exitCode == 0)
            #expect(values == ["beta"])
        }

        @Test func missingInputInScriptClosureIsAUsageError() async {
            let result = await SwiftCITest.run(["test"]) {
                let track: String = try input("track")
                command(Command("test") { _ = track })
            }

            #expect(result.exitCode == 2)
            #expect(result.log.map(stripANSI).contains("<Error> Missing input: pass --track=value or set the environment variable TRACK."))
        }

        @Test func invalidOptionValueIsAUsageErrorNamingOptionEnvironmentVariableAndType() async {
            var ran = false
            let result = await SwiftCITest.run(["test", "--build-number=abc"]) {
                command(Command("test") {
                    ran = true
                    let number: Int = try input("build-number")
                    _ = number
                })
            }

            let lines = result.log.map(stripANSI)
            #expect(result.exitCode == 2)
            #expect(ran)
            #expect(lines.contains { $0.hasPrefix("<Error>") && $0.contains("--build-number=value") && $0.contains("BUILD_NUMBER") && $0.contains("Int") })
        }

        @Test func invalidEnvironmentValueIsAUsageErrorNamingTheVariable() async {
            let result = await SwiftCITest.run(["test"], environment: ["BUILD_NUMBER": "abc"]) {
                command(Command("test") {
                    let number: Int = try input("build-number")
                    _ = number
                })
            }

            let lines = result.log.map(stripANSI)
            #expect(result.exitCode == 2)
            #expect(lines.contains { $0.hasPrefix("<Error>") && $0.contains("BUILD_NUMBER") && $0.contains("Int") })
        }

        @Test func optionAppliesToEveryCommand() async {
            var values: [String] = []
            let result = await SwiftCITest.run(["test", "release", "--track=beta"]) {
                command(Command("test") {
                    let track: String = try input("track")
                    values.append(track)
                })
                command(Command("release") {
                    let track: String = try input("track")
                    values.append(track)
                })
            }

            let lines = result.log.map(stripANSI)
            #expect(result.exitCode == 0)
            #expect(values == ["beta", "beta"])
            #expect(!lines.contains { $0.contains("No input read these options") })
        }

        @Test func rawValueInputConvertsFromRawValue() async {
            var values: [Track] = []
            let result = await SwiftCITest.run(["test", "--track=production"]) {
                command(Command("test") {
                    let track: Track = try input("track")
                    values.append(track)
                })
            }

            #expect(result.exitCode == 0)
            #expect(values == [.production])
        }

        @Test func rawValueInputWithDefaultUsesDefaultWhenMissing() async {
            var values: [Track] = []
            let result = await SwiftCITest.run(["test"]) {
                command(Command("test") {
                    let track: Track = try input("track", default: .beta)
                    values.append(track)
                })
            }

            #expect(result.exitCode == 0)
            #expect(values == [.beta])
        }

        @Test func unknownRawValueIsAUsageError() async {
            let result = await SwiftCITest.run(["test", "--track=nightly"]) {
                command(Command("test") {
                    let track: Track = try input("track")
                    _ = track
                })
            }

            let lines = result.log.map(stripANSI)
            #expect(result.exitCode == 2)
            #expect(lines.contains { $0.hasPrefix("<Error>") && $0.contains("--track=value") && $0.contains("Track") })
        }

        @Test func duplicateOptionIsAUsageError() async {
            var ran = false
            let result = await SwiftCITest.run(["test", "--device=a", "--device=b"]) {
                command(Command("test") { ran = true })
            }

            let lines = result.log.map(stripANSI)
            #expect(result.exitCode == 2)
            #expect(!ran)
            #expect(lines.contains { $0.hasPrefix("<Error>") && $0.contains("--device") && $0.contains("more than once") })
        }

        @Test func unreadOptionIsWarnedAfterASuccessfulRun() async {
            let result = await SwiftCITest.run(["test", "--trak=beta"]) {
                command(Command("test") {
                    let device: String = try input("device", default: "iPhone 17")
                    _ = device
                })
            }

            let lines = result.log.map(stripANSI)
            #expect(result.exitCode == 0)
            #expect(lines.contains("<Warning> No input read these options: --trak. Check their spelling, or remove them."))
        }

        @Test func unreadOptionIsWarnedAfterAFailedRunWithTheSameExitCode() async {
            let result = await SwiftCITest.run(["test", "--trak=beta"]) {
                command(Command("test") {
                    try await step("Work") { throw TestError.boom }
                })
            }

            let lines = result.log.map(stripANSI)
            #expect(result.exitCode == 1)
            #expect(lines.contains { $0.hasPrefix("<Warning> No input read these options: --trak") })
            #expect(lines.contains("Command [test] failed"))
        }

        @Test func warningListsEveryUnreadOptionInNameOrder() async {
            let result = await SwiftCITest.run(["test", "--trak=beta", "--dvice=iPad", "--device=iPhone"]) {
                command(Command("test") {
                    let device: String = try input("device", default: "iPhone 17")
                    _ = device
                })
            }

            let lines = result.log.map(stripANSI)
            #expect(result.exitCode == 0)
            #expect(lines.contains("<Warning> No input read these options: --dvice, --trak. Check their spelling, or remove them."))
        }

        @Test func optionReadInFailedCommandIsNotWarned() async {
            let result = await SwiftCITest.run(["test", "--device=iPad"]) {
                command(Command("test") {
                    let device: String = try input("device", default: "iPhone 17")
                    _ = device
                    throw TestError.boom
                })
            }

            let lines = result.log.map(stripANSI)
            #expect(result.exitCode == 1)
            #expect(!lines.contains { $0.contains("No input read these options") })
        }

        @Test func verboseWithCommandRunsTheCommand() async {
            var ran = false
            let result = await SwiftCITest.run(["test", "--verbose"]) {
                command(Command("test") { ran = true })
            }

            let lines = result.log.map(stripANSI)
            #expect(result.exitCode == 0)
            #expect(ran)
            #expect(!lines.contains { $0.contains("No input read these options") })
        }

        @Test func unknownCommandWithOptionsWarnsNothing() async {
            let result = await SwiftCITest.run(["missing", "--trak=beta"]) {
                command(Command("test") { })
            }

            let lines = result.log.map(stripANSI)
            #expect(result.exitCode == 2)
            #expect(!lines.contains { $0.contains("No input read these options") })
        }
    }

    @Suite(.serialized) struct ArgumentsTests {
        @Test func listWithCommandsPrintsTheListAndRunsNothing() async {
            var ran = false
            let result = await SwiftCITest.run(["test", "release", "--list", "--track=beta"]) {
                command(Command("test", description: "Run the unit tests.") { ran = true })
                command(Command("release") { ran = true })
            }

            let lines = result.log.map(stripANSI)
            #expect(result.exitCode == 0)
            #expect(!ran)
            #expect(lines.suffix(3) == ["Available commands:", "  test     Run the unit tests.", "  release"])
            #expect(!lines.contains { $0.contains("No input read these options") })
        }

        @Test func helpPrintsUsageAndCommandsAndRunsNothing() async {
            var ran = false
            let result = await SwiftCITest.run(["test", "--help"]) {
                command(Command("test", description: "Run the unit tests.") { ran = true })
            }

            let lines = result.log.map(stripANSI)
            #expect(result.exitCode == 0)
            #expect(!ran)
            #expect(lines.first == "Usage:")
            #expect(lines.contains { $0.contains("--name=value") })
            #expect(lines.contains { $0.contains("--list") })
            #expect(lines.contains { $0.contains("--verbose") })
            #expect(lines.suffix(2) == ["Available commands:", "  test  Run the unit tests."])
        }

        @Test func helpShowsTheProgramNameWithAlignedDescriptions() async {
            let log = LogMock()
            let exitCode = await SwiftCITest.withMocks(log: log) {
                await runSwiftCI(arguments: ["--help"], programName: "./sci") {
                    command(Command("test") { })
                }
            }

            let lines = log.loggedLines.map(stripANSI)
            #expect(exitCode == 0)
            let forms = Array(lines.dropFirst().prefix(4))
            #expect(forms.allSatisfy { $0.hasPrefix("  ./sci ") })
            #expect(forms[0] == "  ./sci <command> [<command> ...] [--name=value ...]  Run commands in order; stop at the first failed command.")
            #expect(forms[1].hasPrefix("  ./sci --list   "))
            // Every description starts in the same column.
            let descriptions = [
                "Run commands in order; stop at the first failed command.",
                "List available commands.",
                "Show unfiltered tool output on the console.",
                "Show this usage and the command list.",
            ]
            #expect(zip(forms, descriptions).allSatisfy { $0.hasSuffix($1) })
            #expect(Set(zip(forms, descriptions).map { $0.count - $1.count }).count == 1)
        }

        @Test func programNameIsTheExecutableFileName() {
            #expect(programName(executablePath: "/tmp/build/debug/sci") == "./sci")
            #expect(programName(executablePath: "ci") == "./ci")
            #expect(programName(executablePath: nil) == "./ci")
            #expect(programName(executablePath: "") == "./ci")
        }

        @Test func helpWinsOverList() async {
            let result = await SwiftCITest.run(["--list", "--help"]) {
                command(Command("test") { })
            }

            let lines = result.log.map(stripANSI)
            #expect(result.exitCode == 0)
            #expect(lines.first == "Usage:")
        }

        @Test func helpWithValueIsAUsageError() async {
            var ran = false
            let result = await SwiftCITest.run(["test", "--help=x"]) {
                command(Command("test") { ran = true })
            }

            let lines = result.log.map(stripANSI)
            #expect(result.exitCode == 2)
            #expect(!ran)
            #expect(lines.contains { $0.hasPrefix("<Error>") && $0.contains("--help") && $0.contains("takes no value") })
        }

        @Test func listWithValueIsAUsageError() async {
            let result = await SwiftCITest.run(["--list=yes"]) {
                command(Command("test") { })
            }

            #expect(result.exitCode == 2)
        }

        @Test func malformedArgumentStopsBeforeTheScriptRuns() async {
            var scriptRan = false
            var ran = false
            let result = await SwiftCITest.run(["--=x", "test"]) {
                scriptRan = true
                command(Command("test") { ran = true })
            }

            let lines = result.log.map(stripANSI)
            #expect(result.exitCode == 2)
            #expect(!scriptRan)
            #expect(!ran)
            #expect(lines.contains { $0.hasPrefix("<Error>") && $0.contains("no name") })
        }

        @Test func bareDoubleDashIsAUsageError() async {
            let result = await SwiftCITest.run(["--"]) {
                command(Command("test") { })
            }

            #expect(result.exitCode == 2)
        }

        @Test func repeatedFlagIsAUsageError() async {
            var ran = false
            let result = await SwiftCITest.run(["test", "--verbose", "--verbose"]) {
                command(Command("test") { ran = true })
            }

            #expect(result.exitCode == 2)
            #expect(!ran)
        }

        @Test func runArgumentsSplitsCommandsOptionsAndFlags() throws {
            let arguments = try RunArguments(parsing: ["test", "--track=beta", "release", "--verbose", "--note=a=b"])

            #expect(arguments.commandNames == ["test", "release"])
            #expect(arguments.options == ["track": "beta", "note": "a=b"])
            #expect(arguments.flags == ["verbose"])
        }
    }
}
