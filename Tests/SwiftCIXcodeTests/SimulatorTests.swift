@testable import SwiftCIXcode
@testable import SwiftCITestSupport
import Foundation
@testable import SwiftCI
import SwiftCITesting
import Testing

extension GlobalStateTests {
    /// `Simulator`, with a mock runner, so no `simctl` is started.
    @Suite(.serialized) struct SimulatorTests {
        @Test func destinationNamesTheDeviceAndTheOS() {
            let destination = Simulator.destination(device: "iPhone 17", os: "26.0")

            #expect(destination == "platform=iOS Simulator,name=iPhone 17,OS=26.0")
        }

        @Test func shutdownAllRunsSimctlWithTheExpectedArguments() async throws {
            let (_, runner) = registerToolMocks()

            try await Simulator.shutdownAll()

            #expect(runner.tools.count == 1)
            #expect(runner.tools[0].command == "/usr/bin/xcrun")
            #expect(runner.tools[0].arguments == ["simctl", "shutdown", "all"])
        }

        /// The step opens its default name at the top level of a command.
        @Test func shutdownAllOpensItsDefaultStepName() async {
            let runner = ProcessRunnerMock()

            let result = await SwiftCITest.run(["shutdown"]) {
                register(ProcessRunner.self, runner)
                command(Command("shutdown") {
                    try await Simulator.shutdownAll()
                })
            }

            #expect(result.exitCode == 0)
            #expect(enteredSteps(in: result.log) == ["Entering step [Shut down simulators]"])
            #expect(runner.tools.count == 1)
        }

        /// `step:` renames the step.
        @Test func shutdownAllStepNameCanBeChanged() async {
            let runner = ProcessRunnerMock()

            let result = await SwiftCITest.run(["named"]) {
                register(ProcessRunner.self, runner)
                command(Command("named") {
                    try await Simulator.shutdownAll(step: "Stop the simulators")
                })
            }

            #expect(result.exitCode == 0)
            #expect(enteredSteps(in: result.log) == ["Entering step [Stop the simulators]"])
        }

        /// A non-zero exit code fails the step, and so the command.
        @Test func shutdownAllFailsTheStepOnANonZeroExitCode() async {
            let runner = ProcessRunnerMock()
            runner.responses = [.init(stderr: "simctl failed", exitCode: 1)]

            let result = await SwiftCITest.run(["shutdown"]) {
                register(ProcessRunner.self, runner)
                command(Command("shutdown") {
                    try await Simulator.shutdownAll()
                })
            }

            #expect(result.exitCode != 0)
            #expect(enteredSteps(in: result.log) == ["Entering step [Shut down simulators]"])
            #expect(runner.tools.count == 1)
        }

        /// `quitApp` runs `killall` on the Simulator app.
        @Test func quitAppRunsKillallOnSimulator() async throws {
            let (_, runner) = registerToolMocks()

            try await Simulator.quitApp()

            #expect(runner.tools.count == 1)
            #expect(runner.tools[0].command == "/usr/bin/killall")
            #expect(runner.tools[0].arguments == ["Simulator"])
        }

        /// Exit code 1 with the message of `killall` for no match means that Simulator was not running, which is not an
        /// error. The message differs for root.
        @Test(arguments: [
            "No matching processes belonging to you were found",
            "No matching processes were found",
        ])
        func quitAppSucceedsWhenSimulatorIsNotRunning(message: String) async {
            let runner = ProcessRunnerMock()
            runner.responses = [.init(stderr: message, exitCode: 1)]

            let result = await SwiftCITest.run(["quit"]) {
                register(ProcessRunner.self, runner)
                command(Command("quit") {
                    try await Simulator.quitApp()
                })
            }

            #expect(result.exitCode == 0)
            #expect(enteredSteps(in: result.log) == ["Entering step [Quit Simulator]"])
            #expect(result.plainLog.contains { $0.contains("Simulator was not running") })
            #expect(!result.plainLog.contains { $0.contains("No matching processes") })
        }

        /// Exit code 1 with another message, such as a process that may not be signalled, fails the step and shows the
        /// message.
        @Test func quitAppFailsWhenKillallExitsWithOneForAnotherReason() async {
            let runner = ProcessRunnerMock()
            runner.responses = [.init(stderr: "killall: warning: kill -TERM 123: Operation not permitted", exitCode: 1)]

            let result = await SwiftCITest.run(["quit"]) {
                register(ProcessRunner.self, runner)
                command(Command("quit") {
                    try await Simulator.quitApp()
                })
            }

            #expect(result.exitCode != 0)
            #expect(result.plainLog.contains { $0.contains("killall exited with code 1. Details: killall: warning: kill -TERM 123: Operation not permitted") })
            #expect(!result.plainLog.contains { $0.contains("Simulator was not running") })
        }

        /// An exit code other than 0 or 1 fails the step, and the message names the code.
        @Test func quitAppFailsOnAnotherExitCode() async {
            let runner = ProcessRunnerMock()
            runner.responses = [.init(exitCode: 3)]

            let result = await SwiftCITest.run(["quit"]) {
                register(ProcessRunner.self, runner)
                command(Command("quit") {
                    try await Simulator.quitApp()
                })
            }

            #expect(result.exitCode != 0)
            #expect(enteredSteps(in: result.log) == ["Entering step [Quit Simulator]"])
            #expect(result.plainLog.contains { $0.contains("killall exited with code 3") })
        }

        /// `step:` renames the step of `quitApp`.
        @Test func quitAppStepNameCanBeChanged() async {
            let runner = ProcessRunnerMock()

            let result = await SwiftCITest.run(["named"]) {
                register(ProcessRunner.self, runner)
                command(Command("named") {
                    try await Simulator.quitApp(step: "Close the simulator app")
                })
            }

            #expect(result.exitCode == 0)
            #expect(enteredSteps(in: result.log) == ["Entering step [Close the simulator app]"])
        }

        /// The transform sets the key at the top level and in every entry of `DevicePreferences`, keeps the other keys,
        /// and keeps an entry that is not a dictionary.
        @Test func disablingHardwareKeyboardSetsTheKeyInEveryPlace() {
            let entryA: [String: Any] = ["ConnectHardwareKeyboard": true, "Language": "en"]
            let entryB: [String: Any] = ["ConnectHardwareKeyboard": false]
            let devicePreferences: [String: Any] = ["device-a": entryA, "device-b": entryB, "device-c": "text"]
            let contents: [String: Any] = [
                "ConnectHardwareKeyboard": true,
                "Other": "keep",
                "DevicePreferences": devicePreferences,
            ]

            let result = Simulator.disablingHardwareKeyboard(in: contents)

            #expect(result["ConnectHardwareKeyboard"] as? Bool == false)
            #expect(result["Other"] as? String == "keep")
            let resultPreferences = result["DevicePreferences"] as? [String: Any]
            let resultA = resultPreferences?["device-a"] as? [String: Any]
            #expect(resultA?["ConnectHardwareKeyboard"] as? Bool == false)
            #expect(resultA?["Language"] as? String == "en")
            let resultB = resultPreferences?["device-b"] as? [String: Any]
            #expect(resultB?["ConnectHardwareKeyboard"] as? Bool == false)
            #expect(resultPreferences?["device-c"] as? String == "text")
        }

        /// Without `DevicePreferences`, the transform adds no such key.
        @Test func disablingHardwareKeyboardAddsNoDevicePreferences() {
            let result = Simulator.disablingHardwareKeyboard(in: [:])

            #expect(result["ConnectHardwareKeyboard"] as? Bool == false)
            #expect(result["DevicePreferences"] == nil)
        }

        /// A missing file is created in binary format, and the parent folder is created too.
        @Test func missingPreferencesFileIsCreatedInBinaryFormat() async throws {
            _ = registerToolMocks()
            let directory = temporaryArtifactsDirectory().deletingLastPathComponent()
            defer { try? FileManager.default.removeItem(at: directory) }
            let url = directory.appending(path: "Library/Preferences/com.apple.iphonesimulator.plist")

            try await Simulator.disableHardwareKeyboard(preferencesURL: url)

            let data = try Data(contentsOf: url)
            #expect(data.prefix(8) == Data("bplist00".utf8))
            let contents = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
            #expect(contents?["ConnectHardwareKeyboard"] as? Bool == false)
        }

        /// An existing XML file keeps its format and its other keys.
        @Test func existingPreferencesFileKeepsItsFormatAndOtherKeys() async throws {
            _ = registerToolMocks()
            let directory = temporaryArtifactsDirectory().deletingLastPathComponent()
            defer { try? FileManager.default.removeItem(at: directory) }
            let url = directory.appending(path: "com.apple.iphonesimulator.plist")
            let entry: [String: Any] = ["ConnectHardwareKeyboard": true, "Scale": 2]
            let original: [String: Any] = [
                "AppleLocale": "en_US",
                "DevicePreferences": ["device-a": entry],
            ]
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try PropertyListSerialization.data(fromPropertyList: original, format: .xml, options: 0).write(to: url)

            try await Simulator.disableHardwareKeyboard(preferencesURL: url)

            let data = try Data(contentsOf: url)
            var format = PropertyListSerialization.PropertyListFormat.binary
            let contents = try PropertyListSerialization.propertyList(from: data, options: [], format: &format) as? [String: Any]
            #expect(format == .xml)
            #expect(contents?["AppleLocale"] as? String == "en_US")
            #expect(contents?["ConnectHardwareKeyboard"] as? Bool == false)
            let resultPreferences = contents?["DevicePreferences"] as? [String: Any]
            let resultEntry = resultPreferences?["device-a"] as? [String: Any]
            #expect(resultEntry?["ConnectHardwareKeyboard"] as? Bool == false)
            #expect(resultEntry?["Scale"] as? Int == 2)
        }

        /// A file that is not a dictionary fails the step, and is not changed.
        @Test func preferencesFileThatIsNotADictionaryIsNotChanged() async throws {
            _ = registerToolMocks()
            let directory = temporaryArtifactsDirectory().deletingLastPathComponent()
            defer { try? FileManager.default.removeItem(at: directory) }
            let url = directory.appending(path: "com.apple.iphonesimulator.plist")
            let original = try PropertyListSerialization.data(fromPropertyList: ["not", "a", "dictionary"], format: .xml, options: 0)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try original.write(to: url)

            let error = await thrownError {
                try await Simulator.disableHardwareKeyboard(preferencesURL: url)
            }

            #expect(error != nil)
            #expect(try Data(contentsOf: url) == original)
        }

        /// The default step name of the hardware keyboard change, and `step:` renames it.
        @Test func disableHardwareKeyboardOpensItsDefaultStepName() async {
            let directory = temporaryArtifactsDirectory().deletingLastPathComponent()
            defer { try? FileManager.default.removeItem(at: directory) }
            let url = directory.appending(path: "com.apple.iphonesimulator.plist")

            let result = await SwiftCITest.run(["keyboard"]) {
                command(Command("keyboard") {
                    try await Simulator.disableHardwareKeyboard(preferencesURL: url)
                })
            }
            let renamed = await SwiftCITest.run(["renamed"]) {
                command(Command("renamed") {
                    try await Simulator.disableHardwareKeyboard(preferencesURL: url, step: "Turn off the keyboard")
                })
            }

            #expect(result.exitCode == 0)
            #expect(enteredSteps(in: result.log) == ["Entering step [Disable the hardware keyboard]"])
            #expect(enteredSteps(in: renamed.log) == ["Entering step [Turn off the keyboard]"])
        }
    }
}
