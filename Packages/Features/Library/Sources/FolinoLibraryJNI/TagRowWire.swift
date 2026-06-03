import Wirelet

/// Display projection of a tag row (Tags list): name, color, live member count.
@WireFormat
public struct TagRowWire: Equatable, Sendable {
    public var id: String // TagID UUID string
    public var name: String
    public var colorHex: String // "#RRGGBB"
    public var memberCount: Int32 // live (non-deleted) scores carrying this tag

    public init(id: String, name: String, colorHex: String, memberCount: Int32) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
        self.memberCount = memberCount
    }
}
