import Foundation

/// A manually ordered sequence of score items. v1 only supports manual playlists;
/// smart playlists arrive in v1.x.
public struct Playlist: Hashable, Sendable, Codable, Identifiable {
    public let id: PlaylistID
    public var name: String
    public var orderedScoreItemIDs: [ScoreItemID]
    public let createdAt: Date

    public init(
        id: PlaylistID = PlaylistID(),
        name: String,
        orderedScoreItemIDs: [ScoreItemID],
        createdAt: Date,
    ) {
        self.id = id
        self.name = name
        self.orderedScoreItemIDs = orderedScoreItemIDs
        self.createdAt = createdAt
    }
}
