// On platforms without Combine (Linux), provide minimal stand-ins for
// `ObservableObject` / `@Published` so the stores still type-check and work.
#if !canImport(Combine)
public protocol ObservableObject: AnyObject {}

@propertyWrapper
public struct Published<Value> {
    public var wrappedValue: Value
    public init(wrappedValue: Value) {
        self.wrappedValue = wrappedValue
    }
    public var projectedValue: Published<Value> {
        get { self }
        set { self = newValue }
    }
}

extension Published: Sendable where Value: Sendable {}
#endif
