/// The registered implementations, by interface type. Global state: tests save and restore it with
/// ``isolateGlobalState(environment:artifactsDirectory:)`` and ``restoreGlobalState(_:)``.
var registrations = [ObjectIdentifier: Any]()

/// Registers an implementation of `Interface`. A logger is always stored as a ``RedactingLog``, so that every line it
/// receives is masked. A logger that is already a `RedactingLog` is not wrapped again.
///
/// This is one generic function, not a separate `register(_: Log.Type, _: Log)` overload. Swift prefers the generic
/// function when the argument is a concrete mock, so an overload would not be chosen for `register(Log.self, LogMock())`.
func register<Interface>(_ type: Interface.Type, _ instance: Interface) {
    let id = ObjectIdentifier(type)
    if id == ObjectIdentifier(Log.self), let log = instance as? Log {
        registrations[id] = log as? RedactingLog ?? RedactingLog(log)
    } else {
        registrations[id] = instance
    }
}

/// Gives access to a registered implementation of `Interface`.
///
/// Declare it as a local variable or a property: `@Use var log: Log`. SwiftCI registers implementations of ``Log``,
/// ``ProcessRunner`` and ``HTTPClient`` when a script starts. Tests replace them with `SwiftCITesting`. Using it with
/// any other type, or outside a script and outside such a test, is a programming error and stops the program.
@propertyWrapper public struct Use<Interface> {
    /// Creates the property wrapper. The implementation is looked up each time the property is read.
    public init() { }

    /// The registered implementation of `Interface`.
    public var wrappedValue: Interface {
        let id = ObjectIdentifier(Interface.self)
        guard let result = registrations[id] as? Interface else {
            fatalError(
                "No implementation registered for <\(String(describing: Interface.self))>. "
                    + "Run the code inside `SwiftCI { … }`, or in a test inside `SwiftCITest.run` or `SwiftCITest.withMocks`."
            )
        }
        return result
    }
}
