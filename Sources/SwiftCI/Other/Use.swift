var registrations = [ObjectIdentifier: Any]()

func register<Interface>(_ type: Interface.Type, _ instance: Interface) {
    let id = ObjectIdentifier(type)
    registrations[id] = instance
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
