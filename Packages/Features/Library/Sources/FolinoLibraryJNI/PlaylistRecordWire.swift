import Wirelet

/// Persistence projection of a playlist's own row (without its membership),
/// 1:1 with the iOS GRDB `playlists` table.
@WireFormat
public struct PlaylistRecordWire: Equatable, Sendable {
    public var id: String
    public var name: String
    public var createdAt: Double // Unix time (Date.timeIntervalSince1970)

    public init(id: String, name: String, createdAt: Double) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
    }
}
