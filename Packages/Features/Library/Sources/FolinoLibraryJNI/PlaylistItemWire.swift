import Wirelet

/// One playlist-membership row. Order is carried by `position` (0-based),
/// mirroring the iOS GRDB `playlist_items` table. A `[String]` field cannot
/// live inside a `@WireFormat` struct, so membership is modeled as flat rows.
@WireFormat
public struct PlaylistItemWire: Equatable, Sendable {
    public var playlistId: String
    public var scoreItemId: String
    public var position: Int32

    public init(playlistId: String, scoreItemId: String, position: Int32) {
        self.playlistId = playlistId
        self.scoreItemId = scoreItemId
        self.position = position
    }
}
