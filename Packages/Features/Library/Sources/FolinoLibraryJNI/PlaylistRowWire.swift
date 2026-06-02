import Wirelet

/// Display projection of a playlist row (list screen): name + live member count.
@WireFormat
public struct PlaylistRowWire: Equatable, Sendable {
    public var id: String
    public var name: String
    public var memberCount: Int32

    public init(id: String, name: String, memberCount: Int32) {
        self.id = id
        self.name = name
        self.memberCount = memberCount
    }
}
