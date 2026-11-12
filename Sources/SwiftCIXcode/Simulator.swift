import Foundation
import SwiftCI

/// Simulator management with `xcrun simctl`, the Simulator app and its preferences.
///
/// ``shutdownAll(step:)`` is meant for a `cleanup` handler on CI:
///
///     cleanup(when: .onCI) { try await Simulator.shutdownAll() }
///
/// ``destination(device:os:)`` gives the `xcodebuild` destination of an iOS simulator. Before UI tests, call
/// ``shutdownAll(step:)``, ``quitApp(step:)`` and ``disableHardwareKeyboard(step:)``.
public enum Simulator {
    @Use private static var log: Log

    /// The `xcodebuild` destination of the iOS simulator `device` with the runtime `os`, such as
    /// `platform=iOS Simulator,name=iPhone 17,OS=latest`. Pass it as `destination` to
    /// ``Xcode/test(destination:testPlan:resultBundleURL:rawLogURL:enableCodeCoverage:timeout:step:)``.
    ///
    /// This is a query: it does not open a step or check that the simulator exists.
    ///
    /// - Parameters:
    ///   - device: The name of the simulator device, for example `iPhone 17`.
    ///   - os: The iOS version of the simulator runtime, for example `26.0`, or `latest`.
    /// - Returns: The destination string.
    public static func destination(device: String, os: String) -> String {
        "platform=iOS Simulator,name=\(device),OS=\(os)"
    }

    /// Runs `xcrun simctl shutdown all`, which shuts down every simulator. A non-zero exit code fails the step.
    ///
    /// Opens a step named "Shut down simulators" when called at the top level of a command. `step` renames it.
    public static func shutdownAll(step name: String? = nil) async throws {
        try await step(default: "Shut down simulators", name: name) {
            let tool = Tool(
                command: Xcode.xcrunPath,
                arguments: ["simctl", "shutdown", "all"]
            )
            try await tool.run()
        }
    }

    /// Quits the Simulator app with `killall Simulator`. The app is asked to quit, as `killall` sends it SIGTERM.
    ///
    /// Exit code 1 with the message "No matching processes" means that Simulator was not running. That is the normal
    /// case, so it is not an error. Any other non-zero exit code, and exit code 1 with another message, such as a
    /// Simulator of another user that may not be signalled, fails the step. The message names the exit code.
    ///
    /// Opens a step named "Quit Simulator" when called at the top level of a command. `step` renames it.
    public static func quitApp(step name: String? = nil) async throws {
        try await step(default: "Quit Simulator", name: name) {
            let tool = Tool(
                command: killallPath,
                arguments: ["Simulator"],
                filters: [quitAppFilter]
            )
            let result = try await tool.result()
            switch result.exitCode {
            case 0:
                break
            case 1 where result.stderr.contains(Self.noMatchingProcesses):
                log("Simulator was not running")
            default:
                let details = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                throw BuildError(
                    message: "Failed to quit Simulator. killall exited with code \(result.exitCode)."
                        + (details.isEmpty ? "" : " Details: \(details)")
                )
            }
        }
    }

    /// Sets `ConnectHardwareKeyboard` to `false` in the Simulator preferences, at the top level and in every entry of
    /// `DevicePreferences`, so that simulators show the software keyboard.
    ///
    /// A typed text field in a UI test fails while the hardware keyboard is connected, because the software keyboard is
    /// hidden then. The file is `~/Library/Preferences/com.apple.iphonesimulator.plist` of the current user. Other keys
    /// are kept, and an entry of `DevicePreferences` that is not a dictionary is kept unchanged. A missing file is
    /// created, in binary format. An existing file keeps its format.
    ///
    /// A running Simulator may write its old values back when it quits, so call ``quitApp(step:)`` before this.
    /// A file that is not a property list dictionary fails the step, and the file is not changed.
    ///
    /// Opens a step named "Disable the hardware keyboard" when called at the top level of a command. `step` renames it.
    public static func disableHardwareKeyboard(step name: String? = nil) async throws {
        try await disableHardwareKeyboard(preferencesURL: preferencesURL, step: name)
    }

    /// The pure transform of ``disableHardwareKeyboard(step:)``: returns `contents` with `ConnectHardwareKeyboard` set to
    /// `false`, at the top level and in each dictionary entry of `DevicePreferences`. Other values are kept as they are.
    static func disablingHardwareKeyboard(in contents: [String: Any]) -> [String: Any] {
        var result = contents
        result["ConnectHardwareKeyboard"] = false
        if let devicePreferences = contents["DevicePreferences"] as? [String: Any] {
            result["DevicePreferences"] = devicePreferences.mapValues { value -> Any in
                guard var entry = value as? [String: Any] else { return value }
                entry["ConnectHardwareKeyboard"] = false
                return entry
            }
        }
        return result
    }

    /// ``disableHardwareKeyboard(step:)`` for the preferences file at `preferencesURL`. Tests use a temporary file.
    static func disableHardwareKeyboard(preferencesURL url: URL, step name: String? = nil) async throws {
        try await step(default: "Disable the hardware keyboard", name: name) {
            let (contents, format) = try readPreferences(at: url)
            let data: Data
            do {
                data = try PropertyListSerialization.data(
                    fromPropertyList: disablingHardwareKeyboard(in: contents),
                    format: format,
                    options: 0
                )
            } catch {
                throw BuildError(message: "Failed to write property list '\(url.filePath)'. Details: \(error)")
            }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                throw BuildError(message: "Failed to write file '\(url.filePath)'. Details: \(error)")
            }
            log("Disabled the hardware keyboard in '\(url.filePath)'")
        }
    }

    /// The contents of the preferences file at `url` and the format it is written in. A missing file has no contents and
    /// the binary format. A file that is not a dictionary is an error, so that its values are not lost.
    private static func readPreferences(at url: URL) throws -> ([String: Any], PropertyListSerialization.PropertyListFormat) {
        var format = PropertyListSerialization.PropertyListFormat.binary
        guard FileManager.default.fileExists(atPath: url.filePath) else {
            return ([:], format)
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw BuildError(message: "Failed to read file '\(url.filePath)'. Details: \(error)")
        }
        let propertyList: Any
        do {
            propertyList = try PropertyListSerialization.propertyList(from: data, options: [], format: &format)
        } catch {
            throw BuildError(message: "Failed to read property list '\(url.filePath)'. Details: \(error)")
        }
        guard let contents = propertyList as? [String: Any] else {
            throw BuildError(
                message: "The property list '\(url.filePath)' is not a dictionary, so it was not changed. "
                    + "Fix or remove the file, then run again."
            )
        }
        return (contents, format)
    }

    private static var preferencesURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Preferences/com.apple.iphonesimulator.plist")
    }

    /// The start of the message of `killall` when no process matched: "No matching processes belonging to you were
    /// found", or "No matching processes were found" for root.
    private static let noMatchingProcesses = "No matching processes"

    /// Hides the message of `killall` when no process matched. The step handles that case, so the message adds nothing.
    static let quitAppFilter: Filter = { line in
        line.contains(noMatchingProcesses) ? nil : line
    }

    private static let killallPath = "/usr/bin/killall"
}
