import Foundation

// Inputs are read from the options of the run, then from the environment, then from the default. An input is a
// value of the script, not a secret: secrets are declared with `Secret`.

/// Reads the input `name` as a value of type `T`, or returns `defaultValue` if neither the command line nor the
/// environment gives one. This is not a step: it reads a value and does not change anything.
///
/// The value is read in this order:
/// 1. The option `--name=value` on the command line. An empty value is a valid value.
/// 2. The environment variable with the upper-case name, with `-` replaced by `_`. For example `build-number` reads
///    `BUILD_NUMBER`. An empty variable counts as not set.
/// 3. `defaultValue`.
///
/// ```swift
/// let device: String = try input("device", default: "iPhone 17")
/// ```
///
/// Call it inside a command body or inside the `SwiftCI { }` script, while the run is going. Calling it elsewhere is a
/// programming error and stops the process. The same goes for a `name` that is empty or is one of the reserved flags
/// `list`, `help` or `verbose`. This check is not unit tested.
///
/// - Parameters:
///   - name: The name of the input, without dashes, for example `track` for `--track=beta`.
///   - defaultValue: The value used when neither the option nor the environment variable is set.
/// - Returns: The value of the input.
/// - Throws: ``BuildError`` with ``ErrorCode/usage`` if the value does not convert to `T`.
public func input<T: LosslessStringConvertible>(_ name: String, default defaultValue: T) throws -> T {
    try readInput(name, default: defaultValue) { T($0) }
}

/// Reads the input `name` as a value of type `T`. It fails if neither the command line nor the environment gives one.
/// This is not a step: it reads a value and does not change anything.
///
/// The value is read from the option `--name=value`, then from the environment variable with the upper-case name, as
/// in ``input(_:default:)``. A missing value is a usage error.
///
/// - Parameter name: The name of the input, without dashes, for example `build-number` for `--build-number=42`.
/// - Returns: The value of the input.
/// - Throws: ``BuildError`` with ``ErrorCode/usage`` if the input is missing or the value does not convert to `T`. The
///   message names the option and the environment variable.
public func input<T: LosslessStringConvertible>(_ name: String) throws -> T {
    try readInput(name, default: nil) { T($0) }
}

/// Reads the input `name` as a raw-value type, such as `enum Track: String`. The raw value is read as in
/// ``input(_:default:)``, and it must convert to a case of `T`.
///
/// ```swift
/// enum Track: String { case beta, production }
///
/// let track: Track = try input("track")
/// ```
///
/// Call it as ``input(_:default:)``. The same programming error applies.
///
/// - Parameters:
///   - name: The name of the input, without dashes.
///   - defaultValue: The value used when neither the option nor the environment variable is set.
/// - Returns: The case that the value names.
/// - Throws: ``BuildError`` with ``ErrorCode/usage`` if the value is not a case of `T`.
public func input<T: RawRepresentable>(_ name: String, default defaultValue: T) throws -> T where T.RawValue: LosslessStringConvertible {
    try readInput(name, default: defaultValue) { rawValueOf($0) }
}

/// Reads the input `name` as a raw-value type, such as `enum Track: String`. It fails if neither the command line nor
/// the environment gives one. Otherwise it behaves as ``input(_:default:)`` for raw-value types.
///
/// - Parameter name: The name of the input, without dashes.
/// - Returns: The case that the value names.
/// - Throws: ``BuildError`` with ``ErrorCode/usage`` if the input is missing or the value is not a case of `T`.
public func input<T: RawRepresentable>(_ name: String) throws -> T where T.RawValue: LosslessStringConvertible {
    try readInput(name, default: nil) { rawValueOf($0) }
}

/// The case of `T` whose raw value is `text`, or `nil` if there is none.
private func rawValueOf<T: RawRepresentable>(_ text: String) -> T? where T.RawValue: LosslessStringConvertible {
    guard let raw = T.RawValue(text) else { return nil }
    return T(rawValue: raw)
}

/// Reads an input for the public `input` overloads: the option, the environment, then `defaultValue`. A value that does
/// not convert with `convert` is a usage error.
///
/// The option is marked as read before the value is converted, so an input that fails is not reported as an unread
/// option as well.
internal func readInput<T>(_ name: String, default defaultValue: T?, convert: (String) -> T?) throws -> T {
    guard let options = RunOptions.current else {
        preconditionFailure(
            "input(\"\(name)\") may only be called while SwiftCI runs: inside the SwiftCI { } script or inside a command body."
        )
    }
    precondition(!name.isEmpty, "input needs a non-empty name, for example input(\"track\").")
    precondition(
        !RunArguments.reservedFlags.contains(name),
        "input(\"\(name)\") uses a reserved name. list, help and verbose are command-line flags, not inputs."
    )
    RunOptions.current?.markRead(name)

    let option = "--\(name)=value"
    let environmentName = name.uppercased().replacingOccurrences(of: "-", with: "_")
    let inputTypeName = String(describing: T.self)

    let fromOption = options.values[name]
    let fromEnvironment = EnvironmentSource.value(environmentName).flatMap { $0.isEmpty ? nil : $0 }
    guard let raw = fromOption ?? fromEnvironment else {
        if let defaultValue {
            return defaultValue
        }
        throw BuildError(
            message: "Missing input: pass \(option) or set the environment variable \(environmentName).",
            code: .usage
        )
    }
    guard let converted = convert(raw) else {
        let message = fromOption != nil
            ? "Invalid value for --\(name): the value is not a valid \(inputTypeName). Pass a valid \(inputTypeName) as \(option), or set \(environmentName) to one."
            : "Invalid value in the environment variable \(environmentName): the value is not a valid \(inputTypeName). Set \(environmentName) to a valid \(inputTypeName), or pass \(option)."
        throw BuildError(message: message, code: .usage)
    }
    return converted
}
