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

@propertyWrapper public struct Use<Interface> {
    public init() { }
    public var wrappedValue: Interface {
        let id = ObjectIdentifier(Interface.self)
        guard let result = registrations[id] as? Interface else {
            fatalError("Error: no implementation registered for <\(String(describing: Interface.self))>.")
        }
        return result
    }
}
