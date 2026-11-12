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
/// Call it inside a command body or inside the `SwiftCI { }` script, while the run is going. Calling it elsewhere
/// throws an internal error. A `name` must consist of letters, digits, `-` and `_`, must not start with `-`, and must
/// not be one of the reserved flags `list`, `help` or `verbose`. Otherwise it throws a usage error.
///
/// The value is written to the full log, with its name, and so is the default value. Only secrets that are declared
/// with ``Secret`` are masked there, so do not read a token or a password with `input`.
///
/// - Parameters:
///   - name: The name of the input, without dashes, for example `track` for `--track=beta`.
///   - defaultValue: The value used when neither the option nor the environment variable is set.
/// - Returns: The value of the input.
/// - Throws: ``BuildError`` with ``ErrorCode/usage`` if the value does not convert to `T` or the name is not valid, and
///   with ``ErrorCode/internal`` if the run is not going.
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

/// Reads the input `name` as a raw-value type that is also `CaseIterable`, such as `enum Track: String, CaseIterable`.
/// It behaves as ``input(_:default:)`` for raw-value types. A value that is not a case of `T` is a usage error that
/// lists the valid raw values.
///
/// - Parameters:
///   - name: The name of the input, without dashes.
///   - defaultValue: The value used when neither the option nor the environment variable is set.
/// - Returns: The case that the value names.
/// - Throws: ``BuildError`` with ``ErrorCode/usage`` if the value is not a case of `T`.
public func input<T: RawRepresentable & CaseIterable>(_ name: String, default defaultValue: T) throws -> T where T.RawValue: LosslessStringConvertible {
    try readInput(name, default: defaultValue, validValues: rawValuesOf(T.self)) { rawValueOf($0) }
}

/// Reads the input `name` as a raw-value type that is also `CaseIterable`, such as `enum Track: String, CaseIterable`.
/// It fails if neither the command line nor the environment gives one. Otherwise it behaves as
/// ``input(_:default:)`` for `CaseIterable` raw-value types.
///
/// ```swift
/// enum Track: String, CaseIterable { case beta, production }
///
/// let track: Track = try input("track")   // --track=beta, or TRACK=production
/// ```
///
/// - Parameter name: The name of the input, without dashes.
/// - Returns: The case that the value names.
/// - Throws: ``BuildError`` with ``ErrorCode/usage`` if the input is missing or the value is not a case of `T`. The
///   message lists the valid raw values.
public func input<T: RawRepresentable & CaseIterable>(_ name: String) throws -> T where T.RawValue: LosslessStringConvertible {
    try readInput(name, default: nil, validValues: rawValuesOf(T.self)) { rawValueOf($0) }
}

/// Reads an input for the public `input` overloads: the option, the environment, then `defaultValue`. A value that does
/// not convert with `convert` is a usage error. `validValues` are the raw values of a `CaseIterable` type. When given,
/// the usage errors list them.
///
/// The option is marked as read before the value is converted, so an input that fails is not reported as an unread
/// option as well.
internal func readInput<T>(
    _ name: String,
    default defaultValue: T?,
    validValues: [String]? = nil,
    convert: (String) -> T?
) throws -> T {
    guard let options = RunOptions.current else {
        throw BuildError(
            message: "input(\"\(name)\") may only be called while SwiftCI runs: inside the SwiftCI { } script or inside a command body.",
            code: .internal
        )
    }
    try validateInputName(name)
    RunOptions.current?.markRead(name)

    let option = "--\(name)=value"
    let environmentName = name.uppercased().replacingOccurrences(of: "-", with: "_")
    let inputTypeName = String(describing: T.self)

    // The valid values of a CaseIterable type, as the messages show them: "one of: beta, production".
    let accepted = validValues.map { "one of: \($0.joined(separator: ", "))" }

    let fromOption = options.values[name]
    let fromEnvironment = EnvironmentSource.value(environmentName).flatMap { $0.isEmpty ? nil : $0 }
    guard let raw = fromOption ?? fromEnvironment else {
        if let defaultValue {
            try FullLog.write("➤ Input \(name)=\(defaultValue)")
            return defaultValue
        }
        let message = accepted.map {
            "Missing input: pass \($0) as \(option), or set the environment variable \(environmentName) to one of them."
        } ?? "Missing input: pass \(option) or set the environment variable \(environmentName)."
        throw BuildError(message: message, code: .usage)
    }
    // Written before the conversion, so that a value that is not valid is in the full log too.
    try FullLog.write("➤ Input \(name)=\(raw)")
    guard let converted = convert(raw) else {
        let message: String
        if fromOption != nil {
            let fix = accepted.map { "Pass \($0) as \(option), or set \(environmentName) to one of them." }
                ?? "Pass a valid \(inputTypeName) as \(option), or set \(environmentName) to one."
            message = "Invalid value for --\(name): the value is not a valid \(inputTypeName). \(fix)"
        } else {
            let fix = accepted.map { "Set \(environmentName) to \($0), or pass \(option)." }
                ?? "Set \(environmentName) to a valid \(inputTypeName), or pass \(option)."
            message = "Invalid value in the environment variable \(environmentName): the value is not a valid \(inputTypeName). \(fix)"
        }
        throw BuildError(message: message, code: .usage)
    }
    return converted
}

/// Throws a usage error unless `name` can be given as `--name=value` and read from an environment variable: letters,
/// digits, `-` and `_`, not starting with `-`, and not a reserved flag.
private func validateInputName(_ name: String) throws {
    guard !name.isEmpty else {
        throw BuildError(message: "input needs a non-empty name, for example input(\"track\").", code: .usage)
    }
    guard !RunArguments.reservedFlags.contains(name) else {
        throw BuildError(
            message: "input(\"\(name)\") uses a reserved name. list, help and verbose are command-line flags, not inputs. Choose another name.",
            code: .usage
        )
    }
    let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
    guard !name.hasPrefix("-"), name.unicodeScalars.allSatisfy(allowed.contains) else {
        throw BuildError(
            message: "The input name \"\(name)\" is not valid. Use letters, digits, '-' and '_', and do not start with '-', for example \"build-number\".",
            code: .usage
        )
    }
}

/// The case of `T` whose raw value is `text`, or `nil` if there is none.
private func rawValueOf<T: RawRepresentable>(_ text: String) -> T? where T.RawValue: LosslessStringConvertible {
    guard let raw = T.RawValue(text) else { return nil }
    return T(rawValue: raw)
}

/// The raw values of the cases of `T`, in declaration order, as the text that the command line shows.
private func rawValuesOf<T: RawRepresentable & CaseIterable>(_: T.Type) -> [String] where T.RawValue: LosslessStringConvertible {
    T.allCases.map { $0.rawValue.description }
}
