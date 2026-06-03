import Wirelet

/// Persistence projection of a tag (mirrors Domain `Tag`).
@WireFormat
public struct TagRecordWire: Equatable, Sendable {
    public var id: String
    public var name: String
    public var colorHex: String

    public init(id: String, name: String, colorHex: String) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
    }
}
