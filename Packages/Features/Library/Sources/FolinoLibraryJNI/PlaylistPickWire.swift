import Wirelet

/// A playlist option in the Add-to-playlist sheet. `contains` is the focused
/// score's current membership (always false for the bulk sheet).
@WireFormat
public struct PlaylistPickWire: Equatable, Sendable {
    public var id: String
    public var name: String
    public var contains: Bool

    public init(id: String, name: String, contains: Bool) {
        self.id = id
        self.name = name
        self.contains = contains
    }
}
