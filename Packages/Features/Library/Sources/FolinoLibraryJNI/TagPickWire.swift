import Wirelet

/// A tag option in the Edit-tags sheet. `contains` is the focused score's
/// current membership (always false for the bulk sheet).
@WireFormat
public struct TagPickWire: Equatable, Sendable {
    public var id: String
    public var name: String
    public var contains: Bool

    public init(id: String, name: String, contains: Bool) {
        self.id = id
        self.name = name
        self.contains = contains
    }
}
